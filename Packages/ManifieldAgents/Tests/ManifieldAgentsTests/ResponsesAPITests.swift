import XCTest
@testable import ManifieldAgents

final class ResponsesAPIRequestBodyTests: XCTestCase {

    private func provider() -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(
            config: ProviderConfig(kind: .openai, apiKey: "k", model: "gpt-5.6-sol"),
            baseURL: URL(string: "https://api.openai.com/v1")!)
    }

    func testHitsResponsesEndpointWithReasoningAndTools() throws {
        let request = LLMRequest(
            system: "sys",
            messages: [.user("hello")],
            tools: [ToolSpec(name: "search", description: "d",
                             inputSchemaJSON: #"{"type":"object"}"#)],
            thinking: .high)
        let urlRequest = try provider().makeURLRequest(request)

        XCTAssertEqual(urlRequest.url?.path, "/v1/responses")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["instructions"] as? String, "sys")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "search")
        XCTAssertNotNil(tools.first?["parameters"])
    }

    func testOffThinkingOmitsReasoning() throws {
        let request = LLMRequest(system: "s", messages: [.user("q")], thinking: .off)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider().makeURLRequest(request).httpBody)) as? [String: Any])
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["include"])
    }

    /// The reasoning item must be replayed *before* the function_call it preceded, and tool
    /// results become function_call_output items keyed by call_id.
    func testReplayPreservesReasoningBeforeToolCall() throws {
        let request = LLMRequest(
            system: "s",
            messages: [
                .user("hello"),
                LLMMessage(role: .assistant, blocks: [
                    .reasoningItem(id: "rs_1", encryptedContent: "ENC"),
                    .toolUse(id: "call_1", name: "search", inputJSON: #"{"q":"x"}"#)
                ]),
                LLMMessage(role: .user, blocks: [
                    .toolResult(toolUseID: "call_1", content: "result", isError: false)
                ])
            ],
            thinking: .medium)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider().makeURLRequest(request).httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])

        XCTAssertEqual(input.map { $0["type"] as? String },
                       ["message", "reasoning", "function_call", "function_call_output"])

        XCTAssertEqual(input[1]["id"] as? String, "rs_1")
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "ENC")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["name"] as? String, "search")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[3]["output"] as? String, "result")
    }

    func testToolErrorResultIsMarked() throws {
        let request = LLMRequest(system: "s", messages: [
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call_9", content: "bad", isError: true)
            ])
        ])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider().makeURLRequest(request).httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["output"] as? String, "ERROR: bad")
    }

    /// Characterizes the `responsesItems(for:)` extraction (shared with `CodexHistoryReplay`):
    /// the provider's request body must still carry exactly what the free function produces for
    /// the same messages, covering every block kind in one pass.
    func testResponsesItemsMatchesTheProviderRequestBodyForEveryBlockKind() throws {
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(role: .user, blocks: [.document(name: "notes.txt", text: "content")]),
            LLMMessage(role: .user, blocks: [.image(mediaType: "image/png", base64: "AAAA")]),
            LLMMessage(role: .assistant, blocks: [
                .reasoningItem(id: "rs_1", encryptedContent: "ENC"),
                .toolUse(id: "call_1", name: "search", inputJSON: #"{"q":"x"}"#)
            ]),
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call_1", content: "result", isError: false)
            ])
        ]
        let request = LLMRequest(system: "s", messages: messages, thinking: .medium)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(try provider().makeURLRequest(request).httpBody)) as? [String: Any])
        let fromProvider = try XCTUnwrap(body["input"] as? [[String: Any]])
        let fromSharedFunction = responsesItems(for: messages)

        XCTAssertTrue(
            (fromProvider as NSArray).isEqual(fromSharedFunction as NSArray),
            "the provider's request body and the shared mapper must produce identical items")
    }
}

final class ResponsesAPIParserTests: XCTestCase {

    private func drain(_ lines: [String]) throws -> [LLMEvent] {
        let parser = OpenAIResponsesParser()
        var events: [LLMEvent] = []
        for line in lines { events += try parser.handle(dataLine: line) }
        events += parser.flush()
        return events
    }

    func testReasoningThenToolCallStreamsInOrder() throws {
        let events = try drain([
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#,
            #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[],"encrypted_content":"ENC"}}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"search","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"q\":"}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"x\"}"}"#,
            #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"search","arguments":"{\"q\":\"x\"}"}}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":5}}}"#
        ])

        XCTAssertEqual(events, [
            .reasoningItemFinished(id: "rs_1", encryptedContent: "ENC"),
            .toolUseStarted(id: "call_1", name: "search"),
            .toolUseFinished(id: "call_1", name: "search", inputJSON: #"{"q":"x"}"#),
            .usage(input: 10, output: 5),
            .finished(.toolUse)
        ])
    }

    func testPlainTextEndsTurn() throws {
        let events = try drain([
            #"{"type":"response.output_text.delta","delta":"Hel"}"#,
            #"{"type":"response.output_text.delta","delta":"lo"}"#,
            #"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":1,"output_tokens":2}}}"#
        ])
        XCTAssertEqual(events, [
            .textDelta("Hel"), .textDelta("lo"),
            .usage(input: 1, output: 2), .finished(.endTurn)
        ])
    }

    func testReasoningSummaryStreamsAsThinking() throws {
        let parser = OpenAIResponsesParser()
        let events = try parser.handle(
            dataLine: #"{"type":"response.reasoning_summary_text.delta","delta":"pondering"}"#)
        XCTAssertEqual(events, [.thinkingDelta("pondering")])
    }

    func testIncompleteMapsToMaxTokens() throws {
        let events = try drain([
            #"{"type":"response.output_text.delta","delta":"partial"}"#,
            #"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":3,"output_tokens":4}}}"#
        ])
        XCTAssertEqual(events, [
            .textDelta("partial"), .usage(input: 3, output: 4), .finished(.maxTokens)
        ])
    }

    func testFailureEventThrows() {
        let parser = OpenAIResponsesParser()
        XCTAssertThrowsError(try parser.handle(
            dataLine: #"{"type":"response.failed","response":{"status":"failed","error":{"message":"boom"}}}"#)) {
            guard case AgentError.api(let message) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertEqual(message, "boom")
        }
    }

    func testUnfinishedToolCallIsFlushed() throws {
        // A function call announced but never explicitly "done" is still emitted at flush.
        let events = try drain([
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_7","name":"lookup","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}"#
        ])
        XCTAssertEqual(events, [
            .toolUseStarted(id: "call_7", name: "lookup"),
            .toolUseFinished(id: "call_7", name: "lookup", inputJSON: "{}"),
            .finished(.toolUse)
        ])
    }
}
