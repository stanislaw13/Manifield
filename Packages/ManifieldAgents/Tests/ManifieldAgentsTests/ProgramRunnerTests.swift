import XCTest
import ManifieldCore
@testable import ManifieldAgents

/// Per-branch scripted provider that also records what it was asked.
private final class BranchProvider: LLMProvider, @unchecked Sendable {
    var description: String { "branch-scripted" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var _requests: [LLMRequest] = []

    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var requestCount: Int { requests.count }

    init(scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        _requests.append(request)
        let events = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class ThrowingProvider: LLMProvider, @unchecked Sendable {
    var description: String { "throwing" }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.http(429, "overloaded")) }
    }
}

private func call(_ name: String, _ json: String) -> [LLMEvent] {
    [.toolUseFinished(id: UUID().uuidString, name: name, inputJSON: json), .finished(.toolUse)]
}

private func finish(_ summary: String) -> [LLMEvent] {
    call("finish_task", #"{"outcome":"completed","summary":"\#(summary)"}"#)
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}

final class ProgramRunnerOrderingTests: XCTestCase {

    /// Whichever agent authored the generation ranked it, and that ranking IS the order.
    /// The old stance/cost heuristic is gone: it put the challenging branch first as a rule,
    /// which overrode a judgment about which route was actually most likely to settle things.
    func testPriorityIsTheOrder() {
        let branches: [ResearchProgram.Branch] = [
            .init(planID: "p-build", title: "A", costClass: .expensive, priority: 0),
            .init(planID: "p-challenge", title: "B", challengesLeadingAnswer: true,
                  costClass: .cheap, priority: 1),
            .init(planID: "p-other", title: "C", costClass: .cheap, priority: 2)
        ]
        XCTAssertEqual(ProgramRunner.executionOrder(branches).map(\.planID),
                       ["p-build", "p-challenge", "p-other"],
                       "an expensive builder runs first when that is where the planner pointed")
    }

    /// Manifest order for anything unranked, with the ranked ones ahead of it — a partially
    /// priced portfolio (an old manifest extended by a new generation) must not bury the
    /// branches that were actually ranked.
    func testUnrankedBranchesKeepManifestOrderBehindRankedOnes() {
        let branches: [ResearchProgram.Branch] = [
            .init(planID: "p-unranked-1", title: "A"),
            .init(planID: "p-ranked", title: "B", priority: 0),
            .init(planID: "p-unranked-2", title: "C")
        ]
        XCTAssertEqual(ProgramRunner.executionOrder(branches).map(\.planID),
                       ["p-ranked", "p-unranked-1", "p-unranked-2"])
    }

    func testOrderIsStableForEquallyRankedBranches() {
        let branches: [ResearchProgram.Branch] = [
            .init(planID: "a", title: "A", priority: 1),
            .init(planID: "b", title: "B", priority: 1)
        ]
        XCTAssertEqual(ProgramRunner.executionOrder(branches).map(\.planID), ["a", "b"])
    }
}

final class ProgramRunnerTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("program-runner-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "P")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Fixtures

    private func branchPlan(_ id: String, tasks: Int = 1) -> PlanDocument {
        PlanDocument(
            id: id, goal: "Settle conj-x", status: .approved, runMode: .auto,
            tokenBudget: 5_000_000,
            tasks: (1...tasks).map { PlanTask(index: $0, title: "Task \($0) of \(id)") },
            program: "prog-1")
    }

    private func program(
        branches: [ResearchProgram.Branch],
        budget: Int = 5_000_000
    ) -> ResearchProgram {
        ResearchProgram(id: "prog-1", goal: "Settle conj-x",
                        programTokenBudget: budget, branches: branches)
    }

    /// Builds a runner whose branches use the supplied providers; every branch gets the
    /// publish tool and a shared-facts closure, exactly as the app wires a real program.
    private func makeRunner(
        program: ResearchProgram,
        plans: [PlanDocument],
        providers: [String: LLMProvider],
        records: [String: RunRecord] = [:],
        programRecord: ProgramRunRecord? = nil,
        savedPrograms: Box<[ResearchProgram]>? = nil,
        saveProgramRecord: (@Sendable (ProgramRunRecord) async throws -> Void)? = nil,
        loadProgram: (@Sendable () async -> ResearchProgram?)? = nil,
        saveAdmittedPlan: (@Sendable (PlanDocument) async throws -> Void)? = nil,
        inspectRuntime: (@Sendable (ResearchProgram.Branch, ProgramRunner.BranchRuntime) -> Void)? = nil,
        resolveWorkerModel: (@Sendable (String?) async -> (providerKind: String, model: String)?)? = nil,
        routeFindings: (@Sendable (ResearchProgram, [ProgramFinding]) async throws -> [FindingRouting])? = nil,
        synthesize: (@Sendable (ResearchProgram, [String: RunRecord]) async throws -> String)? = nil,
        direct: (@Sendable (ResearchProgram, [String: RunRecord],
                            Director.ProgressSignal, Director.Trigger) async throws -> Director.Decision?)? = nil,
        openGeneration: (@Sendable (ResearchProgram, [ResearchRoute], Int) async throws
            -> (program: ResearchProgram, plans: [String: PlanDocument]))? = nil,
        adjudicate: (@Sendable (ProgramFinding) async throws -> FindingAdjudicator.Ruling?)? = nil,
        events: Box<[String]>? = nil,
        extraTools: [AgentTool] = [],
        meterBranches: Bool = false,
        maxLegRetries: Int = 2
    ) -> ProgramRunner {
        let store = self.store!
        let planMap = Dictionary(uniqueKeysWithValues: plans.map { ($0.id, $0) })
        return ProgramRunner(
            program: program,
            plans: planMap,
            records: records,
            programRecord: programRecord ?? ProgramRunRecord(programID: program.id),
            makeBranchWorkbench: { branch, runtime, onEvent in
                inspectRuntime?(branch, runtime)
                guard let provider = providers[branch.planID] else {
                    throw ResearchError(message: "no provider for \(branch.planID)")
                }
                let baseRunner: AgentRunner = AgentLoop(provider: provider)
                let branchRunner: AgentRunner = meterBranches
                    ? ProgramBudgetedRunner(
                        base: baseRunner,
                        programID: program.id,
                        stage: "branch_research",
                        subjectID: branch.planID,
                        workClass: .research,
                        assignmentBudget: runtime.program.workerAssignments.first { $0.planID == branch.planID }
                            .map { ProgramUsageBudget(totalBudget: $0.tokenBudget) })
                    : baseRunner
                return ResearchWorkbench(
                    runner: branchRunner,
                    store: store,
                    contextTools: [ProgramTools.publishFindingTool(
                        branchPlanID: branch.planID,
                        adjudicate: adjudicate, publish: runtime.publish)] + extraTools,
                    memoryTool: nil,
                    writePolicy: .direct { _ in "" },
                    proveRunner: { _, _ in throw ResearchError(message: "no prove runner") },
                    verifier: nil,
                    savePlan: { try store.savePlan($0) },
                    memoryText: { store.loadBranchMemory(planID: branch.planID) },
                    sharedFactsText: {
                        // Stands in for the director's routing: everything from a sibling
                        // reaches this branch. What gets routed where is decided on the
                        // manifest and pinned in ProgramToolsTests; this suite is about
                        // whether a routed finding is *delivered* at the right moment.
                        ProgramContext.sharedFactsSection(
                            projectMemory: store.memory,
                            routedFindings: runtime.findings()
                                .filter { $0.branchPlanID != branch.planID && !$0.isRejected })
                    },
                    configuration: .init(extraSystemSections: [runtime.plan.lens]),
                    onEvent: onEvent)
            },
            saveProgram: { saved in savedPrograms?.mutate { $0.append(saved) } },
            saveProgramRecord: saveProgramRecord,
            savePlan: saveAdmittedPlan ?? { try store.savePlan($0) },
            resolveWorkerModel: resolveWorkerModel,
            loadProgram: loadProgram,
            synthesize: synthesize,
            direct: direct,
            routeFindings: routeFindings,
            openGeneration: openGeneration,
            maxLegRetries: maxLegRetries,
            legRetryBackoff: 0,          // exercise the retry path without paying for the wait
            onEvent: { event in
                switch event {
                case .branchStarted(let id): events?.mutate { $0.append("start:\(id)") }
                case .branchStatusChanged(let id, let s): events?.mutate { $0.append("status:\(id):\(s.rawValue)") }
                case .recordUpdated(let id, _): events?.mutate { $0.append("record:\(id)") }
                case .findingPublished(let f): events?.mutate { $0.append("finding:\(f.kind.rawValue)") }
                case .problemChallengeReviewed(let c):
                    events?.mutate { $0.append("challenge:\(c.status.rawValue)") }
                case .programPaused: events?.mutate { $0.append("paused") }
                case .synthesisStarted: events?.mutate { $0.append("synthesis") }
                case .branchFailed(let id, _): events?.mutate { $0.append("failed:\(id)") }
                case .directorStarted: events?.mutate { $0.append("director") }
                case .directorDecided(let d): events?.mutate { $0.append("verdict:\(d.verdict.rawValue)") }
                case .branchEvent: break
                }
            })
    }

    // MARK: Actor isolation

    /// Branch legs run on the cooperative pool, never the main actor. The app's factory
    /// touches the main-actor-only store, so it must *hop* — an early version asserted
    /// main-actor isolation instead and trapped on every program run.
    func testBranchWorkbenchFactoryRunsOffTheMainActor() async throws {
        let plan = branchPlan("b-refute")
        try store.savePlan(plan)
        let provider = BranchProvider(scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let sawMainThread = Box<Bool?>(nil)
        let store = self.store!

        let result = try await ProgramRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap)
            ]),
            plans: [plan.id: plan],
            records: [:],
            programRecord: ProgramRunRecord(programID: "prog-1"),
            makeBranchWorkbench: { _, _, onEvent in
                sawMainThread.mutate { $0 = Thread.isMainThread }
                return ResearchWorkbench(
                    runner: AgentLoop(provider: provider), store: store, contextTools: [], memoryTool: nil,
                    writePolicy: .direct { _ in "" },
                    proveRunner: { _, _ in throw ResearchError(message: "n/a") },
                    verifier: nil,
                    savePlan: { try store.savePlan($0) },
                    onEvent: onEvent)
            },
            saveProgram: { _ in }
        ).run()

        guard case .finished = result.outcome else {
            return XCTFail("expected finished, got \(result.outcome)")
        }
        XCTAssertEqual(sawMainThread.value, false,
                       "the factory must be able to hop to the main actor, not assume it")
    }

    // MARK: Slot behavior

    /// A branch waiting on the user must not hold the program hostage: its slot is
    /// released and the next branch runs, even at the shipping concurrency of 1.
    func testAskUserReleasesTheSlotSoSiblingsKeepWorking() async throws {
        let refuter = branchPlan("b-refute")
        let prover = branchPlan("b-prove")
        try store.savePlan(refuter)
        try store.savePlan(prover)

        let refuterProvider = BranchProvider(scripts: [
            call("ask_user", #"{"question":"Should C5 count as a counterexample?"}"#)
        ])
        let proverProvider = BranchProvider(scripts: [
            finish("proved it"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let runner = makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .standard)
            ]),
            plans: [refuter, prover],
            providers: ["b-refute": refuterProvider, "b-prove": proverProvider])

        let result = try await runner.run()

        guard case .waitingOnUser = result.outcome else {
            return XCTFail("expected waitingOnUser, got \(result.outcome)")
        }
        XCTAssertEqual(result.programRecord.status(of: "b-refute"), .waitingUser)
        XCTAssertEqual(result.programRecord.status(of: "b-prove"), .finished,
                       "the prover ran while the refuter waited")
        XCTAssertGreaterThan(proverProvider.requestCount, 0)
    }

    /// The user's override of the scheduler: run the approach they care about now, even
    /// though ordering would have picked another.
    func testRestrictToRunsOnlyTheChosenBranch() async throws {
        let refuter = branchPlan("b-refute")
        let prover = branchPlan("b-prove")
        try store.savePlan(refuter)
        try store.savePlan(prover)

        let refuterProvider = BranchProvider(scripts: [finish("should not run")])
        let proverProvider = BranchProvider(scripts: [
            finish("ran on demand"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .expensive)
            ]),
            plans: [refuter, prover],
            providers: ["b-refute": refuterProvider, "b-prove": proverProvider]
        ).run(restrictTo: ["b-prove"])

        XCTAssertEqual(refuterProvider.requestCount, 0,
                       "the cheap refuter is skipped when the user picked another branch")
        XCTAssertGreaterThan(proverProvider.requestCount, 0)
        XCTAssertEqual(result.programRecord.status(of: "b-prove"), .finished)
        guard case .waitingOnUser = result.outcome else {
            return XCTFail("the program is not done while other branches remain, got \(result.outcome)")
        }
    }

    func testAnsweredBranchResumesOnTheNextDrive() async throws {
        let refuter = branchPlan("b-refute", tasks: 2)
        try store.savePlan(refuter)

        let provider = BranchProvider(scripts: [
            call("ask_user", #"{"question":"Which convention?"}"#)
        ])
        let branches: [ResearchProgram.Branch] = [
            .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap)
        ]
        let first = try await makeRunner(program: program(branches: branches),
                                         plans: [refuter],
                                         providers: ["b-refute": provider]).run()
        XCTAssertEqual(first.programRecord.status(of: "b-refute"), .waitingUser)

        // Answering re-admits it; the workbench resumes from the pending transcript.
        let resumeProvider = BranchProvider(scripts: [
            finish("task 1 done"),
            finish("task 2 done"),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let second = try await makeRunner(
            program: program(branches: branches),
            plans: [try XCTUnwrap(store.plan(id: "b-refute"))],
            providers: ["b-refute": resumeProvider],
            records: first.records,
            programRecord: first.programRecord
        ).run(answers: ["b-refute": "Use the strict convention."])

        guard case .finished = second.outcome else {
            return XCTFail("expected finished, got \(second.outcome)")
        }
        XCTAssertTrue(resumeProvider.requests.contains { $0.messages.contains {
            $0.plainText.contains("Use the strict convention.")
        } }, "the answer reaches the resumed branch")
    }

    // MARK: Findings

    func testFindingsReachSiblingsButNotThePublisher() async throws {
        let refuter = branchPlan("b-refute", tasks: 2)
        let prover = branchPlan("b-prove")
        try store.savePlan(refuter)
        try store.savePlan(prover)

        let refuterProvider = BranchProvider(scripts: [
            call("publish_finding", #"{"kind":"obstruction","statement":"OBSTRUCTION-SENTINEL"}"#),
            finish("task 1 done"),
            finish("task 2 done"),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let proverProvider = BranchProvider(scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .standard)
            ]),
            plans: [refuter, prover],
            providers: ["b-refute": refuterProvider, "b-prove": proverProvider]).run()

        guard case .finished = result.outcome else {
            return XCTFail("expected finished, got \(result.outcome)")
        }

        let proverSystem = try XCTUnwrap(proverProvider.requests.first).system.text
        XCTAssertTrue(proverSystem.contains("OBSTRUCTION-SENTINEL"),
                      "the sibling sees the published fact")

        // The publisher never reads its own finding back — not in the frozen system prompt,
        // and not in the boundary message that delivers what changed since the last task.
        let refuterTask2 = try XCTUnwrap(refuterProvider.requests.first {
            $0.messages.last?.plainText.contains("Execute task 2") ?? false
        })
        XCTAssertFalse(refuterTask2.system.text.contains("OBSTRUCTION-SENTINEL"))
        XCTAssertFalse(refuterTask2.messages.last?.plainText.contains("OBSTRUCTION-SENTINEL") ?? true,
                       "a branch never reads back its own finding")
    }

    /// A counterexample used to stop the whole program and wait for the user. It no longer
    /// does: it is a finding like any other, submitted to a pool the director routes, and the
    /// branch that found it carries on with its remaining tasks. Whether it *answers the
    /// question* is a separate claim, adjudicated and reviewed independently.
    func testACounterexampleNeitherPausesTheProgramNorEndsTheBranch() async throws {
        let refuter = branchPlan("b-refute", tasks: 2)
        let prover = branchPlan("b-prove")
        try store.savePlan(refuter)
        try store.savePlan(prover)

        let refuterProvider = BranchProvider(scripts: [
            call("publish_finding", #"{"kind":"counterexample","statement":"W6 breaks the bound"}"#),
            finish("submitted the counterexample"),
            finish("task two still ran"),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let proverProvider = BranchProvider(scripts: [
            finish("one"), finish("two"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true,
                      costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .expensive)
            ]),
            plans: [refuter, prover],
            providers: ["b-refute": refuterProvider, "b-prove": proverProvider],
            synthesize: { _, _ in "report" }).run()

        if case .paused = result.outcome {
            XCTFail("a counterexample must not pause the program any more")
        }
        XCTAssertGreaterThan(proverProvider.requestCount, 0,
                             "the sibling keeps its slot — nothing was decided by the finding")
        XCTAssertEqual(result.records["b-refute"]?.journal.count, 2,
                       "the publishing branch works its remaining tasks")
    }

    /// A submitted finding reaches nobody until it is routed. Silence is the default, and it
    /// is what stops a portfolio of contradictory approaches collapsing into one.
    func testAnUnroutedFindingIsRecordedButReachesNoBranch() async throws {
        let refuter = branchPlan("b-refute")
        try store.savePlan(refuter)
        let refuterProvider = BranchProvider(scripts: [
            call("publish_finding", #"{"kind":"obstruction","statement":"OBSTRUCTION-SENTINEL"}"#),
            finish("submitted"),
            finish("two"),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let saved = Box<[ResearchProgram]>([])

        _ = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true,
                      costClass: .cheap)
            ]),
            plans: [refuter],
            providers: ["b-refute": refuterProvider],
            savedPrograms: saved,
            synthesize: { _, _ in "report" }).run()

        let latest = try XCTUnwrap(saved.value.last)
        XCTAssertEqual(latest.findings.count, 1, "the finding is durably recorded")
        XCTAssertTrue(latest.routings.isEmpty, "no router was wired, so nothing was routed")
        XCTAssertTrue(latest.findings(routedTo: "b-other").isEmpty)
    }

    // MARK: Budget, errors, synthesis

    /// A governed resume needs no planner — the branch already exists, fully planned — so the
    /// runner admits it in the same task group rather than handing back for the app to build a
    /// whole new run around one already-known branch. The run keeps going until the resumed
    /// branch reaches its own next boundary, which convenes the director a second time.
    func testAcceptedChallengeResumesUnaffectedBranchInPlaceWithoutNewRoutes() async throws {
        let unaffected = branchPlan("b-unaffected")
        try store.savePlan(unaffected)
        var challenge = ProblemChallenge(
            id: "c1", branchPlanID: "b-other", targetRevisionID: "legacy",
            description: "Only the other subrequest is malformed.")
        challenge.status = .accepted
        var challengedProgram = program(branches: [
            .init(planID: "b-unaffected", title: "Unaffected")
        ])
        challenge.targetRevisionID = challengedProgram.activeTargetRevisionID
        challengedProgram.challenges = [challenge]
        let saved = Box<[ResearchProgram]>([])
        let provider = BranchProvider(scripts: [finish("runs after governance")])
        let triggers = Box<[Director.Trigger]>([])

        let result = try await makeRunner(
            program: challengedProgram,
            plans: [unaffected],
            providers: ["b-unaffected": provider],
            savedPrograms: saved,
            direct: { _, _, _, trigger in
                triggers.mutate { $0.append(trigger) }
                switch trigger {
                case .problemChallengeAccepted:
                    return Director.Decision(
                        verdict: .continue, rationale: "unaffected work remains",
                        status: "Resume it.",
                        challengeGovernance: .init(
                            applyRevision: false,
                            stopBranchPlanIDs: [], replanBranchPlanIDs: [],
                            continueBranchPlanIDs: ["b-unaffected"], openNewPortfolio: false,
                            rationale: "The challenge does not touch this branch."))
                default:
                    // The resumed branch ran to completion within the same call — the
                    // ordinary boundary the director sees next.
                    return Director.Decision(
                        verdict: .settled, rationale: "the unaffected branch answers it",
                        status: "Done.")
                }
            }).run()

        XCTAssertEqual(triggers.value, [
            .problemChallengeAccepted(challengeID: "c1"), .generationEnded
        ], "governance resumed the branch in place; its completion reached the next boundary "
            + "without the run ever exiting")
        guard case .decided(let decision, _) = result.outcome else {
            return XCTFail("expected the second boundary to decide, got \(result.outcome)")
        }
        XCTAssertEqual(decision.verdict, .settled)
        XCTAssertEqual(result.programRecord.status(of: "b-unaffected"), .finished)
        XCTAssertGreaterThan(provider.requestCount, 0,
                       "the resumed branch actually ran, admitted by the same task group")
        let persisted = try XCTUnwrap(saved.value.first { $0.challenges.first?.status == .governed })
        XCTAssertEqual(persisted.challenges.first?.status, .governed)
        XCTAssertEqual(persisted.status, .active)
        let final = try XCTUnwrap(saved.value.last)
        XCTAssertEqual(final.status, .done)
    }

    /// The crux of continuous admission: a `continue` decision with routes is planned and
    /// admitted into the *same* task group — no `.awaitingNextGeneration` exit, no second
    /// `run()` call. `openGeneration` here plays the app's role (it is what `appendGeneration`
    /// really is: an opaque planner the runner never looks inside), and the generation-2
    /// branch it hands back runs to completion before the second director turn settles.
    func testContinueWithRoutesOpensAndRunsTheNextGenerationInPlace() async throws {
        let first = branchPlan("b-gen1")
        try store.savePlan(first)
        let gen1Provider = BranchProvider(scripts: [finish("gen 1 found the obstruction")])
        let gen2Provider = BranchProvider(scripts: [finish("gen 2 closes it")])
        let saved = Box<[ResearchProgram]>([])
        let triggers = Box<[Director.Trigger]>([])
        let openedWith = Box<[ResearchRoute]>([])

        let route = ResearchRoute(mechanism: "attack the residual case directly")

        let result = try await makeRunner(
            program: program(branches: [.init(planID: "b-gen1", title: "Gen 1")]),
            plans: [first],
            providers: ["b-gen1": gen1Provider, "b-gen1-g2": gen2Provider],
            savedPrograms: saved,
            // Mirrors how the app really wires this: `openGeneration` (like the real
            // `appendGeneration`) persists the extended roster itself, and `loadProgram`
            // reads it back — this is what makes the director's *next* turn see it.
            loadProgram: { saved.value.last },
            direct: { prog, _, _, trigger in
                triggers.mutate { $0.append(trigger) }
                if prog.branches.count == 1 {
                    return Director.Decision(
                        verdict: .continue, rationale: "the residual case needs its own branch",
                        status: "Opening generation 2.", routes: [route])
                }
                // Called again once generation 2 has also finished, with both branches now
                // visible in the program the runner handed in — proof the roster is current.
                XCTAssertEqual(prog.branches.count, 2)
                return Director.Decision(
                    verdict: .settled, rationale: "generation 2 closed it", status: "Done.")
            },
            openGeneration: { prog, routes, _ in
                openedWith.mutate { $0.append(contentsOf: routes) }
                var extended = prog
                extended.branches.append(.init(planID: "b-gen1-g2", title: "Gen 2", priority: 1))
                let plan = self.branchPlan("b-gen1-g2")
                try self.store.savePlan(plan)
                saved.mutate { $0.append(extended) }
                return (extended, ["b-gen1-g2": plan])
            }).run()

        XCTAssertEqual(triggers.value, [.generationEnded, .generationEnded])
        guard case .decided(let decision, _) = result.outcome else {
            return XCTFail("expected the second boundary to decide, got \(result.outcome)")
        }
        XCTAssertEqual(decision.verdict, .settled)
        XCTAssertEqual(openedWith.value.map(\.mechanism), [route.mechanism])
        XCTAssertEqual(result.programRecord.generation, 2)
        XCTAssertEqual(result.programRecord.status(of: "b-gen1"), .finished)
        XCTAssertEqual(result.programRecord.status(of: "b-gen1-g2"), .finished)
        XCTAssertGreaterThan(gen2Provider.requestCount, 0,
                             "generation 2 ran inside this same run() call")
        let final = try XCTUnwrap(saved.value.last)
        XCTAssertEqual(final.branches.count, 2, "the extended roster was persisted")
        XCTAssertEqual(final.status, .done)
    }

    /// The pre-existing behaviour when no inline planner is wired: unchanged. This is the
    /// safety net a caller not yet updated for continuous admission falls back to.
    func testContinueWithRoutesFallsBackToAwaitingNextGenerationWhenNoOpenGenerationIsWired() async throws {
        let first = branchPlan("b-gen1")
        try store.savePlan(first)
        let provider = BranchProvider(scripts: [finish("gen 1 found the obstruction")])
        let route = ResearchRoute(mechanism: "attack the residual case directly")

        let result = try await makeRunner(
            program: program(branches: [.init(planID: "b-gen1", title: "Gen 1")]),
            plans: [first],
            providers: ["b-gen1": provider],
            direct: { _, _, _, _ in
                Director.Decision(
                    verdict: .continue, rationale: "the residual case needs its own branch",
                    status: "Opening generation 2.", routes: [route])
            }).run()

        guard case .awaitingNextGeneration(let decision) = result.outcome else {
            return XCTFail("expected the pre-existing hand-back, got \(result.outcome)")
        }
        XCTAssertEqual(decision.routes.map(\.mechanism), [route.mechanism])
    }

    /// The mechanism a "director-first" program creation flow depends on entirely: a program
    /// approved with zero branches is not stuck — `trackedBranches.values.allSatisfy` is
    /// vacuously true over an empty collection, so the very first `run()` call sees "every
    /// branch terminal" immediately and convenes the director with no branch ever having run.
    /// Its first move can build the program's first branch from nothing.
    func testAZeroBranchProgramConvenesTheDirectorImmediately() async throws {
        let workerPlanID = "prog-1-w1-establish-the-base-case"
        let workerProvider = BranchProvider(scripts: [finish("base case established")])
        let triggers = Box<[Director.Trigger]>([])
        let saved = Box<[ResearchProgram]>([])

        let result = try await makeRunner(
            program: program(branches: []),
            plans: [],
            providers: [workerPlanID: workerProvider],
            savedPrograms: saved,
            loadProgram: { saved.value.last },
            direct: { prog, _, _, trigger in
                triggers.mutate { $0.append(trigger) }
                if prog.workerAssignments.isEmpty {
                    XCTAssertEqual(prog.branches.count, 0,
                                   "the director's first convening sees the empty roster it started with")
                    return Director.Decision(
                        verdict: .continue, rationale: "nothing has been tried yet",
                        status: "Dispatching the first worker.",
                        workerAssignments: [WorkerAssignment(
                            objective: "establish the base case",
                            targetRevisionID: prog.activeTargetRevisionID,
                            tokenBudget: 100_000,
                            stopCondition: "the base case is established or refuted")])
                }
                XCTAssertEqual(prog.branches.count, 1,
                               "the second convening sees the branch the first dispatch built")
                return Director.Decision(
                    verdict: .settled, rationale: "the base case was the whole problem",
                    status: "Done.")
            }).run()

        XCTAssertEqual(triggers.value, [.generationEnded, .generationEnded])
        guard case .decided(let decision, _) = result.outcome else {
            return XCTFail("expected the second boundary to decide, got \(result.outcome)")
        }
        XCTAssertEqual(decision.verdict, .settled)
        XCTAssertGreaterThan(workerProvider.requestCount, 0,
                             "the very first branch this program ever had ran to completion")
        XCTAssertEqual(result.programRecord.status(of: workerPlanID), .finished)
    }

    /// Coverage rejection is a planning result, not a runner crash. The app persists the
    /// proposed routes as blocked with the auditor's feedback and returns no plans; the same
    /// run must then convene the director once more against that updated registry.
    func testAnEmptyRejectedGenerationGetsOneImmediateDirectorRepairTurn() async throws {
        let saved = Box<[ResearchProgram]>([])
        let triggers = Box<[Director.Trigger]>([])
        let rejected = ResearchRoute(mechanism: "assume the desired limit exists")

        let result = try await makeRunner(
            program: program(branches: []),
            plans: [],
            providers: [:],
            savedPrograms: saved,
            loadProgram: { saved.value.last },
            direct: { prog, _, _, trigger in
                triggers.mutate { $0.append(trigger) }
                if prog.routes?.isEmpty != false {
                    return Director.Decision(
                        verdict: .continue,
                        rationale: "try the proposed route",
                        status: "Checking coverage.",
                        routes: [rejected])
                }
                let blocked = try XCTUnwrap(prog.routes?.first)
                XCTAssertEqual(blocked.status, .blocked)
                XCTAssertTrue(blocked.obstruction?.contains("circular assumption") == true)
                return Director.Decision(
                    verdict: .futile,
                    rationale: "the coverage gate exposed a circular assumption",
                    status: "The proposed route was rejected; no sound repair remains.")
            },
            openGeneration: { prog, routes, _ in
                var updated = prog
                updated.routes = routes.map { route in
                    var blocked = route
                    blocked.status = .blocked
                    blocked.obstruction = "circular assumption"
                    return blocked
                }
                saved.mutate { $0.append(updated) }
                return (updated, [:])
            }).run()

        XCTAssertEqual(triggers.value, [.generationEnded, .generationEnded])
        guard case .decided(let decision, _) = result.outcome else {
            return XCTFail("expected the repair turn to decide, got \(result.outcome)")
        }
        XCTAssertEqual(decision.verdict, .futile)
        XCTAssertEqual(result.programRecord.generation, 1,
                       "a rejected admission did not open generation 2")
    }

    /// The other half of continuous admission: a freeform `dispatch_worker` decision needs no
    /// `openGeneration` at all — no pass-2 planner turn, no portfolio coverage review. The
    /// runner builds the branch and its bootstrap plan mechanically and admits it into the
    /// same task group; the branch then plans itself, inside its own conversation, from that
    /// bootstrap task.
    func testDispatchWorkerBuildsAndRunsASelfPlanningBranchWithNoExternalPlanner() async throws {
        let first = branchPlan("b-gen1")
        try store.savePlan(first)
        let gen1Provider = BranchProvider(scripts: [finish("gen 1 found the obstruction")])
        // Deterministic from `program.id` ("prog-1") and the objective — nothing here goes
        // through `openGeneration`, so there is no test-supplied planID to key off instead.
        let workerPlanID = "prog-1-w1-close-the-residual-case-directly"
        let workerProvider = BranchProvider(scripts: [
            finish("the residual case closes by direct computation")
        ])
        let saved = Box<[ResearchProgram]>([])
        let triggers = Box<[Director.Trigger]>([])

        let result = try await makeRunner(
            program: program(branches: [.init(planID: "b-gen1", title: "Gen 1")]),
            plans: [first],
            providers: ["b-gen1": gen1Provider, workerPlanID: workerProvider],
            savedPrograms: saved,
            loadProgram: { saved.value.last },
            direct: { prog, _, _, trigger in
                triggers.mutate { $0.append(trigger) }
                if prog.workerAssignments.isEmpty {
                    return Director.Decision(
                        verdict: .continue,
                        rationale: "one small decisive dispatch settles the residual case",
                        status: "Dispatching a worker.",
                        workerAssignments: [WorkerAssignment(
                            objective: "close the residual case directly",
                            targetRevisionID: prog.activeTargetRevisionID,
                            tokenBudget: 200_000,
                            stopCondition: "the residual case is closed or ruled out")])
                }
                XCTAssertEqual(prog.workerAssignments.count, 1)
                XCTAssertNotNil(prog.workerAssignments.first?.planID)
                return Director.Decision(
                    verdict: .settled, rationale: "the dispatch closed it", status: "Done.")
            }
            // openGeneration deliberately left nil: this path must not need it.
            ).run()

        XCTAssertEqual(triggers.value, [.generationEnded, .generationEnded])
        guard case .decided(let decision, _) = result.outcome else {
            return XCTFail("expected the second boundary to decide, got \(result.outcome)")
        }
        XCTAssertEqual(decision.verdict, .settled)
        XCTAssertEqual(result.programRecord.status(of: workerPlanID), .finished)
        XCTAssertGreaterThan(workerProvider.requestCount, 0,
                             "the dispatched worker ran inside this same run() call")
        // Not left at generation 1: it never was, since a dispatch is not a new wave — but the
        // program record must still reflect the branch actually admitted and finished.
        let final = try XCTUnwrap(saved.value.last { $0.workerAssignments.count == 1 })
        XCTAssertEqual(final.branches.map(\.planID).contains(workerPlanID), true)
        XCTAssertEqual(final.workerAssignments.first?.planID, workerPlanID)
        XCTAssertEqual(final.workerAssignments.first?.stopCondition,
                       "the residual case is closed or ruled out")
    }

    func testSharedCeilingPausesProgramAndDefersAdmission() async throws {
        let first = branchPlan("b-refute")
        let second = branchPlan("b-prove")
        try store.savePlan(first)
        try store.savePlan(second)

        let ledger = Box<[ProgramUsageEntry]>([])
        await ProgramUsageRegistry.shared.register(
            programID: "prog-1",
            totalBudget: 500,
            append: { entry in ledger.mutate { $0.append(entry) } })

        let firstProvider = BranchProvider(scripts: [
            [.usage(input: 400, output: 400)] + finish("burned the budget"),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let secondProvider = BranchProvider(scripts: [finish("should never run")])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .standard)
            ], budget: 500),
            plans: [first, second],
            providers: ["b-refute": firstProvider, "b-prove": secondProvider],
            meterBranches: true).run()
        await ProgramUsageRegistry.shared.unregister(programID: "prog-1")

        guard case .paused(.programBudgetReached) = result.outcome else {
            return XCTFail("expected a budget pause, got \(result.outcome)")
        }
        XCTAssertEqual(secondProvider.requestCount, 0)
        XCTAssertEqual(ledger.value.last?.termination, .budgetPaused)
    }

    func testBranchErrorIsRecordedAndSiblingsContinue() async throws {
        let broken = branchPlan("b-refute")
        let healthy = branchPlan("b-prove")
        try store.savePlan(broken)
        try store.savePlan(healthy)

        let healthyProvider = BranchProvider(scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let events = Box<[String]>([])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .standard)
            ]),
            plans: [broken, healthy],
            providers: ["b-refute": ThrowingProvider(), "b-prove": healthyProvider],
            events: events).run()

        guard case .waitingOnUser = result.outcome else {
            return XCTFail("expected waitingOnUser, got \(result.outcome)")
        }
        XCTAssertEqual(result.programRecord.status(of: "b-refute"), .errored)
        XCTAssertEqual(result.programRecord.status(of: "b-prove"), .finished)
        XCTAssertTrue(events.value.contains("failed:b-refute"))
    }

    func testAllBranchesTerminalRunsSynthesisOnce() async throws {
        let a = branchPlan("b-refute")
        let b = branchPlan("b-prove")
        try store.savePlan(a)
        try store.savePlan(b)

        let providers: [String: LLMProvider] = [
            "b-refute": BranchProvider(scripts: [finish("a done"), [.textDelta("R"), .finished(.endTurn)]]),
            "b-prove": BranchProvider(scripts: [finish("b done"), [.textDelta("R"), .finished(.endTurn)]])
        ]
        let synthesisCalls = Box<[Int]>([])
        let saved = Box<[ResearchProgram]>([])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap),
                .init(planID: "b-prove", title: "Prove", costClass: .standard)
            ]),
            plans: [a, b],
            providers: providers,
            savedPrograms: saved,
            synthesize: { _, records in
                synthesisCalls.mutate { $0.append(records.count) }
                return "REPORT-SENTINEL"
            }).run()

        guard case .finished(let report) = result.outcome else {
            return XCTFail("expected finished, got \(result.outcome)")
        }
        XCTAssertEqual(report, "REPORT-SENTINEL")
        XCTAssertEqual(synthesisCalls.value, [2], "synthesis runs once, seeing both branches")
        XCTAssertTrue(saved.value.contains { $0.status == .done })
    }

    /// A standalone plan runs through the same coordinator with none of the program
    /// machinery attached — no manifest writes, no cross-branch section.
    func testVirtualProgramNeverPersistsAManifest() async throws {
        let plan = PlanDocument(id: "solo", goal: "One line of attack", status: .approved,
                                runMode: .auto,
                                tasks: [PlanTask(index: 1, title: "Do the thing")])
        try store.savePlan(plan)
        let provider = BranchProvider(scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let saved = Box<[ResearchProgram]>([])
        let virtual = ResearchProgram.virtual(plan: plan)

        let result = try await ProgramRunner(
            program: virtual,
            plans: [plan.id: plan],
            records: [:],
            programRecord: ProgramRunRecord(programID: virtual.id),
            makeBranchWorkbench: { [store] _, _, onEvent in
                ResearchWorkbench(
                    runner: AgentLoop(provider: provider), store: store!, contextTools: [], memoryTool: nil,
                    writePolicy: .direct { _ in "" },
                    proveRunner: { _, _ in throw ResearchError(message: "n/a") },
                    verifier: nil,
                    savePlan: { try store!.savePlan($0) },
                    onEvent: onEvent)
            },
            saveProgram: { program in saved.mutate { $0.append(program) } }
        ).run()

        guard case .finished = result.outcome else {
            return XCTFail("expected finished, got \(result.outcome)")
        }
        XCTAssertTrue(saved.value.isEmpty, "virtual programs are never written to disk")
        for request in provider.requests {
            XCTAssertFalse(request.system.text.contains("Shared facts from the research program"))
        }
    }

    // MARK: - A dropped provider stream does not end the branch

    func testATransientProviderFailureIsRetried() async throws {
        let plan = branchPlan("b-refute")
        try store.savePlan(plan)
        let provider = FlakyProvider(failures: 1, scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap)
            ]),
            plans: [plan],
            providers: ["b-refute": provider]).run()

        XCTAssertEqual(result.programRecord.status(of: "b-refute"), .finished,
                       "one dropped stream must not end the branch")
    }

    func testWithoutRetriesTheSameFailureEndsTheBranch() async throws {
        let plan = branchPlan("b-refute")
        try store.savePlan(plan)
        let provider = FlakyProvider(failures: 1, scripts: [
            finish("done"), [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap)
            ]),
            plans: [plan],
            providers: ["b-refute": provider],
            maxLegRetries: 0).run()

        // Pins that the retry is what saved the branch above, not something else.
        XCTAssertEqual(result.programRecord.status(of: "b-refute"), .errored)
    }

    /// The reason the runner tracks the freshest plan and record per branch: a retry that
    /// restarted from the load-time copy would redo work the branch had already finished.
    func testARetryResumesInsteadOfRedoingCompletedTasks() async throws {
        let plan = branchPlan("b-refute", tasks: 2)
        try store.savePlan(plan)
        let provider = FlakyProvider(failures: 0, scripts: [
            finish("one"),
            [.textDelta("Done."), .finished(.endTurn)],
            nil,                                        // stream drops partway into task 2
            finish("two"),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let result = try await makeRunner(
            program: program(branches: [
                .init(planID: "b-refute", title: "Refute", challengesLeadingAnswer: true, costClass: .cheap)
            ]),
            plans: [plan],
            providers: ["b-refute": provider]).run()

        XCTAssertEqual(result.programRecord.status(of: "b-refute"), .finished)
        XCTAssertEqual(result.records["b-refute"]?.journal.map(\.summary), ["one", "two"],
                       "task 1 must not run twice")
        XCTAssertEqual(try XCTUnwrap(store.plan(id: "b-refute")).tasks.map(\.status),
                       [.completed, .completed])
    }
    func testProgramDeadlineCancelsASlowWorkerTool() async throws {
        var p = program(branches: [.init(planID: "b1", title: "Slow experiment")])
        p.continuation = .init(maxWallClockSeconds: 0.1)
        let cancelled = Box(false)
        let provider = BranchProvider(scripts: [call("slow_experiment", "{}")])
        let result = try await makeRunner(program: p, plans: [branchPlan("b1")], providers: ["b1": provider],
            direct: { _, _, _, _ in XCTFail("deadline must prevent another decision"); return nil },
            extraTools: [SlowExperiment(cancelled: cancelled)]).run()
        XCTAssertEqual(result.programRecord.pause, .wallClockReached)
        XCTAssertEqual(result.programRecord.status(of: "b1"), .queued)
        XCTAssertTrue(cancelled.value)
    }

    func testRevisedTargetIsFormalizedBeforeDirectWorkerAdmission() async throws {
        var p = program(branches: [])
        let oldRevision = p.activeTargetRevisionID
        var challenge = ProblemChallenge(id: "c1", branchPlanID: "prior", targetRevisionID: oldRevision,
                                         description: "Scope needs correction")
        challenge.status = .accepted
        p.challenges = [challenge]
        let formalized = Box(false)
        let provider = BranchProvider(scripts: [finish("checked revised scope")])
        _ = try await makeRunner(program: p, plans: [], providers: ["prog-1-w1-inspect": provider],
            inspectRuntime: { _, runtime in
                XCTAssertTrue(formalized.value)
                XCTAssertNotEqual(runtime.program.activeTargetRevisionID, oldRevision)
                XCTAssertEqual(runtime.program.researchRequest, "Classify all finite cases.")
                XCTAssertEqual(runtime.plan.goal, "Classify all finite cases.")
                XCTAssertEqual(runtime.program.contract?.statement, "Revised contract")
                XCTAssertEqual(runtime.program.workerAssignments.first?.targetRevisionID,
                               runtime.program.activeTargetRevisionID)
            },
            direct: { _, _, _, trigger in
                if case .problemChallengeAccepted = trigger {
                    return .init(verdict: .continue, rationale: "correct scope", status: "revise",
                        workerAssignments: [.init(objective: "inspect", targetRevisionID: oldRevision,
                                                  tokenBudget: 10_000)],
                        challengeGovernance: .init(applyRevision: true,
                            replacementRequest: "Classify all finite cases.",
                            stopBranchPlanIDs: [], replanBranchPlanIDs: [], continueBranchPlanIDs: [],
                            openNewPortfolio: false, rationale: "preserve intended quantifier"))
                }
                return .init(verdict: .futile, rationale: "test done", status: "stop")
            },
            openGeneration: { live, routes, _ in
                XCTAssertTrue(routes.isEmpty)
                XCTAssertNil(live.contract)
                var updated = live
                updated.contract = .init(statement: "Revised contract", completeAnswers: [],
                                         completenessRationale: "Test scope")
                formalized.mutate { $0 = true }
                return (updated, [:])
            }).run()
        XCTAssertGreaterThan(provider.requestCount, 0)
    }

    func testExpiredProgramDeadlineSurvivesRestartAndPreventsDirectorCall() async throws {
        var p = program(branches: [])
        p.continuation = .init(maxWallClockSeconds: 10)
        let start = Date().addingTimeInterval(-20)
        let persisted = Box<[ProgramRunRecord]>([])
        let record = ProgramRunRecord(programID: p.id, startedAt: start)
        let decoded = try JSONDecoder().decode(ProgramRunRecord.self, from: JSONEncoder().encode(record))
        let result = try await makeRunner(program: p, plans: [], providers: [:], programRecord: decoded,
            saveProgramRecord: { value in persisted.mutate { $0.append(value) } },
            direct: { _, _, _, _ in XCTFail("expired program must not buy another call"); return nil }).run()
        XCTAssertEqual(result.programRecord.pause, .wallClockReached)
        XCTAssertEqual(result.programRecord.startedAt, start)
        XCTAssertEqual(persisted.value.last?.pause, .wallClockReached)
    }

    func testProgramDeadlineCancelsASlowDirectorAndDoesNotFinish() async throws {
        var p = program(branches: [])
        p.continuation = .init(maxWallClockSeconds: 0.05)
        let saved = Box<[ResearchProgram]>([])
        let cancelled = Box(false)
        let result = try await makeRunner(program: p, plans: [], providers: [:], savedPrograms: saved,
            direct: { _, _, _, _ in
                do { try await Task.sleep(for: .seconds(10)) }
                catch { cancelled.mutate { $0 = true }; throw error }
                return .init(verdict: .settled, rationale: "must not happen", status: "done")
            }).run()
        XCTAssertEqual(result.programRecord.pause, .wallClockReached)
        XCTAssertTrue(cancelled.value)
        XCTAssertFalse(saved.value.contains { $0.status == .done })
    }

    func testFailedRunCheckpointPreventsAnyModelCall() async throws {
        do {
            _ = try await makeRunner(program: program(branches: []), plans: [], providers: [:],
                saveProgramRecord: { _ in throw ResearchError(message: "disk full") },
                direct: { _, _, _, _ in XCTFail("must save before execution"); return nil }).run()
            XCTFail("required checkpoint failure must propagate")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disk full")) }
    }

    func testDirectDispatchAdvancesProgressCursorAndSavesItBeforeNextWorker() async throws {
        let one = WorkerAssignment(objective: "first", targetRevisionID: "target", tokenBudget: 10_000, stopCondition: "done")
        let two = WorkerAssignment(objective: "second", targetRevisionID: "target", tokenBudget: 10_000, stopCondition: "done")
        let providers: [String: LLMProvider] = [
            "prog-1-w1-first": BranchProvider(scripts: [call("publish_finding", #"{"kind":"evidence","statement":"a new result"}"#), finish("done")]),
            "prog-1-w2-second": BranchProvider(scripts: [finish("no further progress")])
        ]
        let checkpoints = Box<[ProgramRunRecord]>([])
        let calls = Box(0)
        let result = try await makeRunner(program: program(branches: []), plans: [], providers: providers,
            saveProgramRecord: { value in checkpoints.mutate { $0.append(value) } },
            inspectRuntime: { branch, _ in
                if branch.planID == "prog-1-w2-second" {
                    XCTAssertEqual(checkpoints.value.last?.findingsAtGenerationStart, 1)
                }
            },
            direct: { _, _, signal, _ in
                calls.mutate { $0 += 1 }
                switch calls.value {
                case 1: return .init(verdict: .continue, rationale: "first", status: "first", workerAssignments: [one])
                case 2:
                    XCTAssertEqual(signal.newFindings, 1)
                    return .init(verdict: .continue, rationale: "second", status: "second", workerAssignments: [two])
                default:
                    XCTAssertEqual(signal.newFindings, 0)
                    XCTAssertTrue(signal.isStalled)
                    return .init(verdict: .futile, rationale: "stop", status: "stop")
                }
            }).run()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(result.programRecord.findingsAtGenerationStart, 1)
    }

    func testDirectorTransportFailureNeverFinishesAnEmptyProgram() async throws {
        let saved = Box<[ResearchProgram]>([])
        do {
            _ = try await makeRunner(program: program(branches: []), plans: [], providers: [:],
                savedPrograms: saved,
                synthesize: { _, _ in XCTFail("must not synthesize success after director failure"); return "" },
                direct: { _, _, _, _ in throw ResearchError(message: "director transport unavailable") }).run()
            XCTFail("expected a recoverable error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("director transport unavailable")) }
        XCTAssertFalse(saved.value.contains { $0.status == .done })
    }

    func testMissingDirectorVerdictNeverFinishesAnEmptyProgram() async throws {
        let saved = Box<[ResearchProgram]>([])
        do {
            _ = try await makeRunner(program: program(branches: []), plans: [], providers: [:],
                savedPrograms: saved, direct: { _, _, _, _ in nil }).run()
            XCTFail("expected a missing-decision error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no valid decision")) }
        XCTAssertFalse(saved.value.contains { $0.status == .done })
    }

    func testDirectorCancellationPropagatesWithoutFinishing() async throws {
        let saved = Box<[ResearchProgram]>([])
        do {
            _ = try await makeRunner(program: program(branches: []), plans: [], providers: [:],
                savedPrograms: saved, direct: { _, _, _, _ in throw CancellationError() }).run()
            XCTFail("expected cancellation")
        } catch is CancellationError { } catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(saved.value.isEmpty)
    }

    func testDispatchPersistsAndDeliversFullBriefAndResolvedModelBeforeFirstCall() async throws {
        let objective = "Inspect the finite construction. " + String(repeating: "Retain this objective clause. ", count: 8)
        let assignment = WorkerAssignment(objective: objective, constraints: ["constraint-marker-731"],
            targetRevisionID: "old-revision", relevantItemIDs: ["lemma-marker-732"], tokenBudget: 100_000,
            modelTier: "strong", stopCondition: "stop-marker-733")
        let planID = "prog-1-w1-" + TheoryItem.sanitizeID(objective)
        let provider = BranchProvider(scripts: [finish("partial conclusion")])
        let store = self.store!
        let saved = Box<[ResearchProgram]>([])
        _ = try await makeRunner(program: program(branches: []), plans: [], providers: [planID: provider],
            savedPrograms: saved, loadProgram: { saved.value.last },
            inspectRuntime: { branch, runtime in
                XCTAssertEqual(store.plan(id: branch.planID)?.lens, assignment.brief)
                XCTAssertEqual(runtime.plan.lens, assignment.brief)
                XCTAssertEqual(runtime.plan.program, runtime.program.id)
                XCTAssertEqual(runtime.program.workerAssignments.first?.targetRevisionID, runtime.program.activeTargetRevisionID)
                XCTAssertEqual(branch.model, "configured-strong-model")
                XCTAssertEqual(branch.providerKind, "codex")
            },
            resolveWorkerModel: { tier in
                XCTAssertEqual(tier, "strong"); return ("codex", "configured-strong-model")
            },
            direct: { live, _, _, _ in
                live.workerAssignments.isEmpty
                    ? .init(verdict: .continue, rationale: "inspect", status: "Dispatch", workerAssignments: [assignment])
                    : .init(verdict: .futile, rationale: "done inspecting", status: "Stop")
            }).run()
        let prompt = try XCTUnwrap(provider.requests.first).system.text
        XCTAssertTrue(prompt.contains(assignment.objective))
        XCTAssertTrue(prompt.contains("constraint-marker-731"))
        XCTAssertTrue(prompt.contains("stop-marker-733"))
        XCTAssertTrue(prompt.contains("lemma-marker-732"))
    }

    func testFailedPlanSavePreventsWorkerAdmission() async throws {
        let provider = BranchProvider(scripts: [finish("must never run")])
        let saved = Box<[ResearchProgram]>([])
        do {
            _ = try await makeRunner(program: program(branches: []), plans: [],
                providers: ["prog-1-w1-inspect": provider], savedPrograms: saved,
                saveAdmittedPlan: { _ in throw ResearchError(message: "disk write failed") },
                direct: { live, _, _, _ in .init(verdict: .continue, rationale: "inspect", status: "Dispatch",
                    workerAssignments: [.init(objective: "inspect", targetRevisionID: live.activeTargetRevisionID,
                        tokenBudget: 100, stopCondition: "checked")]) }).run()
            XCTFail("must surface the persistence failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disk write failed")) }
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertTrue(saved.value.isEmpty)
    }

    func testRoutingSeesWorkersAdmittedAfterTheEmptyProgramStarted() async throws {
        let routed = expectation(description: "routing receives current roster")
        let workerID = "prog-1-w1-inspect"
        let provider = BranchProvider(scripts: [
            call("publish_finding", #"{"kind":"evidence","statement":"finite test result"}"#),
            finish("checked")
        ])
        let saved = Box<[ResearchProgram]>([])
        _ = try await makeRunner(program: program(branches: []), plans: [], providers: [workerID: provider],
            savedPrograms: saved, loadProgram: { saved.value.last },
            routeFindings: { live, _ in
                XCTAssertEqual(live.branches.map(\.planID), [workerID])
                XCTAssertEqual(live.workerAssignments.first?.planID, workerID)
                routed.fulfill(); return []
            },
            direct: { live, _, _, _ in
                live.workerAssignments.isEmpty
                    ? .init(verdict: .continue, rationale: "inspect", status: "Dispatch", workerAssignments: [
                        .init(objective: "inspect", targetRevisionID: live.activeTargetRevisionID,
                              tokenBudget: 100_000, stopCondition: "checked")])
                    : .init(verdict: .futile, rationale: "stop", status: "Stop")
            }).run()
        await fulfillment(of: [routed], timeout: 2)
    }

    func testAssignmentExhaustionReturnsControlToTheDirector() async throws {
        await ProgramUsageRegistry.shared.register(programID: "prog-1", totalBudget: 10_000, append: { _ in })
        let workerID = "prog-1-w1-inspect"
        let provider = BranchProvider(scripts: [[.usage(input: 200, output: 20)] + finish("partial")])
        let saved = Box<[ResearchProgram]>([])
        let calls = Box(0)
        let result = try await makeRunner(program: program(branches: []), plans: [], providers: [workerID: provider],
            savedPrograms: saved, loadProgram: { saved.value.last },
            direct: { live, records, _, _ in
                calls.mutate { $0 += 1 }
                if live.workerAssignments.isEmpty {
                    return .init(verdict: .continue, rationale: "inspect", status: "Dispatch", workerAssignments: [
                        .init(objective: "inspect", targetRevisionID: live.activeTargetRevisionID,
                              tokenBudget: 100, stopCondition: "checked")])
                }
                XCTAssertEqual(records[workerID]?.state, .budgetPause)
                return .init(verdict: .futile, rationale: "allocation exhausted", status: "Stop")
            }, meterBranches: true).run()
        await ProgramUsageRegistry.shared.unregister(programID: "prog-1")
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(result.programRecord.status(of: workerID), .assignmentExhausted)
        XCTAssertNil(result.programRecord.pause)
    }
    func testMixedRoutesAndWorkersPreserveBothInTheNextDirectorContext() async throws {
        let routedPlan = branchPlan("b-route")
        let routedProvider = BranchProvider(scripts: [finish("route finished")])
        let workerPlanID = "prog-1-w1-check-the-witness"
        let workerProvider = BranchProvider(scripts: [finish("worker finished")])
        let saved = Box<[ResearchProgram]>([])
        let seenAtSecondDirector = Box<ResearchProgram?>(nil)
        let proposedRoute = ResearchRoute(
            mechanism: "exhaustively rule out maxima below the witness",
            nextTest: "enumerate all four-subsets of 1 through 6")

        _ = try await makeRunner(
            program: program(branches: []),
            plans: [],
            providers: ["b-route": routedProvider, workerPlanID: workerProvider],
            savedPrograms: saved,
            loadProgram: { saved.value.last },
            direct: { prog, _, _, _ in
                if prog.workerAssignments.isEmpty {
                    return Director.Decision(
                        verdict: .continue,
                        rationale: "run the proof route and a witness checker",
                        status: "Opening both pieces.",
                        routes: [proposedRoute],
                        workerAssignments: [WorkerAssignment(
                            objective: "check the witness",
                            targetRevisionID: prog.activeTargetRevisionID,
                            tokenBudget: 100_000,
                            stopCondition: "all subset sums are explicitly verified")])
                }
                seenAtSecondDirector.mutate { $0 = prog }
                return Director.Decision(
                    verdict: .futile,
                    rationale: "stop after the probe",
                    status: "Probe complete.")
            },
            openGeneration: { prog, routes, _ in
                var opened = prog
                opened.routes = (opened.routes ?? []) + routes
                opened.branches.append(.init(planID: routedPlan.id, title: "Lower bound route"))
                saved.mutate { $0.append(opened) }
                return (opened, [routedPlan.id: routedPlan])
            }).run()

        let second = try XCTUnwrap(seenAtSecondDirector.value)
        XCTAssertTrue(second.branches.contains { $0.planID == routedPlan.id },
                       "route branch must survive the worker admission")
        XCTAssertTrue(second.routes?.contains { $0.mechanism == proposedRoute.mechanism } == true,
                       "route registry must survive the worker admission")
        XCTAssertTrue(second.branches.contains { $0.planID == workerPlanID })
    }
}

/// Fails its first `failures` streams outright, then plays `scripts`. A `nil` slot inside
/// `scripts` drops the stream at that point instead of yielding events.
private final class FlakyProvider: LLMProvider, @unchecked Sendable {
    var description: String { "flaky" }
    private let lock = NSLock()
    private var failures: Int
    private var scripts: [[LLMEvent]?]

    init(failures: Int, scripts: [[LLMEvent]?]) {
        self.failures = failures
        self.scripts = scripts
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        if failures > 0 {
            failures -= 1
            lock.unlock()
            return AsyncThrowingStream { $0.finish(throwing: AgentError.http(503, "stream dropped")) }
        }
        let slot = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        guard let events = slot else {
            return AsyncThrowingStream { $0.finish(throwing: AgentError.http(503, "stream dropped")) }
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct SlowExperiment: AgentTool, @unchecked Sendable {
    let cancelled: Box<Bool>
    var spec: ToolSpec { .init(name: "slow_experiment", description: "Slow cancellable experiment",
                               inputSchemaJSON: #"{"type":"object","properties":{}}"#) }
    func execute(inputJSON: String) async throws -> String {
        do { try await Task.sleep(for: .seconds(10)) }
        catch { cancelled.mutate { $0 = true }; throw error }
        return "done"
    }
}
