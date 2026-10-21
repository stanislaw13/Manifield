import Foundation

/// Chat Completions streaming provider. Covers OpenAI directly and Gemini through
/// its OpenAI-compatible endpoint.
public struct OpenAICompatProvider: LLMProvider {

    let config: ProviderConfig
    let baseURL: URL

    public var description: String { "\(config.kind.displayName) \(config.model)" }

    public init(config: ProviderConfig, baseURL: URL) {
        self.config = config
        self.baseURL = baseURL
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamWithReasoningFallback(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a Chat Completions turn, transparently handling models that reject
    /// `reasoning_effort` alongside function tools (e.g. gpt-5.6-sol). Such a model 400s before
    /// any event is yielded, so the turn can be cleanly re-issued: on OpenAI we escalate to the
    /// Responses API, keeping reasoning *and* tools; on providers without it (Gemini/xAI/z.ai)
    /// we fall back to reasoning off so tool calls still work.
    private func streamWithReasoningFallback(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let mayConflict = request.thinking != .off && !request.tools.isEmpty

        // A model already known (this run) to need the Responses API skips the doomed Chat
        // Completions attempt entirely, sparing every later tool-loop turn a wasted 400.
        if mayConflict, config.kind.supportsResponsesAPI,
           await ResponsesAPIEscalation.shared.isRequired(config.model) {
            try await streamViaResponsesAPI(request, into: continuation)
            return
        }

        do {
            try await runAttempt(request, forceReasoningOff: false, into: continuation)
        } catch AgentError.http(let status, let body)
            where status == 400 && mayConflict && body.contains("reasoning_effort") {
            if config.kind.supportsResponsesAPI {
                await ResponsesAPIEscalation.shared.markRequired(config.model)
                try await streamViaResponsesAPI(request, into: continuation)
            } else {
                try await runAttempt(request, forceReasoningOff: true, into: continuation)
            }
        }
    }

    /// Forwards a Responses API stream (reasoning + tools together) through this continuation.
    private func streamViaResponsesAPI(
        _ request: LLMRequest,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let provider = OpenAIResponsesProvider(config: config, baseURL: baseURL)
        for try await event in provider.stream(request) {
            continuation.yield(event)
        }
    }

    /// Runs one Chat Completions request and forwards its parsed events. A non-200 status is
    /// raised before any event is yielded, which lets `stream` retry cleanly without double output.
    private func runAttempt(
        _ request: LLMRequest,
        forceReasoningOff: Bool,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(request, forceReasoningOff: forceReasoningOff)
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4000 { break }
            }
            throw AgentError.http(status, body)
        }
        let parser = OpenAIStreamParser()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            for event in parser.handle(dataLine: payload) {
                continuation.yield(event)
            }
        }
        for event in parser.flush() {
            continuation.yield(event)
        }
    }

    /// Lists models available to this API key via GET {baseURL}/models.
    public static func listModels(apiKey: String, baseURL: URL) async throws -> [ModelOption] {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("models"))
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AgentError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct Entry: Decodable { let id: String }
        struct List: Decodable { let data: [Entry] }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.data.map { ModelOption(id: $0.id, displayName: $0.id) }.sorted { $0.id < $1.id }
    }

    func makeURLRequest(_ request: LLMRequest, forceReasoningOff: Bool = false) throws -> URLRequest {
        var messages: [[String: Any]] = [["role": "system", "content": request.system.text]]

        for message in request.messages {
            switch message.role {
            case .user:
                // Tool results become separate role:"tool" messages in this dialect.
                // Text/document/image blocks merge into one user message; the array
                // content form is only used when an image forces it.
                var parts: [[String: Any]] = []
                var hasImage = false
                for block in message.blocks {
                    switch block {
                    case .toolResult(let toolUseID, let content, let isError):
                        messages.append([
                            "role": "tool",
                            "tool_call_id": toolUseID,
                            "content": isError ? "ERROR: \(content)" : content
                        ])
                    case .text(let text) where !text.isEmpty:
                        parts.append(["type": "text", "text": text])
                    case .document(let name, let text):
                        parts.append(["type": "text",
                                      "text": "[Attached file: \(name)]\n\n\(text)"])
                    case .image(let mediaType, let base64):
                        hasImage = true
                        parts.append(["type": "image_url",
                                      "image_url": ["url": "data:\(mediaType);base64,\(base64)"]])
                    default:
                        break
                    }
                }
                if !parts.isEmpty {
                    if hasImage {
                        messages.append(["role": "user", "content": parts])
                    } else {
                        let text = parts.compactMap { $0["text"] as? String }
                            .joined(separator: "\n\n")
                        messages.append(["role": "user", "content": text])
                    }
                }
            case .assistant:
                var text = ""
                var toolCalls: [[String: Any]] = []
                for block in message.blocks {
                    switch block {
                    case .text(let t): text += t
                    case .toolUse(let id, let name, let inputJSON):
                        toolCalls.append([
                            "id": id, "type": "function",
                            "function": ["name": name, "arguments": inputJSON]
                        ])
                    case .toolResult: break
                    // Chat Completions has no channel for replaying reasoning; the
                    // assistant never produces image/document blocks.
                    case .thinking, .redactedThinking, .reasoningItem, .image, .document: break
                    }
                }
                var msg: [String: Any] = ["role": "assistant", "content": text]
                if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
                messages.append(msg)
            }
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if forceReasoningOff {
            // Fallback for models that reject reasoning_effort alongside function tools on
            // /v1/chat/completions; "none" is the value such models bless for tool use.
            body["reasoning_effort"] = "none"
        } else if request.thinking != .off {
            // Most reasoning models across OpenAI/Gemini/xAI/z.ai accept reasoning_effort;
            // non-reasoning models ignore the unknown field.
            body["reasoning_effort"] = request.thinking.rawValue
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map {
                ["type": "function",
                 "function": ["name": $0.name, "description": $0.description,
                              "parameters": $0.schemaObject]]
            }
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}

/// Stateful parser for Chat Completions streaming chunks (unit-tested separately).
final class OpenAIStreamParser {

    private struct PartialCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
        var announced = false
    }

    private var calls: [Int: PartialCall] = [:]
    private var finishReason: String?
    private var usageEvent: LLMEvent?

    func handle(dataLine: String) -> [LLMEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(dataLine.utf8)) as? [String: Any]
        else { return [] }

        var events: [LLMEvent] = []

        if let usage = obj["usage"] as? [String: Any],
           let input = usage["prompt_tokens"] as? Int,
           let output = usage["completion_tokens"] as? Int {
            usageEvent = .usage(input: input, output: output)
        }

        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return events }

        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.textDelta(content))
            }
            // DeepSeek-style streamed reasoning (also GLM); not all providers send it.
            if let reasoning = (delta["reasoning_content"] as? String)
                ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                events.append(.thinkingDelta(reasoning))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                var partial = calls[index] ?? PartialCall()
                if let id = call["id"] as? String { partial.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String { partial.name += name }
                    if let args = function["arguments"] as? String { partial.arguments += args }
                }
                if !partial.announced, !partial.id.isEmpty, !partial.name.isEmpty {
                    partial.announced = true
                    events.append(.toolUseStarted(id: partial.id, name: partial.name))
                }
                calls[index] = partial
            }
        }

        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
        }
        return events
    }

    /// Called after the stream ends ([DONE]); emits completed tool calls, usage and stop reason.
    func flush() -> [LLMEvent] {
        var events: [LLMEvent] = []
        for index in calls.keys.sorted() {
            guard let call = calls[index], !call.id.isEmpty else { continue }
            events.append(.toolUseFinished(
                id: call.id,
                name: call.name,
                inputJSON: call.arguments.isEmpty ? "{}" : call.arguments
            ))
        }
        calls.removeAll()
        if let usageEvent { events.append(usageEvent) }
        switch finishReason {
        case "tool_calls", "function_call": events.append(.finished(.toolUse))
        case "stop", .none: events.append(.finished(.endTurn))
        case "length": events.append(.finished(.maxTokens))
        case .some(let other): events.append(.finished(.other(other)))
        }
        return events
    }
}

/// Remembers, for this process, which model ids rejected `reasoning_effort` alongside function
/// tools on Chat Completions, so later turns route straight to the Responses API instead of
/// eating a 400 each time. Monotonic (only ever gains entries) and cheap to consult.
actor ResponsesAPIEscalation {
    static let shared = ResponsesAPIEscalation()
    private var requiredModels: Set<String> = []
    func isRequired(_ model: String) -> Bool { requiredModels.contains(model) }
    func markRequired(_ model: String) { requiredModels.insert(model) }
}
