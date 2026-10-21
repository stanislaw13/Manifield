import Foundation

/// Anthropic Messages API with SSE streaming and tool use.
public struct AnthropicProvider: LLMProvider {

    let config: ProviderConfig
    let baseURL = URL(string: "https://api.anthropic.com/v1")!

    public var description: String { "Anthropic \(config.model)" }

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request)
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
                    let parser = AnthropicStreamParser()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        for event in try parser.handle(dataLine: payload) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists models available to this API key via GET /v1/models.
    public static func listModels(apiKey: String) async throws -> [ModelOption] {
        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AgentError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        struct Entry: Decodable {
            let id: String
            let displayName: String?
            enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
        }
        struct List: Decodable { let data: [Entry] }
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.data.map {
            ModelOption(id: $0.id, displayName: ($0.displayName ?? $0.id).replacingOccurrences(of: "Claude ", with: ""))
        }
    }

    /// How thinking is requested for a given Anthropic model generation.
    enum ThinkingStrategy {
        /// Adaptive thinking + output_config.effort (Claude 4.6 and newer).
        case adaptive
        /// Explicit token budget: thinking {type: enabled, budget_tokens} (older models).
        case budget
    }

    /// Adaptive thinking exists on Claude ≥ 4.6 (Opus 4.6+, Sonnet 4.6+/5, Fable/Mythos);
    /// budget_tokens is REMOVED there (400) but still required on older models. Unknown
    /// ids default to adaptive — future models will be 4.6+.
    static func thinkingStrategy(forModel model: String) -> ThinkingStrategy {
        let id = model.lowercased()
        if id.contains("fable") || id.contains("mythos") { return .adaptive }
        if id.hasPrefix("claude-2") || id.hasPrefix("claude-3") { return .budget }
        if id.contains("haiku") { return .budget }   // Haiku 4.5 has no adaptive/effort
        for family in ["opus", "sonnet"] {
            guard let version = versionNumber(after: family, in: id) else { continue }
            return version >= 4.6 ? .adaptive : .budget
        }
        return .adaptive
    }

    /// Version parsed from ids like "claude-opus-4-8" (→ 4.8) or "claude-sonnet-5" (→ 5.0);
    /// date suffixes ("-20251001") are ignored. Nil when the family isn't present.
    static func versionNumber(after family: String, in id: String) -> Double? {
        let parts = id.split(separator: "-").map(String.init)
        guard let index = parts.firstIndex(of: family) else { return nil }
        let numbers = parts.dropFirst(index + 1).prefix(2)
            .compactMap { Int($0) }
            .filter { $0 < 100 }   // skip date stamps
        guard let major = numbers.first else { return nil }
        let minor = numbers.count > 1 ? Double(numbers[1]) / 10.0 : 0
        return Double(major) + minor
    }

    func makeURLRequest(_ request: LLMRequest) throws -> URLRequest {
        var messages: [[String: Any]] = []
        for message in request.messages {
            var blocks: [[String: Any]] = []
            for block in message.blocks {
                switch block {
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    blocks.append(["type": "text", "text": text])
                case .toolUse(let id, let name, let inputJSON):
                    blocks.append(["type": "tool_use", "id": id, "name": name,
                                   "input": jsonObject(inputJSON)])
                case .toolResult(let toolUseID, let content, let isError):
                    blocks.append(["type": "tool_result", "tool_use_id": toolUseID,
                                   "content": content, "is_error": isError])
                case .thinking(let text, let signature):
                    // Replayed verbatim in tool loops; an unsigned block can't be
                    // verified by the API, so it is omitted rather than rejected.
                    guard let signature, !signature.isEmpty else { continue }
                    blocks.append(["type": "thinking", "thinking": text,
                                   "signature": signature])
                case .redactedThinking(let data):
                    blocks.append(["type": "redacted_thinking", "data": data])
                case .reasoningItem:
                    // OpenAI Responses reasoning; no Anthropic Messages channel for it.
                    continue
                case .image(let mediaType, let base64):
                    blocks.append(["type": "image",
                                   "source": ["type": "base64", "media_type": mediaType,
                                              "data": base64]])
                case .document(let name, let text):
                    blocks.append(["type": "text",
                                   "text": "[Attached file: \(name)]\n\n\(text)"])
                }
            }
            guard !blocks.isEmpty else { continue }
            messages.append(["role": message.role.rawValue, "content": blocks])
        }
        Self.markConversationCacheBreakpoint(&messages)

        var maxTokens = request.maxTokens
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true
        ]
        let segments = request.system.segments
        if segments.isEmpty {
            body["system"] = ""
        } else {
            // Block form, not a plain string, so the system prompt can carry a cache
            // breakpoint. It ends the *stable* block and so covers tools + instructions
            // together (prefix order is tools → system → messages); everything volatile —
            // research memory, access grants, the library outline — sits in the block
            // after it, where rewriting it still reads the instructions from cache.
            var blocks = segments.map { ["type": "text", "text": $0] as [String: Any] }
            blocks[0]["cache_control"] = ["type": "ephemeral"]
            body["system"] = blocks
        }
        if request.thinking != .off {
            switch Self.thinkingStrategy(forModel: config.model) {
            case .adaptive:
                // display: summarized so the UI can stream the reasoning; on 4.7+
                // the default ("omitted") returns thinking blocks with empty text.
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
                body["output_config"] = ["effort": request.thinking.rawValue]
                maxTokens = max(maxTokens, request.thinking.recommendedMinimumMaxTokens)
            case .budget:
                let budget = request.thinking.budgetTokens
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                // budget must be strictly below max_tokens; keep under Haiku's 64K cap.
                maxTokens = max(maxTokens, budget + 16_384)
            }
        }
        body["max_tokens"] = maxTokens
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = request.tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.schemaObject]
            }
            // Breakpoint on the last tool keeps the tool prefix cached even when the
            // system prompt changes between turns (memory edits, full-text grants).
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = tools
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Block types that may carry cache_control (thinking blocks may not).
    private static let cacheableBlockTypes: Set<String> =
        ["text", "image", "tool_use", "tool_result", "document"]

    /// Marks the last block of the last message as a cache breakpoint, so each
    /// tool-loop iteration and follow-up turn re-reads the whole conversation
    /// prefix from cache (~0.1x input price) instead of re-paying it in full.
    /// The marker moves forward every request; the API finds the previous
    /// entry by looking back up to 20 blocks, which consecutive requests
    /// always satisfy because they extend the history by one exchange.
    static func markConversationCacheBreakpoint(_ messages: inout [[String: Any]]) {
        guard let messageIndex = messages.indices.last,
              var blocks = messages[messageIndex]["content"] as? [[String: Any]],
              let blockIndex = blocks.indices.last,
              let type = blocks[blockIndex]["type"] as? String,
              cacheableBlockTypes.contains(type) else { return }
        blocks[blockIndex]["cache_control"] = ["type": "ephemeral"]
        messages[messageIndex]["content"] = blocks
    }
}

/// Stateful parser for Anthropic SSE `data:` payloads. Factored out of the network path
/// so it can be unit-tested against canned event streams.
final class AnthropicStreamParser {

    private struct ToolBlock {
        let id: String
        let name: String
        var partialJSON: String = ""
    }

    private struct ThinkingBlock {
        var text: String = ""
        var signature: String = ""
        /// Set for redacted_thinking blocks (encrypted payload, no text).
        var redactedData: String?
    }

    private var toolBlocks: [Int: ToolBlock] = [:]
    private var thinkingBlocks: [Int: ThinkingBlock] = [:]
    private var inputTokens = 0

    func handle(dataLine: String) throws -> [LLMEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(dataLine.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        switch type {
        case "message_start":
            if let message = obj["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                // input_tokens is only the uncached remainder — add cache reads and
                // writes so the reported figure is the full context size.
                inputTokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            }
            return []

        case "content_block_start":
            guard let index = obj["index"] as? Int,
                  let block = obj["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return [] }
            switch blockType {
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String else { return [] }
                toolBlocks[index] = ToolBlock(id: id, name: name)
                return [.toolUseStarted(id: id, name: name)]
            case "thinking":
                thinkingBlocks[index] = ThinkingBlock(
                    text: block["thinking"] as? String ?? "")
                return []
            case "redacted_thinking":
                thinkingBlocks[index] = ThinkingBlock(
                    redactedData: block["data"] as? String ?? "")
                return []
            default:
                return []
            }

        case "content_block_delta":
            guard let index = obj["index"] as? Int,
                  let delta = obj["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String else { return [] }
                return [.textDelta(text)]
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    toolBlocks[index]?.partialJSON += partial
                }
                return []
            case "thinking_delta":
                guard let text = delta["thinking"] as? String else { return [] }
                thinkingBlocks[index]?.text += text
                return [.thinkingDelta(text)]
            case "signature_delta":
                if let signature = delta["signature"] as? String {
                    thinkingBlocks[index]?.signature += signature
                }
                return []
            default:
                return []
            }

        case "content_block_stop":
            guard let index = obj["index"] as? Int else { return [] }
            if let block = toolBlocks.removeValue(forKey: index) {
                let input = block.partialJSON.isEmpty ? "{}" : block.partialJSON
                return [.toolUseFinished(id: block.id, name: block.name, inputJSON: input)]
            }
            if let block = thinkingBlocks.removeValue(forKey: index) {
                if let data = block.redactedData {
                    return [.redactedThinking(data: data)]
                }
                return [.thinkingFinished(
                    text: block.text,
                    signature: block.signature.isEmpty ? nil : block.signature)]
            }
            return []

        case "message_delta":
            var events: [LLMEvent] = []
            if let usage = obj["usage"] as? [String: Any],
               let output = usage["output_tokens"] as? Int {
                events.append(.usage(input: inputTokens, output: output))
            }
            if let delta = obj["delta"] as? [String: Any],
               let stopRaw = delta["stop_reason"] as? String {
                let reason: StopReason
                switch stopRaw {
                case "end_turn", "stop_sequence": reason = .endTurn
                case "tool_use": reason = .toolUse
                case "max_tokens": reason = .maxTokens
                default: reason = .other(stopRaw)
                }
                events.append(.finished(reason))
            }
            return events

        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? dataLine
            throw AgentError.api(message)

        default:
            return []
        }
    }
}
