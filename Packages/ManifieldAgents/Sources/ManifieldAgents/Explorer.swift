import Foundation
import ManifieldCore

/// The Explorer proposes NEW candidate theory (conjectures, occasionally definitions)
/// extending the project — in a user-given direction or open-ended. Candidates are
/// numerically pre-screened where feasible and delivered through the standard
/// propose_theory_edit flow, so the user triages each one like any agent edit.
public enum Explorer {

    public static func systemPrompt(
        notation: String,
        items: [TheoryItem],
        userProfile: String,
        candidateCount: Int,
        memory: String = ""
    ) -> String {
        var parts: [String] = []
        parts.append(PromptLibrary.text("explorer_system", [
            "CANDIDATE_COUNT": String(candidateCount)
        ]))
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.mathematicalTaste)
        if !MemoryDocument.parse(markdown: memory).isEmpty {
            parts.append(ContextAssembly.memorySection(memory))
        }
        parts.append(ContextAssembly.latexRules)
        if !userProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("About the user (aim candidates at their interests): \(userProfile)")
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(ContextAssembly.outline(items: items))")
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(direction: String) -> String {
        let trimmed = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Explore open-ended: propose the most promising new candidates you can find in this theory."
            : "Explore in this direction: \(trimmed)"
    }
}

// MARK: - Per-task model selection

/// The distinct agent jobs a user may want to run on different models
/// (e.g. a cheap model for importing an easy file, a strong one for proving).
public enum AgentTask: String, CaseIterable, Identifiable, Sendable {
    case chat
    case chatNaming
    case importer
    case prover
    case reviewer
    case explorer
    case planner
    /// Decides what a research program does when a generation stops, or when a confirmed
    /// counterexample interrupts one. Separately configurable from the planner, but
    /// inherits its model until it is given one — that is what it ran on before.
    case director
    case researcher

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .chatNaming: return "Chat Naming"
        case .importer: return "Import / Organizer"
        case .prover: return "Prover"
        case .reviewer: return "Reviewer"
        case .explorer: return "Explorer"
        case .planner: return "Planner"
        case .director: return "Research Director"
        case .researcher: return "Researcher"
        }
    }

    /// One line for the roles table in Settings — what this model is actually deciding.
    public var roleSummary: String {
        switch self {
        case .chat: return "Your conversation with Prismo."
        case .chatNaming: return "Titles a new chat. Deliberately light."
        case .importer: return "Turns imported documents into theory items."
        case .prover: return "Writes proofs. Also the model a research branch marked “strong” runs on."
        case .reviewer: return "Checks proofs in clean context, and adjudicates counterexample claims. Never weaker than what it judges."
        case .explorer: return "Suggests items and connections in the library."
        case .planner: return "Designs the portfolio of approaches, and plans each branch."
        case .director: return "Decides whether a program continues, is settled, or is futile — and what the next generation attacks."
        case .researcher: return "Executes research branches. This is where the mathematics gets done."
        }
    }

    /// How hard each role thinks by default — allocated like a mathematician's attention:
    /// deep for planning, proving and reviewing, medium for exploration and research
    /// steps, light for chat, none for mechanical restructuring. Users can override per
    /// task in Settings.
    public var defaultThinkingLevel: ThinkingLevel {
        switch self {
        case .chat: return .low
        case .chatNaming: return .off
        case .importer: return .off
        case .prover: return .high
        case .reviewer: return .high
        case .explorer: return .medium
        case .planner: return .high
        case .director: return .high
        case .researcher: return .medium
        }
    }
}

/// A concrete (provider, model) pair chosen for a task.
public struct ModelChoice: Codable, Equatable, Sendable {
    public var kind: ProviderKind
    public var model: String

    public init(kind: ProviderKind, model: String) {
        self.kind = kind
        self.model = model
    }
}

/// A selectable model: the raw id sent to the provider, paired with a short display name.
public enum ModelInputModality: String, Hashable, Sendable {
    case text, image, audio
}

public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let inputModalities: Set<ModelInputModality>
    public let supportedReasoningEfforts: [String]
    public let defaultReasoningEffort: String?

    public init(
        id: String, displayName: String,
        inputModalities: Set<ModelInputModality> = [.text],
        supportedReasoningEfforts: [String] = [],
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.inputModalities = inputModalities
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// Suggested models per provider, strongest first. Feeds the model pickers in Settings
/// and per-task menus.
public enum ModelCatalog {
    public static func suggested(for kind: ProviderKind) -> [ModelOption] {
        switch kind {
        case .anthropic:
            return [
                ModelOption(id: "claude-opus-4-8", displayName: "Opus 4.8"),
                ModelOption(id: "claude-sonnet-5", displayName: "Sonnet 5"),
                ModelOption(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")
            ]
        case .openai:
            return [
                ModelOption(id: "gpt-5", displayName: "GPT-5"),
                ModelOption(id: "gpt-5-mini", displayName: "GPT-5 Mini"),
                ModelOption(id: "gpt-5-nano", displayName: "GPT-5 Nano")
            ]
        case .gemini:
            return [
                ModelOption(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro"),
                ModelOption(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash")
            ]
        case .xai:
            return [
                ModelOption(id: "grok-4", displayName: "Grok 4"),
                ModelOption(id: "grok-4-fast", displayName: "Grok 4 Fast"),
                ModelOption(id: "grok-code-fast-1", displayName: "Grok Code Fast 1")
            ]
        case .zai:
            return [
                ModelOption(id: "glm-5.2", displayName: "GLM-5.2"),
                ModelOption(id: "glm-5.1", displayName: "GLM-5.1"),
                ModelOption(id: "glm-4.6", displayName: "GLM-4.6"),
                ModelOption(id: "glm-4.5-air", displayName: "GLM-4.5 Air")
            ]
        case .nvidia:
            return [
                ModelOption(id: "nvidia/nemotron-3-ultra-550b-a55b", displayName: "Nemotron 3 Ultra"),
                ModelOption(id: "nvidia/nemotron-3-super-120b-a12b", displayName: "Nemotron 3 Super"),
                ModelOption(id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B"),
                ModelOption(id: "meta/llama-3.3-70b-instruct", displayName: "Llama 3.3 70B")
            ]
        case .codex:
            // The live catalog (`CodexServer.listModels`) is what actually reflects the signed-in
            // account, since availability differs by ChatGPT plan; this is only the fallback
            // shown before that has loaded, or if it fails.
            return [
                ModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
                ModelOption(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
                ModelOption(id: "gpt-5.5", displayName: "GPT-5.5"),
                ModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini")
            ]
        }
    }
}
