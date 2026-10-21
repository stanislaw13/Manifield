import Foundation
import ManifieldCore

/// One bounded verification/triage pass before pilots and portfolio design. Its purpose is to
/// catch work that is already substantially available in the library, an established result,
/// or a short exact calculation — not to develop a multi-obligation solution before planning.
public enum Recognition {

    public struct Claim: Equatable, Sendable {
        public var primaryItemID: String
        public var supportingItemIDs: [String]
        public var argument: String

        public init(primaryItemID: String, supportingItemIDs: [String] = [], argument: String) {
            self.primaryItemID = primaryItemID
            self.supportingItemIDs = supportingItemIDs
            self.argument = argument
        }
    }

    public struct Result: Equatable, Sendable {
        public var summary: String
        public var claim: Claim?
        public var candidate: SolutionCandidate?
        public var finding: ProgramFinding?
        public var targetItemID: String?

        public init(summary: String, claim: Claim? = nil,
                    candidate: SolutionCandidate? = nil, finding: ProgramFinding? = nil,
                    targetItemID: String? = nil) {
            self.summary = summary
            self.claim = claim
            self.candidate = candidate
            self.finding = finding
            self.targetItemID = targetItemID
        }

        /// Primary input to every later planning stage. Failed checks are named explicitly:
        /// they are often a better portfolio brief than the recognizer's original reasoning.
        public var digest: String {
            var lines = ["## Recognition pass", summary]
            if let targetItemID {
                lines.append("Research goal item: `\(targetItemID)`.")
            }
            if let finding {
                lines.append("Durable finding: [\(finding.kind.rawValue)] \(finding.statement)")
            }
            if let candidate {
                lines.append("Solution candidate on `\(candidate.primaryItemID)`: \(candidate.status.rawValue)")
                if let ruling = candidate.contractRuling, !ruling.accepted {
                    lines.append("Scope check rejected it; the portfolio must address this gap: \(ruling.note)")
                }
                if let ruling = candidate.reviewRuling, !ruling.accepted {
                    lines.append("Mathematical review rejected it; the portfolio must address this gap: \(ruling.note)")
                }
                if candidate.status == .accepted {
                    lines.append("Both independent checks accepted this as an answer.")
                }
            }
            return lines.joined(separator: "\n\n")
        }
    }

    public static func systemPrompt(goal: String, contract: SuccessContract?,
                                    targetItemID: String = "",
                                    notation: String, outline: String) -> String {
        var parts = ["""
        You are the recognition pass before a research portfolio is launched. This is a bounded
        verification and triage pass, not a general solving phase. Determine whether the request
        is already answered by the project, by an established result you can check exactly, or
        by a short direct computation. You may finish an answer only when its substance is already
        available through one of those routes; do not develop a multi-obligation solution from
        scratch merely because parts of it look approachable.

        Search and read before claiming. Use exact computation when it is the natural check.
        A checked citation or an exact verified witness may be sufficient when that is what the
        request asks for. Do not demand a broader theorem. The research goal was already
        formalized as theory item `\(targetItemID)`; selecting or redefining it is not your job.
        If you obtain a durable result, first create a separate theory item for it with
        `create_theory_item`; set `resolves: [\(targetItemID)]` in its frontmatter so the item
        remains meaningful outside this run. You cannot edit existing theory during recognition.
        Then file it with `claim_solution` by item id before the final recognition report.

        The stopping boundary is operational, not a classification of the user's problem. Once
        further progress requires choosing or constructing a research route, proving several new
        dependencies, or continuing across separate hard subproblems, stop the attempt. Pilots
        and research branches exist to develop those routes. Do not change the request to make it
        easier. Report the checked evidence, the best candidate mechanism, and the unresolved
        obligations that should guide the pilot selector and portfolio planner. Call
        `report_recognition` exactly once, then stop.
        """]
        parts.append(ContextAssembly.honestyRules)
        parts.append(ContextAssembly.researchTargetSection(
            originalRequest: goal, contract: contract))
        parts.append(ContextAssembly.checkerRules)
        parts.append(ContextAssembly.computeEnvironment)
        parts.append(ContextAssembly.latexRules)
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        parts.append("Library outline:\n\(outline)")
        return parts.joined(separator: "\n\n")
    }

    public static func run(
        runner: AgentRunner,
        goal: String,
        contract: SuccessContract?,
        targetItemID: String,
        tools: [AgentTool],
        notation: String = "",
        outline: String = "",
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> Result? {
        let signals = Signals(targetItemID: targetItemID)
        let claimTool = RecognitionClaimTool(signals: signals)
        let reportTool = ReportTool(signals: signals)
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt(
                goal: goal, contract: contract, targetItemID: targetItemID,
                notation: notation, outline: outline)),
            tools: tools + [claimTool, reportTool],
            // The fourteenth opportunity is held back for structured finalization below. A
            // model that uses every attempt step must still be able to hand evidence to pilots.
            maxIterations: 13,
            thinking: thinking)
        let attempt = try await runRecordedTurn(
            runner: runner, config: config,
            history: [.user("Run the recognition pass now.")],
            programID: programID, role: .recognition,
            title: "Can this be answered before launching a portfolio?",
            record: record,
            outcome: { _ in signals.result?.summary ?? "no recognition report" },
            onActivity: onActivity)

        if signals.result == nil {
            let finalizationConfig = AgentConfig(
                systemPrompt: SystemPrompt(finalizationPrompt(hasTarget: true)),
                tools: [reportTool],
                maxIterations: 1,
                thinking: thinking)
            _ = try await runRecordedTurn(
                runner: runner, config: finalizationConfig,
                history: attempt.transcript + [.user("Finalize the recognition report now.")],
                programID: programID, role: .recognition,
                title: "File the bounded recognition report",
                record: record,
                outcome: { _ in signals.result?.summary ?? "no recognition report" },
                onActivity: onActivity)
        }
        return signals.result
    }

    static func finalizationPrompt(hasTarget: Bool) -> String {
        """
        The bounded recognition attempt is over. Do not search, compute, solve further, create
        theory, or claim a solution now. Use only the evidence already present in the transcript.
        \(hasTarget ? "The research target is already selected." : "First select an existing or already-created item from the transcript as the research target; do not invent a new item.")
        Call `report_recognition` exactly once with the checked evidence, candidate mechanism,
        and unresolved obligations, then stop. This finalization opportunity exists only to make
        the recognition handoff durable.
        """
    }

    /// Recognition is create-only. Existing items can be cited but not altered while the
    /// system is still deciding whether a portfolio is needed.
    public static func createItemTool(
        store: ProjectStore,
        apply: @escaping @Sendable (TheoryProposal) async throws -> String
    ) -> AgentTool {
        CreateItemTool(store: store, apply: apply)
    }
}

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Recognition.Result?
    private var _claim: Recognition.Claim?
    private var _targetItemID: String?
    init(targetItemID: String) { _targetItemID = targetItemID }
    var result: Recognition.Result? { lock.lock(); defer { lock.unlock() }; return _result }
    var claim: Recognition.Claim? { lock.lock(); defer { lock.unlock() }; return _claim }
    var targetItemID: String? { lock.lock(); defer { lock.unlock() }; return _targetItemID }
    func set(_ result: Recognition.Result) { lock.lock(); _result = result; lock.unlock() }
    func setClaim(_ claim: Recognition.Claim) { lock.lock(); _claim = claim; lock.unlock() }
}

/// The same control-plane verb branches use. In recognition it records the claim in the
/// provisional planning session; the host runs both gates immediately after the turn.
private struct RecognitionClaimTool: AgentTool {
    let signals: Signals

    var spec: ToolSpec {
        ToolSpec(
            name: "claim_solution",
            description: "Claim that durable library items answer the user's whole request. This settles nothing; independent scope and mathematical review run immediately after recognition.",
            inputSchemaJSON: #"{"type":"object","properties":{"primary_item_id":{"type":"string"},"supporting_item_ids":{"type":"array","items":{"type":"string"}},"argument":{"type":"string","description":"Why the cited items answer the whole request"}},"required":["primary_item_id","argument"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let primary = (input["primary_item_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !primary.isEmpty,
              let argument = (input["argument"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !argument.isEmpty else {
            throw ResearchError(message: "claim_solution needs primary_item_id and argument")
        }
        signals.setClaim(.init(
            primaryItemID: primary,
            supportingItemIDs: (input["supporting_item_ids"] as? [Any] ?? [])
                .compactMap { $0 as? String },
            argument: argument))
        return "Candidate filed provisionally. Call report_recognition with the attempt summary."
    }
}

private struct ReportTool: AgentTool {
    let signals: Signals

    var spec: ToolSpec {
        let kinds = ProgramFinding.Kind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return ToolSpec(
            name: "report_recognition",
            description: "Report the bounded attempt and an optional durable finding. File any solution first with claim_solution; the host reviews it independently.",
            inputSchemaJSON: """
            {"type":"object","properties":{
            "summary":{"type":"string","description":"What you checked and the decisive result or remaining gap"},
            "finding":{"type":"object","properties":{
              "kind":{"type":"string","enum":[\(kinds)]},
              "statement":{"type":"string"},
              "item_ids":{"type":"array","items":{"type":"string"}},
              "artifact_path":{"type":"string"}},
              "required":["kind","statement"]}},
            "required":["summary"]}
            """)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let summary = (input["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            throw ResearchError(message: "missing 'summary'")
        }
        guard signals.targetItemID != nil else {
            throw ResearchError(message: "select the natural library target with set_research_target before reporting recognition")
        }
        var finding: ProgramFinding?
        if let raw = input["finding"] as? [String: Any] {
            guard let kindRaw = raw["kind"] as? String,
                  let kind = ProgramFinding.Kind(rawValue: kindRaw),
                  let statement = (raw["statement"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !statement.isEmpty else {
                throw ResearchError(message: "a finding needs a valid kind and statement")
            }
            finding = ProgramFinding(
                branchPlanID: "planning-recognition", kind: kind, statement: statement,
                itemIDs: (raw["item_ids"] as? [Any] ?? []).compactMap { $0 as? String },
                artifactPath: raw["artifact_path"] as? String)
        }
        signals.set(Recognition.Result(summary: String(summary.prefix(2000)),
                                       claim: signals.claim, finding: finding,
                                       targetItemID: signals.targetItemID))
        return "Recognition report recorded. End your turn."
    }
}

private struct CreateItemTool: AgentTool {
    let store: ProjectStore
    let apply: @Sendable (TheoryProposal) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "create_theory_item",
            description: "Create one new durable theory item from recognition. Existing items are immutable in this stage. Use complete item markdown, an agent-settable status, and the research goal id in `resolves` when this item answers it.",
            inputSchemaJSON: #"{"type":"object","properties":{"markdown":{"type":"string","description":"Complete item file: YAML frontmatter followed by Statement and optional Proof/Evidence sections"}},"required":["markdown"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        guard let markdown = jsonObject(inputJSON)["markdown"] as? String else {
            throw ResearchError(message: "missing 'markdown'")
        }
        try TheoryTools.validateAgentMarkdown(markdown)
        let item = try TheoryItem.parse(markdown: markdown)
        guard TheoryWritePolicy.agentSettableStatuses.contains(item.status) else {
            throw ResearchError(message: "status '\(item.status.rawValue)' is human-owned")
        }
        guard store.item(id: item.id) == nil else {
            throw ResearchError(message: "item '\(item.id)' already exists; recognition cannot edit it")
        }
        return try await apply(TheoryProposal(action: .create, item: item))
    }
}
