import Foundation
import ManifieldCore

/// Drafts the formal statement used alongside the user's verbatim request.
///
/// Drafting is not the safeguard — timing is. A contract an agent wrote still does its job
/// provided it is anchored to the user's own question, frozen before any research or planning
/// sees the problem, and a human has had one cheap look.
///
/// It deliberately sees **no pilot results, no proposed routes and no findings.** An earlier
/// design drafted after the pilots so the bottom of a progress ladder would be an observed fact;
/// with the ladder gone, that ordering only lets what turned out to be reachable shape what
/// counts as an answer — which is the drift the contract exists to prevent. What it needs is the
/// question, read precisely, and nothing else.
public enum ContractDrafter {

    public struct Draft: Equatable, Sendable {
        public var contract: SuccessContract
        /// What the drafter found unresolved, beyond what the audit already flagged. The most
        /// useful single thing for the human reviewing the draft.
        public var ambiguityNote: String?

        public init(contract: SuccessContract, ambiguityNote: String? = nil) {
            self.contract = contract
            self.ambiguityNote = ambiguityNote
        }
    }

    public static func systemPrompt(audit: StatementAuditor.Audit?) -> String {
        var parts = [PromptLibrary.text("contract_drafter")]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.latexRules)
        if let audit { parts.append(auditSection(audit)) }
        return parts.joined(separator: "\n\n")
    }

    /// The statement audit as the drafter sees it. Rendered here rather than folded into the
    /// user message so the drafter reads the recommended reading as settled context, not as
    /// one more thing to weigh against the raw wording.
    static func auditSection(_ audit: StatementAuditor.Audit) -> String {
        var parts = ["""
        Statement audit (produced before you, by a pass that only read the statement):

        **Normalized statement.** \(audit.normalizedStatement)
        """]
        if !audit.recommendedReading.isEmpty {
            parts.append("**Recommended reading.** \(audit.recommendedReading)")
        }
        if !audit.ambiguities.isEmpty {
            parts.append("""
            **Readings the statement admits.** Carry these into `ambiguities` — the human \
            reviewing this contract needs to see the fork you drafted against.

            \(audit.ambiguities.map { "- \($0.line)" }.joined(separator: "\n"))
            """)
        }
        if !audit.conventions.isEmpty {
            parts.append("""
            **Conventions in play.**

            \(audit.conventions.map { "- \($0)" }.joined(separator: "\n"))
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    public static func userMessage(goal: String) -> String {
        """
        The user's problem, exactly as they wrote it:

        \(goal)

        Call draft_success_contract once. Preserve the question. Only make its quantifiers,
        scope, and adopted conventions explicit.
        """
    }

    /// Runs one drafting turn. Nil when the turn produced nothing usable — the caller then
    /// runs without a contract rather than binding the program to an invented one.
    public static func draft(
        runner: AgentRunner,
        goal: String,
        audit: StatementAuditor.Audit? = nil,
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Draft? {
        let signals = ContractSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(audit: audit)),
            tools: [DraftContractTool(signals: signals,
                                      recommendedReading: audit?.recommendedReading ?? "",
                                      ambiguities: audit?.contractAmbiguities ?? [])],
            maxIterations: 4,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user(userMessage(goal: goal))],
            programID: programID, role: .contractDraft,
            title: "The formal statement for this run",
            record: record,
            outcome: { _ in
                guard let draft = signals.draft else { return "no contract was drafted" }
                return "formal statement recorded"
            },
            onActivity: onActivity)
        return signals.draft
    }
}

final class ContractSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _draft: ContractDrafter.Draft?
    var draft: ContractDrafter.Draft? { lock.lock(); defer { lock.unlock() }; return _draft }
    func set(_ draft: ContractDrafter.Draft) { lock.lock(); _draft = draft; lock.unlock() }
}

struct DraftContractTool: AgentTool {
    let signals: ContractSignals
    /// Reading adopted by the audit for the ambiguities below.
    var recommendedReading: String = ""
    /// Ambiguities the audit already found. Merged with whatever the drafter adds, so a
    /// flagged fork cannot be dropped by a drafter that simply did not repeat it.
    var ambiguities: [String] = []

    var spec: ToolSpec {
        ToolSpec(
            name: "draft_success_contract",
            description: """
            Record the formal statement used by the run. It must preserve the user's request;
            only make quantifiers, scope, and adopted conventions explicit. Do not prescribe
            answer forms, proof methods, or exclusions.
            """,
            inputSchemaJSON: #"""
            {"type":"object","properties":{
            "statement":{"type":"string","description":"Exact statement, quantifiers and conventions. The user's question, said precisely — not a stronger or weaker one."},
            "ambiguities":{"type":"array","items":{"type":"string"},"description":"Readings the statement admits and which was chosen"},
            "ambiguity_note":{"type":"string","description":"Anything still unresolved that the human reviewing this should decide"}},
            "required":["statement"]}
            """#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let statement = (input["statement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
            throw ResearchError(message: "missing 'statement'")
        }

        let drafted = (input["ambiguities"] as? [Any] ?? []).compactMap { $0 as? String }
        // Union, audit first: a fork the audit flagged survives a drafter that forgot it.
        let merged = ambiguities + drafted.filter { !ambiguities.contains($0) }

        let contract = SuccessContract(
            statement: statement,
            recommendedReading: recommendedReading,
            ambiguities: merged)

        // The same shape rules the human would check, applied before the draft is accepted —
        // an instructive refusal now is cheaper than a malformed contract binding a whole run.
        let problems = contract.validationProblems
        guard problems.isEmpty else {
            throw ResearchError(message: """
            REJECTED — this contract cannot bind a run as written:
            \(problems.map { "- \($0)" }.joined(separator: "\n"))
            Fix these and call draft_success_contract again.
            """)
        }

        signals.set(ContractDrafter.Draft(
            contract: contract,
            ambiguityNote: (input["ambiguity_note"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }))
        return "Formal statement recorded. End your turn."
    }
}
