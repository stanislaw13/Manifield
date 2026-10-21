import XCTest
import ManifieldCore
@testable import ManifieldAgents

// MARK: - Scripted infrastructure

private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    var description: String { "scripted" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var _requests: [LLMRequest] = []

    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

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

private func toolCall(_ name: String, _ json: String, id: String = UUID().uuidString) -> [LLMEvent] {
    [.toolUseFinished(id: id, name: name, inputJSON: json), .finished(.toolUse)]
}

final class ResearchWorkbenchTests: XCTestCase {
    func testExplicitReviewGapBlocksDependentTaskWithoutExtraReportingTurn() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks[0].title = "Prove midpoint preservation"
        plan.tasks[0].reviewGate = true
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [toolCall("finish_task", #"{"outcome":"completed","summary":"Midpoints are preserved by a reflection argument."}"#)])
        let verifier = StubReviewer(result: .init(verdict: .issues, issues: [
            .init(location: "midpoint step", severity: "fatal", description: "The local reflection need not stay in the domain.")]))
        let record = try await makeWorkbench(provider: provider, verifier: verifier,
            configuration: .init(explicitOutcomes: true, reviewRounds: .bounded(0)))
            .run(plan: plan, record: RunRecord(plan: plan))
        let saved = try XCTUnwrap(store.plan(id: plan.id))
        XCTAssertEqual(saved.tasks[0].status, .blocked)
        XCTAssertEqual(saved.tasks[1].status, .pending)
        XCTAssertTrue(saved.tasks[0].needs?.contains("reflection") == true)
        XCTAssertEqual(record.journal.count, 1)
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testExplicitTaskToolLimitPreservesTranscriptWithoutOutcomeNudge() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [toolCall("search_theory", #"{"query":"midpoint"}"#)])
        let record = try await makeWorkbench(provider: provider,
            configuration: .init(maxTaskIterations: 1, explicitOutcomes: true))
            .run(plan: plan, record: RunRecord(plan: plan))
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(record.lastStopReason, .toolLimit)
        XCTAssertEqual(store.plan(id: plan.id)?.tasks[0].status, .blocked)
        XCTAssertEqual(store.plan(id: plan.id)?.tasks[1].status, .pending)
    }

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "R")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func savePlan(_ plan: PlanDocument) throws {
        try store.savePlan(plan)
    }

    private func makeWorkbench(
        provider: ScriptedProvider,
        writePolicy: TheoryWritePolicy? = nil,
        proveRunner: (@Sendable (String, @escaping @Sendable (AgentActivity) -> Void) async throws -> ProofWorkbench.Outcome)? = nil,
        verifier: ProofVerifier? = nil,
        configuration: ResearchWorkbench.Configuration = .init(),
        onEvent: @escaping @Sendable (ResearchWorkbench.Event) -> Void = { _ in }
    ) -> ResearchWorkbench {
        let store = self.store!
        return ResearchWorkbench(
            runner: AgentLoop(provider: provider),
            store: store,
            contextTools: TheoryTools.readOnlyTools(store: store),
            memoryTool: nil,
            writePolicy: writePolicy ?? .direct { proposal in
                try store.save(proposal.item)
                return "Wrote '\(proposal.item.id)'."
            },
            proveRunner: proveRunner ?? { _, _ in
                XCTFail("unexpected prove task")
                throw ResearchError(message: "no prove runner")
            },
            verifier: verifier,
            savePlan: { try store.savePlan($0) },
            configuration: configuration,
            onEvent: onEvent
        )
    }

    private func twoTaskPlan(mode: RunMode, budget: Int = 5_000_000) -> PlanDocument {
        PlanDocument(
            id: "p1", goal: "Prove conj-x", status: .approved, runMode: mode,
            tokenBudget: budget,
            approach: "Test approach",
            tasks: [
                PlanTask(index: 1, title: "Survey small cases"),
                PlanTask(index: 2, title: "Draft the key lemma", dependsOn: [1])
            ])
    }

    // MARK: Auto mode

    /// The branch keeps its own reasoning across tasks. Task 2 does not read a 1200-character
    /// digest of task 1 — it was there for task 1, which is the whole point: in mathematics
    /// the insight is usually in the working, and the digest is exactly what drops it.
    func testAutoRunCarriesTheBranchConversationAcrossTasks() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.textDelta("Working notes for task one: the δ=2 family is where it binds.")] +
                toolCall("finish_task", #"{"outcome":"completed","summary":"Surveyed 853 graphs; wrote rem-survey."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Lemma drafted as lem-key."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Run summary: both tasks done."), .finished(.endTurn)]  // reconciliation
        ])
        let workbench = makeWorkbench(provider: provider)

        let record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        guard case .finished(let summary) = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
        XCTAssertTrue(summary.contains("both tasks done"))
        XCTAssertEqual(record.journal.map(\.outcome), ["completed", "completed"])

        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertEqual(saved.tasks.map(\.status), [.completed, .completed])
        XCTAssertEqual(saved.status, .done)
        XCTAssertTrue(saved.log.contains { $0.contains("task 1 completed") })

        let task2Request = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("Execute task 2") }
        })
        XCTAssertTrue(task2Request.messages.contains { $0.plainText.contains("δ=2 family") },
                      "task 2 inherits task 1's actual working, not a summary of it")
        XCTAssertGreaterThan(task2Request.messages.count, 1)
        XCTAssertFalse(task2Request.system.text.contains("task 1 [completed]: Surveyed 853 graphs"),
                       "the journal is the fallback for a compacted branch, not a duplicate of the transcript")

        // The system prompt is frozen for the conversation: prompt caching is prefix-based,
        // so rebuilding it per task would re-charge the whole transcript every time.
        let task1Request = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("Execute task 1") }
        })
        XCTAssertEqual(task1Request.system.text, task2Request.system.text)
        XCTAssertNotNil(record.conversation)
    }

    /// The escape hatch, and the pre-conversation behaviour: a zero budget puts every task
    /// back in its own context behind the journal.
    func testZeroConversationBudgetRestoresPerTaskFreshContext() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.textDelta("Secret working notes for task one.")] +
                toolCall("finish_task", #"{"outcome":"completed","summary":"Surveyed 853 graphs."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Lemma drafted."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await makeWorkbench(
            provider: provider, configuration: .init(maxConversationTokens: 0)
        ).run(plan: plan, record: RunRecord(plan: plan))

        XCTAssertNil(record.conversation)
        let task2Request = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("Execute task 2") }
        })
        XCTAssertEqual(task2Request.messages.count, 1, "each task starts fresh")
        XCTAssertTrue(task2Request.system.text.contains("task 1 [completed]: Surveyed 853 graphs"))
        XCTAssertFalse(task2Request.messages.contains { $0.plainText.contains("Secret working notes") })
    }

    /// A conversation that outgrows its budget is dropped at the task boundary and the
    /// journal carries the branch forward — mechanically, with no summarisation turn.
    func testConversationCompactsWhenItOutgrowsItsBudget() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks = [
            PlanTask(index: 1, title: "Enumerate"),
            PlanTask(index: 2, title: "Draft"),
            PlanTask(index: 3, title: "Check", dependsOn: [2])
        ]
        try savePlan(plan)
        // A realistic filler: a big tool result is what actually fills a research transcript.
        let bulky = String(repeating: "x", count: 60_000)
        let provider = ScriptedProvider(scripts: [
            [.textDelta(bulky)] + toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await makeWorkbench(
            provider: provider, configuration: .init(maxConversationTokens: 10_000)
        ).run(plan: plan, record: RunRecord(plan: plan))

        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertTrue(saved.log.contains { $0.contains("conversation compacted") },
                      "the compaction is on the record, not silent")

        // Task 2 opens a new conversation, and the journal is what carries task 1 into it.
        let task2Request = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("Execute task 2") }
        })
        XCTAssertEqual(task2Request.messages.count, 1)
        XCTAssertTrue(task2Request.system.text.contains("task 1 [completed]: Enumerated"))
        XCTAssertFalse(task2Request.messages.contains { $0.plainText.contains(bulky) })
    }

    /// Work that ran outside the conversation has to be told, not remembered: a `prove:`
    /// task executes in the ProofWorkbench, so the branch never saw it happen.
    func testProveTaskOutcomeIsInjectedAtTheNextBoundary() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks = [
            PlanTask(index: 1, title: "Explore"),
            PlanTask(index: 2, title: "Prove it", kind: .prove(targetID: "lem-key")),
            PlanTask(index: 3, title: "Use the lemma", dependsOn: [2])
        ]
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"Explored."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Used it."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        _ = try await makeWorkbench(
            provider: provider,
            proveRunner: { _, _ in
                ProofWorkbench.Outcome(finalStatus: .reviewedNoErrors, roundsUsed: 1,
                                       proposalCount: 1, externalsUsed: [], outstandingIssues: [])
            }
        ).run(plan: plan, record: RunRecord(plan: plan))

        let task3Request = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("Execute task 3") }
        })
        let opening = try XCTUnwrap(task3Request.messages.last?.plainText)
        XCTAssertTrue(opening.contains("outside this conversation"), "got: \(opening)")
        XCTAssertTrue(opening.contains("lem-key"), "got: \(opening)")
    }

    // MARK: Checkpoint mode

    func testCheckpointPausesAfterEachTaskAndResumes() async throws {
        let plan = twoTaskPlan(mode: .checkpoint)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"Task one done."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Task two done."}"#),
            [.finished(.endTurn)],
            [.textDelta("All done."), .finished(.endTurn)]
        ])
        let workbench = makeWorkbench(provider: provider)

        var record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))
        guard case .checkpoint(let afterTask) = record.state else {
            return XCTFail("expected checkpoint, got \(record.state)")
        }
        XCTAssertEqual(afterTask, 1)
        XCTAssertEqual(store.plan(id: "p1")?.tasks.map(\.status), [.completed, .pending])

        // The user reviewed; continue.
        let resumed = try XCTUnwrap(store.plan(id: "p1"))
        record = try await workbench.run(plan: resumed, record: record)
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
        XCTAssertEqual(store.plan(id: "p1")?.tasks.map(\.status), [.completed, .completed])
    }

    // MARK: ask_user

    func testAskUserPausesAndResumesSameConversation() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks = [PlanTask(index: 1, title: "Decide the boundary case")]
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.textDelta("I tried both readings.")] +
                toolCall("ask_user", #"{"question":"Does C5 count as a valid extremal case?","context":"Both conventions appear in the sources."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Resolved with the user's convention."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])
        let workbench = makeWorkbench(provider: provider)

        var record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))
        guard case .waitingForUser(let question) = record.state else {
            return XCTFail("expected waitingForUser, got \(record.state)")
        }
        XCTAssertEqual(question.taskIndex, 1)
        XCTAssertTrue(question.question.contains("C5"))
        XCTAssertNotNil(record.conversation, "the question turn is kept, so the answer continues it")

        // The record survives an app restart.
        let data = try JSONEncoder().encode(record)
        record = try JSONDecoder().decode(RunRecord.self, from: data)

        let current = try XCTUnwrap(store.plan(id: "p1"))
        record = try await workbench.run(plan: current, record: record, userInput: "Yes, C5 counts.")
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }

        // The resume request continues the SAME conversation with the answer injected.
        let resumeRequest = try XCTUnwrap(provider.requests.first {
            $0.messages.contains { $0.plainText.contains("<user-answer>") }
        })
        XCTAssertTrue(resumeRequest.messages.contains { $0.plainText.contains("Yes, C5 counts.") })
        XCTAssertTrue(resumeRequest.messages.first?.plainText.contains("Execute task 1") ?? false,
                      "the original task conversation is preserved")
    }

    // MARK: Budget

    func testBudgetCrossingPausesAndRaisedBudgetContinues() async throws {
        let plan = twoTaskPlan(mode: .auto, budget: 100)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.usage(input: 90, output: 30)] +
                toolCall("finish_task", #"{"outcome":"completed","summary":"Task one done."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Task two done."}"#),
            [.finished(.endTurn)],
            [.finished(.endTurn)]
        ])
        let workbench = makeWorkbench(provider: provider)

        var record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))
        guard case .budgetPause = record.state else {
            return XCTFail("expected budgetPause, got \(record.state)")
        }
        XCTAssertEqual(record.tokensUsed, 120)
        XCTAssertEqual(store.plan(id: "p1")?.tasks.map(\.status), [.completed, .pending],
                       "the task that crossed the cap still concluded cleanly")

        record.tokenBudget = 10_000
        let current = try XCTUnwrap(store.plan(id: "p1"))
        record = try await workbench.run(plan: current, record: record)
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
    }

    func testProgramBranchIgnoresLegacyPerBranchBudget() async throws {
        let plan = twoTaskPlan(mode: .auto, budget: 100)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.usage(input: 90, output: 30)]
                + toolCall("finish_task", #"{"outcome":"completed","summary":"Task one done."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Task two done."}"#),
            [.finished(.endTurn)],
            [.textDelta("Both tasks complete."), .finished(.endTurn)]
        ])
        let workbench = makeWorkbench(
            provider: provider,
            configuration: .init(programID: "prog-1"))

        let record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        guard case .finished = record.state else {
            return XCTFail("program work must use the shared ceiling, got \(record.state)")
        }
        XCTAssertEqual(record.journal.map(\.outcome), ["completed", "completed"])
        XCTAssertEqual(record.tokensUsed, 120)
    }

    // MARK: finish_task discipline

    func testMissingFinishTaskGetsOneNudgeThenFails() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks = [PlanTask(index: 1, title: "Drift off")]
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.textDelta("I did some things."), .finished(.endTurn)],   // no finish_task
            [.textDelta("Still no tool call."), .finished(.endTurn)],  // ignores the nudge
            [.finished(.endTurn)]                                       // reconciliation
        ])
        let workbench = makeWorkbench(provider: provider)

        let record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
        XCTAssertEqual(record.journal.first?.outcome, "failed")
        XCTAssertEqual(store.plan(id: "p1")?.tasks.first?.status, .failed)
        XCTAssertTrue(provider.requests.contains {
            $0.messages.contains { $0.plainText.contains("without calling finish_task") }
        }, "the nudge message was sent")
    }

    // MARK: prove tasks

    func testProveTaskDelegatesToProveRunner() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks = [PlanTask(index: 1, title: "Prove the key lemma",
                               kind: .prove(targetID: "lem-key"))]
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let capturedTarget = CapturedString()
        let workbench = makeWorkbench(provider: provider, proveRunner: { targetID, onActivity in
            capturedTarget.set(targetID)
            onActivity(.usage(input: 500, output: 700))
            return ProofWorkbench.Outcome(
                finalStatus: .reviewedNoErrors, roundsUsed: 2,
                proposalCount: 1, externalsUsed: [], outstandingIssues: [])
        })

        let record = try await workbench.run(plan: plan, record: RunRecord(plan: plan))
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }
        XCTAssertEqual(capturedTarget.value, "lem-key")
        XCTAssertEqual(record.tokensUsed, 1200, "prove-task usage feeds the budget guard")
        XCTAssertEqual(store.plan(id: "p1")?.tasks.first?.status, .completed)
        XCTAssertTrue(record.journal.first?.summary.contains("no errors found") ?? false)
    }

    private final class CapturedString: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return _value }
    }

    // MARK: - Research-program branch seams

    private func makeBranchWorkbench(
        provider: ScriptedProvider,
        memoryText: (@Sendable () -> String)? = nil,
        sharedFactsText: (@Sendable () -> String?)? = nil,
        lens: String? = nil
    ) -> ResearchWorkbench {
        let store = self.store!
        return ResearchWorkbench(
            runner: AgentLoop(provider: provider),
            store: store,
            contextTools: TheoryTools.readOnlyTools(store: store),
            memoryTool: nil,
            writePolicy: .direct { proposal in
                try store.save(proposal.item)
                return "Wrote '\(proposal.item.id)'."
            },
            proveRunner: { _, _ in
                XCTFail("unexpected prove task")
                throw ResearchError(message: "no prove runner")
            },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            memoryText: memoryText,
            sharedFactsText: sharedFactsText,
            configuration: .init(extraSystemSections: lens.map { [$0] } ?? []))
    }

    /// The core of branch isolation: a branch reads its own memory file, and the
    /// project's beliefs never reach it.
    func testMemoryTextClosureReplacesProjectMemoryEverywhere() async throws {
        try store.saveMemory("## Key Insights\nPROJECT-BELIEF: the conjecture is true.\n")
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let workbench = makeBranchWorkbench(
            provider: provider,
            memoryText: { "## Key Insights\nBRANCH-NOTES: assume it is false.\n" })

        _ = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        XCTAssertGreaterThanOrEqual(provider.requests.count, 3)
        for request in provider.requests {
            XCTAssertTrue(request.system.text.contains("BRANCH-NOTES"),
                          "every turn (tasks and reconcile) reads the branch's own memory")
            XCTAssertFalse(request.system.text.contains("PROJECT-BELIEF"),
                           "the project's beliefs must never reach a branch")
        }
    }

    func testLensIsInjectedAfterHonestyRulesAndBeforeMemory() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let workbench = makeBranchWorkbench(provider: provider, lens: "LENS-SENTINEL: assume it is false.")

        _ = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        let system = try XCTUnwrap(provider.requests.first).system.text
        let lensRange = try XCTUnwrap(system.range(of: "LENS-SENTINEL"))
        let honestyRange = try XCTUnwrap(system.range(of: "Epistemic contract"))
        let memoryRange = try XCTUnwrap(system.range(of: "Research memory"))
        XCTAssertLessThan(honestyRange.lowerBound, lensRange.lowerBound)
        XCTAssertLessThan(lensRange.lowerBound, memoryRange.lowerBound)
    }

    /// Findings published mid-run must reach the next task — the closure is re-read at
    /// every task start, which is what makes the broadcast timely.
    func testSharedFactsAreRefreshedAtEveryTaskStart() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let facts = CapturedString()
        facts.set("FINDINGS-V1")
        let store = self.store!
        // The pool flips the moment task 1 finishes, as a sibling publishing would.
        let workbench = ResearchWorkbench(
            runner: AgentLoop(provider: provider),
            store: store,
            contextTools: [],
            memoryTool: nil,
            writePolicy: .direct { _ in "" },
            proveRunner: { _, _ in throw ResearchError(message: "no prove runner") },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            sharedFactsText: { facts.value },
            onEvent: { event in
                if case .taskFinished(let index, _, _) = event, index == 1 {
                    facts.set("FINDINGS-V2")
                }
            })

        _ = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        // Task 1 opens the conversation, so its facts are in the frozen system prompt.
        let task1 = try XCTUnwrap(provider.requests.first {
            $0.messages.last?.plainText.contains("Execute task 1") ?? false
        })
        XCTAssertTrue(task1.system.text.contains("FINDINGS-V1"))

        // Task 2 continues it, so what a sibling published while task 1 ran arrives in the
        // boundary message — new information in causal order, and the cached prefix intact.
        let task2 = try XCTUnwrap(provider.requests.first {
            $0.messages.last?.plainText.contains("Execute task 2") ?? false
        })
        XCTAssertFalse(task2.system.text.contains("FINDINGS-V2"))
        XCTAssertTrue(task2.messages.last?.plainText.contains("FINDINGS-V2") ?? false,
                      "task 2 must see what was published while task 1 ran")
    }

    /// Steering must reach the *next* task, not require restarting the branch — so the
    /// closure is re-read per task, like findings.
    func testGuidanceIsReReadAtEveryTaskStart() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let guidance = CapturedString()
        let store = self.store!
        let workbench = ResearchWorkbench(
            runner: AgentLoop(provider: provider),
            store: store,
            contextTools: [],
            memoryTool: nil,
            writePolicy: .direct { _ in "" },
            proveRunner: { _, _ in throw ResearchError(message: "no prove runner") },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            guidanceText: { guidance.value },
            onEvent: { event in
                // The user types a correction while task 1 runs.
                if case .taskFinished(let index, _, _) = event, index == 1 {
                    guidance.set("STEER-SENTINEL: drop the δ=2 case.")
                }
            })

        _ = try await workbench.run(plan: plan, record: RunRecord(plan: plan))

        let task1 = try XCTUnwrap(provider.requests.first {
            $0.messages.last?.plainText.contains("Execute task 1") ?? false
        })
        XCTAssertFalse(task1.system.text.contains("STEER-SENTINEL"))

        let task2 = try XCTUnwrap(provider.requests.first {
            $0.messages.last?.plainText.contains("Execute task 2") ?? false
        })
        let opening = try XCTUnwrap(task2.messages.last?.plainText)
        XCTAssertTrue(opening.contains("STEER-SENTINEL"),
                      "guidance added mid-run reaches the next task")
        XCTAssertTrue(opening.contains("Standing guidance"))
    }

    func testNoSharedFactsClosureOmitsTheSectionEntirely() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        _ = try await makeBranchWorkbench(provider: provider)
            .run(plan: plan, record: RunRecord(plan: plan))

        for request in provider.requests {
            XCTAssertFalse(request.system.text.contains("Shared facts from the research program"),
                           "a standalone plan gets no program chrome")
        }
    }

    // MARK: - A failed task takes its dependents with it

    /// Scripts one failing task, then the reconciliation turn.
    private func failingFirstTask() -> ScriptedProvider {
        ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"failed","summary":"Kill criterion fired."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Run summary: the approach is dead."), .finished(.endTurn)]
        ])
    }

    func testAFailedTaskBlocksItsDependentsInsteadOfStrandingThemPending() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)

        _ = try await makeWorkbench(provider: failingFirstTask())
            .run(plan: plan, record: RunRecord(plan: plan))

        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertEqual(saved.tasks.map(\.status), [.failed, .blocked])
        XCTAssertEqual(saved.tasks[1].needs, "task 1 failed, so this can no longer run",
                       "the plan has to say why the task never ran")
    }

    func testARunThatCompletedNothingRecordsAsFailedNotPaused() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)

        _ = try await makeWorkbench(provider: failingFirstTask())
            .run(plan: plan, record: RunRecord(plan: plan))

        // `failed` is a verdict the archive is read for; `paused` reads as an interruption.
        XCTAssertEqual(try XCTUnwrap(store.plan(id: "p1")).status, .failed)
    }

    func testStrandedTasksDoNotStopTheRunToAskTheUser() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)

        let record = try await makeWorkbench(provider: failingFirstTask())
            .run(plan: plan, record: RunRecord(plan: plan))

        // No answer can complete a failed dependency, so asking would stall forever.
        if case .waitingForUser(let question) = record.state {
            XCTFail("run stopped to ask about an unanswerable task: \(question.question)")
        }
        guard case .finished = record.state else {
            return XCTFail("expected the run to finish, got \(record.state)")
        }
    }

    func testTheRecordIsPublishedAtEveryTaskBoundary() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let published = RecordBox()
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"one"}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"two"}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        _ = try await makeWorkbench(provider: provider, onEvent: { event in
            if case .recordUpdated(let record) = event { published.append(record) }
        }).run(plan: plan, record: RunRecord(plan: plan))

        // Without this the controller only persists when the leg returns, so a crash
        // mid-branch loses the journal of every task already finished.
        XCTAssertEqual(published.values.count, 2, "one per completed task")
        XCTAssertEqual(published.values.first?.journal.count, 1)
        XCTAssertEqual(published.values.last?.journal.map(\.summary), ["one", "two"])
    }

    // MARK: - Review gate on a task that failed

    private static let provedItemMarkdown = """
    {"action":"create","markdown":"---\\nid: lem-review-me\\ntype: lemma\\nname: Review me\\n\
    status: proof-drafted\\ndepends_on: []\\ntags: []\\n---\\n## Statement\\n$P$ holds.\\n\\n\
    ## Proof\\nBy induction.\\n"}
    """

    func testAWrittenProofIsReviewedEvenWhenTheTaskFails() async throws {
        var plan = twoTaskPlan(mode: .auto)
        plan.tasks[0].reviewGate = true
        try savePlan(plan)
        let reviewed = ItemIDBox()
        let provider = ScriptedProvider(scripts: [
            toolCall("write_theory_item", Self.provedItemMarkdown),
            toolCall("finish_task", #"{"outcome":"failed","summary":"Ran out of road."}"#),
            [.textDelta("Done."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        let verifier = StubReviewer(result: ReviewResult(
            verdict: .issues,
            issues: [ReviewIssue(location: "step 2", severity: "gap", description: "induction base missing")]))

        let record = try await makeWorkbench(
            provider: provider, verifier: verifier,
            onEvent: { event in
                if case .reviewStarted(let id) = event { reviewed.append(id) }
            }
        ).run(plan: plan, record: RunRecord(plan: plan))

        // The item is in the library either way; a failed task is exactly when nobody
        // would otherwise look at it.
        XCTAssertEqual(reviewed.values, ["lem-review-me"])
        let summary = try XCTUnwrap(record.journal.first?.summary)
        XCTAssertTrue(summary.contains("review found issues"), "got: \(summary)")
        XCTAssertTrue(summary.contains("no fix round"), "got: \(summary)")
    }

    /// Fully unattended, a blocked task has nobody to answer it: the branch gets its replan
    /// turn instead of parking the night on a question. Under any other policy it still asks.
    func testBlockedTaskReplansInsteadOfAskingWhenNobodyIsWatching() async throws {
        let plan = twoTaskPlan(mode: .auto)
        try savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"blocked","summary":"need a convention","needs":"which indexing?"}"#),
            // The replan turn: drop the stalled tail and conclude.
            toolCall("revise_plan", #"{"drop":[2],"reason":"the blocker cannot be resolved unattended"}"#),
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let record = try await makeWorkbench(
            provider: provider,
            configuration: .init(continuation: .fullAuto)
        ).run(plan: plan, record: RunRecord(plan: plan))

        if case .waitingForUser = record.state {
            XCTFail("a fully unattended run must not stop on a blocked task")
        }
        guard case .finished = record.state else {
            return XCTFail("expected the leg to conclude, got \(record.state)")
        }
    }
}

/// Minimal thread-safe flag for the tests above.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ value: T) { lock.lock(); _value = value; lock.unlock() }
}

// MARK: - Mid-branch replanning

final class RevisePlanTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replan-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "RP")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 1 fails, 2 and 3 depend on it, 4 is independent.
    private func plan() -> PlanDocument {
        PlanDocument(id: "p1", goal: "Settle conj-x", status: .approved, runMode: .auto,
                     tokenBudget: 5_000_000,
                     tasks: [PlanTask(index: 1, title: "Audit the lens"),
                             PlanTask(index: 2, title: "Build on the audit", dependsOn: [1]),
                             PlanTask(index: 3, title: "Finish the proof", dependsOn: [2])])
    }

    private func workbench(_ provider: LLMProvider, maxRevisions: Int = 3) -> ResearchWorkbench {
        let store = self.store!
        return ResearchWorkbench(
            runner: AgentLoop(provider: provider), store: store,
            contextTools: [], memoryTool: nil,
            writePolicy: .direct { _ in "" },
            proveRunner: { _, _ in throw ResearchError(message: "none") },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            configuration: .init(maxPlanRevisions: maxRevisions))
    }

    private static let failTask1 = #"{"outcome":"failed","summary":"Kill criterion fired."}"#

    func testAFailureThatStrandsWorkTriggersAReplanTurn() async throws {
        let plan = self.plan()
        try store.savePlan(plan)
        let provider = ScriptedRungProvider(scripts: [
            toolCallEvents("finish_task", Self.failTask1),
            [.textDelta("."), .finished(.endTurn)],
            // replan turn: drop the dead tail, add work that survives
            toolCallEvents("revise_plan", #"""
            {"drop":[2,3],"add":[{"title":"Compute the small cases directly","kind":"research"}],
             "reason":"The lens died but the small-case computation never depended on it."}
            """#),
            [.textDelta("."), .finished(.endTurn)],
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"computed"}"#),
            [.textDelta("."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        _ = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertEqual(saved.tasks.map(\.status), [.failed, .dropped, .dropped, .completed])
        XCTAssertEqual(saved.tasks[3].title, "Compute the small cases directly")
        XCTAssertTrue(saved.log.contains { $0.contains(PlanDocument.revisionLogMarker) })
    }

    /// Stopping is a legitimate outcome, and the cheaper mistake to make.
    func testAReplanThatRevisesNothingLetsTheBranchClose() async throws {
        let plan = self.plan()
        try store.savePlan(plan)
        let provider = ScriptedRungProvider(scripts: [
            toolCallEvents("finish_task", Self.failTask1),
            [.textDelta("."), .finished(.endTurn)],
            [.textDelta("Nothing here survives the lens."), .finished(.endTurn)],  // replan: no tool
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        guard case .finished = record.state else {
            return XCTFail("expected the branch to close, got \(record.state)")
        }
        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertEqual(saved.status, .failed)
        XCTAssertEqual(saved.tasks.map(\.status), [.failed, .blocked, .blocked])
    }

    func testTheRevisionBudgetIsFinite() async throws {
        let plan = self.plan()
        try store.savePlan(plan)
        // Every replan drops nothing and adds a task that fails again — the thrash shape.
        var scripts: [[LLMEvent]] = [
            toolCallEvents("finish_task", Self.failTask1),
            [.textDelta("."), .finished(.endTurn)]
        ]
        for round in 1...6 {
            scripts.append(toolCallEvents("revise_plan", #"""
            {"drop":[],"add":[{"title":"Retry \#(round)","kind":"research"}],"reason":"try again"}
            """#))
            scripts.append([.textDelta("."), .finished(.endTurn)])
            scripts.append(toolCallEvents("finish_task", Self.failTask1))
            scripts.append([.textDelta("."), .finished(.endTurn)])
        }
        scripts.append([.textDelta("Reconciled."), .finished(.endTurn)])

        _ = try await workbench(ScriptedRungProvider(scripts: scripts), maxRevisions: 2)
            .run(plan: plan, record: RunRecord(plan: plan))

        let saved = try XCTUnwrap(store.plan(id: "p1"))
        XCTAssertEqual(saved.revisionCount, 2, "a branch must stop replanning and conclude")
    }

    func testARevisionCannotRewriteATaskThatAlreadyRan() async throws {
        var plan = self.plan()
        plan.tasks[0].status = .completed        // task 1 is now the record
        plan.tasks[1].status = .failed
        try store.savePlan(plan)
        let provider = ScriptedRungProvider(scripts: [
            toolCallEvents("revise_plan",
                           #"{"drop":[1,2,3],"reason":"start over"}"#),
            [.textDelta("."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])
        _ = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        let saved = try XCTUnwrap(store.plan(id: "p1"))
        // Only the never-started task 3 may go; 1 and 2 are what happened.
        XCTAssertEqual(saved.tasks[0].status, .completed)
        XCTAssertEqual(saved.tasks[1].status, .failed)
        XCTAssertEqual(saved.tasks[2].status, .dropped)
    }

    func testDroppedTasksAreTerminalSoTheRunCanEnd() {
        XCTAssertTrue(PlanTask.Status.dropped.isTerminal)
        XCTAssertFalse(PlanTask.Status.dropped.isUnstarted)
        var plan = self.plan()
        plan.tasks[0].status = .completed
        plan.tasks[1].status = .dropped
        plan.tasks[2].status = .dropped
        XCTAssertTrue(plan.isFinished)
    }
}

// MARK: - Success contract enforcement

final class FinishTaskContractTests: XCTestCase {

    private func contract() -> SuccessContract {
        SuccessContract(
            statement: "S",
            completeAnswers: [
                .init(id: "A1", statement: "the closed form", evidence: "a reviewed proof"),
                .init(id: "A2", statement: "a proof no closed form exists", evidence: "review")
            ],
            completenessRationale: "Either a closed form exists or it provably does not.")
    }

    private func tool(_ contract: SuccessContract?) -> (FinishTaskTool, TaskSignals) {
        let signals = TaskSignals()
        return (FinishTaskTool(signals: signals, contract: contract), signals)
    }

    func testTheOutcomeIsRecordedWithoutAnyContract() async throws {
        let (tool, signals) = self.tool(nil)
        _ = try await tool.execute(inputJSON: #"{"outcome":"completed","summary":"done"}"#)
        XCTAssertEqual(signals.outcome?.kind, .completed)
        XCTAssertEqual(signals.outcome?.summary, "done")
    }

    /// Nothing about the outcome is validated against the contract any more. A task's outcome
    /// is a fact about the task; whether the *problem* was answered is decided by
    /// `claim_solution` and two independent passes, neither of which is this tool.
    func testACompletedTaskNeedsNothingBeyondItsSummary() async throws {
        let (tool, signals) = self.tool(contract())
        _ = try await tool.execute(
            inputJSON: #"{"outcome":"completed","summary":"set up the benchmark"}"#)
        XCTAssertEqual(signals.outcome?.kind, .completed)
    }

    /// The one thing the contract still does here: remind the model that finishing tasks is
    /// not answering the question, and name the tool that would be.
    func testTheContractMakesTheDescriptionSayFinishingIsNotAnswering() {
        let (withContract, _) = tool(contract())
        let (without, _) = tool(nil)
        XCTAssertTrue(withContract.spec.description.contains("claim_solution"))
        XCTAssertFalse(without.spec.description.contains("claim_solution"))
    }

    func testAnUnknownOutcomeIsRejected() async {
        let (tool, _) = self.tool(contract())
        do {
            _ = try await tool.execute(inputJSON: #"{"outcome":"solved","summary":"s"}"#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("completed, blocked or failed"))
        }
    }

    func testAMissingSummaryIsRejected() async {
        let (tool, _) = self.tool(contract())
        do {
            _ = try await tool.execute(inputJSON: #"{"outcome":"completed"}"#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("summary"))
        }
    }
}

final class SuccessContractRunTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contract-run-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "C")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func contract() -> SuccessContract {
        SuccessContract(
            statement: "Settle conj-x",
            completeAnswers: [
                .init(id: "A1", statement: "a proof of the theorem", evidence: "review"),
                .init(id: "A2", statement: "a counterexample", evidence: "a verified witness")
            ],
            completenessRationale: "The statement is either true or false.",
            notCounted: ["numerical evidence without a finite-reduction theorem"])
    }

    private func workbench(_ provider: LLMProvider, contract: SuccessContract?) -> ResearchWorkbench {
        let store = self.store!
        return ResearchWorkbench(
            runner: AgentLoop(provider: provider), store: store,
            contextTools: TheoryTools.readOnlyTools(store: store),
            memoryTool: nil,
            writePolicy: .direct { _ in "" },
            proveRunner: { _, _ in throw ResearchError(message: "none") },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            configuration: .init(successContract: contract))
    }

    private func plan() -> PlanDocument {
        PlanDocument(id: "p1", goal: "Settle conj-x", status: .approved, runMode: .auto,
                     tokenBudget: 5_000_000,
                     tasks: [PlanTask(index: 1, title: "One"),
                             PlanTask(index: 2, title: "Two"),
                             PlanTask(index: 3, title: "Three")])
    }

    func testTheAuthoritativeTargetReachesEveryTaskWithoutLegacyExclusions() async throws {
        let plan = self.plan()
        try store.savePlan(plan)
        let provider = ScriptedRungProvider(scripts: [
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"a","rung":"none"}"#),
            [.textDelta("."), .finished(.endTurn)],
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"b","rung":"none"}"#),
            [.textDelta("."), .finished(.endTurn)],
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"c","rung":"none"}"#),
            [.textDelta("."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        _ = try await workbench(provider, contract: contract())
            .run(plan: plan, record: RunRecord(plan: plan))

        let taskRequests = provider.requests.filter {
            $0.messages.contains { $0.plainText.contains("Execute task") }
        }
        XCTAssertFalse(taskRequests.isEmpty)
        for request in taskRequests {
            XCTAssertTrue(request.system.text.contains("Research goal"))
            XCTAssertTrue(request.system.text.contains("Settle conj-x"))
            XCTAssertFalse(request.system.text.contains("numerical evidence without a finite-reduction theorem"),
                           "legacy exclusions must not constrain new research prompts")
        }
    }

    /// A run that never claims anything simply works through its tasks. Nothing in the
    /// contract stops a leg any more: the ladder's target match was the only mechanism that
    /// did, and it stopped branches on a string comparison against a self-reported rung.
    func testPartialProgressNeverStopsTheRun() async throws {
        let plan = self.plan()
        try store.savePlan(plan)
        let provider = ScriptedRungProvider(scripts: [
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"a"}"#),
            [.textDelta("."), .finished(.endTurn)],
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"b"}"#),
            [.textDelta("."), .finished(.endTurn)],
            toolCallEvents("finish_task", #"{"outcome":"completed","summary":"c"}"#),
            [.textDelta("."), .finished(.endTurn)],
            [.textDelta("Reconciled."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider, contract: contract())
            .run(plan: plan, record: RunRecord(plan: plan))

        guard case .finished = record.state else {
            return XCTFail("expected the run to finish, got \(record.state)")
        }
        XCTAssertEqual(record.journal.count, 3)
    }
}

/// Local scripted provider so these suites do not depend on the fileprivate one above.
final class ScriptedRungProvider: LLMProvider, @unchecked Sendable {
    var description: String { "scripted-rung" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var _requests: [LLMRequest] = []

    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

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

func toolCallEvents(_ name: String, _ json: String) -> [LLMEvent] {
    [.toolUseFinished(id: UUID().uuidString, name: name, inputJSON: json), .finished(.toolUse)]
}

/// Thread-safe collectors for events emitted off the test's own actor.
private final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [RunRecord] = []
    var values: [RunRecord] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ record: RunRecord) { lock.lock(); _values.append(record); lock.unlock() }
}

private final class ItemIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ id: String) { lock.lock(); _values.append(id); lock.unlock() }
}

private struct StubReviewer: ProofVerifier {
    let result: ReviewResult
    func review(target: TheoryItem, proofMarkdown: String,
                onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws -> ReviewResult {
        result
    }
}

final class WriteTheoryItemToolTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-tool-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "W")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTool() -> AgentTool {
        let store = self.store!
        return ResearchTools.writeTool(
            policy: .direct { proposal in
                try store.save(proposal.item)
                return "Wrote '\(proposal.item.id)' [\(proposal.item.status.rawValue)]."
            },
            store: store,
            signals: TaskSignals())
    }

    func testDirectWriteLands() async throws {
        let reply = try await makeTool().execute(inputJSON: """
        {"action": "create", "markdown": "---\\nid: conj-new\\ntype: conjecture\\nname: New\\nstatus: tested\\ndepends_on: []\\ntags: []\\n---\\n## Statement\\n$P$ holds.\\n\\n## Evidence\\nChecked n ≤ 8."}
        """)
        XCTAssertTrue(reply.contains("conj-new"))
        XCTAssertEqual(store.item(id: "conj-new")?.status, .tested)
    }

    func testHumanOnlyStatusIsRejected() async throws {
        do {
            _ = try await makeTool().execute(inputJSON: """
            {"action": "create", "markdown": "---\\nid: thm-cheat\\ntype: theorem\\nname: Cheat\\nstatus: human-approved\\ndepends_on: []\\ntags: []\\n---\\n## Statement\\n$Q$."}
            """)
            XCTFail("expected clamp rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("human"))
        }
        XCTAssertNil(store.item(id: "thm-cheat"), "nothing must be written")
    }

    func testUnsafeControlCharactersFromUnescapedLaTeXAreRejectedBeforeWrite() async throws {
        let base = """
        ---
        id: thm-unsafe
        type: theorem
        name: Unsafe
        status: proof-drafted
        depends_on: []
        tags: []
        ---
        ## Statement
        $f: X PLACEHOLDER Y$.
        """
        let unsafeControls = ((0...31).filter { $0 != 10 } + [127]).map {
            String(UnicodeScalar($0)!)
        }
        for control in unsafeControls {
            let markdown = base.replacingOccurrences(of: "PLACEHOLDER", with: control)
            let data = try JSONSerialization.data(withJSONObject: [
                "action": "create", "markdown": markdown
            ])
            do {
                _ = try await makeTool().execute(inputJSON: String(decoding: data, as: UTF8.self))
                XCTFail("expected unsafe control character rejection")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
                XCTAssertTrue(error.localizedDescription.contains("LaTeX backslash"))
            }
            XCTAssertNil(store.item(id: "thm-unsafe"), "rejected content must not be written")
        }
    }
}

/// Archiving a branch's conversation. The guarantee: a branch's reasoning is recoverable after
/// the run, including the stretches compaction drops out of the prompt.
final class BranchArchiveTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-archive-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "A")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func workbench(_ provider: ScriptedProvider,
                           maxConversationTokens: Int = 120_000,
                           programID: String = "prog-1") -> ResearchWorkbench {
        let store = self.store!
        return ResearchWorkbench(
            runner: AgentLoop(provider: provider),
            store: store,
            contextTools: TheoryTools.readOnlyTools(store: store),
            memoryTool: nil,
            writePolicy: .direct { proposal in
                try store.save(proposal.item)
                return "Wrote '\(proposal.item.id)'."
            },
            proveRunner: { _, _ in throw ResearchError(message: "no prove runner") },
            verifier: nil,
            savePlan: { try store.savePlan($0) },
            configuration: .init(maxConversationTokens: maxConversationTokens,
                                 programID: programID))
    }

    private func threeTaskPlan() -> PlanDocument {
        PlanDocument(
            id: "p1", goal: "Prove conj-x", status: .approved, runMode: .auto,
            tokenBudget: 5_000_000, approach: "Test approach",
            tasks: [
                PlanTask(index: 1, title: "Enumerate"),
                PlanTask(index: 2, title: "Draft"),
                PlanTask(index: 3, title: "Check", dependsOn: [2])
            ])
    }

    private func everyArchivedMessage() -> [String] {
        store.turnSummaries(programID: "prog-1")
            .compactMap { store.loadTurn(programID: "prog-1", fileName: $0.fileName) }
            .flatMap { $0.messages }
            .map(\.plainText)
    }

    /// **The regression guard for the whole transcript store.** Compaction drops the transcript
    /// out of the prompt, which is correct and is the point. It used to also destroy it: a
    /// branch long enough to compact three times had permanently lost three stretches of its
    /// own reasoning, and no view could recover them.
    func testCompactionArchivesTheConversationItDrops() async throws {
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let bulky = String(repeating: "x", count: 60_000)
        let opening: [LLMEvent] = [.textDelta("The δ=2 family is where it binds. " + bulky)]
        let provider = ScriptedProvider(scripts: [
            opening + toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider, maxConversationTokens: 10_000)
            .run(plan: plan, record: RunRecord(plan: plan))
        guard case .finished = record.state else {
            return XCTFail("expected finished, got \(record.state)")
        }

        let compacted = store.turnSummaries(programID: "prog-1").filter(\.endedByCompaction)
        XCTAssertFalse(compacted.isEmpty, "the dropped conversation was never written down")
        XCTAssertTrue(everyArchivedMessage().contains { $0.contains("δ=2 family") },
                      "task 1's reasoning is gone from the prompt AND from the disk")
    }

    /// Every leg boundary archives, and the watermark is what keeps that from writing the same
    /// message twice — a branch that pauses at each checkpoint archives adjacent slices.
    func testResumingACheckpointedBranchDoesNotArchiveTheSameMessageTwice() async throws {
        var plan = threeTaskPlan()
        plan.runMode = .checkpoint
        try store.savePlan(plan)
        let one: [LLMEvent] = [.textDelta("UNIQUE-MARKER-ONE")]
        let two: [LLMEvent] = [.textDelta("UNIQUE-MARKER-TWO")]
        let three: [LLMEvent] = [.textDelta("UNIQUE-MARKER-THREE")]
        let provider = ScriptedProvider(scripts: [
            one + toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            two + toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            three + toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])
        let bench = workbench(provider)

        // Three legs, each stopping at its checkpoint, then the reconciliation leg.
        var record = try await bench.run(plan: plan, record: RunRecord(plan: plan))
        for _ in 0..<3 {
            guard case .checkpoint = record.state else { break }
            let current = try XCTUnwrap(store.plan(id: "p1"))
            record = try await bench.run(plan: current, record: record)
        }

        let archived = everyArchivedMessage()
        for marker in ["UNIQUE-MARKER-ONE", "UNIQUE-MARKER-TWO", "UNIQUE-MARKER-THREE"] {
            XCTAssertEqual(archived.filter { $0.contains(marker) }.count, 1,
                           "\(marker) should be archived exactly once")
        }
    }

    func testAnArchivedLegNamesTheTasksItCoversAndWhatItCost() async throws {
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let metered: [LLMEvent] = [.usage(input: 90, output: 30)]
        let provider = ScriptedProvider(scripts: [
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        _ = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        let legs = store.turnSummaries(programID: "prog-1").filter { $0.role == .branchLeg }
        let leg = try XCTUnwrap(legs.last)
        XCTAssertEqual(leg.subjectID, "p1")
        XCTAssertTrue(leg.title.contains("tasks 1–3"), "got '\(leg.title)'")
        XCTAssertTrue(leg.outcome.contains("finished"), "got '\(leg.outcome)'")
        XCTAssertEqual(leg.tokensIn, 270)
        XCTAssertEqual(leg.tokensOut, 90)
    }

    /// A leg reports what *it* cost, not the branch's running total — otherwise every later leg
    /// re-reports every earlier leg's spend and the transcript list adds up to far more than the
    /// branch actually used.
    func testEachArchivedLegReportsOnlyItsOwnSpend() async throws {
        var plan = threeTaskPlan()
        plan.runMode = .checkpoint
        try store.savePlan(plan)
        let metered: [LLMEvent] = [.usage(input: 100, output: 10)]
        let provider = ScriptedProvider(scripts: [
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            metered + toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])
        let bench = workbench(provider)

        var record = try await bench.run(plan: plan, record: RunRecord(plan: plan))
        for _ in 0..<3 {
            guard case .checkpoint = record.state else { break }
            let current = try XCTUnwrap(store.plan(id: "p1"))
            record = try await bench.run(plan: current, record: record)
        }

        let legs = store.turnSummaries(programID: "prog-1").filter { $0.role == .branchLeg }
        XCTAssertGreaterThan(legs.count, 1, "a checkpointed branch archives one leg per pause")
        XCTAssertEqual(legs.reduce(0) { $0 + $1.tokensUsed }, record.tokensUsed,
                       "the legs sum to the branch's total, with nothing double-counted")
    }

    // MARK: - Library attribution

    /// A change has to be placeable on a branch and a moment. The whole-run diff it supplements
    /// compares a snapshot from before the run against the library afterwards, so it can say
    /// what changed but never who changed it or when.
    func testAWrittenItemIsAttributedToItsBranchAndTask() async throws {
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let write = """
        {"action":"create","markdown":"---\\nid: lem-new\\ntype: lemma\\nname: New lemma\\n\
        status: conjecture\\ndepends_on: []\\ntags: []\\n---\\n## Statement\\n$S$ holds.\\n"}
        """
        let provider = ScriptedProvider(scripts: [
            toolCall("write_theory_item", write),
            toolCall("finish_task", #"{"outcome":"completed","summary":"Wrote lem-new."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        let change = try XCTUnwrap(record.libraryChanges.first { $0.itemID == "lem-new" })
        XCTAssertEqual(change.kind, .created)
        XCTAssertEqual(change.branchPlanID, "p1")
        XCTAssertEqual(change.taskIndex, 1)
        XCTAssertTrue(change.isAttributed)
        XCTAssertNotNil(change.at)
    }

    /// The case a status diff loses entirely: a branch rewrites a proof and leaves the trust
    /// level where it was. Nothing moved, so a snapshot comparison reports nothing — but "which
    /// branch touched this item" is exactly the question being asked.
    func testARewriteThatMovesNoStatusIsStillRecorded() async throws {
        try store.save(TheoryItem(id: "lem-old", type: .lemma, name: "Old lemma",
                                  status: .proofDrafted,
                                  body: "## Statement\n$S$ holds.\n\n## Proof\nFirst attempt.\n"))
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let rewrite = """
        {"action":"update","markdown":"---\\nid: lem-old\\ntype: lemma\\nname: Old lemma\\n\
        status: proof-drafted\\ndepends_on: []\\ntags: []\\n---\\n## Statement\\n$S$ holds.\\n\\n\
        ## Proof\\nA better argument.\\n"}
        """
        let provider = ScriptedProvider(scripts: [
            toolCall("write_theory_item", rewrite),
            toolCall("finish_task", #"{"outcome":"completed","summary":"Rewrote the proof."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))

        let change = try XCTUnwrap(record.libraryChanges.first { $0.itemID == "lem-old" })
        XCTAssertEqual(change.kind, .revised)
        XCTAssertEqual(change.branchPlanID, "p1")
        XCTAssertEqual(change.taskIndex, 1)
    }

    func testATaskThatWritesNothingRecordsNoChanges() async throws {
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"Read only."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        let record = try await workbench(provider).run(plan: plan, record: RunRecord(plan: plan))
        XCTAssertTrue(record.libraryChanges.isEmpty)
    }

    /// A standalone plan has no manifest on disk, so archiving under its virtual id would leave
    /// a directory nothing ever reads.
    func testAnEmptyProgramIDDisablesArchivingEntirely() async throws {
        let plan = threeTaskPlan()
        try store.savePlan(plan)
        let provider = ScriptedProvider(scripts: [
            toolCall("finish_task", #"{"outcome":"completed","summary":"Enumerated."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Drafted."}"#),
            [.finished(.endTurn)],
            toolCall("finish_task", #"{"outcome":"completed","summary":"Checked."}"#),
            [.finished(.endTurn)],
            [.textDelta("Summary."), .finished(.endTurn)]
        ])

        _ = try await workbench(provider, programID: "")
            .run(plan: plan, record: RunRecord(plan: plan))

        XCTAssertEqual(store.turnSummaries(programID: ""), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.programsURL.path),
                       "no stray directory for a plan that belongs to no program")
    }
}
