import XCTest
@testable import ManifieldAgents

final class CodexPersistentSessionTests: XCTestCase {
    func testReusesExactHistoryAndReplacesThreadAfterCompactionOrToolChange() async throws {
        let server = ReusableTestServer(), runner = CodexRunner(model: "test")
        var config = AgentConfig(systemPrompt: "director")
        config.sessionKey = UUID().uuidString
        let first = try await runner.run(server: server, config: config, history: [.user("first")], onActivity: { _ in })
        let second = try await runner.run(server: server, config: config,
            history: first.transcript + [.user("next")], onActivity: { _ in })
        var stats = await server.stats()
        XCTAssertEqual(stats.starts, 1)
        XCTAssertEqual(stats.continues, 1)
        XCTAssertEqual(stats.injectedMessages, 0, "native continuation must not replay the retained prefix")
        config.sessionEpoch += 1
        let compacted = try await runner.run(server: server, config: config,
            history: [.user("strategic handoff only")], onActivity: { _ in })
        stats = await server.stats()
        XCTAssertEqual(stats.starts, 2)
        XCTAssertEqual(stats.closed, 1)
        config.tools = [FunctionAgentTool(name: "new_tool", description: "", schema: "{}") { _, _ in "ok" }]
        _ = try await runner.run(server: server, config: config,
            history: compacted.transcript + [.user("use changed tools")], onActivity: { _ in })
        stats = await server.stats()
        XCTAssertEqual(stats.starts, 3)
        XCTAssertTrue(second.transcript.starts(with: first.transcript))
        await CodexSessionCache.shared.remove(config.sessionKey!)
    }

    func testFailedNativeTurnCannotBeReusedAsSuccessfulHistory() async throws {
        let server = ReusableTestServer(), runner = CodexRunner(model: "test")
        var config = AgentConfig(systemPrompt: "director"); config.sessionKey = UUID().uuidString
        let first = try await runner.run(server: server, config: config, history: [.user("first")], onActivity: { _ in })
        await server.failNext()
        do {
            _ = try await runner.run(server: server, config: config, history: first.transcript + [.user("fails")], onActivity: { _ in })
            XCTFail("expected transport failure")
        } catch {}
        _ = try await runner.run(server: server, config: config, history: first.transcript + [.user("recover")], onActivity: { _ in })
        let stats = await server.stats()
        XCTAssertEqual(stats.starts, 2)
        XCTAssertEqual(stats.continues, 1)
        await CodexSessionCache.shared.remove(config.sessionKey!)
    }

    func testTerminalToolDrainsLateUsageAndDoesNotExecuteQueuedMutation() async throws {
        let server = ReusableTestServer()
        let events: [CodexEvent] = [
            .toolCallRequested(requestID: .number(1), callID: "finish", tool: "finish", argumentsJSON: "{}"),
            .usage(input: 1200, output: 30),
            .toolCallRequested(requestID: .number(2), callID: "late", tool: "mutate", argumentsJSON: "{}"),
            .turnCompleted]
        let stream = AsyncThrowingStream<CodexEvent, Error> { continuation in
            events.forEach { continuation.yield($0) }; continuation.finish()
        }
        let usage = NativeUsageCapture()
        var config = AgentConfig(systemPrompt: "", tools: [
            FunctionAgentTool(name: "finish", description: "", schema: "{}", effect: .finish) { _, _ in "Saved" },
            FunctionAgentTool(name: "mutate", description: "", schema: "{}") { _, _ in XCTFail("late mutation"); return "" }
        ], maxIterations: 1)
        config.stopOnToolEffect = true
        let result = try await CodexRunner.consume(stream, server: server, threadID: "t", turnID: "turn",
            config: config, history: [.user("work")], onActivity: { usage.record($0) })
        XCTAssertEqual(result.stop, .toolCompleted)
        XCTAssertEqual(usage.total, 1230)
    }
}

private actor ReusableTestServer: CodexServing {
    struct Stats { var starts = 0; var continues = 0; var closed = 0; var injectedMessages = 0 }
    private var counters = Stats()
    private var continuation: AsyncThrowingStream<CodexEvent, Error>.Continuation?
    private var shouldFail = false
    func stats() -> Stats { counters }
    func failNext() { shouldFail = true }
    private func stream(_ id: String) -> CodexServer.StartedThread {
        let (stream, continuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        self.continuation = continuation
        return .init(threadID: id, events: stream)
    }
    func startThread(model: String, developerInstructions: String, tools: [ToolSpec]) async throws -> CodexServer.StartedThread {
        counters.starts += 1; return stream("thread-\(counters.starts)")
    }
    func retainThread(_ threadID: String) async {}
    func continueThread(_ threadID: String) async throws -> CodexServer.StartedThread {
        counters.continues += 1; return stream(threadID)
    }
    func injectItems(threadID: String, items: [[String: Any]]) async throws { counters.injectedMessages += items.count }
    func startTurn(threadID: String, input: [[String: Any]], effort: String) async throws -> String {
        if shouldFail { shouldFail = false; continuation?.finish(throwing: AgentError.api("simulated disconnect")) }
        else {
            continuation?.yield(.agentMessageCompleted(text: "result", isFinal: true))
            continuation?.yield(.turnCompleted); continuation?.finish()
        }
        return "turn"
    }
    func interruptTurn(threadID: String, turnID: String) async {}
    func respond(requestID: CodexProtocol.RequestID, success: Bool, text: String) async {}
    func closeThread(_ threadID: String) async { counters.closed += 1 }
}

private final class NativeUsageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var total: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ activity: AgentActivity) {
        if case .usage(let input, let output) = activity { lock.lock(); value += input + output; lock.unlock() }
    }
}
