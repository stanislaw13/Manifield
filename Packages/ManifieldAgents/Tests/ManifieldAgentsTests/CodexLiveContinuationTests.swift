import XCTest
import ManifieldCore
@testable import ManifieldAgents

/// Explicit opt-in: uses Manifield's existing private Codex sign-in, never API keys.
/// Ordinary test runs skip this test and make no network requests.
final class CodexLiveContinuationTests: XCTestCase {
    func testNativeContinuationAndCompactionWithExistingSignIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MANIFIELD_LIVE_CONTINUATION"] == "1" else { throw XCTSkip("Opt-in native provider check") }
        let model = try XCTUnwrap(env["MANIFIELD_LIVE_MODEL"])
        let entries = LiveContinuationEntries()
        let programID = "native-live-" + UUID().uuidString
        await ProgramUsageRegistry.shared.register(programID: programID, totalBudget: 50_000,
            limits: .init(toolCalls: .bounded(3), programTokens: .bounded(50_000)), append: { entries.append($0) })
        let runner = ProgramBudgetedRunner(base: CodexRunner(model: model), programID: programID,
            stage: "native_continuation_eval", workClass: .control, requiresAccounting: true)
        let answers = LiveContinuationAnswers()
        let tool = FunctionAgentTool(name: "record_answer", description: "Record the requested text and finish.",
            schema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#, effect: .finish) { _, json in
                let value = try requiredResearchString(jsonObject(json), "text")
                await answers.append(value); return "Saved."
            }
        let key = programID
        var config = AgentConfig(systemPrompt: "This is a protocol check. Follow the user's instruction with record_answer exactly once. Do no other work.",
            tools: [tool], maxIterations: 3, thinking: .off)
        config.stopOnToolEffect = true; config.sessionKey = key
        do {
            let first = try await runner.run(config: config,
                history: [.user("Remember the token cobalt-seventeen for the next turn. Record exactly ready.")])
            let firstEntry = try await CodexSessionCache.shared.acquire(key)
            let firstID = try XCTUnwrap(firstEntry?.threadID)
            await CodexSessionCache.shared.release(key, entry: firstEntry)
            let second = try await runner.run(config: config,
                history: first.transcript + [.user("Record exactly the token I asked you to remember.")])
            let secondEntry = try await CodexSessionCache.shared.acquire(key)
            let secondID = try XCTUnwrap(secondEntry?.threadID)
            await CodexSessionCache.shared.release(key, entry: secondEntry)
            XCTAssertEqual(firstID, secondID, "Retained history should reuse the native thread.")
            XCTAssertTrue(second.transcript.starts(with: first.transcript))
            config.sessionEpoch += 1
            _ = try await runner.run(config: config, history: [.user("This is the full retained checkpoint. Record exactly fresh-context.")])
            let thirdEntry = try await CodexSessionCache.shared.acquire(key)
            let thirdID = try XCTUnwrap(thirdEntry?.threadID)
            await CodexSessionCache.shared.release(key, entry: thirdEntry)
            XCTAssertNotEqual(secondID, thirdID, "Compaction must replace the native context.")
            let recorded = await answers.values
            XCTAssertEqual(recorded, ["ready", "cobalt-seventeen", "fresh-context"])
            let ledger = entries.values
            XCTAssertEqual(ledger.count, 3)
            XCTAssertTrue(ledger.allSatisfy { $0.actualTokens > 0 && $0.termination == .toolCompleted })
            if let path = env["MANIFIELD_LIVE_LEDGER"] {
                try JSONEncoder().encode(ledger).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            print("Native continuation: same thread on turn 2, replacement on epoch change. Input \(ledger.reduce(0) { $0 + $1.inputTokens }), cached \(ledger.reduce(0) { $0 + $1.cachedInputTokens }), output \(ledger.reduce(0) { $0 + $1.outputTokens }).")
        } catch {
            await CodexSessionCache.shared.remove(key)
            await ProgramUsageRegistry.shared.unregister(programID: programID)
            throw error
        }
        await CodexSessionCache.shared.remove(key)
        await ProgramUsageRegistry.shared.unregister(programID: programID)
    }
}

private actor LiveContinuationAnswers {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private final class LiveContinuationEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProgramUsageEntry] = []
    func append(_ entry: ProgramUsageEntry) { lock.lock(); entries.append(entry); lock.unlock() }
    var values: [ProgramUsageEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}
