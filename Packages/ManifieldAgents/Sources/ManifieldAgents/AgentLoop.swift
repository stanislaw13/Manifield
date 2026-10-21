import Foundation

public struct AgentConfig {
    public var systemPrompt: SystemPrompt
    public var tools: [AgentTool]
    /// Safety cap on individual tool calls per turn, including calls in a batch.
    /// Pass `unlimitedIterations` to opt out — the turn then runs until the model stops
    /// calling tools on its own instead of being cut off.
    public var maxIterations: Int
    public var maxTokens: Int
    /// How hard the model thinks; providers map it to their native parameter.
    public var thinking: ThinkingLevel
    public var stopOnToolEffect: Bool = false
    public var checkpoint: (@Sendable ([LLMMessage]) async throws -> Void)?
    public var boundaryMessages: (@Sendable () async throws -> [LLMMessage])?
    public var beforeProviderCall: (@Sendable () async throws -> Void)?
    /// Return at a completed tool boundary so the caller can compact authoritative history.
    public var contextTokenThreshold: Int?
    /// Opt-in native provider continuity. A changed epoch means discarded history must be forgotten.
    public var sessionKey: String?
    public var sessionEpoch: Int = 0

    /// `maxIterations` value that removes the cap in practice (both `AgentLoop` and
    /// `CodexRunner` key off this field directly, so there's no separate "no limit" case
    /// to thread through — a bound this high is never reached).
    public static let unlimitedIterations = Int.max

    public func estimatedContextTokens(history: [LLMMessage]) -> Int {
        let toolCharacters = tools.reduce(0) { $0 + $1.spec.name.count + $1.spec.description.count + $1.spec.inputSchemaJSON.count }
        return BranchConversation(system: systemPrompt.text, messages: history).estimatedTokens + (toolCharacters + 3) / 4
    }

    public init(systemPrompt: SystemPrompt, tools: [AgentTool] = [], maxIterations: Int = 12,
                maxTokens: Int = 8192, thinking: ThinkingLevel = .off) {
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.maxIterations = maxIterations
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

/// UI-facing progress events emitted while an agent turn runs.
public enum AgentActivity: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolStarted(name: String, summary: String)
    case toolFinished(name: String, resultPreview: String, isError: Bool)
    case usage(input: Int, output: Int)
    /// Provider-specific usage detail beyond the portable input/output totals. Codex currently
    /// supplies all fields; HTTP providers may omit this event until their parsers expose them.
    case usageDetails(AgentUsageDetails)
    case iterationLimitReached
}

public struct AgentUsageDetails: Sendable, Equatable {
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let reasoningOutputTokens: Int
    public let contextWindowTokens: Int?

    public init(
        cachedInputTokens: Int, cacheWriteInputTokens: Int,
        reasoningOutputTokens: Int, contextWindowTokens: Int?
    ) {
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.contextWindowTokens = contextWindowTokens
    }
}

public enum AgentTurnStop: String, Codable, Sendable { case completed, toolCompleted, suspended, toolLimit, contextBoundary }

public struct AgentTurnResult {
    /// Text of the final assistant message.
    public let finalText: String
    /// Full transcript including tool calls/results, ready to persist as history.
    public let transcript: [LLMMessage]
    public let stop: AgentTurnStop
    public init(finalText: String, transcript: [LLMMessage], stop: AgentTurnStop = .completed) {
        self.finalText = finalText; self.transcript = transcript; self.stop = stop
    }
}

/// Runs one agent turn to completion: send config + history, get back the final text and
/// the transcript ready to persist or feed into the next turn.
///
/// `AgentLoop` (a request/response `LLMProvider` driven through the tool loop below) is one
/// conformance. `CodexRunner` (an OpenAI Codex session running its own tool loop internally,
/// authenticated with a ChatGPT account instead of an API key) is another — see
/// `Codex/CodexRunner.swift`. Both produce the same `AgentTurnResult` shape, so every call site
/// in the app is agnostic to which is actually running.
public protocol AgentRunner: Sendable {
    var description: String { get }
    func run(
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult
}

extension AgentRunner {
    /// Convenience for the common case where nobody is listening to progress — a protocol
    /// requirement can't carry a default argument, so this restores the one `AgentLoop.run`
    /// used to have.
    public func run(config: AgentConfig, history: [LLMMessage]) async throws -> AgentTurnResult {
        try await run(config: config, history: history, onActivity: { _ in })
    }
}

/// The generic tool-use loop: send → (execute tools → send)* → final text.
/// Every role agent (chat, organizer, later prover/reviewer) is this loop with
/// a different system prompt and tool subset.
public final class AgentLoop: AgentRunner, Sendable {

    private let provider: LLMProvider

    public init(provider: LLMProvider) {
        self.provider = provider
    }

    public var description: String { provider.description }

    public func run(
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> AgentTurnResult {

        var messages = history
        var lastText = ""

        var callsUsed = 0
        let limit = max(config.maxIterations, 1)
        while callsUsed < limit {
            try Task.checkCancellation()
            try await config.beforeProviderCall?()

            let request = LLMRequest(
                system: config.systemPrompt,
                messages: messages,
                tools: config.tools.map(\.spec),
                maxTokens: config.maxTokens,
                thinking: config.thinking
            )

            // Blocks are assembled in stream order: thinking blocks must be replayed
            // in their original position (the API verifies them by signature).
            var blocks: [ContentBlock] = []
            var text = ""
            var toolCalls: [(id: String, name: String, inputJSON: String)] = []
            var stop: StopReason = .endTurn

            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    if case .text(let existing) = blocks.last {
                        blocks[blocks.count - 1] = .text(existing + delta)
                    } else {
                        blocks.append(.text(delta))
                    }
                    onActivity(.textDelta(delta))
                case .thinkingDelta(let delta):
                    onActivity(.thinkingDelta(delta))
                case .thinkingFinished(let thinkingText, let signature):
                    blocks.append(.thinking(text: thinkingText, signature: signature))
                case .redactedThinking(let data):
                    blocks.append(.redactedThinking(data: data))
                case .reasoningItemFinished(let id, let encryptedContent):
                    // Preserved in stream order so it precedes the function_call it belongs to
                    // when replayed to the Responses API next turn.
                    blocks.append(.reasoningItem(id: id, encryptedContent: encryptedContent))
                case .toolUseStarted:
                    break
                case .toolUseFinished(let id, let name, let inputJSON):
                    toolCalls.append((id, name, inputJSON))
                    blocks.append(.toolUse(id: id, name: name, inputJSON: inputJSON))

                case .usage(let input, let output):
                    onActivity(.usage(input: input, output: output))
                case .finished(let reason):
                    stop = reason
                }
            }

            let assistantBlocks = blocks.filter { block in
                if case .text(let t) = block { return !t.isEmpty }
                return true
            }
            if !assistantBlocks.isEmpty {
                messages.append(LLMMessage(role: .assistant, blocks: assistantBlocks))
            }
            lastText = text

            guard stop == .toolUse, !toolCalls.isEmpty else {
                try await config.checkpoint?(messages)
                return AgentTurnResult(finalText: lastText, transcript: messages)
            }

            try await config.checkpoint?(messages)
            var resultBlocks: [ContentBlock] = []
            var effect: AgentToolEffect = .none
            for call in toolCalls {
                if effect != .none || callsUsed >= limit {
                    resultBlocks.append(.toolResult(toolUseID: call.id,
                        content: "Not executed: the turn has ended. Submit this call in a later turn if still needed.", isError: true))
                    continue
                }
                try Task.checkCancellation()
                callsUsed += 1
                onActivity(.toolStarted(name: call.name, summary: Self.summarize(inputJSON: call.inputJSON)))
                let (result, isError) = await execute(call: call, tools: config.tools)
                resultBlocks.append(.toolResult(toolUseID: call.id, content: result, isError: isError))
                try await config.checkpoint?(messages + [LLMMessage(role: .user, blocks: resultBlocks)])
                onActivity(.toolFinished(name: call.name, resultPreview: String(result.prefix(200)), isError: isError))
                if !isError, config.stopOnToolEffect {
                    effect = config.tools.first { $0.spec.name == call.name }?.turnEffect ?? .none
                    if effect != .none { lastText = result }
                }
            }
            messages.append(LLMMessage(role: .user, blocks: resultBlocks))
            if let boundaryMessages = config.boundaryMessages {
                messages += try await boundaryMessages()
            }
            try await config.checkpoint?(messages)
            if effect != .none {
                return AgentTurnResult(finalText: lastText, transcript: messages,
                                       stop: effect == .suspend ? .suspended : .toolCompleted)
            }
            if callsUsed < limit, let threshold = config.contextTokenThreshold,
               config.estimatedContextTokens(history: messages) >= threshold {
                return AgentTurnResult(finalText: lastText, transcript: messages, stop: .contextBoundary)
            }
        }
        onActivity(.iterationLimitReached)

        return AgentTurnResult(
            finalText: lastText + "\n\n*(Stopped: reached the tool-use iteration limit.)*",
            transcript: messages, stop: .toolLimit
        )
    }

    private func execute(
        call: (id: String, name: String, inputJSON: String),
        tools: [AgentTool]
    ) async -> (String, Bool) {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return ("Unknown tool '\(call.name)'. Available: \(tools.map(\.spec.name).joined(separator: ", "))", true)
        }
        do {
            let result = try await tool.execute(callID: call.id, inputJSON: call.inputJSON)
            return (result, false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    /// Short human-readable summary of a tool input for the activity feed.
    public static func summarize(inputJSON: String) -> String {
        let obj = jsonObject(inputJSON)
        var summary = String(inputJSON.prefix(80))
        for key in ["query", "id", "ref", "source", "action", "name", "label"] {
            if let value = obj[key] as? String, !value.isEmpty {
                summary = "\(key): \(value.prefix(80))"
                break
            }
        }
        // run_python declares its expected runtime — surface it where the call is shown.
        if let estimate = obj["estimated_runtime_seconds"] as? Double, estimate > 0 {
            summary += " · est ~\(Int(estimate))s"
        }
        return summary
    }
}
