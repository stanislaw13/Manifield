import Foundation
import ManifieldCore

/// Turns a user's prompt into the durable mathematical object a program will work on.
///
/// This deliberately combines the former statement-audit and contract-drafting turns. The
/// same agent that resolves project notation and selects the intended reading must also decide
/// whether the library already contains that goal or create the missing item. Its one durable
/// output is the item; the audit/contract views are derived from the item's frozen Statement.
public enum ResearchGoalEditor {

    public struct Result: Equatable, Sendable {
        public var item: TheoryItem
        public var audit: StatementAuditor.Audit
        public var draft: ContractDrafter.Draft
        public var createdItem: Bool
        /// False until a person explicitly approves the interpretation in the review UI.
        public var interpretationConfirmed: Bool

        public init(item: TheoryItem, audit: StatementAuditor.Audit,
                    draft: ContractDrafter.Draft, createdItem: Bool,
                    interpretationConfirmed: Bool = false) {
            self.item = item
            self.audit = audit
            self.draft = draft
            self.createdItem = createdItem
            self.interpretationConfirmed = interpretationConfirmed
        }
    }

    /// Deliberately without `honestyRules`: this agent makes no mathematical claim, cites
    /// nothing and runs no computation, so nine of its ten bullets are inert here — and the
    /// one that is not ("never silently alter the user's statement") is the spine of
    /// `research_goal_editor.md` rather than item three of a list about proofs.
    ///
    /// The request is repeated here as well as in the opening message. The library search
    /// runs first and can put tens of thousands of characters of unrelated theory between
    /// the request and the decision; in the goal editor that distance is the failure mode,
    /// not a saving.
    public static func systemPrompt(request: String, notation: String, macros: String,
                                    outline: String) -> String {
        var parts = [PromptLibrary.text("research_goal_editor")]
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append("""
            # The request you are recording

            The user's request, exactly as they wrote it. It is the authority for every
            decision below, and it is repeated as the first message of this conversation.

            \(trimmed)
            """)
        }
        parts.append(ContextAssembly.latexRules)
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        if !macros.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project LaTeX macros:\n\(macros)")
        }
        parts.append("Library outline:\n\(outline)")
        return parts.joined(separator: "\n\n")
    }

    /// Named so it can be read and tested beside the system prompt. Its predecessor told the
    /// model not to use the request's "shorthand" as the goal — one sentence that turned a
    /// precise question into something to be replaced.
    public static func openingMessage(request: String) -> String {
        """
        The user's request, exactly as they wrote it:

        \(request)

        Put it on the record as a research goal now.
        """
    }

    public static func run(
        runner: AgentRunner,
        request: String,
        store: ProjectStore,
        tools: [AgentTool] = [],
        notation: String = "",
        macros: String = "",
        outline: String = "",
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        applyCreate: @escaping @Sendable (TheoryProposal) async throws -> String,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Result? {
        let signals = Signals()
        let finalizer = FinalizeTool(store: store, signals: signals, applyCreate: applyCreate)
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                request: request, notation: notation, macros: macros, outline: outline)),
            tools: tools + [finalizer], maxIterations: 11, thinking: thinking)
        let attempt = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user(openingMessage(request: request))],
            programID: programID, role: .goalFormalization,
            title: "Formalize the research goal",
            record: record,
            outcome: { _ in
                guard let result = signals.result else { return "no goal item selected" }
                return "goal: \(result.item.id) — \(result.item.name)"
            }, onActivity: onActivity)

        if signals.result == nil {
            let finalConfig = AgentConfig(
                systemPrompt: SystemPrompt("""
                The investigation is over. Using only the transcript, call
                `finalize_research_goal` now. Select an existing item that states the same
                question, or create the missing one. Its Statement is the user's question,
                said precisely — not a related, cleaner or easier one. Do not search or
                continue reasoning.
                """), tools: [finalizer], maxIterations: 1, thinking: thinking)
            _ = try await runRecordedTurn(
                runner: runner, config: finalConfig,
                history: attempt.transcript + [.user("Finalize the goal item now.")],
                programID: programID, role: .goalFormalization,
                title: "Finalize the research goal item", record: record,
                outcome: { _ in signals.result == nil ? "no goal item selected" : "goal selected" },
                onActivity: onActivity)
        }
        return signals.result
    }
}

private final class ResearchGoalSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: ResearchGoalEditor.Result?
    var result: ResearchGoalEditor.Result? {
        lock.lock(); defer { lock.unlock() }; return _result
    }
    func set(_ result: ResearchGoalEditor.Result) {
        lock.lock(); _result = result; lock.unlock()
    }
}

private typealias Signals = ResearchGoalSignals

private struct FinalizeTool: AgentTool {
    let store: ProjectStore
    let signals: Signals
    let applyCreate: @Sendable (TheoryProposal) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "finalize_research_goal",
            description: "Record the user's question as one theory item: select the existing item that states the same question, or create the missing one. Exactly one of existing_item_id and new_item_markdown is required. Leave ambiguities empty when the request settles its own terms.",
            inputSchemaJSON: #"""
            {"type":"object","properties":{
              "existing_item_id":{"type":"string","description":"Existing library item whose Statement already asks this same question — same object, hypotheses, quantifiers and requested output"},
              "new_item_markdown":{"type":"string","description":"Complete new theory item file with frontmatter and a nonempty Statement, stating the user's question and nothing else"},
              "recommended_reading":{"type":"string","description":"Required only when ambiguities is non-empty: which of them you adopted, and why"},
              "ambiguities":{"type":"array","items":{"type":"object","properties":{
                "reading":{"type":"string"},"consequence":{"type":"string"}},
                "required":["reading","consequence"]},
                "description":"Only readings the request leaves genuinely open AND that would change the mathematical answer. A reading the request itself fixes is not an ambiguity; a clear request has none"},
              "conventions":{"type":"array","items":{"type":"string"},"description":"Conventions you made explicit that the request left implicit"},
              "interpretation_note":{"type":"string","description":"Anything a future user should know about how their request was recorded"}
            }}
            """#)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        let existingID = (input["existing_item_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMarkdown = input["new_item_markdown"] as? String
        if let rawMarkdown { try TheoryTools.validateAgentMarkdown(rawMarkdown) }
        let markdown = rawMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (existingID?.isEmpty == false) != (markdown?.isEmpty == false) else {
            throw ResearchError(message: "provide exactly one of existing_item_id or new_item_markdown")
        }

        let item: TheoryItem
        let created: Bool
        if let existingID, !existingID.isEmpty {
            guard let found = store.item(id: existingID) else {
                throw CoreError.itemNotFound(existingID)
            }
            item = found
            created = false
        } else if let markdown {
            let parsed = try TheoryItem.parse(markdown: markdown)
            guard store.item(id: parsed.id) == nil else {
                throw ResearchError(message: "item '\(parsed.id)' already exists; select it instead of overwriting it")
            }
            guard TheoryWritePolicy.agentSettableStatuses.contains(parsed.status) else {
                throw ResearchError(message: "status '\(parsed.status.rawValue)' is human-owned")
            }
            _ = try await applyCreate(TheoryProposal(action: .create, item: parsed))
            item = parsed
            created = true
        } else {
            throw ResearchError(message: "missing goal item")
        }

        guard let statement = item.statement?
            .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
            throw ResearchError(message: "goal item '\(item.id)' needs a nonempty ## Statement")
        }

        let ambiguities = (input["ambiguities"] as? [[String: Any]] ?? []).compactMap {
            raw -> StatementAuditor.Ambiguity? in
            guard let reading = (raw["reading"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !reading.isEmpty else { return nil }
            return StatementAuditor.Ambiguity(
                reading: reading,
                consequence: (raw["consequence"] as? String) ?? "")
        }
        let recommended = (input["recommended_reading"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ambiguities.isEmpty || !recommended.isEmpty else {
            throw ResearchError(message: "list which reading was automatically adopted")
        }
        let conventions = (input["conventions"] as? [Any] ?? []).compactMap { $0 as? String }
        let note = (input["interpretation_note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let audit = StatementAuditor.Audit(
            normalizedStatement: statement,
            recommendedReading: recommended,
            ambiguities: ambiguities,
            conventions: conventions)
        let contract = SuccessContract(
            statement: statement,
            recommendedReading: audit.recommendedReading,
            ambiguities: audit.contractAmbiguities)
        let problems = contract.validationProblems
        guard problems.isEmpty else {
            throw ResearchError(message: "goal Statement is not usable: \(problems.joined(separator: "; "))")
        }
        signals.set(ResearchGoalEditor.Result(
            item: item, audit: audit,
            draft: ContractDrafter.Draft(
                contract: contract,
                ambiguityNote: note?.isEmpty == false ? note : nil),
            createdItem: created))
        return "Research goal set to '\(item.id)' — \(item.name). The interpretation is automatic and not user-confirmed. End your turn."
    }
}
