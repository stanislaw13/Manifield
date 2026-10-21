import XCTest
@testable import ManifieldAgents

final class CodexHistoryReplayTests: XCTestCase {

    func testEmitsResponsesItemsNeverThreadItemShapes() {
        let items = CodexHistoryReplay.items(for: [.user("hello")])
        XCTAssertEqual(items.first?["type"] as? String, "message")
        XCTAssertEqual(items.first?["role"] as? String, "user")
        // A `ThreadItem` would use `agentMessage`/`dynamicToolCall`/etc — never this shape.
        XCTAssertNil(items.first?["itemType"])
    }

    func testReasoningItemIsStripped() {
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(role: .assistant, blocks: [
                .reasoningItem(id: "rs_1", encryptedContent: "ENC"),
                .toolUse(id: "call_1", name: "search", inputJSON: #"{"q":"x"}"#)
            ])
        ]
        let items = CodexHistoryReplay.items(for: messages)
        XCTAssertFalse(items.contains { $0["type"] as? String == "reasoning" })
        XCTAssertEqual(items.map { $0["type"] as? String }, ["message", "function_call"])
    }

    func testThinkingAndRedactedThinkingAreStripped() {
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "hmm", signature: "sig"),
                .redactedThinking(data: "opaque"),
                .text("the answer")
            ])
        ]
        let items = CodexHistoryReplay.items(for: messages)
        XCTAssertEqual(items.map { $0["type"] as? String }, ["message", "message"])
        XCTAssertEqual(items.last?["role"] as? String, "assistant")
    }

    /// `.toolUse`/`.toolResult` still pair by `call_id` after the reasoning strip — dropping the
    /// reasoning block in between must not disturb the ids the model matches calls to results by.
    func testToolUseAndToolResultStillPairByCallID() {
        let messages: [LLMMessage] = [
            .user("hello"),
            LLMMessage(role: .assistant, blocks: [
                .reasoningItem(id: "rs_1", encryptedContent: "ENC"),
                .toolUse(id: "call_1", name: "search", inputJSON: #"{"q":"x"}"#)
            ]),
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call_1", content: "result", isError: false)
            ])
        ]
        let items = CodexHistoryReplay.items(for: messages)
        XCTAssertEqual(items.map { $0["type"] as? String },
                        ["message", "function_call", "function_call_output"])
        XCTAssertEqual(items[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(items[2]["call_id"] as? String, "call_1")
    }

    func testEmptyHistoryProducesNoItems() {
        XCTAssertEqual(CodexHistoryReplay.items(for: []).count, 0)
    }

    func testProviderSwitchReplayPreservesDocumentsAndImagesButNotForeignReasoning() {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, blocks: [
                .document(name: "proof.txt", text: "complete proof text"),
                .image(mediaType: "image/png", base64: "AA==")
            ]),
            LLMMessage(role: .assistant, blocks: [
                .thinking(text: "provider-private thought", signature: "foreign"),
                .text("portable answer")
            ])
        ]
        let data = try! JSONSerialization.data(withJSONObject: CodexHistoryReplay.items(for: messages))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("complete proof text"))
        XCTAssertTrue(json.contains("data:image\\/png;base64,AA==") || json.contains("data:image/png;base64,AA=="))
        XCTAssertTrue(json.contains("portable answer"))
        XCTAssertFalse(json.contains("provider-private thought"))
        XCTAssertFalse(json.contains("foreign"))
    }
}
