import XCTest
import ManifieldCore
import ManifieldAgents
@testable import Manifield

/// Explicit opt-in integration evaluation. Originals are read only; each run has a new project.
final class PersistentResearchLiveTests: XCTestCase {
    @MainActor
    func testResumePendingReviewAfterBudgetIncrease() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MANIFIELD_LIVE_RESEARCH"] == "1", let path = env["MANIFIELD_LIVE_RESUME_PROJECT"] else {
            throw XCTSkip("Opt-in continuation evaluation")
        }
        let model = try XCTUnwrap(env["MANIFIELD_LIVE_MODEL"])
        let store = try ProjectStore(opening: URL(fileURLWithPath: path))
        let p = try XCTUnwrap(store.program(id: "eval-nononto"))
        XCTAssertNil(p.execution?.resolution)
        let originalAssignmentIDs = p.execution!.assignments.map(\.id)
        let state = AppState(); state.store = store; state.research.attach(appState: state)
        state.researchRunnerOverride = { _ in CodexRunner(model: model) }
        var limits = p.execution!.limits
        limits.programTokens = .bounded(450_000); limits.assignmentTokens = .unlimited; limits.elapsedSeconds = .unlimited
        state.research.setPersistentLimits(p, limits: limits)
        let updated = try XCTUnwrap(store.program(id: p.id))
        state.research.guidePersistentProgram(updated,
            text: "The user raised the program budget and removed the assignment ceiling. Inspect the existing challenge and finish its pending independent review with review_assignment_evidence. Preserve the existing counterexample and assignment; do not duplicate them. Then resolve the fixed original target using the independently accepted evidence.")
        let deadline = Date().addingTimeInterval(180)
        while state.research.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if state.research.isRunning { state.research.cancel() }
        let final = try XCTUnwrap(store.program(id: p.id))
        let ledger = store.loadUsageLedger(programID: p.id)
        let summary: [String: Any] = ["case": "nononto-resume", "model": model, "project": path,
            "resolution": final.execution?.resolution?.kind.rawValue ?? "unresolved",
            "explanation": final.execution?.resolution?.explanation ?? state.research.lastError ?? "",
            "assignments": final.execution?.assignments.count ?? 0, "ledgerEntries": ledger.count,
            "input": ledger.reduce(0) { $0 + $1.inputTokens }, "cachedInput": ledger.reduce(0) { $0 + $1.cachedInputTokens },
            "output": ledger.reduce(0) { $0 + $1.outputTokens }]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("manifield-live-nononto-resume-summary.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        print("Live resumed review metrics: \(url.path)")
        XCTAssertFalse(state.research.isRunning)
        XCTAssertEqual(final.execution?.resolution?.kind, .invalidTarget)
        XCTAssertEqual(final.execution?.assignments.map(\.id), originalAssignmentIDs)
    }

    @MainActor
    func testBoundedMathematicalRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MANIFIELD_LIVE_RESEARCH"] == "1" else { throw XCTSkip("Opt-in mathematical evaluation") }
        let model = try XCTUnwrap(env["MANIFIELD_LIVE_MODEL"])
        let variant = env["MANIFIELD_LIVE_CASE"] ?? "injective"
        let statement: String
        let expected: ProgramResolution.Kind
        switch variant {
        case "injective":
            statement = "Let E and F be real normed vector spaces and let f:E→F preserve distances: ‖f(x)−f(y)‖=‖x−y‖ for all x,y in E. Prove that f is injective."
            expected = .answered
        case "nononto":
            statement = "For this problem isometry means distance preserving only; surjectivity onto the stated codomain is NOT assumed. Let E,F be real normed vector spaces, U⊂E and V⊂F nonempty open connected subsets, and f:U→V an isometry in this explicit sense. Prove that f extends to a bijective isometry E→F. These conventions are fixed for this evaluation."
            expected = .invalidTarget
        default: throw XCTSkip("Unknown live case")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manifield-live-\(variant)-\(UUID().uuidString)")
        let store = try ProjectStore.create(at: directory, name: "Persistent director evaluation: " + variant)
        var fixtureHashes: [String: String] = [:]
        if let source = env["MANIFIELD_LIVE_FIXTURES"] {
            let theory = URL(fileURLWithPath: source).appendingPathComponent("theory")
            for file in try FileManager.default.contentsOfDirectory(at: theory, includingPropertiesForKeys: nil)
                where file.pathExtension == "md" && (file.lastPathComponent.hasPrefix("ex-z-af1t-") || file.lastPathComponent.hasPrefix("exercise-z-af1t-")) {
                let data = try Data(contentsOf: file)
                fixtureHashes[file.lastPathComponent] = ResearchTargetRevision.sha256(data)
                try data.write(to: store.theoryURL.appendingPathComponent(file.lastPathComponent))
            }
            XCTAssertEqual(fixtureHashes.count, 16, "Frozen exercise/theorem library should contain 16 items.")
            try store.reload()
        }
        let item = TheoryItem(id: "eval-goal", type: .exercise, name: "Evaluation goal", status: .conjecture,
            body: "## Statement\n" + statement)
        try store.save(item)
        let target = try store.makeResearchTargetRevision(requestText: statement, libraryItemID: item.id)
        let limits = ResearchLimits(toolCalls: .bounded(20), programTokens: .bounded(250_000),
            assignmentTokens: .bounded(150_000), elapsedSeconds: .bounded(240), planRevisions: .bounded(2), reviewRounds: .bounded(2))
        let program = ResearchProgram(id: "eval-" + variant, goal: statement, targetRevisions: [target],
            activeTargetRevisionID: target.id, maxConcurrentBranches: 1, programTokenBudget: 250_000,
            execution: .init(limits: limits))
        try store.saveProgram(program)
        let state = AppState(); state.store = store; state.research.attach(appState: state)
        state.researchRunnerOverride = { _ in CodexRunner(model: model) }
        state.research.startProgram(program)
        let deadline = Date().addingTimeInterval(270)
        while state.research.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if state.research.isRunning {
            state.research.cancel()
            let cleanupDeadline = Date().addingTimeInterval(20)
            while state.research.isRunning && Date() < cleanupDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        let final = try XCTUnwrap(store.program(id: program.id))
        let ledger = store.loadUsageLedger(programID: program.id)
        let summary: [String: Any] = ["case": variant, "model": model, "project": directory.path,
            "fixtures": fixtureHashes, "resolution": final.execution?.resolution?.kind.rawValue ?? "unresolved",
            "explanation": final.execution?.resolution?.explanation ?? state.research.lastError ?? final.execution?.events.last?.summary ?? "",
            "assignments": final.execution?.assignments.count ?? 0, "ledgerEntries": ledger.count,
            "input": ledger.reduce(0) { $0 + $1.inputTokens }, "cachedInput": ledger.reduce(0) { $0 + $1.cachedInputTokens },
            "output": ledger.reduce(0) { $0 + $1.outputTokens }]
        let summaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("manifield-live-\(variant)-summary.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: summaryURL, options: .atomic)
        print("Live research artifacts: \(directory.path); metrics: \(summaryURL.path)")
        XCTAssertFalse(state.research.isRunning)
        XCTAssertEqual(final.execution?.resolution?.kind, expected, "Inspect retained run artifacts for exact gaps or provider failures.")
    }
}
