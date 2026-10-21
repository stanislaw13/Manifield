import Foundation
import ManifieldCore

/// How research-run library writes are applied.
public enum TheoryWritePolicy: Sendable {
    /// Checkpoint mode: writes become proposals the user confirms (existing flow).
    case propose(@Sendable (TheoryProposal) -> Void)
    /// Auto mode: writes are applied immediately through a callback that hops to the
    /// main actor, saves through the store (FTS/graph/breakage stay correct) and
    /// returns a confirmation string.
    case direct(@Sendable (TheoryProposal) async throws -> String)

    /// Statuses an agent may set on its own. The rest of the trust ladder
    /// (human-approved, source, formally-verified) is the user's alone — in every mode.
    public static let agentSettableStatuses: Set<ItemStatus> =
        [.conjecture, .tested, .proofDrafted, .reviewedNoErrors]
}

/// What the researcher reported for its current task via finish_task.
public struct TaskOutcome: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case completed, blocked, failed

        public var taskStatus: PlanTask.Status {
            switch self {
            case .completed: return .completed
            case .blocked: return .blocked
            case .failed: return .failed
            }
        }
    }
    public var kind: Kind
    public var summary: String
    public var needs: String?
    public var stopReason: AssignmentReport.StopReason?

    public init(kind: Kind, summary: String, needs: String? = nil, stopReason: AssignmentReport.StopReason? = nil) {
        self.kind = kind
        self.summary = summary
        self.needs = needs
        self.stopReason = stopReason
    }
}

/// Collects the control-flow signals a task turn can raise (finish_task / ask_user),
/// checked by the workbench after the turn ends. Thread-safe: tools run off-main.
final class TaskSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: TaskOutcome?
    private var _question: (question: String, context: String, scope: QuestionScope)?
    private var _writtenItemIDs: [String] = []
    private var _assumptions: [(question: String, assumption: String)] = []
    private var _solutionClaim: String?
    private var _problemChallenge: String?

    var outcome: TaskOutcome? {
        lock.lock(); defer { lock.unlock() }; return _outcome
    }
    var question: (question: String, context: String, scope: QuestionScope)? {
        lock.lock(); defer { lock.unlock() }; return _question
    }
    var writtenItemIDs: [String] {
        lock.lock(); defer { lock.unlock() }; return _writtenItemIDs
    }
    /// Questions the run answered for itself. Journalled with the task so a later answer can
    /// invalidate what was built on top of them.
    var assumptions: [(question: String, assumption: String)] {
        lock.lock(); defer { lock.unlock() }; return _assumptions
    }

    /// Id of a solution candidate filed this turn. The workbench reads it after the turn to
    /// run contract adjudication before deciding whether the branch pauses.
    var solutionClaim: String? {
        lock.lock(); defer { lock.unlock() }; return _solutionClaim
    }
    var problemChallenge: String? {
        lock.lock(); defer { lock.unlock() }; return _problemChallenge
    }

    func setOutcome(_ outcome: TaskOutcome) {
        lock.lock(); _outcome = outcome; lock.unlock()
    }
    func setSolutionClaim(_ candidateID: String) {
        lock.lock(); _solutionClaim = candidateID; lock.unlock()
    }
    func setProblemChallenge(_ challengeID: String) {
        lock.lock(); _problemChallenge = challengeID; lock.unlock()
    }
    func setQuestion(_ question: String, context: String, scope: QuestionScope = .statement) {
        lock.lock(); _question = (question, context, scope); lock.unlock()
    }
    func recordWrite(id: String) {
        lock.lock(); _writtenItemIDs.append(id); lock.unlock()
    }
    func recordAssumption(question: String, assumption: String) {
        lock.lock(); _assumptions.append((question, assumption)); lock.unlock()
    }
    func reset() {
        lock.lock()
        _outcome = nil; _question = nil; _writtenItemIDs = []; _assumptions = []
        _solutionClaim = nil; _problemChallenge = nil
        lock.unlock()
    }
}

struct ResearchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ResearchTools {

    static func taskTools(
        signals: TaskSignals,
        contract: SuccessContract? = nil,
        questionHandling: ContinuationPolicy.QuestionHandling = .alwaysPause,
        addTask: @escaping @Sendable (String, PlanTask.Kind) async throws -> Int,
        appendLog: @escaping @Sendable (String) async -> Void,
        revisePlan: (@Sendable (_ drop: [Int], _ add: [(title: String, kind: PlanTask.Kind)],
                                _ reason: String) async throws -> String)? = nil
    ) -> [AgentTool] {
        var tools: [AgentTool] = [
            FinishTaskTool(signals: signals, contract: contract),
            AskUserTool(signals: signals, handling: questionHandling),
            AddTaskTool(addTask: addTask),
            AppendPlanLogTool(appendLog: appendLog)
        ]
        // Absent once the branch has spent its revision budget, so an exhausted branch stops
        // being offered the option it can no longer take.
        if let revisePlan { tools.append(RevisePlanTool(revise: revisePlan)) }
        return tools
    }

    /// The library-write tool matching the run's policy.
    static func writeTool(
        policy: TheoryWritePolicy,
        store: ProjectStore,
        signals: TaskSignals
    ) -> AgentTool {
        switch policy {
        case .propose(let onProposal):
            return ProposeTheoryEditTool(store: store, onProposal: onProposal)
        case .direct(let apply):
            return WriteTheoryItemTool(store: store, apply: apply, signals: signals)
        }
    }
}

struct FinishTaskTool: AgentTool {
    var turnEffect: AgentToolEffect { .finish }
    let signals: TaskSignals
    /// Present so the tool can name what a complete answer would be when it reminds the model
    /// that finishing a task is not answering the question. Nothing here is validated against
    /// it: a task's outcome is a fact about the task, and only `claim_solution` — adjudicated
    /// and reviewed independently — records that the problem was answered.
    let contract: SuccessContract?

    init(signals: TaskSignals, contract: SuccessContract? = nil) {
        self.signals = signals
        self.contract = contract
    }

    var spec: ToolSpec {
        var description = "Report the outcome of the CURRENT task and end your turn. 'completed' when the task's deliverable exists; 'blocked' when it cannot proceed without something (say what in 'needs'); 'failed' when the approach is dead (say why). The summary is the only thing later tasks and the user see about this task — name concrete results: theory item ids written, artifact paths, findings you submitted, and dead ends."
        if contract != nil {
            description += " Completing a task is not answering the user's question, and a run of completed tasks is not progress toward one. If you believe durable results now answer it in full, say so with claim_solution instead of implying it here."
        }
        let properties = #""outcome":{"type":"string","enum":["completed","blocked","failed"]},"summary":{"type":"string","description":"What happened, ≤10 lines: results, item ids, artifacts, submitted findings, dead ends"},"needs":{"type":"string","description":"For 'blocked': what the task is waiting for"}"#

        return ToolSpec(
            name: "finish_task",
            description: description,
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{\(properties)},\"required\":[\"outcome\",\"summary\"]}"
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let raw = input["outcome"] as? String, let kind = TaskOutcome.Kind(rawValue: raw) else {
            throw ResearchError(message: "outcome must be completed, blocked or failed")
        }
        guard let summary = input["summary"] as? String, !summary.isEmpty else {
            throw ResearchError(message: "missing 'summary'")
        }

        signals.setOutcome(TaskOutcome(
            kind: kind,
            summary: String(summary.prefix(1200)),
            needs: input["needs"] as? String
        ))
        return "Task outcome recorded. End your turn now — do not start further work."
    }
}

struct AskUserTool: AgentTool {
    var turnEffect: AgentToolEffect { signals.question == nil ? .none : .suspend }
    let signals: TaskSignals
    /// How the run handles questions. Unattended, a task-level question is answered by the
    /// agent's own stated assumption rather than by stopping the branch until morning.
    let handling: ContinuationPolicy.QuestionHandling

    init(signals: TaskSignals,
         handling: ContinuationPolicy.QuestionHandling = .alwaysPause) {
        self.signals = signals
        self.handling = handling
    }

    var spec: ToolSpec {
        var description = "Pause the run and ask the user for help with the CURRENT task — a decision only they can make, missing information, or a genuinely stuck point after you tried the obvious routes. Ask one precise question and give the context needed to answer it."
        description += " Classify it in 'scope': 'task' for how to carry out this task (a parameter, a convention, which of two routes to try); 'statement' for anything about what the problem is asking or what would count as an answer."
        if handling != .alwaysPause {
            description += " This run is unattended. A 'task' question will NOT stop the run — you must supply the 'assumption' you will proceed under, and you will be told to continue under it. A 'statement' question does stop the run, because assuming the wrong problem invalidates everything built afterwards."
        }
        return ToolSpec(
            name: "ask_user",
            description: description,
            inputSchemaJSON: #"{"type":"object","properties":{"question":{"type":"string","description":"One precise question"},"context":{"type":"string","description":"What you tried and why you're stuck — enough for the user to answer well"},"scope":{"type":"string","enum":["task","statement"],"description":"'task' = how to do this task; 'statement' = what is being asked or what counts as an answer"},"assumption":{"type":"string","description":"The answer you will proceed under if the run does not stop for this"}},"required":["question"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let question = input["question"] as? String, !question.isEmpty else {
            throw ResearchError(message: "missing 'question'")
        }
        let context = input["context"] as? String ?? ""
        // Unclassified questions are treated as statement-level: the safe default is the one
        // that stops, not the one that guesses at what is being asked.
        let scope = QuestionScope(rawValue: input["scope"] as? String ?? "") ?? .statement
        let assumption = (input["assumption"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let proceeds: Bool
        switch handling {
        case .alwaysPause: proceeds = false
        case .assumeAll: proceeds = true
        case .assumeTaskLevel: proceeds = scope == .task
        }

        guard proceeds else {
            signals.setQuestion(question, context: context, scope: scope)
            return "Question sent to the user; the run is pausing. End your turn now."
        }
        guard let assumption else {
            throw ResearchError(message: """
            This run does not stop for \(scope.rawValue)-level questions. Supply the \
            'assumption' you will proceed under and call ask_user again — or, if you cannot \
            state one, raise the scope to 'statement' so the run does stop.
            """)
        }
        signals.recordAssumption(question: question, assumption: assumption)
        return """
        The run did not stop: this is a \(scope.rawValue)-level question and nobody is \
        watching. Proceed under your stated assumption — "\(assumption)" — and continue the \
        task. The assumption is recorded with your task outcome, so say in your summary what \
        would change if it turns out to be wrong.
        """
    }
}

/// Rewrites the *pending tail* of the plan. The guardrails are the design, not decoration:
/// a branch that can rewrite what it already did, or redefine what would count as success,
/// is not replanning — it is drifting with an audit trail.
struct RevisePlanTool: AgentTool {
    let revise: @Sendable (_ drop: [Int], _ add: [(title: String, kind: PlanTask.Kind)],
                           _ reason: String) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "revise_plan",
            description: """
            Rewrite the REMAINING plan when what you have learned makes it wrong — a task \
            whose premise is now dead, or work that a finding has made pointless or newly \
            necessary. Drop tasks by index and/or add new ones, and say why in 'reason'. \
            Only tasks that have not started can be dropped; completed and failed tasks are \
            the record of what happened and cannot be changed, and neither can this branch's \
            research lens or its kill criterion. Use this sparingly: if the branch's whole \
            approach is dead, finish the task as failed instead of replanning around it.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"drop":{"type":"array","items":{"type":"integer"},"description":"Indices of unstarted tasks to drop"},"add":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"kind":{"type":"string","description":"'research' or 'prove: <item-id>'"}},"required":["title","kind"]},"description":"Tasks to append"},"reason":{"type":"string","description":"What you learned that makes this revision right"}},"required":["reason"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let reason = (input["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ResearchError(message: "missing 'reason' — a revision has to say what changed")
        }
        let drop = (input["drop"] as? [Any] ?? []).compactMap { $0 as? Int }
        var add: [(title: String, kind: PlanTask.Kind)] = []
        for entry in (input["add"] as? [[String: Any]] ?? []) {
            guard let title = entry["title"] as? String, !title.isEmpty else {
                throw ResearchError(message: "every added task needs a 'title'")
            }
            guard let kind = PlanTask.Kind.parse(entry["kind"] as? String ?? "") else {
                throw ResearchError(message: "task '\(title)': 'kind' must be 'research' or 'prove: <item-id>'")
            }
            add.append((title, kind))
        }
        guard !drop.isEmpty || !add.isEmpty else {
            throw ResearchError(message: "a revision must drop or add at least one task")
        }
        return try await revise(drop, add, String(reason.prefix(400)))
    }
}

struct AddTaskTool: AgentTool {
    let addTask: @Sendable (String, PlanTask.Kind) async throws -> Int

    var spec: ToolSpec {
        ToolSpec(
            name: "add_task",
            description: "Append a new task to the plan — for follow-up work discovered during the current task (a lemma that must be proved first, an experiment worth running). Use sparingly; the plan should stay focused.",
            inputSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string"},"kind":{"type":"string","description":"'research' or 'prove: <item-id>'"}},"required":["title","kind"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let title = input["title"] as? String, !title.isEmpty else {
            throw ResearchError(message: "missing 'title'")
        }
        guard let kind = PlanTask.Kind.parse(input["kind"] as? String ?? "") else {
            throw ResearchError(message: "'kind' must be 'research' or 'prove: <item-id>'")
        }
        let index = try await addTask(title, kind)
        return "Added task \(index): \(title)"
    }
}

struct AppendPlanLogTool: AgentTool {
    let appendLog: @Sendable (String) async -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "append_plan_log",
            description: "Append one line to the plan's run log — notable events worth an audit trail (a surprising result, a pivot, an artifact worth remembering). Task outcomes are logged automatically; don't duplicate them.",
            inputSchemaJSON: #"{"type":"object","properties":{"note":{"type":"string"}},"required":["note"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let note = input["note"] as? String, !note.isEmpty else {
            throw ResearchError(message: "missing 'note'")
        }
        await appendLog(String(note.prefix(300)))
        return "Logged."
    }
}

/// Auto-mode direct library write. Same input contract as propose_theory_edit, but the
/// item lands immediately — within the agent-settable slice of the trust ladder.
struct WriteTheoryItemTool: AgentTool {
    let store: ProjectStore
    let apply: @Sendable (TheoryProposal) async throws -> String
    let signals: TaskSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "write_theory_item",
            description: "Create or update a theory item DIRECTLY (this run is in auto mode; no per-write confirmation). Provide the complete item file: YAML frontmatter (id, type, name, status, depends_on, tags, section) followed by markdown body with '## Statement' and optionally '## Proof'/'## Evidence'. Allowed statuses: conjecture, tested, proof-drafted, reviewed-no-errors — the rest of the trust ladder is set by humans only. Every write is journaled in the plan log.",
            inputSchemaJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update"]},"markdown":{"type":"string","description":"Complete item file content: frontmatter + body"}},"required":["action","markdown"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let action = TheoryProposal.Action(rawValue: input["action"] as? String ?? "") else {
            throw ResearchError(message: "action must be 'create' or 'update'")
        }
        guard let markdown = input["markdown"] as? String else {
            throw ResearchError(message: "missing 'markdown'")
        }
        try TheoryTools.validateAgentMarkdown(markdown)
        let item = try TheoryItem.parse(markdown: markdown)

        guard TheoryWritePolicy.agentSettableStatuses.contains(item.status) else {
            let allowed = TheoryWritePolicy.agentSettableStatuses
                .map(\.rawValue).sorted().joined(separator: ", ")
            throw ResearchError(message: """
            REJECTED — status '\(item.status.rawValue)' can only be set by a human. \
            Agents may set: \(allowed). Write the item with an honest agent-settable \
            status; the user promotes it later.
            """)
        }
        if action == .update, store.item(id: item.id) == nil {
            throw CoreError.itemNotFound(item.id)
        }
        if action == .create, store.item(id: item.id) != nil {
            throw ResearchError(message: "id '\(item.id)' already exists; use action=update or pick a new id")
        }

        let confirmation = try await apply(TheoryProposal(action: action, item: item))
        signals.recordWrite(id: item.id)
        return confirmation
    }
}
