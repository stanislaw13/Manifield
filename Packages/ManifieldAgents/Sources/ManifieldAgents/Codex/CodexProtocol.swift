import Foundation

/// Wire-format helpers for `codex app-server`'s JSON-RPC 2.0 protocol (newline-delimited JSON
/// over stdio, `"jsonrpc"` header omitted — matching what the running binary itself sends and
/// accepts). Everything here is pure: building a request body, or classifying a decoded line.
/// No process, no actor — see `CodexServer` for the transport that uses this.
public enum CodexProtocol {

    /// JSON-RPC ids are `string | integer` on the wire (`RequestId` in the app-server schema).
    /// Server-initiated requests (`item/tool/call`) choose their own id; the reply must echo it
    /// back verbatim, so this has to round-trip either shape rather than assuming an int.
    public enum RequestID: Sendable, Equatable, Hashable {
        case number(Int)
        case string(String)

        var jsonValue: Any {
            switch self {
            case .number(let n): return n
            case .string(let s): return s
            }
        }

        init?(_ any: Any?) {
            switch any {
            case let n as Int: self = .number(n)
            case let n as NSNumber: self = .number(n.intValue)
            case let s as String: self = .string(s)
            default: return nil
            }
        }
    }

    /// A decoded top-level JSON-RPC line, classified by shape. `codex app-server` never sends the
    /// `"jsonrpc"` field, so classification goes purely on which of `id`/`method`/`result`/`error`
    /// are present — the same rule used to write the encoder below.
    enum IncomingMessage: Sendable, Equatable {
        /// A reply to a request *we* sent — has `id` plus `result` or `error`, no `method`.
        case response(id: RequestID, result: [String: JSONValue]?, error: [String: JSONValue]?)
        /// A request *the server* sent that we must reply to — has `id` and `method`.
        case serverRequest(id: RequestID, method: String, params: [String: JSONValue])
        /// A one-way notification — has `method`, no `id`.
        case notification(method: String, params: [String: JSONValue])
    }

    static func classify(line: String) -> IncomingMessage? {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = RequestID(raw["id"])
        let method = raw["method"] as? String
        let params: [String: JSONValue] = (raw["params"] as? [String: Any]).map {
            JSONValue.wrap(dict: $0)
        }.flatMap { $0.objectValue } ?? [:]

        if let method {
            if let id {
                return .serverRequest(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id else { return nil }
        let result = (raw["result"] as? [String: Any]).map { $0.mapValues(JSONValue.wrap) }
        let error = (raw["error"] as? [String: Any]).map { $0.mapValues(JSONValue.wrap) }
        guard result != nil || error != nil else { return nil }
        return .response(id: id, result: result, error: error)
    }

    // MARK: - Outgoing request bodies

    static func initializeParams(clientName: String, clientTitle: String, clientVersion: String) -> [String: Any] {
        [
            "clientInfo": ["name": clientName, "title": clientTitle, "version": clientVersion],
            "capabilities": ["experimentalApi": true]
        ]
    }

    /// `dynamicTools` is experimental-gated — absent unless `initialize` sent
    /// `capabilities.experimentalApi: true`. Every tool is registered as the `function` variant;
    /// Manifield never uses Codex's `namespace` grouping.
    static func threadStartParams(
        model: String,
        cwd: String,
        developerInstructions: String,
        tools: [ToolSpec],
        configOverrides: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "model": model,
            "cwd": cwd,
            "ephemeral": true,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "developerInstructions": developerInstructions,
            "dynamicTools": tools.map { dynamicToolSpec(for: $0) },
            "config": configOverrides
        ]
    }

    private static func dynamicToolSpec(for tool: ToolSpec) -> [String: Any] {
        [
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.schemaObject
        ]
    }

    /// `effort` is sent explicitly on every turn — omitting it would silently inherit whatever
    /// `model_reasoning_effort` the user's own `~/.codex/config.toml` happens to have set.
    static func turnStartParams(
        threadID: String, input: [[String: Any]], effort: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "effort": effort,
            "input": input
        ]
    }

    static func turnStartParams(threadID: String, inputText: String, effort: String) -> [String: Any] {
        turnStartParams(
            threadID: threadID, input: [["type": "text", "text": inputText]], effort: effort)
    }

    static func threadInjectItemsParams(threadID: String, items: [[String: Any]]) -> [String: Any] {
        ["threadId": threadID, "items": items]
    }

    static func turnInterruptParams(threadID: String, turnID: String) -> [String: Any] {
        ["threadId": threadID, "turnId": turnID]
    }

    static func accountReadParams(refreshToken: Bool) -> [String: Any] {
        ["refreshToken": refreshToken]
    }

    /// Reply body for a `item/tool/call` server request. `success: false` still lets the turn
    /// continue — Codex treats it as a tool error the model can react to, the same as an
    /// `AgentTool` throwing does in `AgentLoop`.
    static func toolCallResult(success: Bool, text: String) -> [String: Any] {
        ["success": success, "contentItems": [["type": "inputText", "text": text]]]
    }

    // MARK: - Encoding

    /// One newline-delimited JSON-RPC line, `id` omitted for a notification.
    static func encode(id: RequestID?, method: String, params: [String: Any]) throws -> Data {
        var body: [String: Any] = ["method": method, "params": params]
        if let id { body["id"] = id.jsonValue }
        var data = try JSONSerialization.data(withJSONObject: body)
        data.append(0x0A)
        return data
    }

    static func encodeReply(id: RequestID, result: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["id": id.jsonValue, "result": result])
        data.append(0x0A)
        return data
    }

    static func encodeErrorReply(id: RequestID, code: Int, message: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "id": id.jsonValue, "error": ["code": code, "message": message]
        ])
        data.append(0x0A)
        return data
    }
}

/// A JSON value decoded from `JSONSerialization` output, reboxed as `Sendable` so parsed
/// notification payloads can cross into an `AsyncStream<CodexEvent>` without a `nonisolated(unsafe)`
/// escape hatch. Only as deep as the fields this integration actually reads — never round-tripped
/// back to `[String: Any]` for re-encoding.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    static func wrap(_ any: Any) -> JSONValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            // `as? Bool` is not the reverse-safe check it looks like: an NSNumber boxing 0 or 1
            // (e.g. `outputTokens: 1`) also satisfies `as? Bool` on Apple platforms, silently
            // becoming `.bool(true)` instead of `.number(1.0)` — which then reads as `nil` from
            // `intValue` everywhere downstream. Checking the boxed CF type is what actually
            // distinguishes a JSON `true`/`false` from a JSON `0`/`1`.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let d as [String: Any]: return wrap(dict: d)
        case let a as [Any]: return .array(a.map(wrap))
        default: return .null
        }
    }

    static func wrap(dict: [String: Any]) -> JSONValue {
        .object(dict.mapValues(wrap))
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Round-trips back to a JSON string for the rare fields (tool-call `arguments`) that need
    /// to become an `inputJSON` string rather than staying a typed value. `arguments` is always
    /// a JSON object in practice (every `ToolSpec.schemaObject` declares `type: "object"`), but
    /// this degrades to `"{}"` rather than crashing if a future tool ever didn't.
    func jsonString() -> String {
        let value = unwrapped
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private var unwrapped: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.unwrapped }
        case .array(let a): return a.map { $0.unwrapped }
        case .null: return NSNull()
        }
    }
}
