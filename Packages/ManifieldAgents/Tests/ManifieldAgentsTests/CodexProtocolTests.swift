import XCTest
@testable import ManifieldAgents

final class CodexProtocolRequestBodyTests: XCTestCase {

    func testThreadStartAlwaysCarriesModelAndRegistersToolsAsFunctions() {
        let tools = [
            ToolSpec(name: "search_theory", description: "Search the library.",
                     inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
        ]
        let params = CodexProtocol.threadStartParams(
            model: "gpt-5.6-terra", cwd: "/tmp/scratch",
            developerInstructions: "Use only the provided tools.", tools: tools)

        XCTAssertEqual(params["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(params["cwd"] as? String, "/tmp/scratch")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")

        let dynamicTools = try! XCTUnwrap(params["dynamicTools"] as? [[String: Any]])
        XCTAssertEqual(dynamicTools.count, 1)
        XCTAssertEqual(dynamicTools[0]["type"] as? String, "function")
        XCTAssertEqual(dynamicTools[0]["name"] as? String, "search_theory")
        XCTAssertEqual(dynamicTools[0]["description"] as? String, "Search the library.")
        let schema = try! XCTUnwrap(dynamicTools[0]["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testTurnStartAlwaysCarriesEffortAndWrapsInputAsText() {
        let params = CodexProtocol.turnStartParams(threadID: "th_1", inputText: "hello", effort: "medium")
        XCTAssertEqual(params["threadId"] as? String, "th_1")
        XCTAssertEqual(params["effort"] as? String, "medium")
        let input = try! XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertEqual(input.first?["text"] as? String, "hello")
    }

    func testTurnStartPreservesNativeTextAndImageInputs() {
        let native: [[String: Any]] = [
            ["type": "text", "text": "caption"],
            ["type": "image", "url": "data:image/png;base64,AA==", "detail": "auto"]
        ]
        let params = CodexProtocol.turnStartParams(threadID: "th_1", input: native, effort: "low")
        let input = try! XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["text"] as? String, "caption")
        XCTAssertEqual(input[1]["type"] as? String, "image")
        XCTAssertEqual(input[1]["url"] as? String, "data:image/png;base64,AA==")
    }

    func testThreadInjectionCarriesRawResponsesItems() {
        let items: [[String: Any]] = [["type": "message", "role": "user", "content": []]]
        let params = CodexProtocol.threadInjectItemsParams(threadID: "th_1", items: items)
        XCTAssertEqual(params["threadId"] as? String, "th_1")
        XCTAssertEqual((params["items"] as? [[String: Any]])?.first?["type"] as? String, "message")
    }

    func testToolCallResultShape() {
        let ok = CodexProtocol.toolCallResult(success: true, text: "1 result")
        XCTAssertEqual(ok["success"] as? Bool, true)
        let items = try! XCTUnwrap(ok["contentItems"] as? [[String: Any]])
        XCTAssertEqual(items.first?["type"] as? String, "inputText")
        XCTAssertEqual(items.first?["text"] as? String, "1 result")

        let failed = CodexProtocol.toolCallResult(success: false, text: "tool not available")
        XCTAssertEqual(failed["success"] as? Bool, false)
    }

    func testManagedAccountReadRequestsProtocolDefinedProactiveRefresh() {
        let params = CodexProtocol.accountReadParams(refreshToken: true)
        XCTAssertEqual(params["refreshToken"] as? Bool, true)
    }

    func testEncodeOmitsIDForNotifications() throws {
        let data = try CodexProtocol.encode(id: nil, method: "initialized", params: [:])
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(line.hasSuffix("\n"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["id"])
        XCTAssertEqual(obj["method"] as? String, "initialized")
        XCTAssertNil(obj["jsonrpc"], "codex app-server omits the jsonrpc header on the wire")
    }

    func testEncodeIncludesIntegerID() throws {
        let data = try CodexProtocol.encode(id: .number(7), method: "thread/start", params: ["model": "m"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? Int, 7)
    }
}

final class CodexProtocolClassifyTests: XCTestCase {

    func testClassifiesAResponseWithIntegerID() throws {
        let message = CodexProtocol.classify(line: #"{"id":1,"result":{"thread":{"id":"t1"}}}"#)
        guard case .response(let id, let result, let error) = message else {
            return XCTFail("expected .response, got \(String(describing: message))")
        }
        XCTAssertEqual(id, .number(1))
        XCTAssertEqual(result?["thread"]?["id"]?.stringValue, "t1")
        XCTAssertNil(error)
    }

    func testClassifiesAnErrorResponse() throws {
        let message = CodexProtocol.classify(line: #"{"id":2,"error":{"code":-32601,"message":"nope"}}"#)
        guard case .response(_, let result, let error) = message else {
            return XCTFail("expected .response")
        }
        XCTAssertNil(result)
        XCTAssertEqual(error?["message"]?.stringValue, "nope")
    }

    func testClassifiesANotificationWithNoID() throws {
        let message = CodexProtocol.classify(
            line: #"{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"Hi"}}"#)
        guard case .notification(let method, let params) = message else {
            return XCTFail("expected .notification")
        }
        XCTAssertEqual(method, "item/agentMessage/delta")
        XCTAssertEqual(params["threadId"]?.stringValue, "t1")
        XCTAssertEqual(params["delta"]?.stringValue, "Hi")
    }

    /// `item/tool/call` is the one server request the parser forwards; its `id` must round-trip
    /// through classification untouched, since the reply has to echo it back verbatim.
    func testClassifiesAServerRequestWithStringID() throws {
        let message = CodexProtocol.classify(
            line: #"{"id":"req-abc","method":"item/tool/call","params":{"threadId":"t1","callId":"c1","tool":"search","arguments":{"q":"x"}}}"#)
        guard case .serverRequest(let id, let method, let params) = message else {
            return XCTFail("expected .serverRequest")
        }
        XCTAssertEqual(id, .string("req-abc"))
        XCTAssertEqual(method, "item/tool/call")
        XCTAssertEqual(params["callId"]?.stringValue, "c1")
    }

    func testUnparseableLineReturnsNil() {
        XCTAssertNil(CodexProtocol.classify(line: "not json"))
        XCTAssertNil(CodexProtocol.classify(line: #"{"foo":"bar"}"#), "no id, no method — not a valid JSON-RPC line")
    }
}

final class JSONValueTests: XCTestCase {

    func testJSONStringRoundTripsAnObject() {
        let value = JSONValue.wrap(dict: ["q": "compactness", "n": 3])
        let parsed = try! JSONSerialization.jsonObject(with: Data(value.jsonString().utf8)) as! [String: Any]
        XCTAssertEqual(parsed["q"] as? String, "compactness")
        XCTAssertEqual(parsed["n"] as? Int, 3)
    }

    func testJSONStringDegradesToEmptyObjectForNonObjectTopLevel() {
        XCTAssertEqual(JSONValue.string("bare").jsonString(), "{}")
    }

    func testSubscriptAndAccessorsNavigateNestedValues() {
        let value = JSONValue.wrap(dict: ["tokenUsage": ["total": ["inputTokens": 10, "outputTokens": 5]]])
        XCTAssertEqual(value["tokenUsage"]?["total"]?["inputTokens"]?.intValue, 10)
        XCTAssertEqual(value["tokenUsage"]?["total"]?["outputTokens"]?.intValue, 5)
        XCTAssertNil(value["missing"])
    }

    /// Regression test: `NSNumber(1) as? Bool` succeeds on Apple platforms, so a naive
    /// `case let b as Bool` check ahead of the `NSNumber` case silently turns a JSON `0`/`1`
    /// into `.bool` instead of `.number` — which then reads as `nil` from `.intValue`
    /// everywhere downstream. This exact bug dropped `outputTokens: 1` and, with it, an entire
    /// usage delta and the baseline update that should have come with it.
    func testIntegerZeroAndOneDecodeAsNumbersNotBooleans() throws {
        let data = try JSONSerialization.data(withJSONObject: ["zero": 0, "one": 1, "flag": true, "ten": 10])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = JSONValue.wrap(dict: obj)
        XCTAssertEqual(value["zero"]?.intValue, 0)
        XCTAssertEqual(value["one"]?.intValue, 1)
        XCTAssertEqual(value["ten"]?.intValue, 10)
        XCTAssertNil(value["zero"]?.boolValue)
        XCTAssertNil(value["one"]?.boolValue)
        XCTAssertEqual(value["flag"]?.boolValue, true)
        XCTAssertNil(value["flag"]?.intValue)
    }
}
