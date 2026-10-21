import SwiftUI
import ManifieldCore
import ManifieldAgents
import ManifieldDiagnostics

/// Drives research runs. Every run is a *program*: a portfolio of branches, or — for a
/// standalone plan — a virtual one-branch program, so there is a single execution path.
/// Persists each branch's RunRecord the moment its leg ends, so a crash or app restart
/// resumes instead of losing work, and publishes live per-branch state for the Research tab.
@MainActor
final class ResearchController: ObservableObject {

    @Published private(set) var activeProgramID: String?
    @Published private(set) var branchStates: [String: RunState] = [:]
    @Published private(set) var branchRecords: [String: RunRecord] = [:]
    @Published private(set) var branchStatuses: [String: BranchRunStatus] = [:]
    /// Set when a branch published a counterexample or the ceiling was hit — the user
    /// decides what happens to the siblings.
    @Published private(set) var programPause: ProgramPause?
    @Published private(set) var findings: [ProgramFinding] = []
    /// The director's last status line — what the research page shows as "where this stands".
    @Published private(set) var directorStatus: String?
    /// Routes the director proposed for a next generation, awaiting the plan-building that
    /// turns them into branches.
    @Published private(set) var pendingRoutes: [ResearchRoute] = []
    /// What the last run of the active program did to the theory library.
    @Published private(set) var libraryChanges: [LibraryChange] = []
    @Published private(set) var isRunning = false
    @Published private(set) var currentActivity = ""
    /// Everything, in one stream. Readable at one branch at a time and not much beyond that,
    /// which is why the per-branch channels below exist.
    @Published var log = ""
    /// The same output split by who produced it, keyed by plan id, plus
    /// `ResearchController.programChannel` for the director and the program's own events.
    ///
    /// `maxConcurrentBranches` goes to 4 and every branch wrote into one string, so at any
    /// concurrency above 1 the live log interleaved several branches' thinking mid-sentence and
    /// was unreadable exactly when there was most to watch.
    @Published private(set) var channelLogs: [String: String] = [:]
    @Published var lastError: String?

    /// Channel key for output that belongs to the program rather than to any one branch.
    static let programChannel = "__program__"

    private weak var appState: AppState?
    private var runTask: Task<Void, Never>?
    private var persistentScheduler: PersistentResearchScheduler?
    private var inThinking = false
    /// Which branch's output the log is currently transcribing, for its prefix.
    private var loggingBranch: String?
    /// The library as it stood when the run started — diffed against the end, so changes
    /// are caught whichever path wrote them (direct writes, accepted proposals, evidence).
    private var snapshotBeforeRun: LibrarySnapshot?

    func attach(appState: AppState) {
        self.appState = appState
        cancel()
        activeProgramID = nil
        branchStates = [:]
        branchRecords = [:]
        branchStatuses = [:]
        programPause = nil
        findings = []
        log = ""
        channelLogs = [:]
        lastError = nil
    }

    private static func sessionName(for planID: String) -> String {
        "research-run-\(planID)"
    }

    private static func programSessionName(for programID: String) -> String {
        "program-run-\(programID)"
    }

    // MARK: - Queries used by the UI

    /// A persisted, resumable record for a branch — shown as a Resume banner.
    func pendingRecord(for planID: String) -> RunRecord? {
        if let live = branchRecords[planID], !live.state.isTerminal { return live }
        guard let store = appState?.store,
              let data = store.loadSession(named: Self.sessionName(for: planID)),
              let saved = try? JSONDecoder().decode(RunRecord.self, from: data),
              !saved.state.isTerminal else { return nil }
        return saved
    }

    func state(of planID: String) -> RunState? { branchStates[planID] }
    func record(of planID: String) -> RunRecord? { branchRecords[planID] }
    func status(of planID: String) -> BranchRunStatus? { branchStatuses[planID] }

    func isActive(programID: String) -> Bool { activeProgramID == programID }

    /// The same durable, all-role total used by admission. Failed calls, reviews, routing,
    /// director turns and earlier resumes count; branch records are not a budget ledger.
    func tokensUsed(of program: ResearchProgram) -> Int {
        appState?.store?.usageTokens(program: program) ?? program.planningTokensUsed
    }

    /// Live when this controller owns the program, otherwise restored from its persisted run
    /// record so the add-tokens action survives an app restart.
    func pause(of program: ResearchProgram) -> ProgramPause? {
        if activeProgramID == program.id, let programPause { return programPause }
        return loadProgramRecord(program)?.pause
    }

    // MARK: - Starting and resuming

    /// Starts a standalone plan. It runs as a virtual one-branch program — same engine,
    /// none of the program machinery (no lens, no findings, no manifest on disk).
    func start(plan: PlanDocument, mode: RunMode) {
        if let programID = plan.program, let program = appState?.program(id: programID) {
            runBranch(program: program, planID: plan.id, mode: mode); return
        }
        var plan = plan
        plan.runMode = mode
        try? appState?.store?.savePlan(plan)
        appState?.reloadPlans()

        var record = RunRecord(plan: plan)
        record.mode = mode
        let program = ResearchProgram.virtual(plan: plan)
        launch(program: program, records: [plan.id: record],
               programRecord: ProgramRunRecord(programID: program.id))
    }

    /// Starts (or restarts) a full research program.
    func startProgram(_ program: ResearchProgram, mode: RunMode? = nil) {
        if program.execution != nil { launchPersistent(program); return }
        guard program.isVirtual else { lastError = "Legacy programs are available for inspection. Start a new research program to continue with the persistent director."; return }
        guard let store = appState?.store else { return }
        var records: [String: RunRecord] = [:]
        for branch in program.branches {
            guard var plan = store.plan(id: branch.planID) else { continue }
            if let mode, plan.runMode != mode {
                plan.runMode = mode
                try? store.savePlan(plan)
            }
            records[branch.planID] = pendingRecord(for: branch.planID) ?? RunRecord(plan: plan)
        }
        appState?.reloadPlans()
        launch(program: program, records: records,
               programRecord: loadProgramRecord(program) ?? ProgramRunRecord(programID: program.id))
    }

    /// Runs one branch only, overriding the scheduler — for when you want a particular
    /// approach pushed forward now rather than whatever is cheapest.
    func runBranch(program: ResearchProgram, planID: String, mode: RunMode? = nil) {
        if let execution = program.execution, let assignment = execution.assignments.first(where: { $0.planID == planID }) {
            guidePersistentProgram(program, text: "Continue assignment \(assignment.id); inspect its saved report and exact unresolved gaps first.")
            return
        }
        guard program.isVirtual else { lastError = "Legacy programs are available for inspection. Start a new research program to continue with the persistent director."; return }
        guard let store = appState?.store else { return }
        if let mode, var plan = store.plan(id: planID), plan.runMode != mode {
            plan.runMode = mode
            try? store.savePlan(plan)
            appState?.reloadPlans()
        }
        resumeProgram(program, continueBranches: [planID], restrictTo: [planID])
    }

    /// Resumes a paused program (after restart, checkpoint, budget raise or an answer).
    func resumeProgram(_ program: ResearchProgram,
                       answers: [String: String] = [:],
                       continueBranches: Set<String> = [],
                       restrictTo: Set<String>? = nil) {
        if program.execution != nil {
            func canonical(_ id: String) -> String {
                program.execution?.assignments.first(where: { $0.id == id || $0.planID == id })?.id ?? id
            }
            let guidance = answers.map { "For assignment \(canonical($0.key)): \($0.value)" }.joined(separator: "\n")
                + (continueBranches.isEmpty ? "" : "\nContinue these assignments: " + continueBranches.sorted().map(canonical).joined(separator: ", "))
            launchPersistent(program, guidance: guidance)
            return
        }
        guard let store = appState?.store else { return }
        var records: [String: RunRecord] = [:]
        for branch in program.branches {
            if let existing = branchRecords[branch.planID] ?? pendingRecord(for: branch.planID) {
                records[branch.planID] = existing
            } else if let plan = store.plan(id: branch.planID) {
                records[branch.planID] = RunRecord(plan: plan)
            }
        }
        launch(program: program, records: records,
               programRecord: loadProgramRecord(program) ?? ProgramRunRecord(programID: program.id),
               answers: answers, continueBranches: continueBranches, restrictTo: restrictTo)
    }

    /// Answers a branch's pending ask_user question and continues the program.
    func answerBranch(program: ResearchProgram, planID: String, text: String) {
        resumeProgram(program, answers: [planID: text])
    }

    /// Continues a branch paused at a checkpoint, a budget stop, or an error.
    func continueBranch(program: ResearchProgram, planID: String) {
        resumeProgram(program, continueBranches: [planID])
    }

    /// Raises one branch's soft budget and continues it.
    func raiseBranchBudget(program: ResearchProgram, planID: String, extraTokens: Int) {
        if var current = branchRecords[planID] ?? pendingRecord(for: planID) {
            current.tokenBudget += extraTokens
            current.state = .ready
            branchRecords[planID] = current
            persist(current)
        }
        resumeProgram(program, continueBranches: [planID])
    }

    /// Raises the program-wide ceiling after a budget pause and continues.
    func raiseProgramBudget(_ program: ResearchProgram, extraTokens: Int) {
        var updated = program
        updated.programTokenBudget += extraTokens
        if !updated.isVirtual { try? appState?.store?.saveProgram(updated) }
        appState?.reloadPlans()
        programPause = nil
        resumeProgram(updated)
    }

    func extendProgramTimeLimit(_ program: ResearchProgram) {
        guard let store = appState?.store else { return }
        var updated = program
        var policy = updated.continuation ?? .manual
        let start = loadProgramRecord(program)?.startedAt ?? Date()
        policy.maxWallClockSeconds = max(policy.maxWallClockSeconds, Date().timeIntervalSince(start)) + 3600
        updated.continuation = policy
        do {
            try store.saveProgram(updated)
            appState?.reloadPlans()
            resumeProgram(updated)
        } catch { lastError = error.localizedDescription }
    }

    func cancel() {
        runTask?.cancel()
        if persistentScheduler != nil { return } // Cleanup drains children before permitting another run.
        runTask = nil
        isRunning = false
    }

    func guidePersistentProgram(_ program: ResearchProgram, text: String) {
        if let persistentScheduler, activeProgramID == program.id {
            Task { do { try await persistentScheduler.guideDirector(text) } catch { lastError = error.localizedDescription } }
        } else { launchPersistent(program, guidance: text) }
    }

    func setPersistentLimits(_ program: ResearchProgram, limits: ResearchLimits) {
        guard !isRunning, var execution = program.execution, let store = appState?.store else { return }
        var updated = program
        let previousAssignmentLimit = execution.limits.assignmentTokens
        execution.limits = limits
        if limits == .unlimited || limits.assignmentTokens != previousAssignmentLimit {
            for i in execution.assignments.indices { execution.assignments[i].tokenLimit = limits.assignmentTokens }
        }
        updated.execution = execution
        updated.programTokenBudget = limits.programTokens.runnerValue
        do { try store.saveProgram(updated); appState?.reloadPlans() }
        catch { lastError = error.localizedDescription }
    }

    private func launchPersistent(_ program: ResearchProgram, guidance: String? = nil) {
        guard !isRunning, let appState, let store = appState.store, let execution = program.execution,
              execution.resolution == nil else { return }
        activeProgramID = program.id; isRunning = true; lastError = nil; programPause = nil
        findings = program.findings; snapshotBeforeRun = LibrarySnapshot(items: store.items)
        appendLog("\n━━ persistent director: \(program.displayName) ━━\n")
        // Ids, counts and a clock — never the program's name, which is the research
        // question itself.
        Diagnostics.log.info("run.started", category: .run, [
            ("program", .id(program.id)),
            ("engine", .symbol("persistent-director")),
            ("assignments", .count(execution.assignments.count))
        ])
        let startedAt = Date()
        runTask = Task { [weak self] in
            guard let self else { return }
            await ProgramUsageRegistry.shared.register(programID: program.id,
                totalBudget: execution.limits.programTokens.runnerValue,
                initialSpent: store.usageTokens(program: program), limits: execution.limits,
                append: { entry in try? store.saveUsageEntry(entry) })
            do {
                let scheduler = try PersistentResearchScheduler(program: program,
                    save: { try store.saveProgram($0) },
                    onChange: { updated in
                        DispatchQueue.main.async {
                            self.findings = updated.findings
                            self.directorStatus = updated.execution?.resolution?.explanation ?? updated.execution?.events.last?.summary
                            appState.reloadPlans()
                        }
                    }, usageForAssignment: { assignmentID in
                        store.loadUsageLedger(programID: program.id)
                            .filter { $0.subjectID == assignmentID }
                            .reduce(0) { $0 + $1.actualTokens }
                    }, execute: { assignment, snapshot, scheduler in
                        try await appState.executePersistentAssignment(assignment, program: snapshot, scheduler: scheduler) { event in
                            DispatchQueue.main.async {
                                self.loggingBranch = assignment.id
                                self.handle(event, planID: assignment.planID ?? assignment.id, program: snapshot)
                                self.loggingBranch = nil
                            }
                        }
                    })
                persistentScheduler = scheduler
                try await scheduler.start()
                let conversation = try ResearchConversation(key: "director-\(program.id)", directory: store.sessionsURL)
                let director = DirectorWorkbench(
                    runner: try appState.persistentRunner(program: program, task: .director, stage: "persistent_director"),
                    scheduler: scheduler, conversation: conversation,
                    libraryTools: TheoryTools.readOnlyTools(store: store)
                        + SourceTools.tools(attached: appState.attachedSources.map { (slug: $0.ref.slug, store: $0.store) })
                        + DocumentTools.tools(store: store, access: appState.makeStandingDocumentAccess()),
                    reviseTarget: { p, c, id in try await appState.revisePersistentTarget(program: p, challenge: c, itemID: id, scheduler: scheduler) },
                    reviewEvidence: { assignment in
                        try await appState.reviewPersistentEvidence(assignment: assignment, scheduler: scheduler,
                            onActivity: { activity in DispatchQueue.main.async { self.handleActivity(activity) } })
                    },
                    thinking: AppSettings.effectiveThinking(for: .director),
                    compactAt: max(8_000, AppSettings.Limit.researchConversationTokens.value),
                    onActivity: { activity in DispatchQueue.main.async { self.handleActivity(activity) } })
                try await director.run(guidance: guidance)
                await scheduler.drain()
                let final = await scheduler.snapshot()
                if let resolution = final.execution?.resolution { self.saveReport(resolution.explanation, for: final) }
            } catch is CancellationError {
                if let scheduler = persistentScheduler {
                    try? await scheduler.pause("Paused by the user.")
                    await scheduler.drain()
                }
                self.appendLog("\nPaused by the user.\n")
                Diagnostics.log.info("run.cancelled", category: .run, [
                    ("program", .id(program.id)),
                    ("elapsed", .seconds(Date().timeIntervalSince(startedAt)))
                ])
            } catch {
                self.lastError = error.localizedDescription
                if let scheduler = persistentScheduler {
                    try? await scheduler.pause(error.localizedDescription)
                    await scheduler.drain()
                }
                self.appendLog("\n\(error.localizedDescription)\n")
                Diagnostics.log.failure("run.failed", category: .run, error: error, [
                    ("program", .id(program.id)),
                    ("elapsed", .seconds(Date().timeIntervalSince(startedAt)))
                ])
            }
            await ProgramUsageRegistry.shared.unregister(programID: program.id)
            persistentScheduler = nil; isRunning = false; runTask = nil
            appState.reloadPlans(); appState.reloadFromDisk()
            captureLibraryChanges(program: program)
            Diagnostics.log.info("run.finished", category: .run, [
                ("program", .id(program.id)),
                ("elapsed", .seconds(Date().timeIntervalSince(startedAt))),
                ("tokens", .count(store.usageTokens(program: program))),
                ("libraryChanges", .count(self.libraryChanges.count))
            ])
        }
    }

    // MARK: - The run

    private func launch(program: ResearchProgram,
                        records: [String: RunRecord],
                        programRecord: ProgramRunRecord,
                        answers: [String: String] = [:],
                        continueBranches: Set<String> = [],
                        restrictTo: Set<String>? = nil) {
        guard program.isVirtual else {
            lastError = "This legacy program is available for inspection. Start a new research program to use the persistent director."
            return
        }
        guard !isRunning, let appState, let store = appState.store else { return }

        var plans: [String: PlanDocument] = [:]
        for branch in program.branches {
            guard let plan = store.plan(id: branch.planID) else { continue }
            plans[branch.planID] = plan
        }
        // A program with real branches whose plan files failed to load is broken and must not
        // launch. A program with *no* branches at all is not broken — it is exactly what a
        // director-first dispatch looks like at creation, and the runner convenes the
        // director on an empty roster instead of ever admitting a branch. Refuse only the
        // first case; both share `plans.isEmpty`, so that alone can't tell them apart.
        guard !plans.isEmpty || program.branches.isEmpty else {
            lastError = "No branch plans could be loaded for this program."
            return
        }

        activeProgramID = program.id
        branchRecords = records
        branchStates = records.mapValues(\.state)
        branchStatuses = programRecord.branchStatuses
        findings = program.findings
        libraryChanges = []
        snapshotBeforeRun = LibrarySnapshot(items: store.items)
        programPause = nil
        isRunning = true
        lastError = nil
        let verb = (answers.isEmpty && continueBranches.isEmpty) ? "started" : "resumed"
        appendLog("\n━━ program \(verb): \(program.branches.count) branch(es) ━━\n")
        Diagnostics.log.info("run.started", category: .run, [
            ("program", .id(program.id)),
            ("engine", .symbol("branch-runner")),
            ("resumed", .flag(verb == "resumed")),
            ("branches", .count(program.branches.count))
        ])
        let startedAt = Date()

        let mode = plans.values.first?.runMode ?? .auto
        runTask = Task { [weak self] in
            guard let self else { return }
            var resumeGovernedBranches = false
            if !program.isVirtual {
                let alreadySpent = store.usageTokens(program: program)
                await ProgramUsageRegistry.shared.register(
                    programID: program.id,
                    totalBudget: program.programTokenBudget,
                    initialSpent: alreadySpent,
                    append: { entry in try? store.saveUsageEntry(entry) })
            }
            do {
                let runner = ProgramRunner(
                    program: program,
                    plans: plans,
                    records: records,
                    programRecord: programRecord,
                    makeBranchWorkbench: { branch, runtime, onEvent in
                        let branchMode = plans[branch.planID]?.runMode ?? mode
                        // Legs run on the cooperative pool; the factory touches the store,
                        // which is main-actor-only, so hop rather than assume.
                        return try await MainActor.run {
                            try appState.makeBranchWorkbench(
                                program: program.isVirtual ? nil : program,
                                // The branch always identifies the plan; `runtime` is what
                                // turns on the program-only machinery.
                                branch: branch,
                                runtime: program.isVirtual ? nil : runtime,
                                mode: branchMode,
                                onEvent: onEvent)
                        }
                    },
                    saveProgram: { @MainActor [weak self] updated in
                        guard !updated.isVirtual else { return }
                        try store.saveProgram(updated)
                        self?.appState?.reloadPlans()
                    },
                    saveRunRecord: { @MainActor record in
                        let data = try JSONEncoder().encode(record)
                        try store.saveSession(named: Self.sessionName(for: record.planID), json: data)
                    },
                    saveProgramRecord: { @MainActor record in
                        guard !program.isVirtual else { return }
                        let data = try JSONEncoder().encode(record)
                        try store.saveSession(named: Self.programSessionName(for: record.programID), json: data)
                    },
                    savePlan: { @MainActor plan in try store.savePlan(plan) },
                    resolveWorkerModel: { tier in
                        await MainActor.run { appState.strongTierOverride(for: tier) }
                    },
                    loadProgram: { @Sendable in
                        await MainActor.run { store.program(id: program.id) }
                    },
                    synthesize: program.isVirtual ? nil : { @Sendable prog, recs in
                        try await MainActor.run { [weak self] in
                            guard let self else { throw CoreError.io("controller went away") }
                            return try self.makeSynthesisRun(program: prog, records: recs)
                        }.run()
                    },
                    // Only for a real program with a continuation policy that allows more than
                    // one generation: a single-generation run has nothing for a director to
                    // decide that synthesis does not already say.
                    direct: nil,
                    routeFindings: nil,
                    reviewSolution: solutionReviewer(for: program),
                    reviewProblemChallenge: problemChallengeReviewer(for: program),
                    // Lets a `continue` decision keep this same run alive instead of the
                    // runner handing it back for `openNextGeneration` to open a fresh one.
                    openGeneration: openGenerationRunner(for: program),
                    currentProgramTokensUsed: { @Sendable in
                        await MainActor.run { store.usageTokens(program: program) }
                    },
                    onEvent: { event in
                        DispatchQueue.main.async { self.handle(event, program: program) }
                    })

                let result = try await runner.run(answers: answers,
                                                  continueBranches: continueBranches,
                                                  restrictTo: restrictTo)
                if case .awaitingNextGeneration(let decision) = result.outcome,
                   decision.routes.isEmpty,
                   !(decision.challengeGovernance?.continueBranchPlanIDs.isEmpty ?? true) {
                    resumeGovernedBranches = true
                }
                self.finishRun(result, program: program)
            } catch is CancellationError {
                self.appendLog("\n✕ run cancelled\n")
                self.branchRecords.values.forEach { self.persist($0) }
                Diagnostics.log.info("run.cancelled", category: .run, [
                    ("program", .id(program.id)),
                    ("elapsed", .seconds(Date().timeIntervalSince(startedAt)))
                ])
            } catch {
                self.lastError = error.localizedDescription
                self.appendLog("\n✕ \(error.localizedDescription)\n")
                self.branchRecords.values.forEach { self.persist($0) }
                Diagnostics.log.failure("run.failed", category: .run, error: error, [
                    ("program", .id(program.id)),
                    ("elapsed", .seconds(Date().timeIntervalSince(startedAt)))
                ])
            }
            if !program.isVirtual {
                await ProgramUsageRegistry.shared.unregister(programID: program.id)
            }
            self.isRunning = false
            // Deferred until every branch has stopped: reindexing mid-program would
            // fight the branch that is still writing.
            appState.reloadPlans()
            appState.reloadFromDisk()
            self.captureLibraryChanges(program: program)
            Diagnostics.log.info("run.finished", category: .run, [
                ("program", .id(program.id)),
                ("elapsed", .seconds(Date().timeIntervalSince(startedAt))),
                ("libraryChanges", .count(self.libraryChanges.count))
            ])
            if resumeGovernedBranches,
               let governed = store.program(id: program.id) {
                // `launch` deliberately refuses re-entry while this task is live. Resume only
                // after its cleanup has dropped `isRunning`, using the governed manifest and
                // the branch statuses the director just persisted.
                self.startProgram(governed, mode: .auto)
            }
        }
    }

    /// Diffs the library against the pre-run snapshot and records the result on the
    /// program, so "what did this actually do to my theory" survives a restart.
    private func captureLibraryChanges(program: ResearchProgram) {
        guard let store = appState?.store, let before = snapshotBeforeRun else { return }
        let changes = merged(runDiff: before.changes(to: LibrarySnapshot(items: store.items)))
        libraryChanges = changes
        guard !program.isVirtual, !changes.isEmpty,
              var stored = store.program(id: program.id) else { return }
        stored.lastRunChanges = changes
        try? store.saveProgram(stored)
        appState?.reloadPlans()
    }

    /// The branches' per-task changes, plus anything the whole-run diff caught that no task
    /// claimed.
    ///
    /// Both are needed and neither subsumes the other. A branch's own record says who wrote what
    /// and when, but only for writes that went through a task; the run diff catches every other
    /// path — a proposal the user accepted mid-run, evidence attached from a sheet — and can say
    /// nothing about who. Attributed entries win on collision, because "branch 2, task 7" beats
    /// "sometime during the run".
    private func merged(runDiff: [LibraryChange]) -> [LibraryChange] {
        let attributed = branchRecords.values
            .flatMap(\.libraryChanges)
            .sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        let claimed = Set(attributed.map(\.itemID))
        return attributed + runDiff.filter { !claimed.contains($0.itemID) }
    }

    /// Reflects a verdict the user just set into the live findings list.
    func applyVerdict(_ verdict: ProgramFinding.Verdict?, note: String?, findingID: String) {
        guard let index = findings.firstIndex(where: { $0.id == findingID }) else { return }
        findings[index].verdict = verdict
        findings[index].verdictNote = note?.isEmpty == true ? nil : note
    }

    /// A synthesis turn packaged so the run task can execute it off the main actor.
    private struct SynthesisRun {
        let runner: AgentRunner
        let config: AgentConfig
        let programID: String
        let record: RecordTurn?

        func run() async throws -> String {
            let result = try await runRecordedTurn(
                runner: runner, config: config,
                history: [.user("Write the program report.")],
                programID: programID, role: .synthesis,
                title: "The program report",
                record: record,
                outcome: { String($0.finalText.prefix(200)) })
            return result.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The director turn, or nil to keep the pre-director behaviour (synthesise and stop).
    /// Lets a `continue` decision with routes keep the runner's task group alive instead of
    /// exiting to `.awaitingNextGeneration` — `appendGeneration` runs from inside the run
    /// instead of after it. Gated exactly like `appendGeneration` itself: a virtual plan has
    /// no program to extend, so there is nothing here for the director to open.
    private func openGenerationRunner(
        for program: ResearchProgram
    ) -> (@Sendable (ResearchProgram, [ResearchRoute], Int) async throws
        -> (program: ResearchProgram, plans: [String: PlanDocument]))? {
        guard !program.isVirtual else { return nil }
        // `appendGeneration` is async and main-actor-isolated (it touches the store
        // throughout), so the closure itself hops rather than wrapping a `MainActor.run`
        // around an async call, which the synchronous-body overload cannot express.
        return { @MainActor [weak self] prog, routes, budget in
            guard let self, let appState = self.appState else {
                throw CoreError.io("controller went away")
            }
            self.appendLog("\n━━ opening generation from \(routes.count) route(s) ━━\n")
            return try await appState.appendGeneration(
                to: prog, routes: routes, tokenBudget: budget,
                onProgress: { route in
                    self.currentActivity = "Planning: \(route.mechanism)"
                    self.appendLog("  → planning \(route.mechanism)\n")
                })
        }
    }

    /// Reviews a candidate that already passed contract adjudication: every cited item and
    /// its dependency closure, then — always — the assembled argument.
    private func solutionReviewer(
        for program: ResearchProgram
    ) -> (@Sendable (ResearchProgram, String) async throws -> SolutionCandidate.ReviewRuling)? {
        guard !program.isVirtual else { return nil }
        return { @Sendable prog, candidateID in
            guard let candidate = prog.solutions.first(where: { $0.id == candidateID }) else {
                throw CoreError.io("solution candidate \(candidateID) is missing")
            }
            let prepared = try await MainActor.run {
                [weak self] () -> (AgentRunner, [AgentTool], ProofVerifier, [TheoryItem],
                                   SolutionReviewGate.ReviewCache, ThinkingLevel, RecordTurn?) in
                guard let self, let appState = self.appState, let store = appState.store else {
                    throw CoreError.io("No project open")
                }
                let c = try appState.makeSolutionReviewContext(program: prog, store: store)
                return (c.0, c.1, c.2, c.3, c.4, c.5, appState.makeTurnRecorder())
            }
            let (runner, tools, verifier, items, cache, thinking, recorder) = prepared

            let (ruling, updatedCache) = try await SolutionReviewGate.review(
                candidate: candidate,
                goal: prog.researchRequest,
                contract: prog.contract,
                items: items,
                cache: cache,
                verifier: verifier,
                reviewAssembly: { chain, candidate in
                    try await SolutionReviewGate.reviewAssembly(
                        runner: runner, goal: prog.researchRequest, contract: prog.contract,
                        chain: chain, candidate: candidate, tools: tools, thinking: thinking,
                        programID: prog.id, record: recorder)
                })

            await MainActor.run { [weak self] in
                self?.appState?.storeSolutionReviewCache(updatedCache, programID: prog.id)
            }
            return ruling
        }
    }

    /// Runs the two challenge gates in separate fresh contexts. The closure re-reads the
    /// manifest because the filing tool wrote the challenge after this runner was constructed.
    private func problemChallengeReviewer(
        for program: ResearchProgram
    ) -> (@Sendable (ResearchProgram, String) async throws -> ProblemChallenge)? {
        guard !program.isVirtual else { return nil }
        return { @Sendable prog, challengeID in
            let prepared = try await MainActor.run {
                [weak self] () -> (ProblemChallenge, ResearchTargetRevision, AgentRunner,
                                   [AgentTool], [TheoryItem], ThinkingLevel, RecordTurn?) in
                guard let self, let appState = self.appState, let store = appState.store,
                      let current = store.program(id: prog.id),
                      let challenge = current.challenges.first(where: { $0.id == challengeID })
                else { throw CoreError.io("problem challenge \(challengeID) is missing") }
                let context = try appState.makeProblemChallengeReviewContext(program: current)
                return (challenge, current.activeTargetRevision, context.runner,
                        context.tools, store.items, context.thinking,
                        appState.makeTurnRecorder())
            }
            return try await ProblemChallengeReviewer.review(
                challenge: prepared.0, target: prepared.1, items: prepared.4,
                tools: prepared.3, runner: prepared.2, thinking: prepared.5,
                programID: prog.id, record: prepared.6)
        }
    }

    private func makeSynthesisRun(program: ResearchProgram,
                                  records: [String: RunRecord]) throws -> SynthesisRun {
        guard let appState else { throw CoreError.io("No project open") }
        let (runner, config) = try appState.makeSynthesisConfig(program: program, records: records)
        return SynthesisRun(runner: runner, config: config,
                            programID: program.isVirtual ? "" : program.id,
                            record: appState.makeTurnRecorder())
    }

    private func finishRun(_ result: (outcome: ProgramRunner.Outcome,
                                      records: [String: RunRecord],
                                      programRecord: ProgramRunRecord),
                           program: ResearchProgram) {
        branchRecords = result.records
        branchStates = result.records.mapValues(\.state)
        branchStatuses = result.programRecord.branchStatuses
        result.records.values.forEach { persist($0) }
        if !program.isVirtual { persist(result.programRecord) }

        switch result.outcome {
        case .finished(let report):
            appendLog("\n━━ program finished ━━\n")
            if let report, !report.isEmpty, !program.isVirtual {
                saveReport(report, for: program)
            }
        case .paused(let pause):
            programPause = pause
            switch pause {
            case .wallClockReached:
                appendLog("\n━━ program paused: wall-clock limit reached ━━\n")
            case .programBudgetReached:
                appendLog("\n━━ program paused: token ceiling reached ━━\n")
            }
        case .waitingOnUser:
            appendLog("\n━━ waiting on you ━━\n")
        case .decided(let decision, let report):
            directorStatus = decision.status
            appendLog("\n━━ director: \(decision.verdict.rawValue) ━━\n\(decision.status)\n")
            if let report, !report.isEmpty, !program.isVirtual {
                saveReport(report, for: program)
            }
        case .awaitingNextGeneration(let decision):
            directorStatus = decision.status
            pendingRoutes = decision.routes
            appendLog("\n━━ director: continue — \(decision.routes.count) route(s) proposed ━━\n"
                + decision.status + "\n"
                + decision.routes.map { "  • \($0.mechanism) — next: \($0.nextTest ?? "—")" }
                    .joined(separator: "\n") + "\n")
            let governed = appState?.store?.program(id: program.id) ?? program
            if !decision.routes.isEmpty {
                openNextGeneration(decision.routes, for: governed)
            }
        }
    }

    /// Plans the director's routes into branches and runs them. This is the step that closes
    /// the loop — without it the director can decide to continue and the program still stops.
    private func openNextGeneration(_ routes: [ResearchRoute], for program: ResearchProgram) {
        guard !routes.isEmpty, let appState else { return }
        // Plan files still carry a legacy budget value. It is not a reservation: every new
        // branch spends from the same persisted program ceiling.
        let budget = program.programTokenBudget
        runTask = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            self.appendLog("\n━━ planning generation from \(routes.count) route(s) ━━\n")
            do {
                let (extended, _) = try await appState.appendGeneration(
                    to: program, routes: routes, tokenBudget: budget,
                    onProgress: { route in
                        self.currentActivity = "Planning: \(route.mechanism)"
                        self.appendLog("  → planning \(route.mechanism)\n")
                    })
                self.pendingRoutes = []
                self.isRunning = false
                // Straight on into the new generation: stopping here to be told to continue
                // is the pause this whole mechanism exists to remove.
                self.startProgram(extended, mode: .auto)
            } catch is CancellationError {
                self.isRunning = false
            } catch {
                self.isRunning = false
                self.lastError = error.localizedDescription
                self.appendLog("\n✕ could not open the next generation: \(error.localizedDescription)\n")
            }
        }
    }

    private func saveReport(_ report: String, for program: ResearchProgram) {
        guard let store = appState?.store else { return }
        let relativePath = "programs/\(program.id)-report.md"
        let url = store.rootURL.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(at: store.programsURL, withIntermediateDirectories: true)
        guard (try? report.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        // Re-read before writing: the runner has already saved this run's findings, routes
        // and final status, and writing the launch-time snapshot back would erase them. The
        // status is the runner's verdict (done, or failed on `futile`) — not ours to set.
        var updated = store.program(id: program.id) ?? program
        updated.reportPath = relativePath
        try? store.saveProgram(updated)
        appState?.reloadPlans()
        appendLog("\n━━ report written to \(relativePath) ━━\n")
    }

    // MARK: - Events

    private func handle(_ event: ProgramRunner.Event, program: ResearchProgram) {
        switch event {
        case .branchStarted(let planID):
            loggingBranch = planID
            appendLog("\n━━ branch \(branchTitle(planID, in: program)) ━━\n")
        case .branchEvent(let planID, let workbenchEvent):
            loggingBranch = planID
            handle(workbenchEvent, planID: planID, program: program)
        case .branchStatusChanged(let planID, let status):
            branchStatuses[planID] = status
        case .directorStarted:
            // The director belongs to the program, not to whichever branch happened to run
            // last — leaving the channel set would file its reasoning under that branch.
            loggingBranch = nil
            appendLog("\n━━ director reviewing the program ━━\n")
        case .directorDecided(let decision):
            directorStatus = decision.status
        case .recordUpdated(let planID, let record):
            branchRecords[planID] = record
            branchStates[planID] = record.state
            persist(record)
        case .findingPublished(let finding):
            findings.append(finding)
            // Filed against the branch that published it, whatever is running now.
            let publishing = loggingBranch
            loggingBranch = finding.branchPlanID
            appendLog("\n★ finding [\(finding.kind.rawValue)]: \(finding.statement.prefix(200))\n")
            loggingBranch = publishing
        case .problemChallengeReviewed(let challenge):
            let result = challenge.status == .accepted ? "accepted by both gates" : challenge.status.rawValue
            appendLog("\n⚑ problem challenge \(result): \(challenge.description.prefix(240))\n")
        case .programPaused(let pause):
            programPause = pause
        case .branchFailed(let planID, let error):
            lastError = error
            appendLog("\n✕ branch \(branchTitle(planID, in: program)) failed: \(error)\n")
        case .synthesisStarted:
            loggingBranch = nil
            appendLog("\n━━ synthesizing the program report ━━\n")
        }
    }

    private func branchTitle(_ planID: String, in program: ResearchProgram) -> String {
        program.branch(planID: planID).map {
            $0.challengesLeadingAnswer ? "\($0.title) [challenger]" : $0.title
        } ?? planID
    }

    private func handle(_ event: ResearchWorkbench.Event, planID: String, program: ResearchProgram) {
        switch event {
        case .taskStarted(let index, let title):
            let prefix = program.isVirtual ? "" : "\(branchTitle(planID, in: program)) · "
            currentActivity = "\(prefix)Task \(index): \(title)"
            appendLog("\n── task \(index): \(title) ──\n")
        case .agentActivity(let activity):
            handleActivity(activity)
        case .reviewStarted(let itemID):
            appendLog("\n── reviewing \(itemID) ──\n")
        case .verdict(let review):
            switch review.verdict {
            case .noErrorsFound: appendLog("\n✓ review: no errors found\n")
            case .issues: appendLog("\n✗ review: \(review.issues.count) issue(s)\n")
            }
        case .taskFinished(let index, let status, let summary):
            appendLog("\n□ task \(index) → \(status.rawValue): \(summary.prefix(200))\n")
        case .stateChanged(let newState):
            branchStates[planID] = newState
        case .planUpdated:
            appState?.reloadPlans()
        case .recordUpdated(let record):
            // Persist at every task boundary, not only when the leg returns: mid-branch the
            // on-disk record otherwise still reads tokensIn: 0 with an empty journal, so a
            // crash loses every finished task's summary — the only view later tasks get of
            // earlier work — and the token counter appears frozen for the whole of a long task.
            branchRecords[planID] = record
            persist(record)
        }
    }

    private func handleActivity(_ activity: AgentActivity) {
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
        case .toolFinished(let name, let preview, let isError):
            if isError {
                appendLog("✕ \(name) failed\n")
            } else if name == "run_python",
                      let firstLine = preview.split(separator: "\n").first,
                      let gist = firstLine.split(separator: "[").first {
                appendLog("✓ run_python — \(gist.trimmingCharacters(in: .whitespaces))\n")
            }
        case .usage(let input, let output):
            // Live counter so a long task visibly progresses; the authoritative totals
            // arrive with the leg's record and overwrite these.
            if let planID = loggingBranch, var current = branchRecords[planID] {
                current.tokensIn += input
                current.tokensOut += output
                current.updatedAt = Date()
                branchRecords[planID] = current
            }
        case .usageDetails:
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

    // MARK: - Persistence

    private func persist(_ record: RunRecord) {
        guard let store = appState?.store,
              let data = try? JSONEncoder().encode(record) else { return }
        try? store.saveSession(named: Self.sessionName(for: record.planID), json: data)
    }

    private func persist(_ record: ProgramRunRecord) {
        guard let store = appState?.store,
              let data = try? JSONEncoder().encode(record) else { return }
        try? store.saveSession(named: Self.programSessionName(for: record.programID), json: data)
    }

    private func loadProgramRecord(_ program: ResearchProgram) -> ProgramRunRecord? {
        guard !program.isVirtual, let store = appState?.store,
              let data = store.loadSession(named: Self.programSessionName(for: program.id)) else {
            return nil
        }
        return try? JSONDecoder().decode(ProgramRunRecord.self, from: data)
    }

    private func appendLog(_ text: String) {
        log = String((log + text).suffix(24_000))
        // Program-level output (the director, the routing turn, synthesis) belongs to no branch;
        // `loggingBranch` is nil for exactly those stretches.
        let channel = loggingBranch ?? Self.programChannel
        channelLogs[channel] = String(((channelLogs[channel] ?? "") + text).suffix(24_000))
    }

    /// The live log for one branch, or for the program's own turns. Empty when that channel has
    /// produced nothing in this session.
    func log(forChannel channel: String) -> String { channelLogs[channel] ?? "" }

    func describe(_ state: RunState) -> String {
        switch state {
        case .ready: return "ready"
        case .runningTask(let index): return "running task \(index)"
        case .checkpoint(let afterTask): return "checkpoint after task \(afterTask) — review and continue"
        case .waitingForUser: return "waiting for your answer"
        case .budgetPause: return "token budget reached — raise it to continue"
        case .solutionUnderReview: return "solution candidate under review"
        case .problemChallengeUnderReview: return "problem challenge under review"
        case .finished(let summary): return "finished — \(summary.prefix(300))"
        case .failed(let reason): return "failed — \(reason)"
        }
    }
}
