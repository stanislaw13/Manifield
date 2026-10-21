import Foundation
import CryptoKit
import ManifieldCore

/// Reviews a solution candidate that has already passed contract adjudication.
///
/// Two levels, and the second is not optional.
///
/// **Item level, with reuse.** Each cited item and everything in its dependency closure is
/// reviewed, unless an earlier review already covered that exact content *and* that exact
/// closure. Hashing both is what makes reuse safe: a lemma whose own text is untouched but
/// whose dependency was re-stated underneath it is not the lemma that was reviewed.
///
/// **Assembly level, never reused.** Every candidate gets a fresh-context review of the whole
/// argument even when every part already carries a valid review. "All dependency nodes were
/// individually reviewed" must never imply "the submitted solution was reviewed" — the parts
/// can each be correct while the combination invokes one of them outside its hypotheses,
/// skips a boundary case, silently changes a convention between two items, or simply does not
/// close. That failure is invisible at item level by construction, because no item-level
/// review ever sees the combination.
public enum SolutionReviewGate {

    /// Reviews already known good, keyed by item id, valued by the closure hash they were
    /// performed against. Persisted on the program so a re-claim of unchanged work is cheap.
    public typealias ReviewCache = [String: String]

    /// A content hash of an item plus everything it transitively depends on. Two items with
    /// the same closure hash are the same mathematics, so a review of one transfers.
    public static func closureHash(
        itemID: String, items: [String: TheoryItem], visiting: Set<String> = []
    ) -> String {
        guard !visiting.contains(itemID), let item = items[itemID] else { return "missing:\(itemID)" }
        let next = visiting.union([itemID])
        let dependencies = item.dependsOn.sorted()
            .map { closureHash(itemID: $0, items: items, visiting: next) }
        return "\(itemID):\(contentHash(item))[\(dependencies.joined(separator: ","))]"
    }

    /// What must not have changed for a review to still hold. Status is included: an item
    /// downgraded to `conjecture` under a proof that cited it is exactly the change a stale
    /// cache would hide.
    public static func contentHash(_ item: TheoryItem) -> String {
        // Stable across processes: persisted review caches must survive app restart.
        // Status has a fixed vocabulary; a NUL separates it from the complete body.
        let data = Data((item.status.rawValue + "\0" + item.body).utf8)
        return "sha256-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every item the candidate rests on, in dependency order, deduplicated.
    public static func closure(of candidate: SolutionCandidate,
                               items: [String: TheoryItem]) -> [TheoryItem] {
        var seen = Set<String>()
        var ordered: [TheoryItem] = []
        func walk(_ id: String) {
            guard !seen.contains(id), let item = items[id] else { return }
            seen.insert(id)
            for dependency in item.dependsOn.sorted() { walk(dependency) }
            ordered.append(item)
        }
        for id in candidate.citedItemIDs { walk(id) }
        return ordered
    }

    /// Runs the gate. `reviewAssembly` is separate from `verifier` because it is a different
    /// question asked of a different prompt — and because making it a distinct injected step
    /// is what stops it from being quietly skipped when the cache is warm.
    public static func review(
        candidate: SolutionCandidate,
        goal: String,
        contract: SuccessContract?,
        items: [TheoryItem],
        cache: ReviewCache,
        verifier: ProofVerifier?,
        reviewAssembly: @Sendable ([TheoryItem], SolutionCandidate) async throws -> (accepted: Bool, note: String),
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> (ruling: SolutionCandidate.ReviewRuling, cache: ReviewCache) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chain = closure(of: candidate, items: byID)

        var updatedCache = cache
        var reviewed: [String] = []
        var itemProblems: [String] = []

        for item in chain {
            let hash = closureHash(itemID: item.id, items: byID)
            if cache[item.id] == hash {
                // Same content, same closure: the earlier review still says what it said.
                reviewed.append(item.id)
                continue
            }
            guard let verifier, let proof = item.proof, !proof.isEmpty else {
                // Nothing to review at item level — a definition, or an item carrying no
                // proof. The assembly review still sees it, which is where an unproved
                // dependency actually shows up as a hole.
                continue
            }
            let result = try await verifier.review(
                target: item, proofMarkdown: proof, onActivity: onActivity)
            reviewed.append(item.id)
            if result.verdict == .noErrorsFound {
                updatedCache[item.id] = hash
            } else {
                updatedCache[item.id] = nil
                itemProblems.append("`\(item.id)`: " + result.issues
                    .map { "\($0.severity) at \($0.location) — \($0.description)" }
                    .joined(separator: "; "))
            }
        }

        // Runs even when every item above was cached clean. This is the whole point of the
        // second level, so it is deliberately outside every early return.
        let assembly = try await reviewAssembly(chain, candidate)

        let accepted = itemProblems.isEmpty && assembly.accepted
        var note: String
        if !itemProblems.isEmpty {
            note = "Review found problems in the cited mathematics:\n"
                + itemProblems.map { "- \($0)" }.joined(separator: "\n")
            if !assembly.accepted {
                note += "\n\nThe assembled argument was also rejected: \(assembly.note)"
            }
        } else if !assembly.accepted {
            note = "Every cited item reviewed clean, but the assembled argument does not "
                + "close: \(assembly.note)"
        } else {
            note = "All \(reviewed.count) cited item(s) reviewed with no errors found, and the "
                + "assembled argument closes. This is review, not human approval or formal "
                + "verification."
        }

        return (SolutionCandidate.ReviewRuling(
            accepted: accepted,
            note: note,
            itemsReviewed: reviewed,
            assemblyNote: assembly.note), updatedCache)
    }

    // MARK: - The assembly reviewer

    public static func assemblySystemPrompt(
        goal: String, contract: SuccessContract?, chain: [TheoryItem]
    ) -> String {
        var parts = [PromptLibrary.text("solution_assembly_reviewer")]
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))
        parts.append("The full chain, in dependency order:\n\n" + chain.map { item in
            var block = "### `\(item.id)` [\(item.status.rawValue)] \(item.name)\n\(item.body)"
            if !item.dependsOn.isEmpty {
                block += "\n\nDepends on: \(item.dependsOn.joined(separator: ", "))"
            }
            return block
        }.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    /// One assembly review turn. Deliberately gets no memory, no taste framing and no lens —
    /// the same thin context every judging agent in this system runs on.
    public static func reviewAssembly(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        chain: [TheoryItem],
        candidate: SolutionCandidate,
        tools: [AgentTool] = [],
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> (accepted: Bool, note: String) {
        let signals = AssemblyReviewSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(assemblySystemPrompt(
                goal: goal, contract: contract, chain: chain)),
            tools: tools + [ReportAssemblyReviewTool(signals: signals)],
            maxIterations: 14,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user("""
            The claim is that these items together answer the question. The branch's own \
            account of why:

            \(candidate.argument)

            Check the assembly. Call report_assembly_review once.
            """)],
            programID: programID, role: .assemblyReview, subjectID: candidate.id,
            title: "Do \(chain.count) item(s) combine into an answer?",
            record: record,
            outcome: { _ in
                guard let ruling = signals.ruling else { return "no ruling" }
                return (ruling.accepted ? "closes" : "does not close")
                    + " — \(ruling.note.prefix(180))"
            },
            onActivity: onActivity)
        // No ruling is not an acceptance. An assembly nobody managed to check is exactly the
        // state this gate exists to keep out of an "accepted" verdict.
        return signals.ruling ?? (false, "the assembly review produced no ruling")
    }
}

final class AssemblyReviewSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _ruling: (accepted: Bool, note: String)?
    var ruling: (accepted: Bool, note: String)? {
        lock.lock(); defer { lock.unlock() }; return _ruling
    }
    func set(accepted: Bool, note: String) {
        lock.lock(); _ruling = (accepted, note); lock.unlock()
    }
}

struct ReportAssemblyReviewTool: AgentTool {
    var turnEffect: AgentToolEffect { .finish }
    let signals: AssemblyReviewSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "report_assembly_review",
            description: """
            Record whether the cited items, taken together, actually establish the claimed \
            answer — every dependency invoked under its real hypotheses, no case or range \
            omitted, no convention shifting between items, and the conclusion following.
            """,
            inputSchemaJSON: #"""
            {"type":"object","properties":{
            "verdict":{"type":"string","enum":["closes","does_not_close"]},
            "note":{"type":"string","description":"Closes: what the chain establishes and the step you checked hardest. Does not close: the exact gap — which item is applied outside its hypotheses, which case is missing, which convention changed and where."}},
            "required":["verdict","note"]}
            """#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let verdict = input["verdict"] as? String,
              ["closes", "does_not_close"].contains(verdict) else {
            throw ResearchError(message: "'verdict' must be 'closes' or 'does_not_close'")
        }
        guard let note = (input["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            throw ResearchError(message: "missing 'note' — name what you checked, or the gap")
        }
        signals.set(accepted: verdict == "closes", note: String(note.prefix(1500)))
        return "Assembly review recorded. End your turn."
    }
}
