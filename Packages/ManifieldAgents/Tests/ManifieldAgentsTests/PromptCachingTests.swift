import XCTest
@testable import ManifieldAgents

/// Anthropic prompt caching: cache_control breakpoints on the request
/// (tools → stable system → last message block) and cache-aware usage parsing.
final class PromptCachingRequestTests: XCTestCase {

    private func body(system: SystemPrompt = "s",
                      messages: [LLMMessage] = [.user("q")],
                      tools: [ToolSpec] = []) throws -> [String: Any] {
        let provider = AnthropicProvider(config: ProviderConfig(
            kind: .anthropic, apiKey: "test-key", model: "claude-sonnet-5"))
        let request = LLMRequest(system: system, messages: messages, tools: tools)
        let urlRequest = try provider.makeURLRequest(request)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    private func tool(_ name: String) -> ToolSpec {
        ToolSpec(name: name, description: "d", inputSchemaJSON: #"{"type":"object"}"#)
    }

    /// An unsplit prompt — what every agent but chat builds — is one marked block.
    func testInstructionsOnlySystemBecomesOneMarkedBlock() throws {
        let body = try body()
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 1)
        XCTAssertEqual(system[0]["type"] as? String, "text")
        XCTAssertEqual(system[0]["text"] as? String, "s")
        let marker = try XCTUnwrap(system[0]["cache_control"] as? [String: Any])
        XCTAssertEqual(marker["type"] as? String, "ephemeral")
    }

    /// The split itself: the breakpoint ends the stable block, and the volatile block
    /// that follows carries none — marking it would cache text the next turn rewrites.
    func testSplitSystemPutsTheBreakpointAtTheEndOfTheStableBlock() throws {
        let body = try body(system: SystemPrompt(
            instructions: "rules", projectContext: "memory + outline"))
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["text"] as? String, "rules")
        XCTAssertEqual(system[1]["text"] as? String, "memory + outline")
        XCTAssertEqual(system[1]["type"] as? String, "text")
        let marker = try XCTUnwrap(system[0]["cache_control"] as? [String: Any])
        XCTAssertEqual(marker["type"] as? String, "ephemeral")
        XCTAssertNil(system[1]["cache_control"])
    }

    /// The reason the split exists. Two chat prompts that differ only in the research
    /// memory must produce a byte-identical stable block, so a memory write re-caches
    /// the project context and nothing else.
    func testMemoryWriteLeavesTheStableBlockUntouched() throws {
        func systemBlocks(memory: String) throws -> [[String: Any]] {
            let prompt = ContextAssembly.chatSystemPrompt(
                projectName: "k-Domination", notation: "", items: [], userProfile: "",
                memory: memory)
            return try XCTUnwrap(body(system: prompt)["system"] as? [[String: Any]])
        }
        let before = try systemBlocks(memory: "## Goal\nProve the doubling conjecture.\n")
        let after = try systemBlocks(memory: """
            ## Goal
            Prove the doubling conjecture.

            ## Eliminated Strategies
            - induction on n — the base case is the whole problem.
            """)

        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(before[0]["text"] as? String, after[0]["text"] as? String,
                       "a memory write must not disturb the cached instruction set")
        XCTAssertNotNil(before[0]["cache_control"])
        XCTAssertNotNil(after[0]["cache_control"])

        let stable = try XCTUnwrap(after[0]["text"] as? String)
        let volatile = try XCTUnwrap(after[1]["text"] as? String)
        XCTAssertTrue(stable.contains("Memory discipline (update_memory):"),
                      "the rules governing memory are fixed text and belong before the breakpoint")
        XCTAssertTrue(volatile.contains("the base case is the whole problem."),
                      "the memory itself belongs after it")
        XCTAssertFalse(stable.contains("the base case is the whole problem."))
        // Project data the agent's own writes can change must stay out of the stable block.
        XCTAssertTrue(volatile.contains("Library outline:"))
    }

    func testEmptySystemStaysPlainString() throws {
        let body = try body(system: "")
        XCTAssertEqual(body["system"] as? String, "")
    }

    /// The API accepts at most four breakpoints per request. Three are spoken for —
    /// tools, system, conversation — so a fourth is the last one going.
    func testRequestStaysWithinTheBreakpointBudget() throws {
        let body = try body(
            system: SystemPrompt(instructions: "rules", projectContext: "memory"),
            tools: [tool("a"), tool("b")])
        var markers = 0
        for block in try XCTUnwrap(body["system"] as? [[String: Any]])
            where block["cache_control"] != nil { markers += 1 }
        for spec in try XCTUnwrap(body["tools"] as? [[String: Any]])
            where spec["cache_control"] != nil { markers += 1 }
        for message in try XCTUnwrap(body["messages"] as? [[String: Any]]) {
            for block in try XCTUnwrap(message["content"] as? [[String: Any]])
                where block["cache_control"] != nil { markers += 1 }
        }
        XCTAssertEqual(markers, 3)
        XCTAssertLessThanOrEqual(markers, 4)
    }

    func testOnlyLastToolCarriesBreakpoint() throws {
        let body = try body(tools: [tool("a"), tool("b"), tool("c")])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3)
        XCTAssertNil(tools[0]["cache_control"])
        XCTAssertNil(tools[1]["cache_control"])
        let marker = try XCTUnwrap(tools[2]["cache_control"] as? [String: Any])
        XCTAssertEqual(marker["type"] as? String, "ephemeral")
    }

    func testOnlyLastBlockOfLastMessageCarriesBreakpoint() throws {
        let messages: [LLMMessage] = [
            .user("first question"),
            LLMMessage(role: .assistant, blocks: [
                .text("Checking."),
                .toolUse(id: "t1", name: "echo", inputJSON: "{}")
            ]),
            LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "t1", content: "ok", isError: false),
                .toolResult(toolUseID: "t1", content: "extra", isError: false)
            ])
        ]
        let body = try body(messages: messages)
        let wire = try XCTUnwrap(body["messages"] as? [[String: Any]])

        for message in wire.dropLast() {
            for block in try XCTUnwrap(message["content"] as? [[String: Any]]) {
                XCTAssertNil(block["cache_control"], "only the final block is marked")
            }
        }
        let lastBlocks = try XCTUnwrap(wire.last?["content"] as? [[String: Any]])
        XCTAssertNil(lastBlocks[0]["cache_control"])
        let marker = try XCTUnwrap(lastBlocks[1]["cache_control"] as? [String: Any])
        XCTAssertEqual(marker["type"] as? String, "ephemeral")
    }

    func testBreakpointSkippedWhenLastBlockIsNotCacheable() throws {
        // A message ending in a thinking block must not be marked — the API
        // rejects cache_control on thinking blocks.
        var messages: [[String: Any]] = [[
            "role": "assistant",
            "content": [["type": "thinking", "thinking": "t", "signature": "sig"]]
        ]]
        AnthropicProvider.markConversationCacheBreakpoint(&messages)
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertNil(blocks[0]["cache_control"])
    }
}

final class PromptCachingUsageTests: XCTestCase {

    func testUsageSumsCachedAndUncachedInput() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []
        let lines = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":9000,"cache_creation_input_tokens":400}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }
        XCTAssertTrue(events.contains(.usage(input: 9412, output: 5)),
                      "context size must include cache reads and writes")
    }

    func testUsageWithoutCacheFieldsUnchanged() throws {
        let parser = AnthropicStreamParser()
        var events: [LLMEvent] = []
        let lines = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":700}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#
        ]
        for line in lines {
            events.append(contentsOf: try parser.handle(dataLine: line))
        }
        XCTAssertTrue(events.contains(.usage(input: 700, output: 3)))
    }
}
