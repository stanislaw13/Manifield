import XCTest
@testable import ManifieldAgents
@testable import ManifieldCore

final class ProgramUsageLedgerTests: XCTestCase {

    func testConcurrentCallsShareOneLiveCeilingWithoutRoleReserves() async throws {
        let budget = ProgramUsageBudget(totalBudget: 100)
        let pauses = PauseBox()
        let research = try await budget.beginCall { used, limit in
            pauses.append((used, limit))
        }
        let control = try await budget.beginCall { used, limit in
            pauses.append((used, limit))
        }

        await budget.report(research, actualTokens: 60)
        var snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.used, 60)
        XCTAssertFalse(snapshot.reached)

        await budget.report(control, actualTokens: 40)
        snapshot = await budget.snapshot()
        XCTAssertEqual(snapshot.used, 100)
        XCTAssertTrue(snapshot.reached)
        XCTAssertEqual(pauses.values.count, 2, "all concurrent work pauses at the one ceiling")

        _ = await budget.finishCall(research, actualTokens: 60)
        snapshot = await budget.finishCall(control, actualTokens: 40)
        XCTAssertEqual(snapshot.spent, 100)
        XCTAssertEqual(snapshot.active, 0)

        do {
            _ = try await budget.beginCall { _, _ in }
            XCTFail("no work should start until the user raises the program ceiling")
        } catch let error as ProgramUsageError {
            XCTAssertEqual(error, .budgetReached(used: 100, limit: 100))
        }
    }

    func testLargeCallIsNotStoppedByItsEstimate() async throws {
        let programID = "usage-estimate-\(UUID().uuidString)"
        let entries = UsageEntryBox()
        await ProgramUsageRegistry.shared.register(
            programID: programID, totalBudget: 1_000,
            append: { entries.append($0) })
        let runner = ProgramBudgetedRunner(
            base: UsageScriptRunner(usage: 201, waitsForCancellation: false),
            programID: programID, stage: "review", workClass: .control)
        // Under the former scheme this configuration reserved 104 tokens and was vulnerable
        // to a 2x estimate cutoff at 208. The estimate is diagnostic now, never a ceiling.
        let config = AgentConfig(systemPrompt: "", maxIterations: 5, maxTokens: 99)
        _ = try await runner.run(config: config, history: [.user("q")])

        let entry = try XCTUnwrap(entries.values.first)
        XCTAssertEqual(entry.estimatedInputTokens, 1)
        XCTAssertEqual(entry.actualTokens, 201)
        XCTAssertEqual(entry.termination, .completed)
        await ProgramUsageRegistry.shared.unregister(programID: programID)
    }

    func testCeilingInterruptsCallAsResumableBudgetPause() async throws {
        let programID = "usage-pause-\(UUID().uuidString)"
        let entries = UsageEntryBox()
        await ProgramUsageRegistry.shared.register(
            programID: programID, totalBudget: 200,
            append: { entries.append($0) })
        let runner = ProgramBudgetedRunner(
            base: UsageScriptRunner(usage: 201, waitsForCancellation: true),
            programID: programID, stage: "branch_research", workClass: .research)
        let config = AgentConfig(systemPrompt: "", maxIterations: 1, maxTokens: 99)
        do {
            _ = try await runner.run(config: config, history: [.user("q")])
            XCTFail("the shared ceiling should pause the call")
        } catch let error as ProgramUsageError {
            XCTAssertEqual(error, .budgetReached(used: 201, limit: 200))
        }
        let entry = try XCTUnwrap(entries.values.first)
        XCTAssertEqual(entry.actualTokens, 201)
        XCTAssertEqual(entry.termination, .budgetPaused)
        XCTAssertTrue(entry.error?.contains("Add tokens to continue") == true)
        await ProgramUsageRegistry.shared.unregister(programID: programID)
    }

    func testAssignmentCapPreservesGlobalBudgetForTheDirector() async throws {
        let id = "assignment-cap-\(UUID().uuidString)"
        let entries = UsageEntryBox()
        await ProgramUsageRegistry.shared.register(programID: id, totalBudget: 1_000,
                                                   append: { entries.append($0) })
        let assignment = ProgramUsageBudget(totalBudget: 100)
        let worker = ProgramBudgetedRunner(
            base: UsageScriptRunner(usage: 110, waitsForCancellation: true),
            programID: id, stage: "branch_research", workClass: .research,
            assignmentBudget: assignment)
        do {
            _ = try await worker.run(config: .init(systemPrompt: ""), history: [])
            XCTFail("assignment ceiling must interrupt the worker")
        } catch let error as AssignmentUsageError {
            XCTAssertEqual(error.used, 110)
            XCTAssertEqual(error.limit, 100)
        }
        let director = ProgramBudgetedRunner(
            base: UsageScriptRunner(usage: 20, waitsForCancellation: false),
            programID: id, stage: "director", workClass: .control)
        _ = try await director.run(config: .init(systemPrompt: ""), history: [])
        XCTAssertEqual(entries.values.map(\.termination), [.assignmentBudgetPaused, .completed])
        XCTAssertEqual(entries.values.reduce(0) { $0 + $1.actualTokens }, 130)
        await ProgramUsageRegistry.shared.unregister(programID: id)
    }

    func testSpentAssignmentCannotStartAnotherRoleOrResume() async throws {
        let id = "assignment-resume-\(UUID().uuidString)"
        let entries = UsageEntryBox()
        await ProgramUsageRegistry.shared.register(programID: id, totalBudget: 1_000,
                                                   append: { entries.append($0) })
        let resumed = ProgramUsageBudget(totalBudget: 100, initialSpent: 100)
        let prover = ProgramBudgetedRunner(
            base: UsageScriptRunner(usage: 50, waitsForCancellation: false),
            programID: id, stage: "branch_prove", workClass: .research,
            assignmentBudget: resumed)
        do {
            _ = try await prover.run(config: .init(systemPrompt: ""), history: [])
            XCTFail("persisted spend must not reset on resume")
        } catch let error as AssignmentUsageError {
            XCTAssertEqual(error.used, 100)
        }
        XCTAssertTrue(entries.values.isEmpty, "no provider call should start")
        await ProgramUsageRegistry.shared.unregister(programID: id)
    }

    func testLedgerPersistsProviderDiagnosticsAndCanBeAdopted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-ledger-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore.create(at: root, name: "Usage")
        let entry = ProgramUsageEntry(
            programID: "planning-x", stage: "pilot", subjectID: "p1",
            workClass: .research, provider: "Codex (test)",
            promptSHA256: String(repeating: "a", count: 64),
            estimatedInputTokens: 80,
            inputTokens: 100, outputTokens: 90,
            cachedInputTokens: 40, cacheWriteInputTokens: 12,
            reasoningOutputTokens: 20, toolCalls: 3,
            termination: .completed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_005))
        try store.saveUsageEntry(entry)
        XCTAssertEqual(store.loadUsageLedger(programID: "planning-x"), [entry])
        XCTAssertEqual(store.usageTokens(programID: "planning-x"), 190)

        try store.adoptUsageLedger(fromSession: "planning-x", toProgram: "program-x")
        XCTAssertTrue(store.loadUsageLedger(programID: "planning-x").isEmpty)
        XCTAssertEqual(store.loadUsageLedger(programID: "program-x"), [entry])

        let program = ResearchProgram(
            id: "program-x", goal: "g", programTokenBudget: 1_000,
            planningTokensUsed: 190,
            created: Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertEqual(
            store.usageTokens(program: program), 190,
            "adopted planning entries must not be counted again through planningTokensUsed")

        let later = ProgramUsageEntry(
            programID: "program-x", stage: "branch_research", workClass: .research,
            provider: "Codex (test)", promptSHA256: String(repeating: "b", count: 64),
            estimatedInputTokens: 10, inputTokens: 30, outputTokens: 20,
            termination: .completed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_020))
        try store.saveUsageEntry(later)
        XCTAssertEqual(store.usageTokens(program: program), 240)
    }

    func testLegacyPlanningTotalIsAddedOnlyWhenTheLedgerDoesNotContainIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-ledger-legacy-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore.create(at: root, name: "Legacy usage")
        let program = ResearchProgram(
            id: "legacy-program", goal: "g", programTokenBudget: 1_000,
            planningTokensUsed: 190,
            created: Date(timeIntervalSince1970: 1_800_000_010))
        let branch = ProgramUsageEntry(
            programID: program.id, stage: "branch_research", workClass: .research,
            provider: "Codex (test)", promptSHA256: String(repeating: "c", count: 64),
            estimatedInputTokens: 10, inputTokens: 30, outputTokens: 20,
            termination: .completed,
            startedAt: program.created)
        try store.saveUsageEntry(branch)

        let summary = store.usageSummary(program: program)
        XCTAssertEqual(summary.inputTokens, 30)
        XCTAssertEqual(summary.outputTokens, 20)
        XCTAssertEqual(summary.cachedInputTokens, 0)
        XCTAssertEqual(summary.earlierPlanningTokens, 190,
                       "adopted formalization usage must remain explicitly visible")
        XCTAssertEqual(summary.totalTokens, 240)
        XCTAssertEqual(store.usageTokens(program: program), summary.totalTokens)
    }
}

private final class PauseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pauses: [(Int, Int)] = []
    func append(_ pause: (Int, Int)) { lock.lock(); pauses.append(pause); lock.unlock() }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return pauses }
}

private struct UsageScriptRunner: AgentRunner {
    let usage: Int
    let waitsForCancellation: Bool
    var description: String { "usage-script" }

    func run(
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult {
        onActivity(.usage(input: usage, output: 0))
        onActivity(.usageDetails(AgentUsageDetails(
            cachedInputTokens: 7, cacheWriteInputTokens: 3,
            reasoningOutputTokens: 5, contextWindowTokens: 200_000)))
        if waitsForCancellation {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return AgentTurnResult(finalText: "done", transcript: history + [.user("done")])
    }
}

private final class UsageEntryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProgramUsageEntry] = []
    func append(_ entry: ProgramUsageEntry) { lock.lock(); entries.append(entry); lock.unlock() }
    var values: [ProgramUsageEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}
