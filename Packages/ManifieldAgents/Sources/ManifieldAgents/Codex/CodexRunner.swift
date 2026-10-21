import Foundation
import CryptoKit

protocol CodexServing: Sendable {
    func startThread(model: String, developerInstructions: String, tools: [ToolSpec]) async throws -> CodexServer.StartedThread
    func injectItems(threadID: String, items: [[String: Any]]) async throws
    func startTurn(threadID: String, input: [[String: Any]], effort: String) async throws -> String
    func interruptTurn(threadID: String, turnID: String) async
    func respond(requestID: CodexProtocol.RequestID, success: Bool, text: String) async
    func closeThread(_ threadID: String) async
    func retainThread(_ threadID: String) async
    func continueThread(_ threadID: String) async throws -> CodexServer.StartedThread
}

extension CodexServing {
    func retainThread(_ threadID: String) async {}
    func continueThread(_ threadID: String) async throws -> CodexServer.StartedThread {
        throw CodexTransportError.unavailable("Native continuation is unavailable; rebuild retained app history.")
    }
}

extension CodexServer: CodexServing {}

/// Runs one agent turn on OpenAI's Codex, authenticated with the user's ChatGPT account instead
/// of an API key — usage draws on plan limits rather than billing per token.
///
/// Unlike `AgentLoop` (which drives the tool loop itself, round-tripping a stateless
/// request/response `LLMProvider`), Codex runs its own tool loop inside a single `turn/start`.
/// This type's job is to seed that turn with Manifield's tools and system prompt, answer the
/// `item/tool/call` requests Codex blocks on by executing the matching `AgentTool`, and translate
/// the resulting event stream back into an `AgentTurnResult` shaped exactly like `AgentLoop`'s —
/// every other call site in the app is agnostic to which of the two actually ran.
///
/// Persistent research may reuse an idle thread while history, epoch, model, prompt, and tools agree.
/// Other callers use fresh ephemeral threads.
/// `ResearchWorkbench.compactIfNeeded` deliberately drops context from `history` at times, and a
/// live Codex thread would silently keep what was supposed to be forgotten. That makes replaying
/// `history` into the new thread unavoidable for multi-turn callers (chat, research branches):
/// Prior retained messages are replayed as structured Responses API items through
/// `thread/inject_items`; the final user message is supplied as native `turn/start.input` text,
/// document text, and image items. Older binaries without injection fall back to flattened text
/// plus native images. A changed session epoch replaces the native thread so caller-side compaction truly forgets
/// discarded context instead of leaving it hidden in a reusable server thread.
public struct CodexRunner: AgentRunner {

    /// The generated app-server schema exposes no output-token-limit field. `maxTokens` therefore
    /// remains advisory for Codex; usage is reported, but an exact pre-generation cap cannot be
    /// represented without a future protocol field.
    static let maxTokensLimitation = "codex app-server does not expose an output-token limit in TurnStartParams"

    public let model: String
    private let binaryOverride: String?

    public init(model: String, binaryOverride: String? = nil) {
        self.model = model
        self.binaryOverride = binaryOverride
    }

    public var description: String { "Codex (\(model))" }

    public func run(
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult {
        guard !history.isEmpty else {
            throw AgentError.api("Codex needs at least one message to respond to.")
        }
        guard let binaryPath = CodexBinaryLocator().locate(override: binaryOverride) else {
            throw CodexTransportError.unavailable(
                "codex binary not found — set a custom path in Settings, or install the ChatGPT app")
        }
        let capabilities = try await CodexEnvironment.capabilities(binaryPath: binaryPath)
        if let detail = capabilities.incompatibilityDescription {
            throw CodexTransportError.unavailable("incompatible codex binary — \(detail)")
        }
        let server = CodexEnvironment.sharedServer(binaryPath: binaryPath)
        let options = codexModelOptions(from: try await server.listModels())
        let modelOption = options.first { $0.id == model }

        let observation = CodexUsageObservation()
        let result = try await run(
            server: server, config: config, history: history,
            supportsHistoryInjection: capabilities.supportsHistoryInjection,
            modelOption: modelOption, onActivity: { activity in
                observation.record(activity); onActivity(activity)
            })
        if config.stopOnToolEffect, observation.tools > 0 && !observation.hasUsage {
            if let key = config.sessionKey { await CodexSessionCache.shared.remove(key) }
            throw ProgramUsageError.usageUnavailable(provider: "Codex")
        }
        return result
    }

    func run(
        server: any CodexServing,
        config: AgentConfig,
        history: [LLMMessage],
        supportsHistoryInjection: Bool = true,
        modelOption: ModelOption? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult {
        try await config.beforeProviderCall?()
        if Self.containsImage(in: history), let modelOption,
           !modelOption.inputModalities.contains(.image) {
            throw CodexTransportError.unavailable(
                "model \(modelOption.displayName) does not advertise image input; remove the image or choose an image-capable Codex model")
        }
        let key = supportsHistoryInjection ? config.sessionKey : nil
        let fingerprint = SHA256.hash(data: Data((model + "\0" + config.systemPrompt.text + "\0" + config.tools.map {
            $0.spec.name + "\0" + $0.spec.description + "\0" + $0.spec.inputSchemaJSON
        }.joined(separator: "\0")).utf8)).map { String(format: "%02x", $0) }.joined()
        var cached: CodexSessionCache.Entry?
        if let key { cached = try await CodexSessionCache.shared.acquire(key) }
        var nativePrefixCount = 0
        var continuing: CodexServer.StartedThread?
        if let cached {
            if cached.epoch == config.sessionEpoch, cached.fingerprint == fingerprint,
               ObjectIdentifier(cached.server as AnyObject) == ObjectIdentifier(server as AnyObject),
               history.count > cached.history.count,
               Array(history.prefix(cached.history.count)) == cached.history {
                continuing = try? await server.continueThread(cached.threadID)
                if continuing != nil { nativePrefixCount = cached.history.count }
            }
            if continuing == nil { await cached.server.closeThread(cached.threadID) }
        }
        let started: CodexServer.StartedThread
        do {
            if let continuing { started = continuing }
            else { started = try await server.startThread(model: model, developerInstructions: config.systemPrompt.text, tools: config.tools.map(\.spec)) }
        } catch {
            if let key { await CodexSessionCache.shared.release(key, entry: nil) }
            throw error
        }
        let threadID = started.threadID
        if key != nil { await server.retainThread(threadID) }
        let cancellation = TurnCancellationState()
        let prefixCount = nativePrefixCount

        return try await withTaskCancellationHandler {
            let outcome: Result<AgentTurnResult, Error>
            do {
                let input: [[String: Any]]
                if supportsHistoryInjection, let latest = history.last, latest.role == .user {
                    let retainedPrefix = Array(history.dropFirst(prefixCount).dropLast())
                    try await server.injectItems(
                        threadID: threadID, items: CodexHistoryReplay.items(for: retainedPrefix))
                    input = Self.turnInput(for: latest)
                } else {
                    // Compatibility fallback: keep every text/document/tool payload in the
                    // flattened transcript and carry every image as a native image item.
                    input = Self.fallbackTurnInput(for: history)
                }
                let effort = Self.effort(
                    for: config.thinking,
                    supported: modelOption?.supportedReasoningEfforts ?? [],
                    defaultEffort: modelOption?.defaultReasoningEffort)
                let turnID = try await server.startTurn(
                    threadID: threadID, input: input, effort: effort)
                if let idToInterrupt = await cancellation.received(turnID: turnID) {
                    // This operation is already cancelled. Use an unstructured cleanup task so
                    // the interrupt JSON-RPC request itself is not immediately cancelled too.
                    await Task {
                        await server.interruptTurn(threadID: threadID, turnID: idToInterrupt)
                    }.value
                }
                try Task.checkCancellation()
                let result = try await Self.consume(
                    started.events, server: server, threadID: threadID, turnID: turnID,
                    config: config, history: history, onActivity: onActivity)
                try Task.checkCancellation()
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            if let key, case .success(let result) = outcome {
                // Boundary guidance has not reached the provider yet. Leave it out of the
                // cached prefix so the next turn sends it exactly once.
                var nativeHistory = result.transcript
                if result.stop == .contextBoundary {
                    while let last = nativeHistory.last, last.role == .user,
                          last.blocks.allSatisfy({ if case .text = $0 { return true }; return false }) {
                        nativeHistory.removeLast()
                    }
                }
                await CodexSessionCache.shared.release(key, entry: .init(threadID: threadID,
                    server: server, fingerprint: fingerprint, epoch: config.sessionEpoch, history: nativeHistory))
            } else {
                await server.closeThread(threadID)
                if let key { await CodexSessionCache.shared.release(key, entry: nil) }
            }
            return try outcome.get()
        } onCancel: {
            Task {
                if let idToInterrupt = await cancellation.cancel() {
                    await server.interruptTurn(threadID: threadID, turnID: idToInterrupt)
                }
            }
        }
    }

    /// `config.maxTokens` is intentionally never read here — Codex has no equivalent parameter,
    /// and only the HTTP providers (`AnthropicProvider`, `OpenAICompatProvider`,
    /// `OpenAIResponsesProvider`) use it.
    ///
    /// Internal rather than `private` so `CodexRunnerTests` can drive it directly with a
    /// synthetic event stream — the transcript-building logic is the highest-value thing to
    /// test here, and it doesn't need a live `codex` process to exercise.
    static func consume(
        _ events: AsyncThrowingStream<CodexEvent, Error>,
        server: any CodexServing,
        threadID: String? = nil,
        turnID: String? = nil,
        config: AgentConfig,
        history: [LLMMessage],
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> AgentTurnResult {
        var messages = history
        var assistantBlocks: [ContentBlock] = []
        var finalText = ""
        var lastText = ""
        var sawFinal = false
        var toolCallCount = 0
        var terminalEffect: AgentToolEffect = .none
        var hitToolLimit = false
        var contextBoundary = false
        var settlingUsage = false
        var settlementDeadline: Task<Void, Never>?
        defer { settlementDeadline?.cancel() }
        // App-server does not expose AgentLoop's provider-round boundaries. The enforceable
        // equivalent is a cap on dynamic tool requests. After the final allowed result is sent,
        // interrupt immediately; never enter an unlimited deny-and-retry cycle.
        let maxToolCalls = max(1, config.maxIterations)

        func flushAssistant() {
            guard !assistantBlocks.isEmpty else { return }
            messages.append(LLMMessage(role: .assistant, blocks: assistantBlocks))
            assistantBlocks.removeAll(keepingCapacity: true)
        }

        func result(stoppedAtToolLimit: Bool = false) -> AgentTurnResult {
            flushAssistant()
            let text = sawFinal ? finalText : lastText
            return AgentTurnResult(
                finalText: stoppedAtToolLimit
                    ? text + "\n\n*(Stopped: reached the tool-use iteration limit.)*"
                    : text,
                transcript: messages,
                stop: stoppedAtToolLimit ? .toolLimit : terminalEffect == .suspend ? .suspended : terminalEffect == .finish ? .toolCompleted : contextBoundary ? .contextBoundary : .completed)
        }

        do {
        eventLoop: for try await event in events {
            switch event {
            case .textDelta(let delta):
                onActivity(.textDelta(delta))
            case .thinkingDelta(let delta):
                onActivity(.thinkingDelta(delta))
            case .agentMessageCompleted(let text, let isFinal):
                if !text.isEmpty { assistantBlocks.append(.text(text)) }
                lastText = text
                if isFinal {
                    finalText = text
                    sawFinal = true
                }
            case .reasoningCompleted(let text):
                assistantBlocks.append(.thinking(text: text, signature: nil))
            case .toolCallRequested(let requestID, let callID, let tool, let argumentsJSON):
                if terminalEffect != .none || hitToolLimit || contextBoundary {
                    await server.respond(requestID: requestID, success: false, text: "Turn has ended; this call was not executed.")
                    continue
                }
                toolCallCount += 1
                assistantBlocks.append(.toolUse(id: callID, name: tool, inputJSON: argumentsJSON))
                flushAssistant()
                onActivity(.toolStarted(name: tool, summary: AgentLoop.summarize(inputJSON: argumentsJSON)))

                try await config.checkpoint?(messages)
                let toolResult: String
                let isError: Bool
                (toolResult, isError) = await execute(
                    tool: tool, callID: callID, inputJSON: argumentsJSON, tools: config.tools)
                messages.append(LLMMessage(role: .user, blocks: [
                    .toolResult(toolUseID: callID, content: toolResult, isError: isError)
                ]))
                onActivity(.toolFinished(
                    name: tool, resultPreview: String(toolResult.prefix(200)), isError: isError))
                await server.respond(requestID: requestID, success: !isError, text: toolResult)
                if let boundaryMessages = config.boundaryMessages {
                    let additions = try await boundaryMessages()
                    messages += additions
                    contextBoundary = !additions.isEmpty
                }
                try await config.checkpoint?(messages)
                if !isError, config.stopOnToolEffect {
                    terminalEffect = config.tools.first { $0.spec.name == tool }?.turnEffect ?? .none
                    if terminalEffect != .none { lastText = toolResult }
                }
                if let threshold = config.contextTokenThreshold {
                    contextBoundary = contextBoundary || config.estimatedContextTokens(history: messages) >= threshold
                }
                if terminalEffect != .none || toolCallCount >= maxToolCalls || contextBoundary {
                    hitToolLimit = terminalEffect == .none && toolCallCount >= maxToolCalls
                    if hitToolLimit { onActivity(.iterationLimitReached) }
                    if let threadID, let turnID {
                        if config.stopOnToolEffect {
                            // A dynamic tool arrives before response usage is necessarily final.
                            // Immediate interruption can discard that accounting event. No more
                            // tools execute while we drain; interrupt on usage or a short deadline.
                            settlingUsage = true
                            settlementDeadline = Task {
                                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                                catch { return }
                                await server.interruptTurn(threadID: threadID, turnID: turnID)
                            }
                        } else {
                            await server.interruptTurn(threadID: threadID, turnID: turnID)
                        }
                    }
                    // Drain the terminal event and usage updates after interruption.
                    if threadID == nil || turnID == nil { return result(stoppedAtToolLimit: hitToolLimit) }
                }
            case .usage(let usage):
                onActivity(.usage(input: usage.inputTokens, output: usage.outputTokens))
                onActivity(.usageDetails(AgentUsageDetails(
                    cachedInputTokens: usage.cachedInputTokens,
                    cacheWriteInputTokens: usage.cacheWriteInputTokens,
                    reasoningOutputTokens: usage.reasoningOutputTokens,
                    contextWindowTokens: usage.contextWindowTokens)))
                if settlingUsage, usage.inputTokens > 0 || usage.outputTokens > 0 {
                    settlementDeadline?.cancel(); settlingUsage = false
                    if let threadID, let turnID { await server.interruptTurn(threadID: threadID, turnID: turnID) }
                }
            case .turnCompleted:
                break eventLoop
            }
        }
        } catch {
            if !(error is CancellationError) || (terminalEffect == .none && !hitToolLimit && !contextBoundary) { throw error }
        }
        return result(stoppedAtToolLimit: hitToolLimit)
    }

    /// Mirrors `AgentLoop.execute` — same unknown-tool message, same error-to-string fallback —
    /// so a transcript reads the same regardless of which runner produced it.
    private static func execute(tool: String, callID: String, inputJSON: String, tools: [AgentTool]) async -> (String, Bool) {
        guard let match = tools.first(where: { $0.spec.name == tool }) else {
            return ("Unknown tool '\(tool)'. Available: \(tools.map(\.spec.name).joined(separator: ", "))", true)
        }
        do {
            return (try await match.execute(callID: callID, inputJSON: inputJSON), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    /// Codex has no "off" — a reasoning model always reasons — so `.off` maps to its cheapest
    /// tier rather than being dropped. `effort` is sent on every turn (see `CodexProtocol.
    /// turnStartParams`) specifically so it never falls back to inheriting the user's own
    /// `~/.codex/config.toml`.
    static func effort(for thinking: ThinkingLevel) -> String {
        switch thinking {
        case .off, .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    static func effort(
        for thinking: ThinkingLevel, supported: [String], defaultEffort: String?
    ) -> String {
        guard !supported.isEmpty else { return effort(for: thinking) }
        let normalized = supported.map { $0.lowercased() }
        if thinking == .off {
            for candidate in ["none", "minimal", "low"] where normalized.contains(candidate) {
                return supported[normalized.firstIndex(of: candidate)!]
            }
            if let defaultEffort, normalized.contains(defaultEffort.lowercased()) { return defaultEffort }
            return supported.first!
        }
        let desired = effort(for: thinking)
        if let index = normalized.firstIndex(of: desired) { return supported[index] }
        if let defaultEffort, normalized.contains(defaultEffort.lowercased()) { return defaultEffort }
        let ranks = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let desiredRank = ranks.firstIndex(of: desired) ?? 2
        return supported.min { lhs, rhs in
            abs((ranks.firstIndex(of: lhs.lowercased()) ?? desiredRank) - desiredRank)
                < abs((ranks.firstIndex(of: rhs.lowercased()) ?? desiredRank) - desiredRank)
        }!
    }

    static func turnInput(for message: LLMMessage) -> [[String: Any]] {
        var input: [[String: Any]] = []
        for block in message.blocks {
            switch block {
            case .text(let text) where !text.isEmpty:
                input.append(["type": "text", "text": text])
            case .document(let name, let text):
                input.append(["type": "text", "text": "[Attached file: \(name)]\n\n\(text)"])
            case .image(let mediaType, let base64):
                input.append([
                    "type": "image", "url": "data:\(mediaType);base64,\(base64)", "detail": "auto"
                ])
            case .toolResult(_, let content, let isError):
                input.append(["type": "text", "text": isError ? "[tool error: \(content)]" : "[tool result: \(content)]"])
            case .toolUse(_, let name, let inputJSON):
                input.append(["type": "text", "text": "[called \(name) with \(inputJSON)]"])
            case .thinking, .redactedThinking, .reasoningItem, .text:
                break
            }
        }
        return input.isEmpty ? [["type": "text", "text": ""]] : input
    }

    static func fallbackTurnInput(for history: [LLMMessage]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": flattenedInput(for: history)]]
        for message in history {
            for block in message.blocks {
                guard case .image(let mediaType, let base64) = block else { continue }
                input.append([
                    "type": "image", "url": "data:\(mediaType);base64,\(base64)", "detail": "auto"
                ])
            }
        }
        return input
    }

    private static func containsImage(in history: [LLMMessage]) -> Bool {
        history.contains { message in
            message.blocks.contains { if case .image = $0 { return true }; return false }
        }
    }

    /// The flattened `turn/start.input` fallback: renders the whole history into one text blob,
    /// since a fresh ephemeral thread has no other memory of it. A single seed message — still
    /// the common case, every role that opens a fresh conversation per turn (reviewer, prover,
    /// director, the adjudicators, contract drafter, pilot selector, chat naming, organizer,
    /// explorer, source metadata) — is sent as its own plain text, unchanged from before
    /// multi-turn replay existed.
    static func flattenedInput(for history: [LLMMessage]) -> String {
        guard history.count > 1 else { return history.first?.plainText ?? "" }
        return history.map(renderedForFlattening).joined(separator: "\n\n")
    }

    private static func renderedForFlattening(_ message: LLMMessage) -> String {
        let label = message.role == .user ? "User" : "Assistant"
        let text = message.blocks.compactMap(renderedBlockForFlattening).joined(separator: "\n")
        return "\(label): \(text)"
    }

    /// Tool calls/results are rendered as bracketed asides rather than dropped — losing them
    /// would make a replayed branch that hinges on a tool result unintelligible. Reasoning blocks
    /// are omitted: they have no Responses-API channel here either way (see
    /// `CodexHistoryReplay`), and Codex re-derives its own reasoning for the new turn regardless.
    private static func renderedBlockForFlattening(_ block: ContentBlock) -> String? {
        switch block {
        case .text(let text): return text.isEmpty ? nil : text
        case .toolUse(_, let name, let inputJSON): return "[called \(name) with \(inputJSON)]"
        case .toolResult(_, let content, let isError):
            return isError ? "[tool error: \(content)]" : "[tool result: \(content)]"
        case .document(let name, let text): return "[Attached file: \(name)]\n\n\(text)"
        case .image: return "[image attached]"
        case .thinking, .redactedThinking, .reasoningItem: return nil
        }
    }
}

private final class CodexUsageObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var reported = false
    var tools: Int { lock.lock(); defer { lock.unlock() }; return count }
    var hasUsage: Bool { lock.lock(); defer { lock.unlock() }; return reported }
    func record(_ activity: AgentActivity) {
        lock.lock(); defer { lock.unlock() }
        switch activity {
        case .toolStarted: count += 1
        case .usage(let input, let output): reported = reported || input > 0 || output > 0
        default: break
        }
    }
}

private actor TurnCancellationState {
    private var turnID: String?
    private var isCancelled = false
    private var interruptWasClaimed = false

    func received(turnID: String) -> String? {
        guard !turnID.isEmpty else { return nil }
        self.turnID = turnID
        return claimInterruptIfReady()
    }

    func cancel() -> String? {
        isCancelled = true
        return claimInterruptIfReady()
    }

    private func claimInterruptIfReady() -> String? {
        guard isCancelled, !interruptWasClaimed, let turnID, !turnID.isEmpty else { return nil }
        interruptWasClaimed = true
        return turnID
    }
}
