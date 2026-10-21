import XCTest
@testable import ManifieldAgents

final class AnthropicThinkingParserTests: XCTestCase {

    func testThinkingBlockStream() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []

        let lines = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me consider "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"the parity argument."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer."}}"#,
            #"{"type":"content_block_stop","index":1}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }

        XCTAssertTrue(events.contains(.thinkingDelta("Let me consider ")))
        XCTAssertTrue(events.contains(.thinkingFinished(
            text: "Let me consider the parity argument.", signature: "sig-abc")))
        XCTAssertTrue(events.contains(.textDelta("Answer.")))
    }

    func testRedactedThinkingBlock() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []
        let lines = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENCRYPTED"}}"#,
            #"{"type":"content_block_stop","index":0}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }
        XCTAssertEqual(events, [.redactedThinking(data: "ENCRYPTED")])
    }

    func testEmptySignatureBecomesNil() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []
        let lines = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#,
            #"{"type":"content_block_stop","index":0}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }
        XCTAssertTrue(events.contains(.thinkingFinished(text: "x", signature: nil)))
    }
}

final class ThinkingStrategyTests: XCTestCase {

    func testAdaptiveModels() {
        for model in ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
                      "claude-sonnet-5", "claude-sonnet-4-6",
                      "claude-fable-5", "claude-mythos-5"] {
            if case .budget = AnthropicProvider.thinkingStrategy(forModel: model) {
                XCTFail("\(model) should use adaptive thinking")
            }
        }
    }

    func testBudgetModels() {
        for model in ["claude-sonnet-4-5-20250929", "claude-opus-4-5", "claude-opus-4-1",
                      "claude-haiku-4-5-20251001", "claude-3-7-sonnet-20250219"] {
            if case .adaptive = AnthropicProvider.thinkingStrategy(forModel: model) {
                XCTFail("\(model) should use budget_tokens thinking")
            }
        }
    }

    func testUnknownFutureModelDefaultsToAdaptive() {
        if case .budget = AnthropicProvider.thinkingStrategy(forModel: "claude-opus-6") {
            XCTFail("future models should default to adaptive")
        }
    }
}

final class ThinkingRequestBodyTests: XCTestCase {

    private func body(model: String, thinking: ThinkingLevel,
                      messages: [LLMMessage] = [.user("q")]) throws -> [String: Any] {
        let provider = AnthropicProvider(config: ProviderConfig(
            kind: .anthropic, apiKey: "test-key", model: model))
        let request = LLMRequest(system: "s", messages: messages, thinking: thinking)
        let urlRequest = try provider.makeURLRequest(request)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    func testAdaptiveThinkingBody() throws {
        let body = try body(model: "claude-opus-4-8", thinking: .high)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertEqual(thinking["display"] as? String, "summarized")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "high")
        XCTAssertGreaterThanOrEqual(body["max_tokens"] as? Int ?? 0, 65_536)
        XCTAssertNil(body["budget_tokens"])
    }

    func testBudgetThinkingBody() throws {
        let body = try body(model: "claude-haiku-4-5-20251001", thinking: .medium)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        let budget = try XCTUnwrap(thinking["budget_tokens"] as? Int)
        XCTAssertEqual(budget, 16_384)
        let maxTokens = try XCTUnwrap(body["max_tokens"] as? Int)
        XCTAssertGreaterThan(maxTokens, budget, "budget must be strictly below max_tokens")
        XCTAssertNil(body["output_config"], "effort is not supported on budget models")
    }

    func testOffSendsNoThinkingField() throws {
        let body = try body(model: "claude-opus-4-8", thinking: .off)
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["output_config"])
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
    }

    func testThinkingBlockReplay() throws {
        let messages: [LLMMessage] = [
            .user("prove it"),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "parity argument", signature: "sig-1"),
                .text("Checking."),
                .toolUse(id: "t1", name: "search_theory", inputJSON: #"{"query":"parity"}"#)
            ]),
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "t1", content: "found", isError: false)
            ])
        ]
        let body = try body(model: "claude-opus-4-8", thinking: .high, messages: messages)
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(wireMessages.first { $0["role"] as? String == "assistant" })
        let blocks = try XCTUnwrap(assistant["content"] as? [[String: Any]])

        XCTAssertEqual(blocks[0]["type"] as? String, "thinking",
                       "thinking must be replayed first, in original position")
        XCTAssertEqual(blocks[0]["thinking"] as? String, "parity argument")
        XCTAssertEqual(blocks[0]["signature"] as? String, "sig-1")
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[2]["type"] as? String, "tool_use")
    }

    func testUnsignedThinkingBlockIsOmitted() throws {
        let messages: [LLMMessage] = [
            .user("q"),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "unsigned", signature: nil),
                .text("answer")
            ])
        ]
        let body = try body(model: "claude-opus-4-8", thinking: .high, messages: messages)
        let wireMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(wireMessages.first { $0["role"] as? String == "assistant" })
        let blocks = try XCTUnwrap(assistant["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"] as? String, "text")
    }

    func testOpenAICompatReasoningEffort() throws {
        let provider = OpenAICompatProvider(
            config: ProviderConfig(kind: .openai, apiKey: "k", model: "gpt-5"),
            baseURL: URL(string: "https://api.openai.com/v1")!)
        let request = LLMRequest(system: "s", messages: [.user("q")], thinking: .medium)
        let urlRequest = try provider.makeURLRequest(request)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")

        // Thinking blocks have no Chat Completions channel — dropped on replay.
        let replay = LLMRequest(system: "s", messages: [
            .user("q"),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "hmm", signature: "sig"), .text("a")
            ])
        ], thinking: .off)
        let replayBody = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider.makeURLRequest(replay).httpBody)) as? [String: Any])
        XCTAssertNil(replayBody["reasoning_effort"])
        let wireMessages = try XCTUnwrap(replayBody["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(wireMessages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual(assistant["content"] as? String, "a")
    }

    func testOpenAICompatForceReasoningOffSendsNone() throws {
        let provider = OpenAICompatProvider(
            config: ProviderConfig(kind: .openai, apiKey: "k", model: "gpt-5.6-sol"),
            baseURL: URL(string: "https://api.openai.com/v1")!)
        // Even at a non-off thinking level, the tool-conflict fallback pins reasoning_effort
        // to "none" so the request stops 400ing on models that reject effort alongside tools.
        let request = LLMRequest(system: "s", messages: [.user("q")], thinking: .high)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider.makeURLRequest(request, forceReasoningOff: true).httpBody))
            as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
    }
}

final class OpenAIReasoningParserTests: XCTestCase {

    func testReasoningContentDelta() {
        let parser = OpenAIStreamParser()
        var events = parser.handle(
            dataLine: #"{"choices":[{"delta":{"reasoning_content":"thinking hard"}}]}"#)
        events += parser.handle(
            dataLine: #"{"choices":[{"delta":{"content":"Done."},"finish_reason":"stop"}]}"#)
        events += parser.flush()
        XCTAssertTrue(events.contains(.thinkingDelta("thinking hard")))
        XCTAssertTrue(events.contains(.textDelta("Done.")))
    }
}

final class ContentBlockCodableTests: XCTestCase {

    func testNewCasesRoundTrip() throws {
        let blocks: [ContentBlock] = [
            .thinking(text: "reason", signature: "sig"),
            .thinking(text: "unsigned", signature: nil),
            .redactedThinking(data: "ENC"),
            .reasoningItem(id: "rs_1", encryptedContent: "ENC2"),
            .text("t"),
            .toolUse(id: "1", name: "n", inputJSON: "{}"),
            .toolResult(toolUseID: "1", content: "c", isError: false)
        ]
        let data = try JSONEncoder().encode(blocks)
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: data)
        XCTAssertEqual(decoded, blocks)
    }

    func testOldTranscriptStillDecodes() throws {
        // A pre-thinking transcript as persisted in sessions/current.json.
        let old = #"[{"kind":"text","text":"hello"},{"kind":"toolUse","id":"t1","name":"echo","inputJSON":"{}"}]"#
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: Data(old.utf8))
        XCTAssertEqual(decoded, [.text("hello"), .toolUse(id: "t1", name: "echo", inputJSON: "{}")])
    }
}

// MARK: - Thinking blocks through the tool loop

private final class ScriptedProvider: LLMProvider {
    var description: String { "scripted" }
    var scripts: [[LLMEvent]]
    private(set) var requests: [LLMRequest] = []

    init(scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        requests.append(request)
        let events = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private struct NoopTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "echo", description: "echoes", inputSchemaJSON: #"{"type":"object"}"#)
    }
    func execute(inputJSON: String) async throws -> String { "ok" }
}

final class AgentLoopThinkingTests: XCTestCase {

    func testThinkingBlocksAreReplayedInOrder() async throws {
        let provider = ScriptedProvider(scripts: [
            [
                .thinkingFinished(text: "plan the call", signature: "sig-1"),
                .textDelta("Let me check."),
                .toolUseFinished(id: "t1", name: "echo", inputJSON: "{}"),
                .finished(.toolUse)
            ],
            [
                .textDelta("Done."),
                .finished(.endTurn)
            ]
        ])
        var thinkingDeltas: [String] = []
        let result = try await AgentLoop(provider: provider).run(
            config: AgentConfig(systemPrompt: "s", tools: [NoopTool()], thinking: .high),
            history: [.user("q")]
        ) { activity in
            if case .thinkingDelta(let d) = activity { thinkingDeltas.append(d) }
        }

        XCTAssertEqual(result.finalText, "Done.")
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[0].thinking, .high)

        // The follow-up request must carry the thinking block, in original order,
        // ahead of the text and tool_use blocks.
        let assistant = try XCTUnwrap(provider.requests[1].messages.first { $0.role == .assistant })
        XCTAssertEqual(assistant.blocks, [
            .thinking(text: "plan the call", signature: "sig-1"),
            .text("Let me check."),
            .toolUse(id: "t1", name: "echo", inputJSON: "{}")
        ])

        // The persisted transcript carries it too.
        let transcriptAssistant = try XCTUnwrap(result.transcript.first { $0.role == .assistant })
        XCTAssertEqual(transcriptAssistant.blocks.first,
                       .thinking(text: "plan the call", signature: "sig-1"))
        XCTAssertEqual(thinkingDeltas, [], "thinkingFinished alone emits no deltas")
    }

    func testThinkingDeltaReachesActivity() async throws {
        let provider = ScriptedProvider(scripts: [
            [.thinkingDelta("step 1"), .thinkingDelta(" step 2"),
             .thinkingFinished(text: "step 1 step 2", signature: "s"),
             .textDelta("A."), .finished(.endTurn)]
        ])
        var deltas: [String] = []
        _ = try await AgentLoop(provider: provider).run(
            config: AgentConfig(systemPrompt: "s", thinking: .low),
            history: [.user("q")]
        ) { activity in
            if case .thinkingDelta(let d) = activity { deltas.append(d) }
        }
        XCTAssertEqual(deltas, ["step 1", " step 2"])
    }
}
