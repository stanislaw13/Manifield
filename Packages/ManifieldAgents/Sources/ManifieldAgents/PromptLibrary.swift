import Foundation

public enum PromptError: LocalizedError, Equatable {
    case missing(String)
    case unresolvedPlaceholder(template: String, key: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "Prompt template '\(name).md' is missing from the ManifieldAgents bundle."
        case .unresolvedPlaceholder(let template, let key):
            return "Prompt template '\(template).md' has an unresolved placeholder {{\(key)}}."
        }
    }
}

/// A markdown prompt fragment with `{{UPPER_SNAKE}}` placeholders.
public struct PromptTemplate: Sendable {
    public let name: String
    public let raw: String

    /// Substitutes every placeholder; throws if any `{{KEY}}` remains afterwards,
    /// so a typo in a template or a forgotten value fails loudly instead of being
    /// sent to a model.
    public func render(_ values: [String: String] = [:]) throws -> String {
        var text = raw
        for (key, value) in values {
            text = text.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        if let key = Self.placeholders(in: text).first {
            throw PromptError.unresolvedPlaceholder(template: name, key: key)
        }
        return text
    }

    /// Placeholder keys present in the text, in order of appearance.
    static func placeholders(in text: String) -> [String] {
        var keys: [String] = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: #"\{\{[A-Z][A-Z0-9_]*\}\}"#,
                                     options: .regularExpression, range: search) {
            keys.append(String(text[range].dropFirst(2).dropLast(2)))
            search = range.upperBound..<text.endIndex
        }
        return keys
    }
}

/// Loads prompt fragments from the bundled `Prompts/` markdown resources. Prompts live
/// in markdown so they can be read, edited and diffed without touching Swift; all
/// conditional composition stays in the Swift prompt builders.
public enum PromptLibrary {

    /// Every template and the exact placeholder set it must contain.
    /// `validateAll()` checks the manifest at app startup.
    static let manifest: [String: Set<String>] = [
        "chat_system": ["PROJECT_NAME"],
        "communication_rules": [],
        "chat_naming": [],
        "honesty_rules": [],
        "mathematical_taste": [],
        "critical_reading": [],
        "provenance_rules": [],
        "latex_rules": [],
        "checker_rules": [],
        "figure_rules": [],
        "sources_section": ["SOURCE_LINES"],
        "fulltext_rules": [],
        "documents_section": ["DOCUMENT_LINES"],
        "document_rules": [],
        "focused_item": ["ITEM_HEADER", "ITEM_BODY"],
        "memory_section": ["MEMORY"],
        "memory_rules": [],
        "chat_mode_plan": [],
        "chat_mode_ask": [],
        "chat_mode_auto": [],
        "researcher_task_system": [],
        "run_reconciliation": [],
        "approach_ontology": [],
        "program_planner_system": [],
        "branch_planner_system": [],
        "branch_lens": ["LENS", "ROLE", "KILL"],
        "branch_guidance": ["GUIDANCE"],
        "chat_branch_context": ["BRANCH"],
        "program_shared_facts": ["FACTS", "FINDINGS"],
        "program_synthesis": [],
        "organizer_system": ["TYPE_LIST"],
        "organizer_existing_items": ["OUTLINE"],
        "organizer_taken_ids": ["IDS"],
        "organizer_source_system": ["CITATION_SUFFIX", "CHUNK_SECTION", "TYPE_LIST"],
        "organizer_metadata": [],
        "organizer_instructions": ["USER_INSTRUCTIONS"],
        "organizer_section_detect": ["CHUNK_SECTION", "KNOWN_SECTIONS"],
        "organizer_chunk_boundary": ["BOUNDARY_NOTES"],
        "link_pass_system": ["CATALOG"],
        "source_overview_system": [],
        "prover_system": [],
        "prover_policy_restricted": [],
        "prover_policy_auto": [],
        "prover_output": [],
        "reviewer_system": [],
        "explorer_system": ["CANDIDATE_COUNT"],
        "compute_environment": ["PACKAGES"],
        "replan_system": [],
        "success_contract": ["STATEMENT", "COMPLETE_ANSWERS", "COMPLETENESS",
                             "AMBIGUITIES", "NOT_COUNTED"],
        "research_goal_editor": [],
        "statement_auditor": [],
        "contract_drafter": [],
        "pilot_selector": ["ROLES", "REQUIRED"],
        "pilot_system": ["DIRECTIVE"],
        "director_system": [],
        "finding_routing": [],
        "finding_adjudicator": [],
        "solution_adjudicator": [],
        "solution_assembly_reviewer": []
    ]

    public static func template(_ name: String) throws -> PromptTemplate {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md",
                                          subdirectory: "Prompts"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw PromptError.missing(name)
        }
        // Editors keep a trailing newline in the files; prompt fragments are joined
        // with explicit separators by the builders, so strip it for stable output.
        var text = raw
        while text.hasSuffix("\n") { text.removeLast() }
        return PromptTemplate(name: name, raw: text)
    }

    /// Non-throwing render for the prompt builders (whose public API is non-throwing).
    /// A failure yields a loud inline marker; `validateAll()` at app startup is the
    /// gate that should have caught it first.
    static func text(_ name: String, _ values: [String: String] = [:]) -> String {
        do {
            return try template(name).render(values)
        } catch {
            return "[PROMPT TEMPLATE ERROR — \(error.localizedDescription)]"
        }
    }

    /// Checks that every manifest template exists and contains exactly the expected
    /// placeholders. Returns human-readable problems (empty when all is well).
    public static func validateAll() -> [String] {
        var problems: [String] = []
        for (name, expected) in manifest.sorted(by: { $0.key < $1.key }) {
            do {
                let loaded = try template(name)
                let found = Set(PromptTemplate.placeholders(in: loaded.raw))
                if found != expected {
                    problems.append(
                        "\(name).md: placeholders \(found.sorted()) do not match expected \(expected.sorted())"
                    )
                }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return problems
    }
}
