import Foundation

/// What a Codex turn actually did, translated out of app-server JSON-RPC lines into something
/// `CodexRunner` can build an `AgentTurnResult` from — the Codex analogue of `LLMEvent`.
///
/// Unlike `LLMEvent`, a tool call here is a *request Codex is blocked on*, not a value to record
/// and move past: `toolCallRequested` must eventually be answered (see `CodexServer.respond`),
/// or the app-server waits on it forever. Failure and interruption are not events at all — see
/// `CodexEventParser.handle`, which throws for both, matching how a stream failure already
/// propagates for every other provider.
public enum CodexEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    /// A completed `agentMessage` item. `isFinal` mirrors Codex's `phase` field — `nil` on some
    /// models, in which case the *last* one seen still has to serve as the turn's answer.
    case agentMessageCompleted(text: String, isFinal: Bool)
    case reasoningCompleted(text: String)
    case toolCallRequested(requestID: CodexProtocol.RequestID, callID: String, tool: String, argumentsJSON: String)
    /// Already a delta on input/output tokens for this notification, never the cumulative total
    /// `thread/tokenUsage/updated` actually reports — see `CodexEventParser`'s usage baseline.
    case usage(CodexUsage)
    case turnCompleted

    /// Source-compatible shorthand for synthetic streams and older parser tests.
    public static func usage(input: Int, output: Int) -> Self {
        .usage(CodexUsage(inputTokens: input, outputTokens: output))
    }
}

public struct CodexUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let reasoningOutputTokens: Int
    public let contextWindowTokens: Int?

    public init(
        inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0, reasoningOutputTokens: Int = 0,
        contextWindowTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.contextWindowTokens = contextWindowTokens
    }
}

/// Parses JSON-RPC lines for one Codex thread. One instance per thread — `CodexServer` creates it
/// when the thread starts and feeds it every line for that thread's `AsyncThrowingStream<CodexEvent, Error>`.
/// All state here (the usage baseline, in particular) is thread-scoped by construction: two
/// parsers for two threads never share it, which is what keeps interleaved notifications for
/// concurrent branches from cross-contaminating each other's token counts.
final class CodexEventParser {

    let threadID: String
    private var usageBaseline = CodexUsage(inputTokens: 0, outputTokens: 0)

    init(threadID: String) {
        self.threadID = threadID
    }

    /// Every server request *except* `item/tool/call` is intercepted and auto-denied by
    /// `CodexServer` before it ever reaches a parser (see its dispatch loop) — that guarantee
    /// does not depend on this parser recognizing every method, only on `item/tool/call` being
    /// the one method `CodexServer` forwards. A `.response` line is never handed to a parser
    /// either: `CodexServer` resolves those against its own pending-request table directly.
    ///
    /// Throws `AgentError.api` for a failed turn and `CancellationError` for an interrupted one —
    /// `CodexServer` turns either into `continuation.finish(throwing:)`, so `CodexRunner` sees
    /// exactly the same shape it already handles from `AgentLoop`: a `for try await` loop that
    /// throws instead of a value event it would otherwise have to check for.
    func handle(line: String) throws -> [CodexEvent] {
        guard let message = CodexProtocol.classify(line: line) else { return [] }
        switch message {
        case .notification(let method, let params):
            guard params["threadId"]?.stringValue == threadID else { return [] }
            return try handleNotification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            guard method == "item/tool/call", params["threadId"]?.stringValue == threadID else { return [] }
            return handleToolCall(id: id, params: params)
        case .response:
            return []
        }
    }

    private func handleNotification(method: String, params: [String: JSONValue]) throws -> [CodexEvent] {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.textDelta(delta)]
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = params["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.thinkingDelta(delta)]
        case "item/completed":
            return itemCompleted(params)
        case "thread/tokenUsage/updated":
            return usageUpdated(params)
        case "turn/completed":
            return try turnCompleted(params)
        case "error":
            // A retriable notification describes an attempt, not the turn's terminal state.
            // Keep consuming until Codex either succeeds or sends a non-retriable error.
            if params["willRetry"]?.boolValue == true { return [] }
            throw AgentError.api(params["error"]?.objectValue?["message"]?.stringValue ?? "codex reported an error")
        default:
            return []
        }
    }

    private func itemCompleted(_ params: [String: JSONValue]) -> [CodexEvent] {
        guard let item = params["item"]?.objectValue, let type = item["type"]?.stringValue else { return [] }
        switch type {
        case "agentMessage":
            guard let text = item["text"]?.stringValue else { return [] }
            return [.agentMessageCompleted(text: text, isFinal: item["phase"]?.stringValue == "final_answer")]
        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !summary.isEmpty else { return [] }
            return [.reasoningCompleted(text: summary.joined(separator: "\n"))]
        default:
            // commandExecution, webSearch, dynamicToolCall, etc. never enter the transcript.
            // dynamicToolCall's id/tool/arguments already came through the item/tool/call
            // request — reading them again here would be a second, redundant source of truth.
            return []
        }
    }

    private func usageUpdated(_ params: [String: JSONValue]) -> [CodexEvent] {
        guard let total = params["tokenUsage"]?["total"]?.objectValue,
              let input = total["inputTokens"]?.intValue,
              let output = total["outputTokens"]?.intValue
        else { return [] }
        let current = CodexUsage(
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: total["cachedInputTokens"]?.intValue ?? 0,
            cacheWriteInputTokens: total["cacheWriteInputTokens"]?.intValue ?? 0,
            reasoningOutputTokens: total["reasoningOutputTokens"]?.intValue ?? 0,
            contextWindowTokens: params["tokenUsage"]?["modelContextWindow"]?.intValue ?? params["modelContextWindow"]?.intValue)
        let delta = CodexUsage(
            inputTokens: max(0, current.inputTokens - usageBaseline.inputTokens),
            outputTokens: max(0, current.outputTokens - usageBaseline.outputTokens),
            cachedInputTokens: max(0, current.cachedInputTokens - usageBaseline.cachedInputTokens),
            cacheWriteInputTokens: max(0, current.cacheWriteInputTokens - usageBaseline.cacheWriteInputTokens),
            reasoningOutputTokens: max(0, current.reasoningOutputTokens - usageBaseline.reasoningOutputTokens),
            contextWindowTokens: current.contextWindowTokens)
        usageBaseline = current
        guard delta.inputTokens > 0 || delta.outputTokens > 0 || delta.cachedInputTokens > 0
                || delta.cacheWriteInputTokens > 0 || delta.reasoningOutputTokens > 0
                || delta.contextWindowTokens != nil
        else { return [] }
        return [.usage(delta)]
    }

    private func turnCompleted(_ params: [String: JSONValue]) throws -> [CodexEvent] {
        guard let turn = params["turn"]?.objectValue, let status = turn["status"]?.stringValue else { return [] }
        switch status {
        case "completed":
            return [.turnCompleted]
        case "interrupted":
            throw CancellationError()
        case "failed":
            throw AgentError.api(turn["error"]?.objectValue?["message"]?.stringValue ?? "codex turn failed")
        default:
            return []
        }
    }

    private func handleToolCall(id: CodexProtocol.RequestID, params: [String: JSONValue]) -> [CodexEvent] {
        guard let callID = params["callId"]?.stringValue, let tool = params["tool"]?.stringValue else { return [] }
        let argumentsJSON = params["arguments"]?.jsonString() ?? "{}"
        return [.toolCallRequested(requestID: id, callID: callID, tool: tool, argumentsJSON: argumentsJSON)]
    }
}
