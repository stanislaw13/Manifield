import Foundation

/// `[LLMMessage] -> Responses API item` — shared by `OpenAIResponsesProvider` (over HTTP) and
/// `CodexHistoryReplay` (over `thread/inject_items`), so this mapping is guarded by
/// `ResponsesAPITests` for both consumers rather than living twice. Tool results become
/// `function_call_output` items; a reasoning item must precede the `function_call` it belongs to,
/// so block order within a message is preserved verbatim.
func responsesItems(for messages: [LLMMessage]) -> [[String: Any]] {
    var input: [[String: Any]] = []
    for message in messages {
        switch message.role {
        case .user:
            // Tool results become their own function_call_output items in this dialect.
            for block in message.blocks {
                switch block {
                case .toolResult(let toolUseID, let content, let isError):
                    input.append([
                        "type": "function_call_output",
                        "call_id": toolUseID,
                        "output": isError ? "ERROR: \(content)" : content
                    ])
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    input.append([
                        "type": "message", "role": "user",
                        "content": [["type": "input_text", "text": text]]
                    ])
                case .document(let name, let text):
                    input.append([
                        "type": "message", "role": "user",
                        "content": [["type": "input_text",
                                     "text": "[Attached file: \(name)]\n\n\(text)"]]
                    ])
                case .image(let mediaType, let base64):
                    input.append([
                        "type": "message", "role": "user",
                        "content": [["type": "input_image",
                                     "image_url": "data:\(mediaType);base64,\(base64)"]]
                    ])
                case .toolUse, .thinking, .redactedThinking, .reasoningItem:
                    break
                }
            }
        case .assistant:
            // Preserve block order: a reasoning item must precede the function_call it belongs
            // to, otherwise the API rejects the pair.
            for block in message.blocks {
                switch block {
                case .reasoningItem(let id, let encryptedContent):
                    input.append([
                        "type": "reasoning", "id": id,
                        "summary": [],
                        "encrypted_content": encryptedContent
                    ])
                case .text(let text):
                    guard !text.isEmpty else { continue }
                    input.append([
                        "type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": text]]
                    ])
                case .toolUse(let id, let name, let inputJSON):
                    input.append([
                        "type": "function_call",
                        "call_id": id, "name": name, "arguments": inputJSON
                    ])
                // Anthropic-style thinking blocks have no Responses channel; the
                // assistant never produces image/document blocks.
                case .thinking, .redactedThinking, .toolResult, .image, .document:
                    break
                }
            }
        }
    }
    return input
}

/// Streaming provider for OpenAI's Responses API (`/v1/responses`). Used only for models that
/// reject `reasoning_effort` alongside function tools on Chat Completions (e.g. gpt-5.6-sol):
/// there, the Responses API is the sole way to combine tool use with reasoning.
///
/// It runs statelessly (`store: false`) to match the app's replay-the-full-history model. The
/// model's reasoning is returned as opaque, encrypted items (`include:
/// ["reasoning.encrypted_content"]`) which are echoed back on later tool-loop turns so the chain
/// of thought survives — the API requires the reasoning item that precedes a `function_call` to
/// travel with it. `OpenAICompatProvider` escalates to this provider on demand; nothing else
/// constructs it directly.
struct OpenAIResponsesProvider: LLMProvider {

    let config: ProviderConfig
    let baseURL: URL

    var description: String { "\(config.kind.displayName) \(config.model) (Responses API)" }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
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
                    let parser = OpenAIResponsesParser()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        for event in try parser.handle(dataLine: payload) {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.flush() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: LLMRequest) throws -> URLRequest {
        var body: [String: Any] = [
            "model": config.model,
            "instructions": request.system.text,
            "input": responsesItems(for: request.messages),
            "stream": true,
            // Stateless: we replay the whole history each turn, so the server keeps nothing.
            "store": false
        ]
        if request.thinking != .off {
            body["reasoning"] = ["effort": request.thinking.rawValue]
            // Ask for the encrypted reasoning so it can be replayed on later tool-loop turns
            // without server-side state.
            body["include"] = ["reasoning.encrypted_content"]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map {
                ["type": "function", "name": $0.name,
                 "description": $0.description, "parameters": $0.schemaObject]
            }
        }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}

/// Stateful parser for Responses API streaming events (unit-tested separately). Each SSE `data:`
/// payload is a JSON object whose `type` names the event; text, tool calls and reasoning items
/// are emitted in stream order so replay ordering is preserved, while usage and the stop reason
/// are held back until `flush()`.
final class OpenAIResponsesParser {

    private struct PartialCall {
        var callID: String = ""
        var name: String = ""
        var arguments: String = ""
        var finished = false
    }

    private var callsByIndex: [Int: PartialCall] = [:]
    private var sawFunctionCall = false
    private var usageEvent: LLMEvent?
    private var stop: StopReason?

    func handle(dataLine: String) throws -> [LLMEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(dataLine.utf8)) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "response.output_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty { return [.textDelta(delta)] }
        case "response.reasoning_summary_text.delta":
            // Present only when reasoning summaries are requested; surfaces live reasoning text.
            if let delta = obj["delta"] as? String, !delta.isEmpty { return [.thinkingDelta(delta)] }
        case "response.output_item.added":
            return itemAdded(obj)
        case "response.function_call_arguments.delta":
            if let index = obj["output_index"] as? Int, let delta = obj["delta"] as? String {
                callsByIndex[index, default: PartialCall()].arguments += delta
            }
        case "response.output_item.done":
            return itemDone(obj)
        case "response.completed":
            captureUsage(obj)
            stop = sawFunctionCall ? .toolUse : .endTurn
        case "response.incomplete":
            captureUsage(obj)
            stop = .maxTokens
        case "response.failed", "error":
            throw AgentError.api(Self.errorMessage(obj))
        default:
            break
        }
        return []
    }

    /// Announces a function call as soon as its item appears (id + name are known then).
    private func itemAdded(_ obj: [String: Any]) -> [LLMEvent] {
        guard let item = obj["item"] as? [String: Any],
              item["type"] as? String == "function_call",
              let index = obj["output_index"] as? Int else { return [] }
        let callID = item["call_id"] as? String ?? ""
        let name = item["name"] as? String ?? ""
        callsByIndex[index] = PartialCall(
            callID: callID, name: name, arguments: item["arguments"] as? String ?? "")
        sawFunctionCall = true
        guard !callID.isEmpty, !name.isEmpty else { return [] }
        return [.toolUseStarted(id: callID, name: name)]
    }

    /// Finalizes an output item: reasoning → replayable encrypted block; function_call → tool use.
    private func itemDone(_ obj: [String: Any]) -> [LLMEvent] {
        guard let item = obj["item"] as? [String: Any],
              let itemType = item["type"] as? String else { return [] }
        switch itemType {
        case "reasoning":
            guard let id = item["id"] as? String,
                  let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty
            else { return [] }
            return [.reasoningItemFinished(id: id, encryptedContent: encrypted)]
        case "function_call":
            let index = obj["output_index"] as? Int ?? -1
            let partial = callsByIndex[index]
            let callID = item["call_id"] as? String ?? partial?.callID ?? ""
            let name = item["name"] as? String ?? partial?.name ?? ""
            let arguments = (item["arguments"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? partial?.arguments ?? ""
            callsByIndex[index]?.finished = true
            sawFunctionCall = true
            guard !callID.isEmpty else { return [] }
            return [.toolUseFinished(
                id: callID, name: name, inputJSON: arguments.isEmpty ? "{}" : arguments)]
        default:
            return []
        }
    }

    private func captureUsage(_ obj: [String: Any]) {
        guard let response = obj["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return }
        usageEvent = .usage(input: input, output: output)
    }

    private static func errorMessage(_ obj: [String: Any]) -> String {
        if let response = obj["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let message = obj["message"] as? String { return message }
        return "Responses API stream failed"
    }

    /// Emits any tool call that never received an explicit done event, then usage and stop reason.
    func flush() -> [LLMEvent] {
        var events: [LLMEvent] = []
        for index in callsByIndex.keys.sorted() {
            guard let call = callsByIndex[index], !call.finished, !call.callID.isEmpty else { continue }
            events.append(.toolUseFinished(
                id: call.callID, name: call.name,
                inputJSON: call.arguments.isEmpty ? "{}" : call.arguments))
        }
        callsByIndex.removeAll()
        if let usageEvent { events.append(usageEvent) }
        // If the stream ended without an explicit completed/incomplete event, infer the reason:
        // pending tool calls mean the loop must continue, otherwise treat it as a finished turn.
        events.append(.finished(stop ?? (sawFunctionCall ? .toolUse : .endTurn)))
        return events
    }
}
