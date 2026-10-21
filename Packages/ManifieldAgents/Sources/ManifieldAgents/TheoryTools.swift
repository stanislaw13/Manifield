import Foundation
import ManifieldCore

/// A proposal produced by `propose_theory_edit`. It is never written to disk directly —
/// the UI shows it to the user for confirmation first (human-in-the-loop writes).
/// Proposals are persisted per project so closing the review sheet (or the app) never
/// loses them.
public struct TheoryProposal: Identifiable, Sendable, Codable {
    public enum Action: String, Sendable, Codable { case create, update }
    public var id: UUID
    public let action: Action
    public let item: TheoryItem
    public let createdAt: Date
    /// For a figure proposed by `save_figure`: the sandbox run holding the image, which
    /// is copied into `figures/` only when the user accepts. Proposing must not write
    /// files, and a rejected figure must not leave one behind.
    public let figureSource: String?

    public init(
        action: Action,
        item: TheoryItem,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        figureSource: String? = nil
    ) {
        self.id = id
        self.action = action
        self.item = item
        self.createdAt = createdAt
        self.figureSource = figureSource
    }
}

public enum TheoryTools {

    /// Agent tool arguments are JSON. A single LaTeX backslash before `t`, `b`, `f`, `r`,
    /// or another JSON escape can decode into an invisible control byte and silently corrupt
    /// the saved mathematics. Reject the decoded payload before parsing; only ordinary line
    /// feeds are valid controls in a Markdown theory item.
    static func validateAgentMarkdown(_ markdown: String) throws {
        guard let scalar = markdown.unicodeScalars.first(where: {
            ($0.value < 0x20 && $0.value != 0x0A) || $0.value == 0x7F
        }) else { return }
        let code = String(format: "U+%04X", scalar.value)
        throw AgentError.badResponse("""
        REJECTED — theory-item markdown contains unsafe control character \(code). This often \
        means a LaTeX backslash was not escaped in the JSON tool argument. Retry with every \
        LaTeX backslash doubled in JSON (for example, `\\\\to` or `\\\\varnothing`). Nothing was written.
        """)
    }

    /// The Phase-1 tool set for the chat agent.
    public static func chatTools(
        store: ProjectStore,
        onProposal: @escaping @Sendable (TheoryProposal) -> Void
    ) -> [AgentTool] {
        readOnlyTools(store: store) + [ProposeTheoryEditTool(store: store, onProposal: onProposal)]
    }

    /// Auto-mode chat: the same surface, but the write lands immediately. `apply` returns
    /// the confirmation string the agent sees, and is where the host journals the write.
    public static func autoChatTools(
        store: ProjectStore,
        apply: @escaping @Sendable (TheoryProposal) async throws -> String
    ) -> [AgentTool] {
        readOnlyTools(store: store) + [ChatWriteTheoryItemTool(store: store, apply: apply)]
    }

    /// Read-only subset for agents that must not write (prover, reviewer).
    public static func readOnlyTools(store: ProjectStore) -> [AgentTool] {
        [
            SearchTheoryTool(store: store),
            ReadTheoryItemTool(store: store),
            ListTheoryTool(store: store)
        ]
    }

    /// Figures are asset-backed, so the generic write tools handle them differently:
    ///
    /// - **Creation is refused.** These tools take markdown, and there is no way to put an
    ///   image in `figures/` through markdown. A figure created here would be an empty
    ///   frame with a caption. `save_figure` is the way in.
    /// - **On update, the asset fields are restored from disk** whatever the model wrote.
    ///   Editing a caption or what a figure illustrates is fine; repointing a figure at a
    ///   different file is not something an agent that cannot see images should be doing,
    ///   and dropping the `image:` line by accident would break the figure silently.
    static func reconcileFigure(
        _ item: inout TheoryItem, action: TheoryProposal.Action, store: ProjectStore
    ) throws {
        guard item.isFigure else { return }
        guard action == .update else {
            throw AgentError.badResponse("""
            REJECTED — a figure cannot be created this way: it needs an image, and this tool \
            only takes markdown. Render the picture with create_visualization, then keep it \
            with save_figure.
            """)
        }
        guard let existing = store.item(id: item.id) else { throw CoreError.itemNotFound(item.id) }
        guard existing.isFigure else {
            throw AgentError.badResponse(
                "REJECTED — '\(item.id)' is a \(existing.type.rawValue); changing an item's type to figure is not something this tool can do.")
        }
        item.image = existing.image
        item.generator = existing.generator
        item.status = .illustration
    }
}

struct SearchTheoryTool: AgentTool {
    let store: ProjectStore

    /// The library is written in one language, which need not be the conversation's.
    private var corpora: [SearchLanguage.Corpus] {
        [SearchLanguage.Corpus(label: "the library", language: store.index.language(of: .items))]
    }

    var spec: ToolSpec {
        ToolSpec(
            name: "search_theory",
            description: "Full-text search over the project's theorems, lemmas, definitions, conjectures and remarks. Returns matching item ids with snippets. Use before answering questions about the theory.\(SearchLanguage.rule(corpora))",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Search terms (plain words, no operators), in the language the library is written in"}},"required":["query"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let query = jsonObject(inputJSON)["query"] as? String ?? ""
        let hits = try store.index.search(query)
        guard !hits.isEmpty else {
            return "No matches for '\(query)'.\(SearchLanguage.emptyHint(corpora)) Try list_theory to see everything."
        }
        return hits.map { "\($0.id) — \($0.name)\n  …\($0.snippet)…" }.joined(separator: "\n")
    }
}

struct ReadTheoryItemTool: AgentTool {
    let store: ProjectStore

    var spec: ToolSpec {
        ToolSpec(
            name: "read_theory_item",
            description: "Read one theory item in full (frontmatter metadata, statement, proof) by its id.",
            inputSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Item id, e.g. lem-degree-bound"}},"required":["id"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let id = jsonObject(inputJSON)["id"] as? String ?? ""
        guard let item = store.item(id: id) else {
            throw CoreError.itemNotFound(id)
        }
        return item.serialized()
    }
}

struct ListTheoryTool: AgentTool {
    let store: ProjectStore

    var spec: ToolSpec {
        ToolSpec(
            name: "list_theory",
            description: "List every item in the project grouped by section: id, type, trust status, name and dependencies.",
            inputSchemaJSON: #"{"type":"object","properties":{}}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        guard !store.items.isEmpty else { return "The project has no theory items yet." }
        var lines: [String] = []
        for (section, items) in ContextAssembly.groupedBySection(store.items) {
            lines.append("§ \(TheoryItem.sectionDisplayName(section)) (section: \(section ?? "none"))")
            for item in items {
                var line = "- \(item.id) [\(item.type.rawValue), \(item.status.rawValue)] \(item.name)"
                if !item.dependsOn.isEmpty {
                    line += " (depends on: \(item.dependsOn.joined(separator: ", ")))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Chat's direct-write tool for Auto mode. Mirrors the research runner's
/// `write_theory_item`, including the trust-ladder guard: agents may write the lower rungs
/// of the ladder and never the two a human owns.
struct ChatWriteTheoryItemTool: AgentTool {
    let store: ProjectStore
    let apply: @Sendable (TheoryProposal) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "write_theory_item",
            description: "Create or update a theory item DIRECTLY — this conversation is in auto mode, so there is no confirmation step and the change lands as soon as you call this. Provide the complete item file: YAML frontmatter (id, type, name, status, depends_on, resolves, tags, section) followed by markdown body with '## Statement' and optionally '## Proof'/'## Evidence'. Use resolves for research-goal item ids this result answers. Allowed statuses: conjecture, tested, proof-drafted, reviewed-no-errors — the rest of the trust ladder is set by humans only. Tell the user about every write in your reply.",
            inputSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update"],"description":"create a new item or update an existing one"},"markdown":{"type":"string","description":"Complete item file content: frontmatter + body"}},"required":["action","markdown"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let obj = jsonObject(inputJSON)
        let actionRaw = obj["action"] as? String ?? "create"
        guard let action = TheoryProposal.Action(rawValue: actionRaw) else {
            throw AgentError.badResponse("action must be 'create' or 'update'")
        }
        guard let markdown = obj["markdown"] as? String else {
            throw AgentError.badResponse("missing 'markdown'")
        }
        try TheoryTools.validateAgentMarkdown(markdown)
        var item = try TheoryItem.parse(markdown: markdown)
        try TheoryTools.reconcileFigure(&item, action: action, store: store)

        // Reconciliation pins a figure to `illustration`, which is not on the ladder.
        guard item.isFigure || TheoryWritePolicy.agentSettableStatuses.contains(item.status) else {
            let allowed = TheoryWritePolicy.agentSettableStatuses
                .map(\.rawValue).sorted().joined(separator: ", ")
            throw AgentError.badResponse("""
            REJECTED — status '\(item.status.rawValue)' can only be set by a human. \
            Agents may set: \(allowed). Write the item with an honest agent-settable \
            status; the user promotes it later.
            """)
        }
        if action == .update, store.item(id: item.id) == nil {
            throw CoreError.itemNotFound(item.id)
        }
        if action == .create, store.item(id: item.id) != nil {
            throw AgentError.badResponse("id '\(item.id)' already exists; use action=update or pick a new id")
        }
        return try await apply(TheoryProposal(action: action, item: item))
    }
}

struct ProposeTheoryEditTool: AgentTool {
    let store: ProjectStore
    let onProposal: @Sendable (TheoryProposal) -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "propose_theory_edit",
            description: "Propose creating or updating a theory item. The proposal is shown to the user for confirmation — nothing is written until they approve. Provide the complete item file: YAML frontmatter (id, type, name, status, depends_on, resolves, tags) followed by markdown body with '## Statement' and optionally '## Proof' sections. Use resolves for goal item ids this result answers. LaTeX allowed.",
            inputSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update"],"description":"create a new item or update an existing one"},"markdown":{"type":"string","description":"Complete item file content: frontmatter + body"}},"required":["action","markdown"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let obj = jsonObject(inputJSON)
        let actionRaw = obj["action"] as? String ?? "create"
        guard let action = TheoryProposal.Action(rawValue: actionRaw) else {
            throw AgentError.badResponse("action must be 'create' or 'update'")
        }
        guard let markdown = obj["markdown"] as? String else {
            throw AgentError.badResponse("missing 'markdown'")
        }
        try TheoryTools.validateAgentMarkdown(markdown)
        var item = try TheoryItem.parse(markdown: markdown)

        if action == .update, store.item(id: item.id) == nil {
            throw CoreError.itemNotFound(item.id)
        }
        if action == .create, store.item(id: item.id) != nil {
            throw AgentError.badResponse("id '\(item.id)' already exists; use action=update or pick a new id")
        }
        try TheoryTools.reconcileFigure(&item, action: action, store: store)

        onProposal(TheoryProposal(action: action, item: item))
        return "Proposal '\(item.id)' recorded and shown to the user for confirmation. Do not assume it was accepted."
    }
}
