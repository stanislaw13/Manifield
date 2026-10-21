import Foundation
import ManifieldCore

// MARK: - Run state (persisted)

/// The coordinator's scheduling view of a branch. The branch's own `RunRecord` stays
/// authoritative for its internals — this only says whether it holds a slot, released
/// one, or is done for good.
public enum BranchRunStatus: String, Codable, Sendable {
    case queued
    case running
    /// Paused on ask_user — the slot is released so siblings keep working.
    case waitingUser = "waiting_user"
    /// Hit its own token budget; resumable once the user raises it.
    case budgetPaused = "budget_paused"
    /// A direct assignment spent its allocation; the director chooses the next work.
    case assignmentExhausted = "assignment_exhausted"
    /// Checkpoint-mode pause after a task.
    case checkpoint
    /// A provider or tool error ended the leg. Resumable — no retry is attempted here.
    case errored
    case finished
    case failed
    /// Stopped by the user, e.g. after a sibling published a counterexample.
    case killed

    public var isTerminal: Bool {
        self == .finished || self == .failed || self == .killed || self == .assignmentExhausted
    }

    /// True while the branch still holds (or wants) an execution slot.
    public var isPausedByUser: Bool {
        self == .waitingUser || self == .budgetPaused || self == .checkpoint || self == .errored
    }
}

/// Why the whole program stopped admitting branches.
public enum ProgramPause: Codable, Equatable, Sendable {

    case programBudgetReached
    case wallClockReached
}

/// Volatile program-run state (`sessions/program-run-<programID>.json`). Branch run
/// records keep their existing per-plan files, so N branches need no new keying.
public struct ProgramRunRecord: Codable, Equatable, Sendable {
    public var programID: String
    public var branchStatuses: [String: BranchRunStatus]
    public var pause: ProgramPause?
    public var updatedAt: Date
    /// First execution start; preserved across dispatches and app restarts.
    public var startedAt: Date?
    /// Which wave of branches is running. Bumped when the director opens a generation.
    public var generation: Int = 1
    /// Findings already published when this generation began, so the progress signal counts
    /// what *this* generation learned rather than the whole program's history.
    public var findingsAtGenerationStart: Int = 0
    /// The director's last status line — the research page's copy, produced by a turn that was
    /// happening anyway rather than by a separate "write a summary" call.
    public var lastStatus: String?

    public init(programID: String, branchStatuses: [String: BranchRunStatus] = [:],
                pause: ProgramPause? = nil, updatedAt: Date = Date(),
                generation: Int = 1, findingsAtGenerationStart: Int = 0,
                lastStatus: String? = nil, startedAt: Date? = nil) {
        self.programID = programID
        self.branchStatuses = branchStatuses
        self.pause = pause
        self.updatedAt = updatedAt
        self.generation = generation
        self.findingsAtGenerationStart = findingsAtGenerationStart
        self.lastStatus = lastStatus
        self.startedAt = startedAt
    }

    public func status(of planID: String) -> BranchRunStatus {
        branchStatuses[planID] ?? .queued
    }
}

// MARK: - Runner

/// Coordinates one research program: branches run in the order whoever authored the
/// generation ranked them; a slot pool where branches paused on the user release their slot
/// instead of stalling the program; findings submitted to a pool the director routes; a
/// program-level token ceiling; and a synthesis turn when every branch has stopped.
///
/// Ordering carries **no opinion of its own**. `executionOrder` honours `Branch.priority` and
/// nothing else — there is no refute-first rule and no cheapest-first fallback. Both existed,
/// and both were a scheduler second-guessing the agent that had just designed the portfolio and
/// knew far more than a three-way cost bucket or a stance label. The pass-1 planner ranks
/// generation 1, the director ranks every later one, and the listed order is the attack order.
///
/// The workbench stays program-agnostic — branches are built by the injected factory and
/// differ only in the memory, lens and tools they were given. The runner never touches
/// `ProjectStore`: plans and records come in pre-loaded, and everything it changes on
/// disk goes out through callbacks the app hops to the main actor.
public final class ProgramRunner {

    /// What the coordinator hands each branch's workbench factory.
    public struct BranchRuntime: Sendable {
        /// Exact admission snapshot, including dynamically created plans and target revisions.
        public let program: ResearchProgram
        public let plan: PlanDocument
        /// The findings pool, read fresh at every task start.
        public let findings: @Sendable () -> [ProgramFinding]
        /// Submits a finding to the program's pool. It reaches nobody until the director
        /// routes it, which this kicks off in the background.
        public let publish: @Sendable (ProgramFinding) async throws -> Void
    }

    public enum Event: Sendable {
        case branchStarted(planID: String)
        case branchEvent(planID: String, ResearchWorkbench.Event)
        case branchStatusChanged(planID: String, BranchRunStatus)
        /// Emitted the moment a leg ends, so the controller persists before the next one.
        case recordUpdated(planID: String, RunRecord)
        case findingPublished(ProgramFinding)
        case problemChallengeReviewed(ProblemChallenge)
        case programPaused(ProgramPause)
        case branchFailed(planID: String, error: String)
        case synthesisStarted
        case directorStarted
        case directorDecided(Director.Decision)
    }

    public enum Outcome: Sendable {
        /// Every branch reached a terminal state; synthesis ran if a runner was supplied.
        case finished(report: String?)
        /// Admission stopped at the program ceiling. The user decides.
        case paused(ProgramPause)
        /// Nothing is runnable because every live branch waits on the user.
        case waitingOnUser
        /// The director settled the program or called it futile. Terminal. The report is the
        /// synthesis run's — the deliverable of an unattended program, written here because
        /// "the user only hears back at the end" means the end has to actually say something.
        case decided(Director.Decision, report: String?)
        /// The director wants another generation and has proposed the routes. Turning routes
        /// into branches needs plan and workbench construction, which only the app can do, so
        /// the runner hands back rather than reaching for the store it deliberately never touches.
        case awaitingNextGeneration(Director.Decision)
    }

    /// Everything mutated across concurrent legs, behind one lock.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _program: ResearchProgram
        private var _checkpoint: ProgramRunRecord?
        var checkpoint: ProgramRunRecord? { lock.lock(); defer { lock.unlock() }; return _checkpoint }
        func setCheckpoint(_ record: ProgramRunRecord) { lock.lock(); _checkpoint = record; lock.unlock() }
        private var _routingTask: Task<Void, Never>?
        var routingTask: Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return _routingTask }
        var program: ResearchProgram { lock.lock(); defer { lock.unlock() }; return _program }
        func setProgram(_ program: ResearchProgram) { lock.lock(); _program = program; lock.unlock() }
        private var _findings: [ProgramFinding]
        private var _records: [String: RunRecord]
        private var _statuses: [String: BranchRunStatus]
        private var _pause: ProgramPause?
        private var _routings: [FindingRouting]
        private var _solutions: [SolutionCandidate]
        private var _challenges: [ProblemChallenge]
        /// True while a routing turn is in flight, so findings landing during one are
        /// coalesced into the next rather than each buying their own director call.
        private var _routingInFlight = false
        /// Freshest plan seen per branch, tracked from `planUpdated`. A retry that restarted
        /// from the runner's load-time copy would re-run tasks that already completed.
        private var _plans: [String: PlanDocument] = [:]

        init(program: ResearchProgram, findings: [ProgramFinding], routings: [FindingRouting],
             solutions: [SolutionCandidate], challenges: [ProblemChallenge],
             records: [String: RunRecord], statuses: [String: BranchRunStatus]) {
            self._program = program
            self._findings = findings
            self._routings = routings
            self._solutions = solutions
            self._challenges = challenges
            self._records = records
            self._statuses = statuses
        }

        func plan(_ planID: String) -> PlanDocument? {
            lock.lock(); defer { lock.unlock() }; return _plans[planID]
        }
        func setPlan(_ plan: PlanDocument, for planID: String) {
            lock.lock(); _plans[planID] = plan; lock.unlock()
        }

        var findings: [ProgramFinding] { lock.lock(); defer { lock.unlock() }; return _findings }
        var records: [String: RunRecord] { lock.lock(); defer { lock.unlock() }; return _records }
        var statuses: [String: BranchRunStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }
        var pause: ProgramPause? { lock.lock(); defer { lock.unlock() }; return _pause }

        func record(_ planID: String) -> RunRecord? {
            lock.lock(); defer { lock.unlock() }; return _records[planID]
        }
        func setRecord(_ record: RunRecord, for planID: String) {
            lock.lock(); _records[planID] = record; lock.unlock()
        }
        func status(_ planID: String) -> BranchRunStatus {
            lock.lock(); defer { lock.unlock() }; return _statuses[planID] ?? .queued
        }
        func setStatus(_ status: BranchRunStatus, for planID: String) {
            lock.lock(); _statuses[planID] = status; lock.unlock()
        }
        var routings: [FindingRouting] { lock.lock(); defer { lock.unlock() }; return _routings }
        var acceptedCandidate: SolutionCandidate? {
            lock.lock(); defer { lock.unlock() }
            return _solutions.first { $0.status == .accepted }
        }
        var solutions: [SolutionCandidate] {
            lock.lock(); defer { lock.unlock() }; return _solutions
        }
        var challenges: [ProblemChallenge] {
            lock.lock(); defer { lock.unlock() }; return _challenges
        }
        var acceptedChallenge: ProblemChallenge? {
            lock.lock(); defer { lock.unlock() }
            return _challenges.first { $0.status == .accepted && $0.governance == nil }
        }
        func upsertSolution(_ candidate: SolutionCandidate) {
            lock.lock()
            _solutions.removeAll { $0.id == candidate.id }
            _solutions.append(candidate)
            lock.unlock()
        }
        func upsertChallenge(_ challenge: ProblemChallenge) {
            lock.lock()
            _challenges.removeAll { $0.id == challenge.id }
            _challenges.append(challenge)
            lock.unlock()
        }
        func mergePersistedClaims(_ persisted: ResearchProgram) {
            lock.lock()
            for candidate in persisted.solutions {
                _solutions.removeAll { $0.id == candidate.id }
                _solutions.append(candidate)
            }
            for challenge in persisted.challenges {
                _challenges.removeAll { $0.id == challenge.id }
                _challenges.append(challenge)
            }
            lock.unlock()
        }

        func addFinding(_ finding: ProgramFinding) {
            lock.lock(); _findings.append(finding); lock.unlock()
        }
        func setRoutings(_ routings: [FindingRouting]) {
            lock.lock()
            for routing in routings {
                _routings.removeAll { $0.findingID == routing.findingID }
                _routings.append(routing)
            }
            lock.unlock()
        }
        /// Findings nobody has ruled on yet. Rejected claims never reach the pool, so
        /// everything here is a live candidate for routing.
        var unroutedFindings: [ProgramFinding] {
            lock.lock(); defer { lock.unlock() }
            let routed = Set(_routings.map(\.findingID))
            return _findings.filter { !routed.contains($0.id) && !$0.isRejected }
        }
        /// Claims the routing slot if it is free. The caller must release it.
        func startRouting(_ operation: @escaping @Sendable () async -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !_routingInFlight else { return }
            _routingInFlight = true
            _routingTask = Task { await operation() }
        }
        func endRouting() {
            lock.lock(); _routingInFlight = false; lock.unlock()
        }
        func setPause(_ pause: ProgramPause) {
            lock.lock(); if _pause == nil { _pause = pause }; lock.unlock()
        }
    }

    private let program: ResearchProgram
    private let plans: [String: PlanDocument]
    private let programRecord: ProgramRunRecord
    private let makeBranchWorkbench: @Sendable (ResearchProgram.Branch, BranchRuntime,
                                                @escaping @Sendable (ResearchWorkbench.Event) -> Void) async throws -> ResearchWorkbench
    private let saveProgram: @Sendable (ResearchProgram) async throws -> Void
    private let saveRunRecord: (@Sendable (RunRecord) async throws -> Void)?
    private let saveProgramRecord: (@Sendable (ProgramRunRecord) async throws -> Void)?
    private let savePlan: (@Sendable (PlanDocument) async throws -> Void)?
    private let resolveWorkerModel: (@Sendable (String?) async -> (providerKind: String, model: String)?)?
    /// Fresh manifest read. Claims are filed by tools while the runner is alive, so the
    /// launch-time value cannot contain them.
    private let loadProgram: (@Sendable () async -> ResearchProgram?)?
    private let synthesize: (@Sendable (ResearchProgram, [String: RunRecord]) async throws -> String)?
    /// Runs a director turn. Nil leaves the pre-director behaviour: synthesise and stop.
    private let direct: (@Sendable (ResearchProgram, [String: RunRecord],
                                    Director.ProgressSignal, Director.Trigger) async throws -> Director.Decision?)?
    /// Routes newly submitted findings. A separate, cheap director turn — it reads the branch
    /// registry and the pool, never a transcript, and decides who needs what. Nil leaves every
    /// finding unrouted, which means no branch sees it: silence is the safe default here,
    /// because the alternative is the broadcast this mechanism exists to stop.
    private let routeFindings: (@Sendable (ResearchProgram, [ProgramFinding]) async throws -> [FindingRouting])?
    /// Judges a solution candidate whose contract adjudication already passed: reviews the
    /// cited items and, always, the assembled argument. Nil leaves the candidate for the user.
    private let reviewSolution: (@Sendable (ResearchProgram, String) async throws -> SolutionCandidate.ReviewRuling)?
    private let reviewProblemChallenge: (@Sendable (ResearchProgram, String) async throws -> ProblemChallenge)?
    /// Turns the director's routes into planned branches, in place, the same way
    /// `appendGeneration` always has — contract redraft on a governed target change,
    /// portfolio coverage review, per-route pass-2 planning — and returns what it built so the
    /// runner can admit it without ever touching `ProjectStore` itself. Nil preserves the
    /// pre-existing behaviour exactly: the runner hands the decision back and the app opens
    /// the generation in a fresh run, as it always did.
    private let openGeneration: (@Sendable (ResearchProgram, [ResearchRoute], Int) async throws
        -> (program: ResearchProgram, plans: [String: PlanDocument]))?
    /// Durable, all-role usage from the program ledger. The director must see the same total
    /// as admission and the UI, including failed calls and earlier resumes.
    private let currentProgramTokensUsed: (@Sendable () async -> Int)?
    private let onEvent: @Sendable (Event) -> Void
    private let state: State
    /// Scheduling view of every branch the program has ever had, including ones `openGeneration`
    /// added after launch. Separate from `program` (frozen at construction) because a branch
    /// born mid-run has nowhere else to be looked up from when it is queued.
    private var trackedBranches: [String: ResearchProgram.Branch]
    /// Retries per leg before it is reported as errored. A dropped provider stream ended both
    /// live branches of the first automode run with no retry attempted at all.
    private let maxLegRetries: Int
    /// Seconds before the first retry, multiplied by the attempt number. Injectable so tests
    /// exercise the retry path without paying for the wait.
    private let legRetryBackoff: TimeInterval

    /// Slot count comes from the manifest. Token admission belongs exclusively to the shared
    /// usage ledger; duplicating it here from branch records was the source of divergent totals.
    private var maxConcurrentBranches: Int { max(1, program.maxConcurrentBranches) }

    public init(
        program: ResearchProgram,
        plans: [String: PlanDocument],
        records: [String: RunRecord],
        programRecord: ProgramRunRecord,
        makeBranchWorkbench: @escaping @Sendable (ResearchProgram.Branch, BranchRuntime,
                                                 @escaping @Sendable (ResearchWorkbench.Event) -> Void) async throws -> ResearchWorkbench,
        saveProgram: @escaping @Sendable (ResearchProgram) async throws -> Void,
        saveRunRecord: (@Sendable (RunRecord) async throws -> Void)? = nil,
        saveProgramRecord: (@Sendable (ProgramRunRecord) async throws -> Void)? = nil,
        savePlan: (@Sendable (PlanDocument) async throws -> Void)? = nil,
        resolveWorkerModel: (@Sendable (String?) async -> (providerKind: String, model: String)?)? = nil,
        loadProgram: (@Sendable () async -> ResearchProgram?)? = nil,
        synthesize: (@Sendable (ResearchProgram, [String: RunRecord]) async throws -> String)? = nil,
        direct: (@Sendable (ResearchProgram, [String: RunRecord],
                            Director.ProgressSignal, Director.Trigger) async throws -> Director.Decision?)? = nil,
        routeFindings: (@Sendable (ResearchProgram, [ProgramFinding]) async throws -> [FindingRouting])? = nil,
        reviewSolution: (@Sendable (ResearchProgram, String) async throws -> SolutionCandidate.ReviewRuling)? = nil,
        reviewProblemChallenge: (@Sendable (ResearchProgram, String) async throws -> ProblemChallenge)? = nil,
        openGeneration: (@Sendable (ResearchProgram, [ResearchRoute], Int) async throws
            -> (program: ResearchProgram, plans: [String: PlanDocument]))? = nil,
        currentProgramTokensUsed: (@Sendable () async -> Int)? = nil,
        maxLegRetries: Int = 2,
        legRetryBackoff: TimeInterval = 2,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.maxLegRetries = max(0, maxLegRetries)
        self.legRetryBackoff = max(0, legRetryBackoff)
        self.program = program
        self.plans = plans
        self.programRecord = programRecord
        self.makeBranchWorkbench = makeBranchWorkbench
        self.saveProgram = saveProgram
        self.saveRunRecord = saveRunRecord
        self.saveProgramRecord = saveProgramRecord
        self.savePlan = savePlan
        self.resolveWorkerModel = resolveWorkerModel
        self.loadProgram = loadProgram
        self.synthesize = synthesize
        self.direct = direct
        self.routeFindings = routeFindings
        self.reviewSolution = reviewSolution
        self.reviewProblemChallenge = reviewProblemChallenge
        self.openGeneration = openGeneration
        self.currentProgramTokensUsed = currentProgramTokensUsed
        self.onEvent = onEvent
        self.trackedBranches = Dictionary(uniqueKeysWithValues: program.branches.map { ($0.planID, $0) })
        self.state = State(program: program, findings: program.findings, routings: program.routings,
                           solutions: program.solutions, challenges: program.challenges,
                           records: records, statuses: programRecord.branchStatuses)
    }

    /// When every branch carries a priority, that IS the order — the planner or director
    /// chose the attack sequence by judgment, and the scheduler's job is to honour it.
    /// Otherwise (manifests from before priorities existed) fall back to the old
    /// manifest order, which for those is the order they were written in.
    ///
    /// There is deliberately no rule putting the challenging branch first. Whichever agent
    /// authored the generation ranked it — the pass-1 planner for generation 1, the director
    /// afterwards — and it knows things a scheduling heuristic does not: whether the cheap
    /// decisive test belongs to the challenger or to a builder, and whether the obvious answer
    /// is worth pinning down before anyone attacks it.
    static func executionOrder(_ branches: [ResearchProgram.Branch]) -> [ResearchProgram.Branch] {
        branches.enumerated().sorted { lhs, rhs in
            let l = lhs.element.priority ?? .max
            let r = rhs.element.priority ?? .max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Runs until the program can make no further progress without the user.
    /// `answers` supplies user text for branches paused on ask_user; `continueBranches`
    /// re-admits checkpoint / budget / errored branches the user chose to continue.
    /// Both jump the queue — an answered branch resumes before new work starts.
    /// `restrictTo`, when set, runs only those branches: the mathematician's override of
    /// the scheduler when they want one approach pushed forward now.
    public func run(
        answers: [String: String] = [:],
        continueBranches: Set<String> = [],
        restrictTo: Set<String>? = nil
    ) async throws -> (outcome: Outcome, records: [String: RunRecord], programRecord: ProgramRunRecord) {

        var initial = programRecord
        initial.startedAt = initial.startedAt ?? state.records.values.compactMap(\.startedAt).min() ?? Date()
        initial.pause = nil
        try await checkpoint(initial)
        let seconds = program.continuation?.maxWallClockSeconds ?? 0
        let deadline = seconds > 0 ? initial.startedAt!.addingTimeInterval(seconds) : nil
        do {
            if let deadline, deadline <= Date() {
                state.setPause(.wallClockReached)
                throw DeadlineReached()
            }
            let result = try await withThrowingTaskGroup(of: RunResult.self) { group in
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.runLoop(answers: answers, continueBranches: continueBranches,
                                                  restrictTo: restrictTo, initialRecord: initial)
                }
                if let deadline {
                    group.addTask {
                        let remaining = deadline.timeIntervalSinceNow
                        if remaining > 0 {
                            try await Task.sleep(for: .seconds(remaining))
                        }
                        try Task.checkCancellation()
                        self.state.setPause(.wallClockReached)
                        throw DeadlineReached()
                    }
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await finishRouting(cancel: true)
            try await checkpoint(result.programRecord)
            return (result.outcome, result.records, result.programRecord)
        } catch {
            await finishRouting(cancel: true)
            var record = state.checkpoint ?? initial
            if error is ProgramUsageError, state.pause == nil { state.setPause(.programBudgetReached) }
            if let pause = state.pause {
                for (id, status) in state.statuses where status == .running { setStatus(.queued, for: id) }
                record.pause = pause
                onEvent(.programPaused(pause))
                try await checkpoint(record)
                return (.paused(pause), state.records, state.checkpoint!)
            }
            if !(error is CancellationError) { record.lastStatus = error.localizedDescription }
            try await checkpoint(record)
            throw error
        }
    }

    private struct DeadlineReached: Error {}
    private struct RunResult: Sendable {
        let outcome: Outcome
        let records: [String: RunRecord]
        let programRecord: ProgramRunRecord
    }

    private func checkpoint(_ input: ProgramRunRecord) async throws {
        var record = input
        record.branchStatuses = state.statuses
        record.pause = state.pause
        record.updatedAt = Date()
        state.setCheckpoint(record)
        for branchRecord in state.records.values { try await saveRunRecord?(branchRecord) }
        try await saveProgramRecord?(record)
    }

    private func finishRouting(cancel: Bool) async {
        guard let task = state.routingTask else { return }
        if cancel { task.cancel() }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func runLoop(
        answers: [String: String], continueBranches: Set<String>, restrictTo: Set<String>?,
        initialRecord: ProgramRunRecord
    ) async throws -> RunResult {

        let resumed = Set(answers.keys).union(continueBranches)
        for planID in resumed where !state.status(planID).isTerminal {
            setStatus(.queued, for: planID)
        }

        var queue = Self.executionOrder(program.branches).filter { branch in
            if let restrictTo, !restrictTo.contains(branch.planID) { return false }
            let status = state.status(branch.planID)
            guard !status.isTerminal else { return false }
            // A branch still waiting on the user stays out until it is answered.
            return resumed.contains(branch.planID) || !status.isPausedByUser
        }
        // Answered branches first: the user is waiting on their continuation.
        queue.sort { lhs, rhs in
            resumed.contains(lhs.planID) && !resumed.contains(rhs.planID)
        }

        var updatedRecord = initialRecord

        let outcome: Outcome = try await withThrowingTaskGroup(of: LegResult.self) { group in
            var active = 0

            func admit() -> Bool {
                guard !Task.isCancelled, state.pause == nil else { return false }
                guard state.pause == nil else { return false }
                // Once a challenge survives both gates, no new branch starts under a target
                // the director may revise. Already-running legs may finish their current
                // boundary; then governance runs in fresh context.
                guard state.acceptedChallenge == nil else { return false }
                guard active < maxConcurrentBranches, !queue.isEmpty else { return false }

                let branch = queue.removeFirst()
                // A branch `openGeneration` created mid-run has no entry in `plans` — that
                // dictionary is the launch-time snapshot. `state` is where its plan was seeded.
                guard let plan = state.plan(branch.planID) ?? plans[branch.planID] else { return true }
                let record = state.record(branch.planID) ?? RunRecord(plan: plan)
                let answer = answers[branch.planID]

                setStatus(.running, for: branch.planID)
                onEvent(.branchStarted(planID: branch.planID))

                let onEvent = self.onEvent
                // Progress a leg made before it threw: without this a retry (and the
                // LegResult of a final failure) would report the leg's load-time state and
                // lose every task the branch had already finished.
                let state = self.state
                let planID = branch.planID
                let onBranchEvent: @Sendable (ResearchWorkbench.Event) -> Void = { event in
                    switch event {
                    case .planUpdated(let updated): state.setPlan(updated, for: planID)
                    case .recordUpdated(let updated): state.setRecord(updated, for: planID)
                    default: break
                    }
                    onEvent(.branchEvent(planID: planID, event))
                }

                group.addTask { [makeBranchWorkbench, maxLegRetries, legRetryBackoff, weak self] in
                    var attempt = 0
                    var input = answer
                    while true {
                        try Task.checkCancellation()
                        // Freshest known state, so a retry resumes rather than restarts.
                        let currentPlan = state.plan(planID) ?? plan
                        let currentRecord = state.record(planID) ?? record
                        do {
                            // Built inside the leg (the app hops to the main actor to do it),
                            // so the factory sees the store's current state for this branch.
                            guard let self else { throw CancellationError() }
                            let runtime = BranchRuntime(
                                program: await self.currentProgram(), plan: currentPlan,
                                findings: { state.findings },
                                publish: { [weak self] finding in try await self?.publish(finding) })
                            let workbench = try await makeBranchWorkbench(branch, runtime, onBranchEvent)
                            var updated = try await workbench.run(
                                plan: currentPlan, record: currentRecord, userInput: input)

                            // A candidate that cleared contract adjudication is reviewed here,
                            // outside the branch's own context. If review rejects it the branch
                            // picks up where it left off, in the same loop, with the ruling in
                            // its conversation — a rejected claim costs it two turns, not its
                            // remaining tasks.
                            if case .solutionUnderReview(let candidateID) = updated.state,
                               let accepted = try await self.reviewCandidate(
                                    candidateID, planID: planID, record: &updated) {
                                if !accepted {
                                    state.setRecord(updated, for: planID)
                                    input = nil
                                    attempt = 0
                                    continue
                                }
                            }
                            if case .problemChallengeUnderReview(let challengeID) = updated.state,
                               let accepted = try await self.reviewChallenge(
                                    challengeID, planID: planID, record: &updated) {
                                if !accepted {
                                    state.setRecord(updated, for: planID)
                                    input = nil
                                    attempt = 0
                                    continue
                                }
                            }
                            return LegResult(
                                planID: planID, record: updated, error: nil,
                                programBudgetDenied: false)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch let error as AssignmentUsageError {
                            var partial = state.record(planID) ?? currentRecord
                            partial.state = .budgetPause
                            partial.conversation?.messages.append(.user(error.localizedDescription))
                            return LegResult(planID: planID, record: partial,
                                             error: nil, programBudgetDenied: false,
                                             assignmentBudgetDenied: true)
                        } catch let error as ProgramUsageError {
                            // The shared ceiling is a program pause, not a broken branch and not
                            // a transient provider failure. Keep the freshest boundary state so
                            // adding tokens resumes this exact task/gate instead of rewinding it.
                            return LegResult(
                                planID: planID, record: state.record(planID) ?? currentRecord,
                                error: error.localizedDescription,
                                programBudgetDenied: true)
                        } catch {
                            attempt += 1
                            guard attempt <= maxLegRetries else {
                                return LegResult(
                                    planID: planID, record: state.record(planID) ?? currentRecord,
                                    error: error.localizedDescription,
                                    programBudgetDenied: false)
                            }
                            // A provider stream that drops mid-branch is the common case here,
                            // and it is transient often enough to be worth two cheap retries.
                            let delay = legRetryBackoff * Double(attempt)
                            if delay > 0 {
                                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                        }
                    }
                }
                active += 1
                return true
            }

            // One completed leg: persist, update status, try to admit more. Named because
            // convening the director mid-run (below) needs to resume draining afterward —
            // the original single `while active > 0 { ... }` becomes this, called twice.
            func drain() async throws {
                while active > 0 {
                    guard let leg = try await group.next() else { break }
                    active -= 1

                    // Persist before anything else runs: a crash after this point must not
                    // lose the branch's progress.
                    state.setRecord(leg.record, for: leg.planID)
                    try await saveRunRecord?(leg.record)
                    onEvent(.recordUpdated(planID: leg.planID, leg.record))

                    if leg.programBudgetDenied {
                        state.setPause(.programBudgetReached)
                        onEvent(.programPaused(.programBudgetReached))
                        setStatus(.queued, for: leg.planID)
                    } else if leg.assignmentBudgetDenied {
                        setStatus(.assignmentExhausted, for: leg.planID)
                    } else if let error = leg.error {
                        setStatus(.errored, for: leg.planID)
                        onEvent(.branchFailed(planID: leg.planID, error: error))
                    } else {
                        setStatus(Self.status(for: leg.record.state), for: leg.planID)
                    }

                    while admit() {}
                }
            }

            while admit() {}
            try await drain()

            // The cohort has stopped producing: every live branch is terminal, paused for a
            // human, or parked pending review. Try to convene the director in place — a
            // `continue` decision (new routes, or governed branches to resume) feeds `queue`
            // and this same task group keeps draining, rather than exiting so the app can
            // build a whole new runner for what routes turn out to be nothing but a plan.
            // One empty admission is allowed to convene the director again immediately. This
            // is how an independently rejected portfolio (persisted as blocked routes by the
            // app callback) gets repaired from its durable feedback instead of leaving a
            // zero-branch program inert. Bound it to one retry: a second empty continuation is
            // a real impasse and must not spin fresh-context director turns indefinitely.
            var emptyAdmissionRetries = 0
            while true {
                try Task.checkCancellation()
                await finishRouting(cancel: false)
                try await checkpoint(updatedRecord)
                if let final = try await self.convene(queue: &queue, updatedRecord: &updatedRecord) {
                    try await checkpoint(updatedRecord)
                    return final
                }
                try await checkpoint(updatedRecord)
                while admit() {}
                guard active > 0 || !queue.isEmpty else {
                    if emptyAdmissionRetries == 0 {
                        emptyAdmissionRetries += 1
                        continue
                    }
                    // Two consecutive decisions admitted nothing. Stop here instead of buying
                    // an unbounded sequence of director repairs.
                    return .waitingOnUser
                }
                emptyAdmissionRetries = 0
                try await drain()
            }
        }

        return RunResult(outcome: outcome, records: state.records, programRecord: updatedRecord)
    }

    // MARK: - Internals

    private struct LegResult: Sendable {
        let planID: String
        let record: RunRecord
        let error: String?
        let programBudgetDenied: Bool
        var assignmentBudgetDenied: Bool = false
    }

    private static func status(for state: RunState) -> BranchRunStatus {
        switch state {
        case .waitingForUser: return .waitingUser
        case .budgetPause: return .budgetPaused
        case .checkpoint: return .checkpoint
        // The branch is parked while its candidate is reviewed. It reads as a checkpoint to
        // the scheduler — slot released, siblings keep running, resumable — and the runner
        // decides separately whether the review lets it continue or the director takes over.
        case .solutionUnderReview: return .checkpoint
        case .problemChallengeUnderReview: return .checkpoint
        case .finished: return .finished
        case .failed: return .failed
        case .ready, .runningTask: return .queued
        }
    }

    private func setStatus(_ status: BranchRunStatus, for planID: String) {
        guard state.status(planID) != status else { return }
        state.setStatus(status, for: planID)
        onEvent(.branchStatusChanged(planID: planID, status))
    }

    /// Appends to the pool and durably records it, then kicks off routing in the background.
    ///
    /// Nothing pauses. A submitted finding reaches no branch until the director rules on it,
    /// and a branch picks up what was routed to it at its own next task boundary — so routing
    /// runs concurrently with the work rather than stopping it.
    private func publish(_ finding: ProgramFinding) async throws {
        state.addFinding(finding)
        onEvent(.findingPublished(finding))

        if !program.isVirtual {
            let updated = await currentProgram()
            try await persistProgram(updated)
        }

        scheduleRouting()
    }

    /// Runs one routing turn over everything unrouted, unless one is already in flight —
    /// findings that land during a turn are picked up by the next, so a burst of publishes
    /// costs one director call rather than one each.
    private func scheduleRouting() {
        guard routeFindings != nil, !program.isVirtual else { return }
        state.startRouting { [weak self] in
            guard let self else { return }
            defer { self.state.endRouting() }
            var pending = self.state.unroutedFindings
            while !pending.isEmpty {
                do {
                    try Task.checkCancellation()
                    let routings = try await self.routeFindings!(
                        await self.currentProgram(), pending)
                    try Task.checkCancellation()
                    guard !routings.isEmpty else { break }
                    self.state.setRoutings(routings)
                    let updated = await self.currentProgram()
                    try await self.persistProgram(updated)
                } catch {
                    // A routing turn that failed leaves its findings unrouted. They stay in
                    // the pool and the director sees them at the generation boundary; nothing
                    // is lost, and no branch is fed something nobody decided to send.
                    break
                }
                pending = self.state.unroutedFindings
            }
        }
    }

    /// Reviews a candidate that already passed contract adjudication: its cited items, and —
    /// always, never reused — the assembled argument. Returns whether it was accepted, or nil
    /// when no reviewer is wired, which leaves the candidate parked for the user.
    ///
    /// The review runs here rather than inside the branch because everything that judges in
    /// this system gets fresh context, and because a branch reviewing its own claim is the
    /// exact failure the two-pass design exists to prevent.
    private func reviewCandidate(
        _ candidateID: String, planID: String, record: inout RunRecord
    ) async throws -> Bool? {
        guard let reviewSolution else { return nil }
        var updated = await currentProgram()
        guard var candidate = updated.solutions.first(where: { $0.id == candidateID }) else {
            return nil
        }
        let ruling: SolutionCandidate.ReviewRuling
        do {
            ruling = try await reviewSolution(updated, candidateID)
        } catch let error as ProgramUsageError {
            // The candidate remains under review, but the *program* pauses visibly. Swallowing
            // this used to turn a ceiling hit into an inert checkpoint that Resume skipped.
            throw error
        } catch {
            // A review that could not run is not a rejection. The candidate stays parked and
            // the director sees it as still under review.
            return nil
        }

        candidate.reviewRuling = ruling
        candidate.status = ruling.accepted ? .accepted : .reviewRejected
        updated.upsertSolution(candidate)
        state.upsertSolution(candidate)
        if !program.isVirtual {
            updated = withCurrentFindings(updated)
            try await persistProgram(updated)
        }

        guard !ruling.accepted else { return true }
        record.state = .ready
        record.conversation?.messages.append(.user("""
        Your solution candidate was reviewed in fresh context and REJECTED: \(ruling.note)
        \(ruling.assemblyNote.isEmpty ? "" : "\nOn the assembled argument: \(ruling.assemblyNote)")

        The contract check had already agreed this would answer the question — what failed is \
        the mathematics or the way the pieces fit together. Your remaining tasks stand. Repair \
        what the ruling names and claim again if you close it.
        """))
        record.updatedAt = Date()
        return false
    }

    /// Runs both independent challenge gates outside the submitting branch. A rejection is
    /// delivered back into that branch's conversation; an acceptance remains parked and is
    /// handled only by the director.
    private func reviewChallenge(
        _ challengeID: String, planID: String, record: inout RunRecord
    ) async throws -> Bool? {
        guard let reviewProblemChallenge else { return nil }
        let live = await currentProgram()
        let reviewed: ProblemChallenge
        do {
            reviewed = try await reviewProblemChallenge(live, challengeID)
        } catch let error as ProgramUsageError {
            throw error
        } catch {
            return nil
        }
        state.upsertChallenge(reviewed)
        onEvent(.problemChallengeReviewed(reviewed))

        if !program.isVirtual {
            var updated = live
            updated.upsertChallenge(reviewed)
            updated = withCurrentFindings(updated)
            try await persistProgram(updated)
        }

        guard reviewed.status == .accepted else {
            record.state = .ready
            let math = reviewed.mathematicalRuling?.note ?? "not completed"
            let scope = reviewed.scopeRuling?.note ?? "not reached"
            record.conversation?.messages.append(.user("""
            Your challenge to the fixed research-goal Statement was independently REJECTED.

            Mathematical review: \(math)
            Scope/necessity review: \(scope)

            The target revision has not changed. Your remaining tasks stand. Continue on the
            request as written; do not submit the same challenge again without new evidence.
            """))
            record.updatedAt = Date()
            return false
        }
        return true
    }

    /// The manifest with the run's live findings folded in — the director must judge on what
    /// this run published, not on the snapshot it was constructed with.
    private func withCurrentFindings(_ program: ResearchProgram) -> ResearchProgram {
        var updated = program
        updated.findings = state.findings
        updated.routings = state.routings
        updated.solutions = state.solutions
        updated.challenges = state.challenges
        return updated
    }

    private func currentProgram() async -> ResearchProgram {
        if let loadProgram, let persisted = await loadProgram() {
            state.setProgram(persisted)
            state.mergePersistedClaims(persisted)
            return withCurrentFindings(persisted)
        }
        return withCurrentFindings(state.program)
    }

    private func persistProgram(_ updated: ResearchProgram) async throws {
        try Task.checkCancellation()
        try await saveProgram(updated)
        state.setProgram(updated)
    }

    /// Called whenever the cohort has stopped producing — every live branch is terminal,
    /// paused for a human, or parked pending review. Tries to convene the director in place.
    ///
    /// Returns nil when it fed `queue` more work — new branches from `openGeneration`, or
    /// branches governance resumed — and the caller should keep draining the same task group.
    /// Returns a concrete `Outcome` only when the program is genuinely done for now: paused,
    /// waiting on a human, or the director settled, called it futile, or (with no inline
    /// planner wired) handed a continuation back for the app to open in a fresh run.
    private func convene(
        queue: inout [ResearchProgram.Branch],
        updatedRecord: inout ProgramRunRecord
    ) async throws -> Outcome? {
        let statuses = state.statuses
        let records = state.records
        updatedRecord.branchStatuses = statuses
        updatedRecord.pause = state.pause
        updatedRecord.updatedAt = Date()

        if let pause = state.pause {
            return .paused(pause)
        }

        // A challenge that survived both gates freezes admission under the questioned target.
        // It does not settle the program: the director may preserve unaffected work, revise
        // the target, and/or open new routes.
        if let accepted = state.acceptedChallenge {
            let trigger = Director.Trigger.problemChallengeAccepted(challengeID: accepted.id)
            switch try await runDirector(trigger: trigger, records: records,
                                         programRecord: &updatedRecord, queue: &queue) {
            case .final(let outcome): return outcome
            case .continuing: return nil
            case .noDecision: break
            }
        }

        // An accepted candidate is the one event that convenes the director before the
        // generation is over — the siblings are still live, and only the director may decide
        // whether an answer to the question means their work is finished.
        if let accepted = acceptedCandidate() {
            let trigger = Director.Trigger.solutionAccepted(itemID: accepted.primaryItemID)
            switch try await runDirector(trigger: trigger, records: records,
                                         programRecord: &updatedRecord, queue: &queue) {
            case .final(let outcome): return outcome
            case .continuing: return nil
            case .noDecision: break
            }
        }

        // Every branch this program has ever had, including ones a prior convening in this
        // same run admitted — not `program.branches`, which is frozen at construction.
        let allTerminal = trackedBranches.values.allSatisfy { statuses[$0.planID]?.isTerminal ?? false }
        guard allTerminal else {
            return .waitingOnUser
        }

        // Every branch has stopped: the point where a program used to write a report nobody
        // consumed and go `done`. The director decides instead — settle, stop, or open the
        // next generation.
        switch try await runDirector(trigger: .generationEnded, records: records,
                                     programRecord: &updatedRecord, queue: &queue) {
        case .final(let outcome): return outcome
        case .continuing: return nil
        case .noDecision: break
        }

        var report: String?
        if let synthesize {
            onEvent(.synthesisStarted)
            do {
                report = try await synthesize(program, records)
            } catch is ProgramUsageError {
                state.setPause(.programBudgetReached)
                updatedRecord.pause = .programBudgetReached
                updatedRecord.updatedAt = Date()
                onEvent(.programPaused(.programBudgetReached))
                return .paused(.programBudgetReached)
            } catch {
                report = nil
            }
        }
        if !program.isVirtual {
            var updated = await currentProgram()
            updated.status = .done
            try await persistProgram(updated)
        }
        return .finished(report: report)
    }

    /// The accepted candidate, re-read from disk: `reviewCandidate` wrote it to the manifest
    /// and the runner's own copy is the load-time snapshot.
    private func acceptedCandidate() -> SolutionCandidate? {
        state.acceptedCandidate
    }

    private enum ConveneStep {
        /// No director wired, or the turn produced no verdict. The caller tries the next
        /// trigger in its fallback chain, exactly as before this existed.
        case noDecision
        /// The program is genuinely done for now. The caller returns this from `run()`.
        case final(Outcome)
        /// The director chose to continue and new work is already in `queue` — new branches
        /// from `openGeneration`, or branches governance resumed. The caller keeps draining.
        case continuing
    }

    /// One director turn plus the bookkeeping its decision implies.
    private func runDirector(
        trigger: Director.Trigger,
        records: [String: RunRecord],
        programRecord updatedRecord: inout ProgramRunRecord,
        queue: inout [ResearchProgram.Branch]
    ) async throws -> ConveneStep {
        guard let direct else {
            if !program.isVirtual, trackedBranches.isEmpty {
                throw ResearchError(message: "No director is configured. The program remains active.")
            }
            return .noDecision
        }
        onEvent(.directorStarted)
        var governedProgram = await currentProgram()
        let authoritativeTokens = await currentProgramTokensUsed?()
        let signal = Director.progressSignal(
            program: governedProgram, records: records,
            generation: updatedRecord.generation,
            findingsBefore: updatedRecord.findingsAtGenerationStart,
            tokensSpent: authoritativeTokens)
        let decision: Director.Decision
        do {
            guard let decided = try await direct(governedProgram, records, signal, trigger) else {
                // A supervised callback may intentionally decline an ordinary boundary.
                let policy = governedProgram.continuation ?? .manual
                if !policy.isUnattended && !policy.autoAdjudicateCounterexamples,
                   !governedProgram.branches.isEmpty, trigger == .generationEnded {
                    return .noDecision
                }
                throw ResearchError(message: "The director returned no valid decision. The program remains active; retry the director.")
            }
            decision = decided
        } catch is ProgramUsageError {
            state.setPause(.programBudgetReached)
            updatedRecord.pause = .programBudgetReached
            updatedRecord.updatedAt = Date()
            onEvent(.programPaused(.programBudgetReached))
            return .final(.paused(.programBudgetReached))
        } catch {
            // Includes cancellation: neither a failed turn nor a missing verdict is success.
            throw error
        }
        try Task.checkCancellation()
        onEvent(.directorDecided(decision))
        updatedRecord.lastStatus = decision.status

        // Branches governance resumed under an unchanged target — queued below only once we
        // know the verdict is actually `continue`; a settled/futile verdict still kills them.
        var justResumedPlanIDs: [String] = []
        if case .problemChallengeAccepted(let challengeID) = trigger,
           var challenge = governedProgram.challenges.first(where: { $0.id == challengeID }),
           var governance = decision.challengeGovernance {
            if governance.applyRevision,
               let request = governance.replacementRequest?.trimmingCharacters(
                    in: .whitespacesAndNewlines), !request.isEmpty {
                let revision = ResearchTargetRevision(
                    parentRevisionID: governedProgram.activeTargetRevisionID,
                    requestText: request,
                    libraryItemID: challenge.proposedTargetItemID,
                    libraryItemType: challenge.proposedTargetItemType,
                    libraryItemName: challenge.proposedTargetItemData
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .flatMap { try? TheoryItem.parse(markdown: $0).name },
                    libraryItemData: challenge.proposedTargetItemData,
                    proposedByChallengeID: challenge.id,
                    changeNote: governance.rationale)
                governedProgram.appendTargetRevision(revision)
                governance.newTargetRevisionID = revision.id
                // A contract adjudicated against the old request cannot govern the new one.
                // `openGeneration` redrafts it before planning any branch under the revision.
                governedProgram.contract = nil
            }
            challenge.governance = governance
            challenge.status = .governed
            governedProgram.upsertChallenge(challenge)
            state.upsertChallenge(challenge)

            for planID in Set(governance.stopBranchPlanIDs + governance.replanBranchPlanIDs) {
                if !state.status(planID).isTerminal { setStatus(.killed, for: planID) }
            }
            for planID in governance.continueBranchPlanIDs where !state.status(planID).isTerminal {
                setStatus(.queued, for: planID)
                justResumedPlanIDs.append(planID)
            }
            updatedRecord.branchStatuses = state.statuses
            if !program.isVirtual { try await persistProgram(governedProgram) }
        }

        if decision.verdict == .continue {
            // The decision supersedes the pause that convened the director — leaving it set
            // would stall the generation it just opened or the branches it explicitly resumed.
            updatedRecord.pause = nil

            if governedProgram.contract == nil, governedProgram.targetRevisions.count > 1 {
                guard let openGeneration else {
                    throw ResearchError(message: "The revised goal needs a success contract before work can be admitted.")
                }
                let prepared = try await openGeneration(governedProgram, [], governedProgram.programTokenBudget)
                governedProgram = prepared.program
                guard governedProgram.contract != nil else {
                    throw ResearchError(message: "The revised goal could not be formalized; no work was admitted.")
                }
                state.setProgram(governedProgram)
            }

            for planID in justResumedPlanIDs {
                if let branch = trackedBranches[planID] { queue.append(branch) }
            }

            if !decision.routes.isEmpty {
                guard let openGeneration else {
                    // No inline planner wired: preserve the original behaviour exactly and
                    // hand the decision back so the app opens the generation in a fresh run.
                    if !program.isVirtual {
                        var updated = withCurrentFindings(governedProgram)
                        updated.routes = (updated.routes ?? []) + decision.routes
                        updated.status = .active
                        try await persistProgram(updated)
                    }
                    return .final(.awaitingNextGeneration(decision))
                }
                // Plan files still require their legacy budget field, but no slice is reserved
                // for this generation or any branch. The shared program ledger is authoritative.
                let tokenBudget = governedProgram.programTokenBudget
                let knownPlanIDs = Set(trackedBranches.keys)
                let extendedGeneration: (program: ResearchProgram, plans: [String: PlanDocument])
                do {
                    extendedGeneration = try await openGeneration(
                        withCurrentFindings(governedProgram), decision.routes, tokenBudget)
                } catch is ProgramUsageError {
                    state.setPause(.programBudgetReached)
                    updatedRecord.pause = .programBudgetReached
                    updatedRecord.updatedAt = Date()
                    onEvent(.programPaused(.programBudgetReached))
                    return .final(.paused(.programBudgetReached))
                }
                let (extended, newPlans) = extendedGeneration
                governedProgram = extended
                state.setProgram(extended)
                for (planID, plan) in newPlans {
                    state.setPlan(plan, for: planID)
                }
                for branch in extended.branches where !knownPlanIDs.contains(branch.planID) {
                    trackedBranches[branch.planID] = branch
                    setStatus(.queued, for: branch.planID)
                    queue.append(branch)
                }
                // A rejected portfolio returns only blocked route records and no branches.
                // It did not open a generation, so do not advance the progress baseline before
                // the director gets its one in-place repair turn.
                if extended.branches.contains(where: { !knownPlanIDs.contains($0.planID) }) {
                    updatedRecord.generation += 1
                    updatedRecord.findingsAtGenerationStart = state.findings.count
                }
            }

            if !decision.workerAssignments.isEmpty {
                // No planner turn to run: the branch plans itself, inside its own conversation,
                // from the bootstrap task `WorkerAssignment.bootstrapPlan` builds mechanically.
                // A dispatch does not bump the generation counter — it is deliberately not a
                // new wave, just work admitted into the one already running.
                var updated = withCurrentFindings(governedProgram)
                var nextPriority = (trackedBranches.values.compactMap(\.priority).max() ?? -1) + 1
                var admitted: [(ResearchProgram.Branch, PlanDocument)] = []
                for var assignment in decision.workerAssignments {
                    var planID = "\(program.id)-w\(updated.workerAssignments.count + 1)-"
                        + TheoryItem.sanitizeID(assignment.objective)
                    if trackedBranches[planID] != nil { planID += "-\(UUID().uuidString.prefix(6))" }
                    assignment.planID = planID
                    assignment.targetRevisionID = updated.activeTargetRevisionID
                    var plan = assignment.bootstrapPlan(planID: planID, goal: updated.researchRequest)
                    plan.program = updated.id
                    let resolved = await resolveWorkerModel?(assignment.modelTier)
                    let branch = ResearchProgram.Branch(
                        planID: planID, title: String(assignment.objective.prefix(80)),
                        providerKind: resolved?.providerKind, model: resolved?.model,
                        priority: assignment.priority ?? nextPriority)
                    nextPriority += 1

                    try await savePlan?(plan)
                    admitted.append((branch, plan))
                    updated.branches.append(branch)
                    updated.workerAssignments.append(assignment)
                }
                updated.status = .active
                if !program.isVirtual { try await persistProgram(updated) }
                for (branch, plan) in admitted {
                    state.setPlan(plan, for: branch.planID)
                    trackedBranches[branch.planID] = branch
                    setStatus(.queued, for: branch.planID)
                    queue.append(branch)
                }
            }
            // Count progress since this decision, including direct-worker continuations.
            if !queue.isEmpty { updatedRecord.findingsAtGenerationStart = state.findings.count }
            return .continuing
        }

        // Settled or futile closes the program: branches that never ran are killed, not
        // left queued — a closed program must not silently resume them on the next launch.
        // Every branch the program has ever had, not just the ones from construction.
        for branch in trackedBranches.values where !state.status(branch.planID).isTerminal {
            setStatus(.killed, for: branch.planID)
        }
        updatedRecord.branchStatuses = state.statuses
        updatedRecord.pause = nil

        // The unattended deliverable: the report is written for decided outcomes too,
        // because "the user only hears back at the end" requires the end to say something.
        var report: String?
        if let synthesize {
            onEvent(.synthesisStarted)
            do {
                report = try await synthesize(withCurrentFindings(governedProgram), records)
            } catch is ProgramUsageError {
                state.setPause(.programBudgetReached)
                updatedRecord.pause = .programBudgetReached
                updatedRecord.updatedAt = Date()
                onEvent(.programPaused(.programBudgetReached))
                return .final(.paused(.programBudgetReached))
            } catch {
                report = nil
            }
        }
        if !program.isVirtual {
            var updated = withCurrentFindings(governedProgram)
            updated.status = decision.verdict == .settled ? .done : .failed
            try await persistProgram(updated)
        }
        return .final(.decided(decision, report: report))
    }
}
