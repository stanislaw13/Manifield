import XCTest
@testable import ManifieldAgents

private struct EchoTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "echo", description: "echoes",
                 inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#)
    }
    func execute(inputJSON: String) async throws -> String {
        "echo:" + ((jsonObject(inputJSON)["query"] as? String) ?? "?")
    }
}

/// Exercises `CodexRunner.consume` — the transcript-building core — directly with a synthetic
/// `CodexEvent` stream, the same way `ResponsesAPIParserTests` drains a synthetic line sequence.
/// No live `codex` process: `respond(...)` is a documented safe no-op on a `CodexServer` that was
/// never started (see `CodexServerTeardownTests`), which is all `consume` needs from it.
final class CodexRunnerConsumeTests: XCTestCase {

    private struct TimedOut: Error {}

    private func withTimeout<T: Sendable>(
        seconds: Double, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func idleServer() -> CodexServer {
        CodexServer(binaryPath: "/bin/sh", codexHome: "/tmp/codex-runner-tests-home",
                   cwd: "/tmp/codex-runner-tests-cwd")
    }

    private func stream(_ events: [CodexEvent]) -> AsyncThrowingStream<CodexEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        for event in events { continuation.yield(event) }
        continuation.finish()
        return stream
    }

    /// Regression for the original timer bug: the producer deliberately remains open after
    /// yielding `.turnCompleted`. `consume` must treat the event itself as terminal instead of
    /// waiting for an EOF that app-server does not send between multiplexed threads.
    func testTurnCompletedReturnsWithoutProducerFinishingTheStream() async throws {
        let (events, continuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        continuation.yield(.agentMessageCompleted(text: "Done.", isFinal: true))
        continuation.yield(.turnCompleted)
        let server = idleServer()
        let result = try await withTimeout(seconds: 1) {
            try await CodexRunner.consume(
                events, server: server,
                config: AgentConfig(systemPrompt: "sys", tools: []),
                history: [.user("q")], onActivity: { _ in })
        }
        XCTAssertEqual(result.finalText, "Done.")
        // Intentionally no continuation.finish(). Keeping it alive until here is the assertion.
        _ = continuation
    }

    /// Mirrors `AgentLoopTests.testToolRoundTrip`'s shape, adapted to how Codex actually reports
    /// itself: it never exposes "round" boundaries the way a request/response provider's
    /// separate turns do. We split at each tool boundary so a final answer can never be stored
    /// before the result that produced it. `.toolResult` lands at
    /// `transcript[2].blocks[0]`, keyed to the same tool-use id.
    func testToolRoundTripProducesAMatchingToolResultAtIndexTwo() async throws {
        let events: [CodexEvent] = [
            .agentMessageCompleted(text: "Let me check.", isFinal: false),
            .toolCallRequested(requestID: .number(1), callID: "t1", tool: "echo", argumentsJSON: #"{"query":"hi"}"#),
            .agentMessageCompleted(text: "The answer is 42.", isFinal: true),
            .turnCompleted
        ]
        let result = try await CodexRunner.consume(
            stream(events), server: idleServer(),
            config: AgentConfig(systemPrompt: "sys", tools: [EchoTool()]),
            history: [.user("question")],
            onActivity: { _ in })

        XCTAssertEqual(result.finalText, "The answer is 42.")
        XCTAssertEqual(result.transcript.count, 4, "user, assistant request, user result, assistant final")
        XCTAssertEqual(result.transcript.prefix(1), [.user("question")],
                       "the seed history must survive as an untouched prefix")

        guard case .toolResult(let id, let content, let isError) = result.transcript[2].blocks[0] else {
            return XCTFail("expected a tool result block at transcript[2].blocks[0]")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(content, "echo:hi")
        XCTAssertFalse(isError)

        XCTAssertEqual(result.transcript[3].blocks, [.text("The answer is 42.")],
                       "the final answer must follow the tool result chronologically")

        // The tool call itself is recorded in the assistant message that requested it.
        guard case .toolUse(let useID, let name, let inputJSON) = result.transcript[1].blocks[1] else {
            return XCTFail("expected the tool_use block to follow the commentary text")
        }
        XCTAssertEqual(useID, "t1")
        XCTAssertEqual(name, "echo")
        XCTAssertEqual(inputJSON, #"{"query":"hi"}"#)
    }

    /// `phase` is unreliable across models — when nothing is ever marked `final_answer`, the
    /// last agentMessage seen still has to serve as the turn's answer rather than leaving
    /// `finalText` empty.
    func testFinalTextFallsBackToLastMessageWhenNothingIsMarkedFinal() async throws {
        let events: [CodexEvent] = [
            .agentMessageCompleted(text: "First.", isFinal: false),
            .agentMessageCompleted(text: "Then this.", isFinal: false),
            .turnCompleted
        ]
        let result = try await CodexRunner.consume(
            stream(events), server: idleServer(),
            config: AgentConfig(systemPrompt: "sys", tools: []),
            history: [.user("q")], onActivity: { _ in })
        XCTAssertEqual(result.finalText, "Then this.")
    }

    /// A reasoning item becomes a `.thinking` block with no signature — verified elsewhere
    /// (`AnthropicProvider`/`OpenAICompatProvider`/`OpenAIResponsesProvider`) to replay as a
    /// harmless no-op on every other provider, which is what makes a mid-conversation provider
    /// switch safe.
    func testReasoningBecomesAThinkingBlockWithNoSignature() async throws {
        let events: [CodexEvent] = [
            .reasoningCompleted(text: "Considering the cases."),
            .agentMessageCompleted(text: "Done.", isFinal: true),
            .turnCompleted
        ]
        let result = try await CodexRunner.consume(
            stream(events), server: idleServer(),
            config: AgentConfig(systemPrompt: "sys", tools: []),
            history: [.user("q")], onActivity: { _ in })
        XCTAssertEqual(result.transcript[1].blocks[0], .thinking(text: "Considering the cases.", signature: nil))
    }

    /// App-server does not reveal provider round boundaries, so `maxIterations` is the maximum
    /// number of dynamic tool requests. The runner interrupts immediately after returning the
    /// final allowed result instead of feeding an unlimited deny/retry loop.
    func testToolCallCapInterruptsAfterFinalAllowedResult() async throws {
        var executed = 0
        struct CountingTool: AgentTool {
            let onExecute: @Sendable () -> Void
            var spec: ToolSpec {
                ToolSpec(name: "count", description: "d", inputSchemaJSON: #"{"type":"object"}"#)
            }
            func execute(inputJSON: String) async throws -> String {
                onExecute()
                return "ok"
            }
        }
        let events: [CodexEvent] = (1...5).map {
            .toolCallRequested(requestID: .number($0), callID: "c\($0)", tool: "count", argumentsJSON: "{}")
        } + [.agentMessageCompleted(text: "Done.", isFinal: true), .turnCompleted]

        var activities: [AgentActivity] = []
        let result = try await CodexRunner.consume(
            stream(events), server: idleServer(),
            // maxIterations: 1 → exactly one dynamic tool request is allowed.
            config: AgentConfig(systemPrompt: "sys", tools: [CountingTool(onExecute: { executed += 1 })],
                                maxIterations: 1),
            history: [.user("q")],
            onActivity: { activities.append($0) })

        XCTAssertEqual(executed, 1)
        let deniedResults = result.transcript[2].blocks.compactMap { block -> Bool? in
            guard case .toolResult(_, _, let isError) = block else { return nil }
            return isError
        }
        XCTAssertEqual(deniedResults, [false])
        XCTAssertEqual(activities.filter { if case .iterationLimitReached = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(result.finalText.contains("Stopped: reached the tool-use iteration limit"))
    }

    /// The invariant every caller of `AgentTurnResult.transcript` relies on:
    /// `BranchConversation.archivedMessageCount` (`ResearchWorkbench`) is an *index* into it.
    func testTranscriptPrefixExactlyMatchesTheSeedHistory() async throws {
        let seed: [LLMMessage] = [.user("first"), LLMMessage(role: .assistant, blocks: [.text("prior reply")])]
        let result = try await CodexRunner.consume(
            stream([.agentMessageCompleted(text: "new reply", isFinal: true), .turnCompleted]),
            server: idleServer(), config: AgentConfig(systemPrompt: "sys", tools: []),
            history: seed, onActivity: { _ in })
        XCTAssertEqual(Array(result.transcript.prefix(seed.count)), seed)
    }

    // MARK: - Effort mapping

    func testEffortMapping() {
        XCTAssertEqual(CodexRunner.effort(for: .off), "low")
        XCTAssertEqual(CodexRunner.effort(for: .low), "low")
        XCTAssertEqual(CodexRunner.effort(for: .medium), "medium")
        XCTAssertEqual(CodexRunner.effort(for: .high), "high")
    }

    func testAdvertisedEffortsAreRespectedAndOffUsesCheapest() {
        XCTAssertEqual(CodexRunner.effort(
            for: .off, supported: ["minimal", "medium", "high"], defaultEffort: "medium"), "minimal")
        XCTAssertEqual(CodexRunner.effort(
            for: .low, supported: ["medium", "high"], defaultEffort: "medium"), "medium")
    }

    func testMaxTokensLimitationIsExplicit() {
        XCTAssertTrue(CodexRunner.maxTokensLimitation.contains("does not expose"))
    }
}

final class CodexRunnerHistoryGuardTests: XCTestCase {

    /// The only history shape `run()` still rejects — nothing to seed a turn from at all.
    /// Everything else (multi-message, non-user-first) is handled by `flattenedInput(for:)`.
    func testEmptyHistoryIsRejectedWithAClearError() async {
        let runner = CodexRunner(model: "gpt-5.6-terra")
        do {
            _ = try await runner.run(
                config: AgentConfig(systemPrompt: "sys", tools: []),
                history: [],
                onActivity: { _ in })
            XCTFail("expected empty history to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("at least one message"))
        }
    }
}

final class CodexRunnerFlattenedInputTests: XCTestCase {

    /// Single-shot roles (reviewer, prover, director, etc.) must see byte-identical input to
    /// before multi-turn replay existed — no "User:" label, no joining.
    func testSingleMessageHistoryIsSentAsPlainTextUnchanged() {
        XCTAssertEqual(CodexRunner.flattenedInput(for: [.user("hello there")]), "hello there")
    }

    func testEmptyHistoryFlattensToEmptyString() {
        XCTAssertEqual(CodexRunner.flattenedInput(for: []), "")
    }

    func testMultiTurnHistoryIsRenderedWithRoleLabels() {
        let history: [LLMMessage] = [
            .user("first question"),
            LLMMessage(role: .assistant, blocks: [.text("first answer")]),
            .user("second question")
        ]
        let flattened = CodexRunner.flattenedInput(for: history)
        XCTAssertEqual(flattened, """
        User: first question

        Assistant: first answer

        User: second question
        """)
    }

    func testToolUseAndToolResultAreRenderedAsBracketedAsides() {
        let history: [LLMMessage] = [
            .user("what's the weather"),
            LLMMessage(role: .assistant, blocks: [
                .toolUse(id: "call_1", name: "weather", inputJSON: #"{"city":"nyc"}"#)
            ]),
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call_1", content: "sunny", isError: false)
            ])
        ]
        let flattened = CodexRunner.flattenedInput(for: history)
        XCTAssertTrue(flattened.contains(#"[called weather with {"city":"nyc"}]"#))
        XCTAssertTrue(flattened.contains("[tool result: sunny]"))
    }

    func testReasoningBlocksAreOmittedFromTheFlattenedText() {
        let history: [LLMMessage] = [
            .user("q"),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "considering", signature: nil),
                .reasoningItem(id: "rs_1", encryptedContent: "ENC"),
                .text("answer")
            ])
        ]
        let flattened = CodexRunner.flattenedInput(for: history)
        XCTAssertFalse(flattened.contains("considering"))
        XCTAssertFalse(flattened.contains("ENC"))
        XCTAssertTrue(flattened.contains("Assistant: answer"))
    }
}

private actor ControllableCodexServer: CodexServing {
    private let events: AsyncThrowingStream<CodexEvent, Error>
    private let eventContinuation: AsyncThrowingStream<CodexEvent, Error>.Continuation
    private var turnContinuation: CheckedContinuation<String, Never>?
    private var startTurnDidReturn = false
    private var interruptIDs: [String] = []
    private var closeCount = 0
    private var injectedItems: [[[String: Any]]] = []
    private var turnInputs: [[[String: Any]]] = []

    init() {
        (events, eventContinuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
    }

    func startThread(model: String, developerInstructions: String, tools: [ToolSpec]) async throws -> CodexServer.StartedThread {
        CodexServer.StartedThread(threadID: "thread-1", events: events)
    }

    func injectItems(threadID: String, items: [[String: Any]]) async throws {
        injectedItems.append(items)
    }

    func startTurn(threadID: String, input: [[String: Any]], effort: String) async throws -> String {
        turnInputs.append(input)
        let id = await withCheckedContinuation { turnContinuation = $0 }
        startTurnDidReturn = true
        return id
    }

    func interruptTurn(threadID: String, turnID: String) async {
        interruptIDs.append(turnID)
        eventContinuation.finish(throwing: CancellationError())
    }

    func respond(requestID: CodexProtocol.RequestID, success: Bool, text: String) async {}

    func closeThread(_ threadID: String) async { closeCount += 1 }

    func releaseTurnID(_ id: String = "turn-1") {
        turnContinuation?.resume(returning: id)
        turnContinuation = nil
    }

    func yield(_ event: CodexEvent) { eventContinuation.yield(event) }
    func fail(_ error: Error) { eventContinuation.finish(throwing: error) }
    func hasPendingTurnStart() -> Bool { turnContinuation != nil }
    func didReturnTurnID() -> Bool { startTurnDidReturn }
    func recordedInterruptIDs() -> [String] { interruptIDs }
    func recordedCloseCount() -> Int { closeCount }
    func recordedInjectedItems() -> [[[String: Any]]] { injectedItems }
    func recordedTurnInputs() -> [[[String: Any]]] { turnInputs }
    func injectedJSON() -> String {
        guard JSONSerialization.isValidJSONObject(injectedItems),
              let data = try? JSONSerialization.data(withJSONObject: injectedItems)
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    func turnInputsJSON() -> String {
        guard JSONSerialization.isValidJSONObject(turnInputs),
              let data = try? JSONSerialization.data(withJSONObject: turnInputs)
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class CodexRunnerLifecycleTests: XCTestCase {
    private struct ExpectedFailure: Error {}

    private func waitUntil(
        seconds: Double = 1, _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition was not met before timeout")
    }

    private func task(
        server: ControllableCodexServer,
        history: [LLMMessage] = [.user("q")],
        supportsHistoryInjection: Bool = true,
        modelOption: ModelOption? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) -> Task<AgentTurnResult, Error> {
        Task {
            try await CodexRunner(model: "m").run(
                server: server, config: AgentConfig(systemPrompt: "sys", tools: []),
                history: history, supportsHistoryInjection: supportsHistoryInjection,
                modelOption: modelOption, onActivity: onActivity)
        }
    }

    private func finish(_ server: ControllableCodexServer) async {
        await server.releaseTurnID()
        await server.yield(.agentMessageCompleted(text: "Done.", isFinal: true))
        await server.yield(.turnCompleted)
    }

    func testSuccessfulTurnClosesThreadExactlyOnce() async throws {
        let server = ControllableCodexServer()
        let run = task(server: server)
        try await waitUntil { await server.hasPendingTurnStart() }
        await server.releaseTurnID()
        await server.yield(.agentMessageCompleted(text: "Done.", isFinal: true))
        await server.yield(.turnCompleted)
        let result = try await run.value
        XCTAssertEqual(result.finalText, "Done.")
        let closeCount = await server.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testFailedTurnClosesThreadExactlyOnce() async throws {
        let server = ControllableCodexServer()
        let run = task(server: server)
        try await waitUntil { await server.hasPendingTurnStart() }
        await server.releaseTurnID()
        try await waitUntil { await server.didReturnTurnID() }
        await server.fail(ExpectedFailure())
        do {
            _ = try await run.value
            XCTFail("expected failure")
        } catch is ExpectedFailure {}
        let closeCount = await server.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testCancellationBeforeTurnIDInterruptsOnceIDArrivesAndNeverSendsEmptyID() async throws {
        let server = ControllableCodexServer()
        let run = task(server: server)
        try await waitUntil { await server.hasPendingTurnStart() }
        run.cancel()
        let earlyInterrupts = await server.recordedInterruptIDs()
        XCTAssertEqual(earlyInterrupts, [])
        await server.releaseTurnID("turn-after-cancel")
        do {
            _ = try await run.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        try await waitUntil { await server.recordedInterruptIDs() == ["turn-after-cancel"] }
        let closeCount = await server.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testCancellationAfterTurnIDInterruptsThatTurnExactlyOnce() async throws {
        let server = ControllableCodexServer()
        let consuming = expectation(description: "runner began consuming events")
        let run = task(server: server) { activity in
            if case .textDelta = activity { consuming.fulfill() }
        }
        try await waitUntil { await server.hasPendingTurnStart() }
        await server.releaseTurnID("known-turn")
        await server.yield(.textDelta("working"))
        await fulfillment(of: [consuming], timeout: 1)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        try await waitUntil { await server.recordedInterruptIDs() == ["known-turn"] }
        let closeCount = await server.recordedCloseCount()
        XCTAssertEqual(closeCount, 1)
    }

    func testStructuredReplayInjectsRetainedHistoryAndSendsLatestDocumentAndImageNatively() async throws {
        let server = ControllableCodexServer()
        let history: [LLMMessage] = [
            .user("old question"),
            LLMMessage(role: .assistant, blocks: [.text("old answer")]),
            LLMMessage(role: .user, blocks: [
                .document(name: "notes.txt", text: "full document text"),
                .image(mediaType: "image/png", base64: "AA=="),
                .text("new question")
            ])
        ]
        let option = ModelOption(id: "m", displayName: "Vision", inputModalities: [.text, .image])
        let run = task(server: server, history: history, modelOption: option)
        try await waitUntil { await server.hasPendingTurnStart() }
        let replay = await server.injectedJSON()
        let input = await server.turnInputsJSON()
        XCTAssertTrue(replay.contains("old question"))
        XCTAssertTrue(replay.contains("old answer"))
        XCTAssertFalse(replay.contains("new question"))
        XCTAssertTrue(input.contains("full document text"))
        XCTAssertTrue(input.contains("data:image\\/png;base64,AA==") || input.contains("data:image/png;base64,AA=="))
        XCTAssertTrue(input.contains("new question"))
        await finish(server)
        _ = try await run.value
    }

    func testFallbackKeepsAllDocumentTextAndCarriesImagesNatively() async throws {
        let server = ControllableCodexServer()
        let history: [LLMMessage] = [
            .user("old"),
            LLMMessage(role: .assistant, blocks: [.text("answer")]),
            LLMMessage(role: .user, blocks: [
                .document(name: "paper.md", text: "important theorem"),
                .image(mediaType: "image/jpeg", base64: "AQ==")
            ])
        ]
        let run = task(server: server, history: history, supportsHistoryInjection: false)
        try await waitUntil { await server.hasPendingTurnStart() }
        let replay = await server.injectedJSON()
        XCTAssertEqual(replay, "[]")
        let input = await server.turnInputsJSON()
        XCTAssertTrue(input.contains("old"))
        XCTAssertTrue(input.contains("important theorem"))
        XCTAssertTrue(input.contains("data:image\\/jpeg;base64,AQ==") || input.contains("data:image/jpeg;base64,AQ=="))
        await finish(server)
        _ = try await run.value
    }

    func testCompactedAwayContextIsNotInjectedIntoFreshThread() async throws {
        let server = ControllableCodexServer()
        let retained: [LLMMessage] = [.user("retained"), .user("current")]
        let run = task(server: server, history: retained)
        try await waitUntil { await server.hasPendingTurnStart() }
        let replay = await server.injectedJSON()
        XCTAssertTrue(replay.contains("retained"))
        XCTAssertFalse(replay.contains("discarded-secret"))
        XCTAssertFalse(replay.contains("current"))
        await finish(server)
        _ = try await run.value
    }

    func testAdvertisedUnsupportedImageModalityFailsBeforeStartingThread() async {
        let server = ControllableCodexServer()
        let option = ModelOption(id: "m", displayName: "Text only", inputModalities: [.text])
        do {
            _ = try await CodexRunner(model: "m").run(
                server: server, config: AgentConfig(systemPrompt: "sys", tools: []),
                history: [LLMMessage(role: .user, blocks: [
                    .image(mediaType: "image/png", base64: "AA==")
                ])], modelOption: option, onActivity: { _ in })
            XCTFail("expected modality error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not advertise image input"))
        }
        let closeCount = await server.recordedCloseCount()
        XCTAssertEqual(closeCount, 0)
    }
}
