import Foundation
import ManifieldCore
import ManifieldSandbox

/// Builds system prompts. Grounding rules live here in one place: agents must use the
/// project's own definitions, cite items by id, and never overstate certainty.
public enum ContextAssembly {

    public static func outline(items: [TheoryItem]) -> String {
        guard !items.isEmpty else { return "(the library is empty)" }
        let hasSections = items.contains { $0.section != nil }
        var lines: [String] = []
        for (section, sectionItems) in groupedBySection(items) {
            if hasSections {
                lines.append("§ \(TheoryItem.sectionDisplayName(section)) (section: \(section ?? "none"))")
            }
            for item in sectionItems {
                lines.append("- \(item.id) [\(item.type.rawValue), status: \(item.status.rawValue)] \(item.name)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Items grouped by section slug, sections in lexicographic order, unsectioned items last.
    public static func groupedBySection(_ items: [TheoryItem]) -> [(section: String?, items: [TheoryItem])] {
        let grouped = Dictionary(grouping: items) { $0.section }
        let sections = grouped.keys.compactMap { $0 }.sorted()
        var result: [(String?, [TheoryItem])] = sections.map { ($0, grouped[$0] ?? []) }
        if let unsectioned = grouped[nil] {
            result.append((nil, unsectioned))
        }
        return result
    }

    static var honestyRules: String { PromptLibrary.text("honesty_rules") }

    /// What counts as good mathematics. Shared with the Prover and Explorer — "prefer the
    /// proof that reveals why" shapes what they produce as much as it shapes chat. Always
    /// assembled *after* the epistemic contract, so its "none of this outranks correctness"
    /// clause has the statuses and the never-list already in front of it.
    static var mathematicalTaste: String { PromptLibrary.text("mathematical_taste") }

    /// The referee stance: attack arguments, refute before proving, separate conflated
    /// statements, and surface library inconsistencies unprompted. Chat-only — the
    /// background agents carry their own (the Reviewer's is stricter still).
    static var criticalReading: String { PromptLibrary.text("critical_reading") }

    /// Citation discipline for results that are not in the library. The guard against
    /// invented authors, years and theorem numbers.
    static var provenanceRules: String { PromptLibrary.text("provenance_rules") }

    /// Composer-mode directives injected near the top of the chat system prompt.
    public static var planModeDirective: String { PromptLibrary.text("chat_mode_plan") }
    public static var askModeDirective: String { PromptLibrary.text("chat_mode_ask") }
    /// Direct-write mode. Propose mode deliberately has no directive — the confirmation
    /// gate is the product's default and needs no explaining to the model.
    public static var autoModeDirective: String { PromptLibrary.text("chat_mode_auto") }

    /// The research memory rendered for a system prompt. Empty memory still renders
    /// (with an explicit empty marker) so agents that can write it know to start.
    static func memorySection(_ memory: String) -> String {
        PromptLibrary.text("memory_section", [
            "MEMORY": MemoryDocument.parse(markdown: memory).promptRendering
        ])
    }

    static var memoryRules: String { PromptLibrary.text("memory_rules") }

    static var latexRules: String { PromptLibrary.text("latex_rules") }

    static var checkerRules: String { PromptLibrary.text("checker_rules") }

    /// Renderer used during planning and by legacy programs. New persisted programs also receive
    /// `pinnedTargetSection`, whose frozen goal-item snapshot is the authority. Callers pass the
    /// formalized statement here after goal editing; the historical raw prompt is not repeated to
    /// workers where it could compete with that statement.
    public static func researchTargetSection(
        originalRequest: String,
        contract: SuccessContract?
    ) -> String {
        let raw = originalRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let formal = contract?.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedFormal = formal?.isEmpty == false ? formal! : raw
        let notes = contract?.ambiguities ?? []
        var section = """
        # Research goal

        **Formal statement used by this work.**

        \(renderedFormal)
        """
        if !notes.isEmpty {
            section += """


            **Interpretation notes.** These record how shorthand was formalized. They do not
            broaden, narrow, or otherwise replace the fixed statement above.

            \(notes.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        section += """


        Work on exactly this statement. A proof of impossibility, a counterexample to a requested
        assertion, an exact verified object, a classification, or another mathematically
        responsive outcome may answer it when that is what the request calls for. Do not invent
        a fixed taxonomy of acceptable answers, proof methods, or exclusions.
        """
        return section
    }

    /// Compatibility for older callers while persisted contracts may still carry the former
    /// complete-answer fields. New research code passes the raw request explicitly.
    public static func successContractSection(_ contract: SuccessContract) -> String {
        researchTargetSection(originalRequest: contract.statement, contract: contract)
    }

    /// The goal reference ordinary research workers and the director need. The historical
    /// byte-for-byte copy is deliberately not exposed here: workers operate on the named live
    /// item (whose defining fields are write-protected), while the independent scope reviewer
    /// receives `pinnedTargetSection` below when comparing a solution with the original goal.
    public static func researchGoalItemSection(_ revision: ResearchTargetRevision) -> String {
        var lines = [
            "# Research-goal item",
            "Goal revision: `\(revision.id)`",
            revision.isReviewed
                ? "Interpretation: confirmed by the user during goal review."
                : "Interpretation: automatic and not user-confirmed."
        ]
        if let itemID = revision.libraryItemID {
            var identity = "Research goal: `\(itemID)`"
                + (revision.libraryItemType.map { " [\($0.rawValue)]" } ?? "")
            if let name = revision.libraryItemName { identity += " — \(name)" }
            lines.append(identity)
        }
        lines.append("""
        Work on the formal Statement above and use the named goal item when durable results need
        to refer to it. You may add Proof or Evidence to the live goal item, but never change its
        Statement, name, or type. If a real defect makes the goal impossible as written, use
        `submit_problem_challenge`; only two accepted reviews followed by director governance can
        adopt a redefinition.

        Permanent theory items must make sense outside this program. Refer to the goal by its item
        id/name or restate the needed context; never write “the pinned request”, “the current run”,
        or similar session-relative prose. An item claiming to answer the goal should include
        `resolves: [\(revision.libraryItemID ?? "goal-item-id")]` in its frontmatter.
        """)
        return lines.joined(separator: "\n\n")
    }

    /// Compatibility name retained for callers. This is the durable research-goal item and the
    /// exact context needed to read the version selected for the program.
    public static func pinnedTargetSection(_ revision: ResearchTargetRevision) -> String {
        var lines = [
            "# Fixed research-goal item",
            "Goal revision: `\(revision.id)`",
            "Formal statement SHA-256: `\(revision.requestSHA256)`",
            revision.isReviewed
                ? "Interpretation: confirmed by the user during goal review."
                : "Interpretation: automatic and not user-confirmed."
        ]
        if let itemID = revision.libraryItemID {
            var identity = "Research goal: `\(itemID)`"
                + (revision.libraryItemType.map { " [\($0.rawValue)]" } ?? "")
            if let name = revision.libraryItemName { identity += " — \(name)" }
            lines.append(identity)
            if let digest = revision.libraryItemSHA256 {
                lines.append("Frozen goal-item SHA-256: `\(digest)`")
            }
            if let data = revision.libraryItemData,
               let markdown = String(data: data, encoding: .utf8) {
                let capped = String(markdown.prefix(16_000))
                let suffix = markdown.count > capped.count
                    ? "\n\n[Snapshot truncated after 16,000 characters; the hash covers all raw bytes.]"
                    : ""
                lines.append("Frozen goal item (authoritative for this revision):\n\n"
                    + capped + suffix)
            }
            if !revision.dependencyItemData.isEmpty {
                var remaining = 16_000
                var snapshots: [String] = []
                for id in revision.dependencyItemData.keys.sorted() where remaining > 0 {
                    guard let data = revision.dependencyItemData[id],
                          let markdown = String(data: data, encoding: .utf8) else { continue }
                    let rendered = String(markdown.prefix(min(remaining, 8_000)))
                    let digest = revision.dependencyItemSHA256[id] ?? "unknown"
                    snapshots.append("## `\(id)` (SHA-256 `\(digest)`)\n\n\(rendered)")
                    remaining -= rendered.count
                }
                lines.append("Frozen local dependencies referenced by the goal:\n\n"
                    + snapshots.joined(separator: "\n\n"))
            }
            if !revision.notationSnapshot.isEmpty {
                lines.append("Frozen notation registry:\n\n"
                    + String(revision.notationSnapshot.prefix(8_000)))
            }
            if !revision.macrosSnapshot.isEmpty {
                lines.append("Frozen LaTeX macros:\n\n"
                    + String(revision.macrosSnapshot.prefix(4_000)))
            }
        } else {
            lines.append("Legacy program: no goal item snapshot is available. Use the formal statement above.")
        }
        if !revision.recommendedReading.isEmpty || !revision.ambiguities.isEmpty {
            var interpretation = [
                "These notes describe the adopted reading of the fixed Statement; they do not "
                    + "replace, broaden, or weaken it."
            ]
            if !revision.recommendedReading.isEmpty {
                interpretation.append("Adopted reading: \(revision.recommendedReading)")
            }
            if !revision.ambiguities.isEmpty {
                interpretation.append("Material ambiguities:\n"
                    + revision.ambiguities.map { "- \($0)" }.joined(separator: "\n"))
            }
            lines.append("Formalization interpretation:\n\n"
                + interpretation.joined(separator: "\n\n"))
        }
        lines.append("""
        Every result is interpreted against this goal revision. You may add Proof or Evidence to
        the live goal item, but never change its Statement, name, or type. If a real defect makes
        the goal impossible as written, use `submit_problem_challenge`; only two accepted reviews
        followed by director governance can adopt a redefinition.

        Permanent theory items must make sense outside this program. Refer to the goal by its item
        id/name or restate the needed context; never write “the pinned request”, “the current run”,
        or similar session-relative prose. An item claiming to answer the goal should include
        `resolves: [\(revision.libraryItemID ?? "goal-item-id")]` in its frontmatter.
        """)
        return lines.joined(separator: "\n\n")
    }

    /// What the Python sandbox can actually run, with the installed package list filled in
    /// from the runtime rather than restated in prose — the two must not be able to disagree.
    /// Planners need it: the first automode run planned a "signed-relation SAT search" and an
    /// integer-programming certificate, neither of which the sandbox can execute.
    static var computeEnvironment: String {
        PromptLibrary.text("compute_environment",
                           ["PACKAGES": PythonRuntime.packages.joined(separator: ", ")])
    }

    /// Figure discipline. Loaded wherever `read_figure` is — which is every mode, since a
    /// figure's caption is already visible in the outline, and the rule that matters most
    /// ("you cannot see images") applies hardest when the agent has no way to check.
    static var figureRules: String { PromptLibrary.text("figure_rules") }

    /// One entry per attached source: a compact header line (name + top-level sections
    /// only, so large libraries don't flood the context) plus the source's overview when
    /// one exists — the briefing that lets agents judge relevance before searching.
    /// Sources with a stored full text say so — agents must know it exists to ask for
    /// it — but the text itself is never injected; it flows only through the gated
    /// fulltext tools.
    static func sourcesSection(
        attached: [(slug: String, store: ProjectStore)],
        fulltextGranted: Set<String> = [],
        fulltextToolsAvailable: Bool = false
    ) -> String {
        var lines: [String] = []
        for (slug, store) in attached {
            let topSections = Set(store.items.compactMap { $0.section?.split(separator: "/").first })
                .map(String.init).sorted()
            var line = "- \(slug) — \(store.meta.name)"
            if let citation = store.meta.citation { line += " (\(citation))" }
            line += " — \(store.items.count) items"
            // Named here as well as in the search tools: relevance is judged from this
            // listing, and "the paper is in Polish" is part of knowing how to query it.
            let itemsLanguage = store.index.language(of: .items)
            if let itemsLanguage { line += " in \(itemsLanguage.name)" }
            if !topSections.isEmpty { line += "; sections: \(topSections.joined(separator: ", "))" }
            if let info = store.fulltextInfo {
                var fulltext = "full text on file (\(info.unitLabel)"
                // Only worth repeating when the two differ — an English abstract over a
                // Polish body, or items translated during import.
                if let language = store.index.language(of: .fulltext),
                   language != itemsLanguage {
                    fulltext += ", in \(language.name)"
                }
                fulltext += ")"
                if fulltextGranted.contains(slug) {
                    line += "; \(fulltext) — access GRANTED"
                } else if fulltextToolsAvailable {
                    line += "; \(fulltext) — locked, ask via request_fulltext_access"
                } else {
                    line += "; \(fulltext) — not accessible in this run"
                }
            }
            lines.append(line)
            let overview = store.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overview.isEmpty {
                let indented = SourceOverview.truncate(overview, SourceOverview.maxLength)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  \($0)" }
                    .joined(separator: "\n")
                lines.append("  Overview:\n\(indented)")
            }
        }
        var section = PromptLibrary.text("sources_section", [
            "SOURCE_LINES": lines.joined(separator: "\n")
        ])
        if fulltextToolsAvailable, attached.contains(where: { $0.store.hasFulltext }) {
            section += "\n\n" + PromptLibrary.text("fulltext_rules")
        }
        return section
    }

    /// The project's own kept files (`documents/`). Agents must know a file exists to be
    /// able to ask for it, so every one is listed with whether it can be read right now;
    /// the text itself only ever flows through the gated document tools. The reading rules
    /// are appended only where those tools exist.
    public static func documentsSection(
        documents: [ProjectDocument],
        granted: Set<String> = [],
        toolsAvailable: Bool = false,
        index: SearchIndex? = nil
    ) -> String {
        var lines: [String] = []
        for document in documents {
            var line = "- \(document.slug) — \(document.meta.title)"
            var format = document.formatLabel
            // The file's language belongs next to its format: it is what search_documents
            // has to be queried in.
            if let language = index?.language(of: .document(document.slug)) {
                format += format.isEmpty ? language.name : ", \(language.name)"
            }
            if !format.isEmpty { line += " (\(format))" }
            if let note = document.meta.note, !note.isEmpty { line += " — \(note)" }
            if !document.isSearchable {
                line += "; no extractable text — you cannot read this one (the user can OCR it)"
            } else if granted.contains(document.slug) {
                line += "; readable — access GRANTED"
            } else if toolsAvailable {
                line += "; readable — locked, ask via request_document_access"
            } else {
                line += "; not accessible in this run"
            }
            lines.append(line)
        }
        var section = PromptLibrary.text("documents_section", [
            "DOCUMENT_LINES": lines.joined(separator: "\n")
        ])
        if toolsAvailable, documents.contains(where: \.isSearchable) {
            section += "\n\n" + PromptLibrary.text("document_rules")
        }
        return section
    }

    /// The item the user pinned to the chat, rendered in full so Prismo centres the
    /// conversation on it without having to fetch it first.
    static func focusedItemSection(_ item: TheoryItem) -> String {
        var header = "\(item.id) [\(item.type.rawValue), status: \(item.status.rawValue)] — \(item.name)"
        if !item.dependsOn.isEmpty {
            header += "\ndepends on: \(item.dependsOn.joined(separator: ", "))"
        }
        return PromptLibrary.text("focused_item", [
            "ITEM_HEADER": header,
            "ITEM_BODY": item.body
        ])
    }

    public static func chatSystemPrompt(
        projectName: String,
        notation: String,
        items: [TheoryItem],
        /// What to call the user. Chat-only by design — see `AppSettings.userName`.
        userName: String = "",
        userProfile: String,
        checkerAvailable: Bool = false,
        figureToolsAvailable: Bool = false,
        attachedSources: [(slug: String, store: ProjectStore)] = [],
        fulltextGranted: Set<String> = [],
        fulltextToolsAvailable: Bool = false,
        documents: [ProjectDocument] = [],
        documentsGranted: Set<String> = [],
        documentToolsAvailable: Bool = false,
        /// The project's index, consulted only for the language each kept file is written in.
        documentIndex: SearchIndex? = nil,
        focusedItems: [TheoryItem] = [],
        memory: String? = nil,
        modeDirective: String? = nil,
        branchContext: String? = nil
    ) -> SystemPrompt {
        // Two groups, and which one a section lands in is a caching decision, not a
        // stylistic one: `instructions` ends the cached prefix, so nothing a turn can
        // rewrite may go there. The rule is "can this change as a side effect of a turn?"
        // — memory, grants, the outline and pinned items all can, the prompt fragments
        // and the settings-level profile cannot.
        var instructions: [String] = []
        var context: [String] = []

        instructions.append(PromptLibrary.text("chat_system", ["PROJECT_NAME": projectName]))
        if let modeDirective { instructions.append(modeDirective) }
        instructions.append(honestyRules)
        instructions.append(mathematicalTaste)
        // Loaded in every mode, ask included: ask mode is exactly where a proof gets
        // pasted for discussion, and reading it critically needs no write tools.
        instructions.append(criticalReading)
        instructions.append(provenanceRules)
        instructions.append(PromptLibrary.text("communication_rules"))
        // The discipline is a fixed rule; only the memory it governs is per-turn.
        if memory != nil { instructions.append(memoryRules) }
        if checkerAvailable { instructions.append(checkerRules) }
        if figureToolsAvailable { instructions.append(figureRules) }
        instructions.append(latexRules)
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = userProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty || !profile.isEmpty {
            var about = ["About the user:"]
            if !name.isEmpty {
                // The second sentence earns its place: told only a name, models open every
                // reply with it, which reads as salesmanship rather than familiarity.
                about.append("""
                Their name is \(name). Use it the way a colleague would — occasionally, \
                where it lands naturally, not in every message.
                """)
            }
            if !profile.isEmpty {
                about.append("""
                Adapt your explanations, examples and level of detail to this:
                \(profile)
                """)
            }
            instructions.append(about.joined(separator: "\n"))
        }

        if let memory { context.append(memorySection(memory)) }
        if let branchContext, !branchContext.isEmpty {
            context.append(PromptLibrary.text("chat_branch_context", ["BRANCH": branchContext]))
        }
        if !attachedSources.isEmpty {
            // The reading rules ride along with the listing they qualify: a grant flips a
            // line in that listing, so the two invalidate together anyway.
            context.append(sourcesSection(
                attached: attachedSources,
                fulltextGranted: fulltextGranted,
                fulltextToolsAvailable: fulltextToolsAvailable))
        }
        if !documents.isEmpty {
            context.append(documentsSection(
                documents: documents,
                granted: documentsGranted,
                toolsAvailable: documentToolsAvailable,
                index: documentIndex))
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            context.append("Project notation registry:\n\(notation)")
        }
        context.append("Library outline:\n\(outline(items: items))")
        for item in focusedItems { context.append(focusedItemSection(item)) }

        return SystemPrompt(
            instructions: instructions.joined(separator: "\n\n"),
            projectContext: context.joined(separator: "\n\n"))
    }
}
