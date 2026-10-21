import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class ProgramAccountingBindingTests: XCTestCase {
    func testDynamicAssignmentStopsAfterFirstOvershootAndCannotResumeWithFreshMeter() async throws {
        var program = ResearchProgram(id: UUID().uuidString, goal: "g", execution: .init())
        let original = program
        let assignment = ResearchAssignment(operationID: "dispatch-1", programID: program.id,
            targetRevisionID: program.activeTargetRevisionID, mode: .direct, objective: "Inspect a lemma",
            tokenLimit: .bounded(8_000))
        program.execution!.assignments.append(assignment)
        XCTAssertThrowsError(try ProgramAccountingBinding(program: original, subjectID: assignment.id, ledger: []))
        let binding = try ProgramAccountingBinding(program: program, subjectID: assignment.id, ledger: [])
        let entries = AccountingEntries()
        await ProgramUsageRegistry.shared.register(programID: program.id, totalBudget: 1_000_000,
            append: { entries.append($0) })
        let provider = OvershootingToolProvider()
        let runner = ProgramBudgetedRunner(base: AgentLoop(provider: provider), programID: program.id, stage: "direct",
            subjectID: assignment.id, workClass: .research,
            assignmentBudget: binding.assignmentBudget, requiresAccounting: true)
        let tool = FunctionAgentTool(name: "inspect", description: "Inspect the selected lemma.", schema: "{}") { _, _ in
            "inspection saved"
        }
        var config = AgentConfig(
            systemPrompt: SystemPrompt(String(repeating: "x", count: 32_004)), tools: [tool])
        config.sessionKey = "assignment-session"
        config.sessionEpoch = 3
        for _ in 0..<2 {
            do {
                _ = try await runner.run(config: config, history: [.user("inspect")])
                XCTFail("must stop on the assignment ceiling")
            } catch let error as AssignmentUsageError { XCTAssertEqual(error.limit, 8_000) }
        }
        XCTAssertEqual(provider.requests, 1, "the second HTTP-style provider request must never start")
        XCTAssertEqual(entries.values.count, 1)
        let entry = try XCTUnwrap(entries.values.first)
        XCTAssertEqual(entry.actualTokens, 9_251)
        XCTAssertEqual(entry.termination, .assignmentBudgetPaused)
        XCTAssertEqual(entry.diagnostics?.assignmentLimit, 8_000)
        XCTAssertEqual(entry.diagnostics?.assignmentSpentBefore, 0)
        XCTAssertEqual(entry.diagnostics?.observedAssignmentOvershootTokens, 1_251)
        XCTAssertGreaterThan(entry.diagnostics?.estimatedInputExceedsAssignmentRemainingBy ?? 0, 0)
        XCTAssertEqual(entry.diagnostics?.applicationSessionKey, "assignment-session")
        XCTAssertEqual(entry.diagnostics?.applicationSessionEpoch, 3)
        XCTAssertEqual(entry.diagnostics?.configurationSHA256?.count, 64)
        XCTAssertFalse(entry.diagnostics?.runtimeIdentity?.isEmpty ?? true)
        XCTAssertFalse(entry.diagnostics?.buildIdentity?.isEmpty ?? true)
        XCTAssertNil(entry.diagnostics?.observedProgramOvershootTokens)
        let resumed = try ProgramAccountingBinding(program: program, subjectID: assignment.id, ledger: entries.values)
        let review = ProgramBudgetedRunner(base: AgentLoop(provider: provider), programID: program.id, stage: "review",
            subjectID: assignment.id, workClass: .control, assignmentBudget: resumed.assignmentBudget,
            requiresAccounting: true)
        do {
            _ = try await review.run(config: .init(systemPrompt: ""), history: [.user("review")])
            XCTFail("resume must include the persisted spend")
        } catch is AssignmentUsageError {}
        XCTAssertEqual(provider.requests, 1)
        await ProgramUsageRegistry.shared.unregister(programID: program.id)
    }

    func testUnlimitedLimitsRemoveConfigurationStageDefaultToolCap() async throws {
        let programID = UUID().uuidString
        let entries = AccountingEntries()
        await ProgramUsageRegistry.shared.register(
            programID: programID, totalBudget: Int.max, limits: .unlimited,
            append: { entries.append($0) })

        let provider = RepeatingToolProvider(toolRounds: 13)
        let tool = FunctionAgentTool(name: "configure", description: "Advance configuration.", schema: "{}") { _, _ in
            "configured"
        }
        let runner = ProgramBudgetedRunner(
            base: AgentLoop(provider: provider), programID: programID,
            stage: "goal_configuration", workClass: .research, requiresAccounting: true)

        let result = try await runner.run(
            config: .init(systemPrompt: "configure", tools: [tool]), history: [.user("begin")])

        XCTAssertEqual(result.finalText, "complete")
        XCTAssertEqual(provider.requests, 14, "the inherited unlimited setting must pass the default 12-call cap")
        XCTAssertEqual(entries.values.count, 1)
        XCTAssertEqual(entries.values.first?.toolCalls, 13)
        XCTAssertEqual(entries.values.first?.termination, .completed)
        await ProgramUsageRegistry.shared.unregister(programID: programID)
    }

    func testMissingRegistryCannotSilentlyDisableRequiredAccounting() async throws {
        let provider = OvershootingToolProvider()
        let runner = ProgramBudgetedRunner(base: AgentLoop(provider: provider), programID: UUID().uuidString,
            stage: "direct", workClass: .research, requiresAccounting: true)
        do {
            _ = try await runner.run(config: .init(systemPrompt: ""), history: [.user("q")])
            XCTFail("missing registry is a configuration error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No provider call was started")) }
        XCTAssertEqual(provider.requests, 0)
    }
}

private final class AccountingEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProgramUsageEntry] = []
    func append(_ entry: ProgramUsageEntry) { lock.lock(); entries.append(entry); lock.unlock() }
    var values: [ProgramUsageEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}
private final class OvershootingToolProvider: LLMProvider, @unchecked Sendable {
    var description: String { "controlled accounting provider" }
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock(); count += 1; let requestNumber = count; lock.unlock()
        let events: [LLMEvent] = requestNumber == 1 ? [
            .usage(input: 9_001, output: 250),
            .toolUseFinished(id: "inspect-1", name: "inspect", inputJSON: "{}"),
            .finished(.toolUse)
        ] : [
            .textDelta("this request must not start"), .finished(.endTurn)
        ]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class RepeatingToolProvider: LLMProvider, @unchecked Sendable {
    var description: String { "controlled repeated-tool provider" }
    private let lock = NSLock()
    private var count = 0
    private let toolRounds: Int
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(toolRounds: Int) { self.toolRounds = toolRounds }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock(); count += 1; let requestNumber = count; lock.unlock()
        let events: [LLMEvent]
        if requestNumber <= toolRounds {
            events = [
                .usage(input: 1, output: 1),
                .toolUseFinished(id: "configure-\(requestNumber)", name: "configure", inputJSON: "{}"),
                .finished(.toolUse)
            ]
        } else {
            events = [.usage(input: 1, output: 1), .textDelta("complete"), .finished(.endTurn)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
