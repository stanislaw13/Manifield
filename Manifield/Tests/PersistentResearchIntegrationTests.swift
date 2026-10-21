import XCTest
import AppKit
import SwiftUI
import ManifieldCore
import ManifieldAgents
@testable import Manifield

final class PersistentResearchIntegrationTests: XCTestCase {
    @MainActor
    func testPersistentLimitsPaneRendersContentInFlexibleTabArea() async throws {
        let limits = ResearchLimits(toolCalls: .unlimited, programTokens: .bounded(500_000),
            assignmentTokens: .unlimited, elapsedSeconds: .unlimited,
            planRevisions: .unlimited, reviewRounds: .bounded(5))
        let view = PersistentResearchLimitsPane(
            program: ResearchProgram(id: "limits-pane", goal: "g", execution: .init(limits: limits)),
            limits: .constant(limits), savedLimits: limits,
            live: true, concurrentAssignments: 1, onSave: {})
            .frame(width: 760, height: 520, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var nonWhitePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
                    nonWhitePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(nonWhitePixels, 1_000,
            "the limits pane must visibly render its labels and controls rather than collapse to blank content")
        window.contentView = nil
    }

    @MainActor
    func testControllerCompletesChallengeThroughBothFreshReviewsWithoutSolution() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Challenge lifecycle")
        let p = ResearchProgram(id: "challenge-flow", goal: "Prove every real number is positive.", execution: .init(limits: .unlimited))
        try store.saveProgram(p)
        let provider = IntegrationChallengeProvider(store: store, programID: p.id)
        let state = AppState(); state.store = store; state.research.attach(appState: state)
        state.researchRunnerOverride = { _ in AgentLoop(provider: provider) }
        state.research.startProgram(p)
        let deadline = Date().addingTimeInterval(15)
        while state.research.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if state.research.isRunning { state.research.cancel(); XCTFail("Controller did not terminate.") }
        let final = try XCTUnwrap(store.program(id: p.id))
        XCTAssertNil(state.research.lastError)
        XCTAssertEqual(final.execution?.resolution?.kind, .invalidTarget)
        XCTAssertEqual(final.challenges.count, 1)
        XCTAssertEqual(final.challenges.first?.scopeRuling?.targetDisposition, .fullInvalidity)
        XCTAssertTrue(final.solutions.isEmpty)
        XCTAssertTrue(store.loadPlans().plans.isEmpty)
        let reportPath = try XCTUnwrap(final.reportPath)
        let report = try String(contentsOf: store.rootURL.appendingPathComponent(reportPath), encoding: .utf8)
        XCTAssertTrue(report.contains("both independent reviews accepted"))
        let reviews = provider.requests.filter { $0.tools.contains { $0.name == "report_problem_challenge_review" } }
        XCTAssertEqual(reviews.count, 2)
        XCTAssertTrue(reviews.allSatisfy { $0.messages.count == 1 && !$0.messages[0].plainText.contains("dispatch_work") })
        XCTAssertTrue(store.loadUsageLedger(programID: p.id).allSatisfy { $0.diagnostics != nil })
    }
    @MainActor
    func testAppFactoryBindsDynamicAssignmentAndBlocksResumeAfterOvershoot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Accounting factory test")
        let state = AppState(); state.store = store
        let calls = IntegrationUsageRunner()
        state.researchRunnerOverride = { _ in calls }
        var program = ResearchProgram(id: "dynamic", goal: "test", execution: .init(limits: .unlimited))
        let assignment = ResearchAssignment(id: "worker", operationID: "dispatch-after-initial-snapshot",
            programID: program.id, targetRevisionID: program.activeTargetRevisionID, mode: .direct,
            objective: "Inspect a lemma", tokenLimit: .bounded(8_000))
        program.execution!.assignments.append(assignment)
        try store.saveProgram(program)
        await ProgramUsageRegistry.shared.register(programID: program.id, totalBudget: 1_000_000,
            limits: .unlimited, append: { try? store.saveUsageEntry($0) })
        let scheduler = try PersistentResearchScheduler(program: program, save: { try store.saveProgram($0) }) { _, _, _ in .init(summary: "") }
        do {
            _ = try await state.executePersistentAssignment(assignment, program: program, scheduler: scheduler, onEvent: { _ in })
            XCTFail("must pause at assignment ceiling")
        } catch is AssignmentUsageError {}
        let reviewer = try state.persistentRunner(program: program, assignment: assignment, task: .reviewer, stage: "resumed_review")
        do {
            _ = try await reviewer.run(config: .init(systemPrompt: "review"), history: [.user("inspect")])
            XCTFail("resume must retain the same assignment spend")
        } catch is AssignmentUsageError {}
        XCTAssertEqual(calls.count, 1)
        let ledger = store.loadUsageLedger(programID: program.id)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger[0].diagnostics?.assignmentLimit, 8_000)
        XCTAssertEqual(ledger[0].termination, .assignmentBudgetPaused)
        XCTAssertTrue(store.loadPlans().plans.isEmpty)
        await ProgramUsageRegistry.shared.unregister(programID: program.id)
    }

    @MainActor
    func testPlannedAssignmentRemainsInItsProgramAndUsesExplicitReview() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Ownership factory test")
        let state = AppState(); state.store = store
        let runner = IntegrationPlanRunner()
        state.researchRunnerOverride = { _ in runner }
        var p = ResearchProgram(id: "owned", goal: "test", execution: .init(limits: .unlimited))
        let a = ResearchAssignment(id: "planned", operationID: "dispatch", programID: p.id,
            targetRevisionID: p.activeTargetRevisionID, mode: .planned, objective: "Inspect possible approaches")
        p.execution!.assignments.append(a)
        try store.saveProgram(p)
        await ProgramUsageRegistry.shared.register(programID: p.id, totalBudget: .max, limits: .unlimited,
            append: { try? store.saveUsageEntry($0) })
        let scheduler = try PersistentResearchScheduler(program: p, save: { try store.saveProgram($0) }) { _, _, _ in .init(summary: "") }
        let report = try await state.executePersistentAssignment(a, program: p, scheduler: scheduler, onEvent: { _ in })
        state.reloadPlans()
        XCTAssertEqual(store.plan(id: a.planID!)?.program, p.id)
        XCTAssertEqual(state.allPrograms.count, 1, "a worker plan must not become a standalone program")
        XCTAssertTrue(runner.explicitEffects)
        XCTAssertEqual(report.stopReason, .completed)
        await ProgramUsageRegistry.shared.unregister(programID: p.id)
    }
}

private final class IntegrationChallengeProvider: LLMProvider, @unchecked Sendable {
    var description: String { "scripted challenge lifecycle" }
    private let store: ProjectStore
    private let programID: String
    private let lock = NSLock()
    private var saved: [LLMRequest] = []
    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return saved }
    init(store: ProjectStore, programID: String) { self.store = store; self.programID = programID }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock(); saved.append(request); let count = saved.count; lock.unlock()
        let names = Set(request.tools.map(\.name)), p = store.program(id: programID)!
        let name: String, input: String
        if names.contains("report_problem_challenge_review") {
            name = "report_problem_challenge_review"
            input = #"{"accepted":true,"note":"Zero is a real number and is not positive. This refutes the entire stated universal claim.","target_disposition":"fullInvalidity"}"#
        } else if names.contains("report_assignment") {
            name = "submit_problem_challenge"
            input = #"{"description":"Zero is real but not positive, refuting the requested universal assertion."}"#
        } else if p.execution!.assignments.isEmpty {
            name = "dispatch_work"; input = #"{"mode":"direct","objective":"Check the universal assertion with zero and file a challenge if it is false."}"#
        } else if let challenge = p.challenges.first(where: { $0.status == .accepted }) {
            name = "resolve_program"
            input = "{\"kind\":\"invalidTarget\",\"evidence_ids\":[\"\(challenge.id)\"],\"explanation\":\"Zero refutes the entire claim; both independent reviews accepted.\"}"
        } else {
            name = "wait_for_work"; input = "{\"after_sequence\":\(p.execution!.events.last?.sequence ?? 0)}"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.toolUseFinished(id: "call-\(count)", name: name, inputJSON: input))
            continuation.yield(.usage(input: 100, output: 20))
            continuation.yield(.finished(.toolUse)); continuation.finish()
        }
    }
}

private final class IntegrationUsageRunner: AgentRunner, @unchecked Sendable {
    var description: String { "controlled app factory usage" }
    private let lock = NSLock(); private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func increment() { lock.lock(); calls += 1; lock.unlock() }
    func run(config: AgentConfig, history: [LLMMessage], onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws -> AgentTurnResult {
        increment(); onActivity(.usage(input: 60_327, output: 1_326))
        return .init(finalText: "Overshoot", transcript: history)
    }
}

private final class IntegrationPlanRunner: AgentRunner, @unchecked Sendable {
    var description: String { "controlled plan" }
    private let lock = NSLock(); private var effects = true
    var explicitEffects: Bool { lock.lock(); defer { lock.unlock() }; return effects }
    private func observe(_ config: AgentConfig) { lock.lock(); effects = effects && config.stopOnToolEffect; lock.unlock() }
    func run(config: AgentConfig, history: [LLMMessage], onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws -> AgentTurnResult {
        observe(config)
        if let tool = config.tools.first(where: { $0.spec.name == "save_assignment_plan" }) {
            _ = try await tool.execute(inputJSON: #"{"approach":"Inspect and report the exact gap","tasks":[{"title":"Inspect the proposed approach and record what remains","kind":"research","depends_on":[],"review":false}]}"#)
        } else if let tool = config.tools.first(where: { $0.spec.name == "finish_task" }) {
            _ = try await tool.execute(inputJSON: #"{"outcome":"completed","summary":"Inspection complete; no mathematical result established."}"#)
        }
        return .init(finalText: "No result established.", transcript: history, stop: .toolCompleted)
    }
}
