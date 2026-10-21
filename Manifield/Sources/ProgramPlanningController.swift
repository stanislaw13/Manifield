import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Drives planning pass 2: one task plan per selected approach, generated under that
/// approach's lens. Legs run sequentially — the providers have no rate-limit backoff, and
/// a planning burst is the easiest way to trip one.
///
/// Owns the whole selection → generation → review flow's mutable state, so dismissing a
/// sheet mid-generation cannot orphan a half-built program.
@MainActor
final class ProgramPlanningController: ObservableObject {

    /// One approach on its way to becoming a branch.
    struct Leg: Identifiable {
        enum Status: Equatable {
            case pending, running, done, failed(String)
        }
        var approach: ApproachProposal.Approach
        var status: Status = .pending
        var option: PlanProposal.Option?
        /// Pass-2 may discover that the route is already dead or redundant and decline it
        /// instead of manufacturing a task list.
        var declineReason: String?
        /// Legacy serialization budget plus the provider settings the user edits.
        /// Running programs ignore this budget and spend from their one shared ceiling.
        var tokenBudget: Int = 2_000_000
        var providerKind: String?
        var model: String?

        var id: String { approach.title }
        var isDone: Bool { if case .done = status { return true }; return false }
    }

    @Published private(set) var legs: [Leg] = []
    @Published private(set) var isGenerating = false
    /// Independent first attempts, run before the portfolio is designed (§3 of the design).
    @Published private(set) var pilots: [Pilots.Result] = []
    @Published private(set) var runningPilot: Pilots.Brief?
    /// The bounded attempt that runs before pilot selection, including both independent
    /// rulings when it filed a solution candidate.
    @Published private(set) var recognition: Recognition.Result?
    /// The one durable output produced before any attempt at the mathematics: a selected or
    /// newly created theory item whose Statement is the program's formal goal.
    @Published private(set) var goalDraft: ResearchGoalEditor.Result?
    /// Drafted from the audited goal before any optional pilots run. Reviewed by the user
    /// before it binds anything — `reviewedAt` stays nil until they approve it.
    @Published var contractDraft: ContractDrafter.Draft?
    /// Everything the review step needs. Held here rather than in the Research tab's view
    /// state: generation outlives any one appearance of that view, and keeping the setup
    /// in the view meant switching tabs mid-planning stranded a running session with no
    /// way back to it.
    @Published private(set) var setup: ProgramSetup?
    @Published var lastError: String?
    /// Which stage a planning pipeline is in, or nil between them. On a full-auto run this
    /// is the whole UI — the user reads it off the program list's session row.
    ///
    /// A typed stage rather than the display string it used to be: the Research tab matched
    /// that string literally to draw its stage strip, so renaming a stage broke the strip
    /// silently.
    @Published private(set) var stage: PlanningStage?

    /// The stage as a line of text, for rows that only show one.
    var fullAutoStage: String? { stage?.label }
    /// The streamed output of the pilots and the planning passes, so a planning run is
    /// watchable rather than a spinner with a stage name on it.
    @Published private(set) var activityLog = ""
    /// Whether the log is mid-thinking-block, for the ┄┄ markers.
    private var inThinking = false
    /// The problem the current pilots were run against, so a re-plan of the *same* problem
    /// reuses them instead of paying for four identical turns again. Pilots do not depend on
    /// the goal kind, which is the only thing a re-plan changes.
    private var pilotProblem: String?
    /// How the statement was read, produced before the contract and kept for the review sheet.
    @Published private(set) var statementAudit: StatementAuditor.Audit?
    /// Where this session's turns are written until there is a program to file them under.
    ///
    /// The front half runs before any program exists, and a program's id is derived from a title
    /// the portfolio pass has not produced yet — so the audit, the contract, the pilots and the
    /// portfolio are recorded under a provisional id and adopted at approval. Without this the
    /// pilots, which are the single thing a reader most wants to see afterwards, would be the
    /// one part of a run with no home.
    private(set) var sessionID = "planning-\(UUID().uuidString.prefix(8))"
    /// The limits the user set before starting, carried through to the selection and review
    /// panes so they are asked once rather than at every gate.
    var proposedLimits = RunLimits()
    /// The problem this session is working. Published so leaving the planner pane and coming
    /// back shows the session that is still running rather than an empty field.
    @Published private(set) var problem = ""

    var goal: String { setup?.goal ?? "" }

    /// True while a planning session exists at all — generating, finished and awaiting
    /// review, or stopped part-way. What the Research tab offers a way back into.
    var hasSession: Bool { setup != nil }

    /// One line describing where the session is, for the row in the program list.
    var sessionStatus: String {
        if let fullAutoStage, isGenerating { return fullAutoStage }
        if isGenerating { return "Planning branches — \(completedCount)/\(legs.count) done" }
        if let lastError { return "Planning stopped — \(lastError)" }
        if allDone { return "\(legs.count) branch plan(s) ready to review" }
        let planned = legs.filter { $0.option != nil }.count
        return "Planning stopped — \(planned)/\(legs.count) branch plan(s) generated"
    }

    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    /// Identifies the newest run, so a superseded one cannot clear `isGenerating` out
    /// from under its replacement.
    private var runToken = 0

    var allDone: Bool { !legs.isEmpty && legs.allSatisfy(\.isDone) }
    var completedCount: Int { legs.filter(\.isDone).count }

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// Begins pass 2 for the approaches the user selected. A fresh selection supersedes any
    /// run still in flight — going Back and changing the picks has to take effect, not be
    /// silently dropped in favour of the plans already being generated.
    func generate(setup: ProgramSetup) {
        cancel()
        self.setup = setup
        legs = setup.legs
        lastError = nil
        run(legIDs: legs.map(\.id))
    }

    /// Re-runs one failed leg without touching the others.
    func retry(legID: String) {
        guard !isGenerating, legs.contains(where: { $0.id == legID }) else { return }
        run(legIDs: [legID])
    }

    func cancel() {
        task?.cancel()
        task = nil
        runToken &+= 1
        isGenerating = false
    }

    func reset() {
        cancel()
        // A new session gets its own directory: turns from a portfolio the user looked at and
        // declined stay together, and are not silently merged into the next attempt's.
        let retiredSessionID = sessionID
        sessionID = "planning-\(UUID().uuidString.prefix(8))"
        Task { await ProgramUsageRegistry.shared.unregister(programID: retiredSessionID) }
        legs = []
        setup = nil
        lastError = nil
        pilots = []
        runningPilot = nil
        recognition = nil
        goalDraft = nil
        contractDraft = nil
        statementAudit = nil
        stage = nil
        activityLog = ""
        inThinking = false
        problem = ""
    }

    /// Clears the branch-planning side of a session while keeping the pilots and the drafted
    /// contract. Called when a new portfolio arrives: the pilots ran *before* it and produced
    /// it, so they are part of this session, not leftovers from the last one.
    func prepareForProposal() {
        legs = []
        setup = nil
        lastError = nil
    }

    /// The shared front half of both paths: **formal goal item → recognition →
    /// optional pilots → portfolio.**
    ///
    /// The order is the point, and it changed. The contract used to be drafted last of the
    /// three, from what the pilots had reached — which let what turned out to be *achievable*
    /// shape what counted as an answer. Now the statement is normalized first, the contract is
    /// frozen from that alone, and everything downstream is told what would settle the problem
    /// before it starts looking. The pilots are contract-aware for the same reason: an attempt
    /// that knows what would count spends its budget differently.
    ///
    /// Both paths run exactly this; what differs is who reviews the gates afterwards.
    private func runFrontHalf(
        problem: String,
        reusablePilots: [Pilots.Result],
        includePilots: Bool,
        fullAuto: Bool,
        token: Int
    ) async throws -> (proposal: ApproachProposal, draft: ContractDrafter.Draft?)? {
        guard let appState else { return nil }
        await registerUsageAccounting(totalBudget: proposedLimits.programTokenBudget)
        self.problem = problem

        // 1. One editor owns interpretation, library selection/creation, and the exact
        //    Statement that will bind every later agent.
        stage = .formalizingGoal
        appendLog("━━ formalizing the research goal item ━━\n")
        let goalContext = try appState.makeResearchGoalEditorContext()
        let formalized = try await optionalUnlessBudgetPause {
            try await ResearchGoalEditor.run(
                runner: goalContext.runner, request: problem, store: goalContext.store,
                tools: goalContext.tools, notation: goalContext.notation,
                macros: goalContext.macros, outline: goalContext.outline,
                thinking: goalContext.thinking,
                programID: sessionID, record: appState.makeTurnRecorder(),
                applyCreate: goalContext.applyCreate,
                onActivity: { activity in
                    Task { @MainActor [weak self] in self?.record(activity) }
                })
        }
        try Task.checkCancellation()
        guard runToken == token else { return nil }
        guard let formalized else {
            throw CoreError.io("The request could not be turned into a formal research-goal item.")
        }
        goalDraft = formalized
        statementAudit = formalized.audit
        let draft = formalized.draft
        contractDraft = draft
        let contract = draft.contract
        let formalGoal = contract.statement

        // 2. One bounded attempt before the portfolio machinery. It may create new items but
        //    cannot edit existing theory; any solution claim is independently checked now.
        stage = .recognizing
        appendLog("\n━━ recognition — can this be answered directly? ━━\n")
        let recognitionContext = try appState.makeRecognitionContext()
        var recognized = try await Recognition.run(
            runner: recognitionContext.runner, goal: formalGoal, contract: contract,
            targetItemID: formalized.item.id,
            tools: recognitionContext.tools, notation: recognitionContext.notation,
            outline: recognitionContext.outline, thinking: recognitionContext.thinking,
            programID: sessionID, record: appState.makeTurnRecorder(),
            onActivity: { activity in
                Task { @MainActor [weak self] in self?.record(activity) }
            })
        if let claim = recognized?.claim {
            let candidate = try await appState.reviewRecognitionClaim(
                claim, goal: formalGoal, contract: contract,
                targetItemID: formalized.item.id, sessionID: sessionID)
            recognized?.candidate = candidate
        }
        try Task.checkCancellation()
        guard runToken == token else { return nil }
        recognition = recognized

        // An unattended run does not launch pilots and a portfolio after both independent
        // gates have already accepted an answer. The empty proposal is a hand-off marker; the
        // full-auto path files the result directly below.
        if fullAuto, recognized?.candidate?.status == .accepted {
            return (ApproachProposal(goal: formalGoal, title: formalized.item.name,
                                     approaches: [], skippedCells: []), draft)
        }

        // 4. Optional pilots, selected after recognition and told exactly what it established
        //    or why its proposed answer failed.
        var results = reusablePilots
        if !includePilots {
            results = []
            runningPilot = nil
            appendLog("\n━━ pilots skipped for this program ━━\n")
        } else if results.isEmpty {
            stage = .selectingPilots
            appendLog("\n━━ choosing this problem's first attempts ━━\n")
            let (selectorRunner, selectorThinking) = try appState.makePilotSelectorContext()
            let briefs = try await PilotSelector.select(
                runner: selectorRunner, goal: formalGoal, contract: contract,
                recognitionDigest: recognized?.digest ?? "",
                thinking: selectorThinking,
                programID: sessionID, record: appState.makeTurnRecorder(),
                onActivity: { activity in
                    Task { @MainActor [weak self] in self?.record(activity) }
                })
            try Task.checkCancellation()
            guard runToken == token else { return nil }

            appendLog("\n━━ pilots — \(briefs.count) independent first attempts ━━\n")
            let (runner, tools, notation, outline, memory, thinking) =
                try appState.makePilotContext()
            results = try await Pilots.runAll(
                runner: runner, briefs: briefs, goal: formalGoal, tools: tools,
                contract: contract, notation: notation, outline: outline, memory: memory,
                thinking: thinking,
                programID: sessionID, record: appState.makeTurnRecorder(),
                onPilotStarted: { brief in
                    Task { @MainActor [weak self] in
                        self?.runningPilot = brief
                        self?.stage = .pilot(brief.title)
                        self?.appendLog("\n── \(brief.title) ──\n")
                    }
                },
                onActivity: { activity in
                    Task { @MainActor [weak self] in self?.record(activity) }
                })
            try Task.checkCancellation()
            guard runToken == token else { return nil }
            runningPilot = nil
        } else {
            appendLog("━━ reusing the \(results.count) pilot(s) already run for this problem ━━\n")
        }
        pilots = results
        pilotProblem = includePilots ? problem : nil

        // 5. The portfolio: broad routes, designed against recognition and the pilots.
        stage = .designingPortfolio
        appendLog("\n━━ designing the portfolio ━━\n")
        let planningEvidence = [recognized?.digest, Pilots.digest(results)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let captured = ProposalBox()
        let (plannerRunner, plannerConfig) = try appState.makeProgramPlannerConfig(
            goal: formalGoal,
            contract: contract,
            pilotDigest: planningEvidence,
            fullAuto: fullAuto,
            onProposal: { captured.set($0) })
        let plannerResult = try await runRecordedTurn(
            runner: plannerRunner, config: plannerConfig,
            history: [.user(ProgramPlanner.pass1UserMessage(problem: formalGoal))],
            programID: sessionID, role: .portfolio,
            title: "The portfolio of routes",
            record: appState.makeTurnRecorder(),
            outcome: { _ in
                guard let proposal = captured.value else { return "no routes proposed" }
                let activated = proposal.approaches.filter(\.activate).count
                return "\(proposal.approaches.count) route(s), \(activated) activated"
            }
        ) { activity in
            Task { @MainActor [weak self] in self?.record(activity) }
        }
        try Task.checkCancellation()
        guard runToken == token else { return nil }
        guard let proposed = captured.value else {
            throw CoreError.io("The planner ended without proposing any routes.")
        }
        // The planner may paraphrase the goal in its tool call. Titles and routes are its
        // output; the program goal is not. Preserve the user's bytes as the sole authority.
        var proposal = ApproachProposal(
            goal: formalGoal, title: proposed.title, approaches: proposed.approaches,
            skippedCells: proposed.skippedCells)

        // The portfolio does not certify its own diversity. A reviewer-tier fresh context sees
        // only the submitted mechanisms and the observed recognition/pilot evidence. One repair
        // is allowed; a second rejection stops planning instead of launching known-bad work.
        appendLog("\n━━ independently auditing portfolio coverage ━━\n")
        let (portfolioAuditRunner, portfolioAuditThinking) =
            try appState.makePortfolioAuditorContext()
        var portfolioAudit = try await PortfolioAuditor.audit(
            runner: portfolioAuditRunner, goal: formalGoal, contract: contract, proposal: proposal,
            evidenceDigest: planningEvidence, thinking: portfolioAuditThinking,
            programID: sessionID, record: appState.makeTurnRecorder(),
            onActivity: { activity in
                Task { @MainActor [weak self] in self?.record(activity) }
            })

        if !portfolioAudit.accepted {
            appendLog("\n━━ coverage rejected; one portfolio repair ━━\n\(portfolioAudit.feedback)\n")
            let revised = ProposalBox()
            let (repairRunner, repairConfig) = try appState.makeProgramPlannerConfig(
                goal: formalGoal, contract: contract, pilotDigest: planningEvidence,
                fullAuto: fullAuto, onProposal: { revised.set($0) })
            _ = try await runRecordedTurn(
                runner: repairRunner, config: repairConfig,
                history: plannerResult.transcript + [.user("""
                A fresh-context coverage auditor rejected the activated portfolio:

                \(portfolioAudit.feedback)

                Repair only those concrete gaps. Do not add routes merely to increase the
                count. Call propose_approaches once with the revised portfolio.
                """)],
                programID: sessionID, role: .portfolio,
                title: "Portfolio repair after coverage audit",
                record: appState.makeTurnRecorder(),
                outcome: { _ in revised.value == nil ? "no revised portfolio" : "portfolio revised" },
                onActivity: { activity in
                    Task { @MainActor [weak self] in self?.record(activity) }
                })
            guard let repaired = revised.value else {
                throw CoreError.io("The planner did not repair the rejected portfolio.")
            }
            proposal = ApproachProposal(
                goal: formalGoal, title: repaired.title, approaches: repaired.approaches,
                skippedCells: repaired.skippedCells)
            let (secondAuditRunner, secondAuditThinking) =
                try appState.makePortfolioAuditorContext()
            portfolioAudit = try await PortfolioAuditor.audit(
                runner: secondAuditRunner, goal: formalGoal, contract: contract,
                proposal: proposal, evidenceDigest: planningEvidence,
                thinking: secondAuditThinking, programID: sessionID,
                record: appState.makeTurnRecorder())
        }
        guard portfolioAudit.accepted else {
            throw CoreError.io("Portfolio coverage remained inadequate: \(portfolioAudit.feedback)")
        }
        return (proposal, draft)
    }

    func draftContract(goal: String) {
        guard let appState else { return }
        cancel()
        lastError = nil
        isGenerating = true
        runToken &+= 1
        let token = runToken

        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.runToken == token { self.isGenerating = false } }
            do {
                await self.registerUsageAccounting(totalBudget: self.proposedLimits.programTokenBudget)
                let context = try appState.makeResearchGoalEditorContext()
                let result = try await ResearchGoalEditor.run(
                    runner: context.runner,
                    request: self.problem.isEmpty ? goal : self.problem,
                    store: context.store, tools: context.tools,
                    notation: context.notation, macros: context.macros,
                    outline: context.outline, thinking: context.thinking,
                    programID: self.sessionID, record: appState.makeTurnRecorder(),
                    applyCreate: context.applyCreate)
                guard self.runToken == token else { return }
                self.goalDraft = result
                self.statementAudit = result?.audit
                self.contractDraft = result?.draft
            } catch is CancellationError {
                return
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Activity log

    private func appendLog(_ text: String) {
        activityLog = String((activityLog + text).suffix(24_000))
    }

    /// Streams an agent turn into the planning log, so the pilots and the portfolio pass are
    /// watchable rather than a spinner with a stage name.
    private func record(_ activity: AgentActivity) {
        switch activity {
        case .thinkingDelta(let delta):
            if !inThinking { inThinking = true; appendLog("\n┄┄ thinking ┄┄\n") }
            appendLog(delta)
        case .textDelta(let delta):
            closeThinking()
            appendLog(delta)
        case .toolStarted(let name, let summary):
            closeThinking()
            appendLog("\n→ \(name) \(summary)\n")
        case .toolFinished(let name, _, let isError):
            if isError { appendLog("✕ \(name) failed\n") }
        case .usage, .usageDetails:
            break
        case .iterationLimitReached:
            appendLog("\n⚠︎ iteration limit reached\n")
        }
    }

    private func closeThinking() {
        guard inThinking else { return }
        inThinking = false
        appendLog("\n┄┄ end thinking ┄┄\n")
    }

    /// The unattended path: the same front half, then branch plans, approval and the run,
    /// with no stop in between. "Attach this problem" and the next thing the user hears is
    /// the result.
    ///
    /// Every stage is the code the supervised flow uses; what changes is who decides. The
    /// contract is frozen from the audited statement first and then binds **unreviewed** —
    /// `reviewedAt` stays nil, so a `settled` verdict reports itself as settled against a
    /// contract nobody checked. The planner's own `activate` picks select the portfolio and
    /// its listed order is the attack order.
    /// Formalize one frozen goal, then let the persistent director choose its assignments.
    func runDirectorFirst(
        problem: String,
        policy: ContinuationPolicy = .fullAuto,
        maxConcurrentBranches: Int = 1,
        limits: ResearchLimits? = nil,
        roleModelOverrides: [String: ResearchProgram.ModelOverride] = [:],
        onStarted: @escaping (ResearchProgram) -> Void
    ) {
        guard let appState else { return }
        let effectiveLimits = limits ?? AppSettings.researchLimits
        cancel()
        reset()
        lastError = nil
        isGenerating = true
        runToken &+= 1
        let token = runToken

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.runToken == token {
                    self.isGenerating = false
                    self.stage = nil
                }
            }
            do {
                await self.registerUsageAccounting(totalBudget: effectiveLimits.programTokens.runnerValue, limits: effectiveLimits)
                self.problem = problem

                self.stage = .formalizingGoal
                self.appendLog("━━ formalizing the research goal item ━━\n")
                let context = try appState.makeResearchGoalEditorContext()
                let formalized = try await self.optionalUnlessBudgetPause {
                    try await ResearchGoalEditor.run(
                        runner: context.runner, request: problem, store: context.store,
                        tools: context.tools, notation: context.notation, macros: context.macros,
                        outline: context.outline, thinking: context.thinking,
                        programID: self.sessionID, record: appState.makeTurnRecorder(),
                        applyCreate: context.applyCreate,
                        onActivity: { activity in
                            Task { @MainActor [weak self] in self?.record(activity) }
                        })
                }
                try Task.checkCancellation()
                guard self.runToken == token else { return }
                guard let formalized else {
                    throw CoreError.io("The request could not be turned into a formal research-goal item.")
                }
                self.goalDraft = formalized
                self.statementAudit = formalized.audit
                self.contractDraft = formalized.draft

                self.stage = .starting
                self.appendLog("\n━━ handing this to the director ━━\n")
                var program = try appState.approveProgram(
                    goal: problem, title: formalized.item.name,
                    branches: [], skippedCells: [],
                    programTokenBudget: effectiveLimits.programTokens.runnerValue,
                    maxConcurrentBranches: maxConcurrentBranches, runMode: .auto,
                    contract: formalized.draft.contract, continuation: policy,
                    pilotsEnabled: false,
                    targetItemID: formalized.item.id,
                    adoptTurnsFromSession: self.sessionID,
                    allowEmptyForDirector: true)
                program.execution = ResearchExecution(limits: effectiveLimits)
                program.roleModelOverrides = roleModelOverrides
                try appState.store?.saveProgram(program)
                appState.reloadPlans()
                onStarted(program)
                self.reset()
            } catch is CancellationError {
                return
            } catch {
                guard self.runToken == token else { return }
                self.lastError = error.localizedDescription
                self.appendLog("\n✕ \(error.localizedDescription)\n")
            }
        }
    }

    /// A display title for `runDirectorFirst`, which has no portfolio-planning turn to author
    /// one — every other path's title comes from the planner. Truncated at a word boundary so
    /// it reads as a title rather than a cut-off sentence; the full problem is untouched as
    /// `goal`, this is display (and the id slug) only. `TheoryItem.sanitizeID` itself caps at
    /// `sanitizedIDMaxLength`, so a too-long title can no longer produce an invalid filename —
    /// this exists so the program's name in the list and the page header reads as one too.
    static func shortTitle(from problem: String, maxLength: Int = 80) -> String {
        let trimmed = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let truncated = trimmed.prefix(maxLength)
        guard let lastSpace = truncated.lastIndex(of: " "), lastSpace > truncated.startIndex
        else { return String(truncated) + "…" }
        return String(truncated[..<lastSpace]) + "…"
    }

    /// What the planner sees of the pilots — empty until they have run.
    var pilotDigest: String { Pilots.digest(pilots) }

    func updateLeg(id: String, _ mutate: (inout Leg) -> Void) {
        guard let index = legs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&legs[index])
    }

    /// What `AppState.approveProgram` needs, for the legs that produced a plan.
    var approvedBranches: [AppState.ApprovedBranch] {
        legs.compactMap { leg in
            guard let option = leg.option else { return nil }
            return AppState.ApprovedBranch(
                approach: leg.approach, option: option, tokenBudget: leg.tokenBudget,
                providerKind: leg.providerKind, model: leg.model)
        }
    }

    /// Legs are addressed by id rather than by position: `legs` can be replaced while a
    /// planning turn is awaiting the provider, and a stale index would then write into the
    /// wrong branch — or past the end of the array.
    private func run(legIDs: [String]) {
        guard let appState else { return }
        isGenerating = true
        runToken &+= 1
        let token = runToken
        for legID in legIDs {
            updateLeg(id: legID) { $0.status = .pending; $0.declineReason = nil }
        }
        let goal = self.goal
        let contract = self.contractDraft?.contract
        // `cancel()` is the user's Stop: it leaves the session in place so the partial
        // result stays reviewable, and only `reset()` throws the session away.
        task = Task { [weak self] in
            if let self {
                await self.registerUsageAccounting(
                    totalBudget: self.setup?.programTokenBudget
                        ?? self.proposedLimits.programTokenBudget)
            }
            for legID in legIDs {
                guard let self, !Task.isCancelled,
                      let approach = self.legs.first(where: { $0.id == legID })?.approach
                else { break }
                self.updateLeg(id: legID) { $0.status = .running }
                do {
                    let captured = OptionBox()
                    let (runner, config) = try appState.makeBranchPlannerConfig(
                        approach: approach, goal: goal, contract: contract,
                        onProposal: { option in captured.set(option) },
                        onDecline: { captured.decline($0) })
                    _ = try await runRecordedTurn(
                        runner: runner, config: config,
                        history: [.user(ProgramPlanner.pass2UserMessage(approach: approach, goal: goal))],
                        programID: self.sessionID, role: .branchPlan,
                        title: "Task list — \(approach.title)",
                        record: appState.makeTurnRecorder(),
                        outcome: { _ in
                            captured.value.map { "\($0.tasks.count) task(s)" }
                                ?? captured.declineReason.map { "declined — \($0.prefix(160))" }
                                ?? "no task list proposed"
                        })

                    if let option = captured.value {
                        self.updateLeg(id: legID) { $0.option = option; $0.status = .done }
                    } else if let reason = captured.declineReason {
                        self.updateLeg(id: legID) {
                            $0.declineReason = reason
                            $0.status = .done
                        }
                    } else {
                        self.updateLeg(id: legID) {
                            $0.status = .failed("The planner ended without proposing a task list.")
                        }
                    }
                } catch is CancellationError {
                    self.updateLeg(id: legID) { $0.status = .failed("cancelled") }
                    break
                } catch {
                    self.updateLeg(id: legID) { $0.status = .failed(error.localizedDescription) }
                    self.lastError = error.localizedDescription
                }
            }
            // Only the newest run owns the flag; a superseded one must leave it alone.
            if let self, self.runToken == token { self.isGenerating = false }
        }
    }

    /// Starts or refreshes the shared gate from what is already durable. Planning can pause
    /// between portfolio review and branch generation; re-registering from the ledger means
    /// that pause never resets its spend.
    private func registerUsageAccounting(totalBudget: Int, limits: ResearchLimits? = nil) async {
        guard let store = appState?.store else { return }
        let id = sessionID
        let alreadySpent = store.usageTokens(programID: id)
        await ProgramUsageRegistry.shared.register(
            programID: id,
            totalBudget: max(1, totalBudget),
            initialSpent: alreadySpent,
            limits: limits,
            append: { entry in try? store.saveUsageEntry(entry) })
    }

    /// Audit and contract drafting deliberately tolerate ordinary provider failures and fall
    /// back to the raw problem. A shared-ceiling pause is different: it must stop the entire
    /// pipeline so the user can raise the one limit and continue from this stage.
    private func optionalUnlessBudgetPause<Value>(
        _ operation: () async throws -> Value?
    ) async throws -> Value? {
        do {
            return try await operation()
        } catch let error as ProgramUsageError {
            throw error
        } catch {
            return nil
        }
    }
}

/// Thread-safe hand-off from the planning tool's callback. Shared with `appendGeneration`,
/// which runs the same pass-2 planner to turn a director's route into a branch.
final class OptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: PlanProposal.Option?
    private var _declineReason: String?
    func set(_ option: PlanProposal.Option) {
        lock.lock(); _value = option; _declineReason = nil; lock.unlock()
    }
    func decline(_ reason: String) {
        lock.lock(); _value = nil; _declineReason = reason; lock.unlock()
    }
    var value: PlanProposal.Option? { lock.lock(); defer { lock.unlock() }; return _value }
    var declineReason: String? { lock.lock(); defer { lock.unlock() }; return _declineReason }
}

/// The same hand-off for pass 1, used by the full-auto pipeline: it captures the portfolio
/// instead of raising the selection pane, because there is nobody to select.
final class ProposalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ApproachProposal?
    func set(_ proposal: ApproachProposal) { lock.lock(); _value = proposal; lock.unlock() }
    var value: ApproachProposal? { lock.lock(); defer { lock.unlock() }; return _value }
}


/// Where a planning pipeline is. Typed rather than a display string, because the Research
/// tab used to match the string literally to draw its stage strip.
enum PlanningStage: Equatable {
    case formalizingGoal
    case auditingStatement
    case draftingContract
    case recognizing
    case selectingPilots
    case pilot(String)
    case designingPortfolio
    case planningBranch(String)
    case starting

    var label: String {
        switch self {
        case .formalizingGoal: return "Formalizing the research goal"
        case .auditingStatement: return "Auditing the statement"
        case .draftingContract: return "Drafting the success contract"
        case .recognizing: return "Checking for a direct answer"
        case .selectingPilots: return "Choosing the first attempts"
        case .pilot(let title): return "Pilot: \(title)"
        case .designingPortfolio: return "Designing the portfolio"
        case .planningBranch(let title): return "Planning branch: \(title)"
        case .starting: return "Starting the run"
        }
    }

    /// Which of the strip's four steps this stage belongs to, so the strip is driven by the
    /// pipeline rather than by string matching.
    var stripIndex: Int {
        switch self {
        case .formalizingGoal: return 0
        case .auditingStatement: return 0
        case .draftingContract: return 0
        case .recognizing, .selectingPilots, .pilot: return 1
        case .designingPortfolio: return 2
        case .planningBranch, .starting: return 3
        }
    }
}
