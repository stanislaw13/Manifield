import Foundation

public enum AgentError: LocalizedError {
    case noAPIKey(ProviderKind)
    case http(Int, String)
    case api(String)
    case badResponse(String)
    case toolNotFound(String)
    case codexUnavailable(String)
    case codexNotSignedIn

    public var errorDescription: String? {
        switch self {
        case .noAPIKey(let kind):
            return "No API key configured for \(kind.displayName). Add one in Settings."
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(500))"
        case .api(let message):
            return "Provider error: \(message)"
        case .badResponse(let message):
            return "Unexpected response: \(message)"
        case .toolNotFound(let name):
            return "Model requested unknown tool '\(name)'"
        case .codexUnavailable(let detail):
            return "Codex is not available: \(detail)"
        case .codexNotSignedIn:
            return "Not signed in to Codex. Sign in with your ChatGPT account in Settings."
        }
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    case gemini
    case xai
    case zai
    case nvidia
    /// OpenAI's Codex agent engine, authenticated with the user's ChatGPT account instead of an
    /// API key — usage draws on plan limits rather than billing per token. Not an HTTP provider:
    /// see `CodexRunner`/`CodexServer`, which speak `codex app-server`'s JSON-RPC protocol over a
    /// local subprocess rather than any of the URLs below.
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        case .gemini: return "Google (Gemini)"
        case .xai: return "x.ai (Grok)"
        case .zai: return "z.ai (GLM)"
        case .nvidia: return "NVIDIA (Build)"
        case .codex: return "Codex (ChatGPT account)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openai: return "gpt-5"
        case .gemini: return "gemini-2.5-pro"
        case .xai: return "grok-4"
        case .zai: return "glm-5.2"
        case .nvidia: return "nvidia/nemotron-3-ultra-550b-a55b"
        case .codex: return "gpt-5.6-terra"
        }
    }

    /// Keychain account name for this provider's API key. Meaningless for `.codex` — it has no
    /// API key (see `usesAPIKey`) — but every `ProviderKind` gets one so call sites don't need
    /// a special case to compute it.
    public var keychainAccount: String { "api-key-\(rawValue)" }

    /// Whether this provider authenticates with an API key stored in the Keychain at all.
    /// `.codex` is the one exception: it authenticates via a ChatGPT account sign-in instead
    /// (`CodexServer.startLogin`), so `ProviderConfig.apiKey` stays empty for it rather than
    /// gating on a Keychain value the way every other provider does.
    public var usesAPIKey: Bool { self != .codex }

    /// Base URL for providers speaking the OpenAI-compatible Chat Completions dialect.
    /// `nil` for Anthropic (its own Messages API) and Codex (no HTTP dialect at all).
    var openAICompatBaseURL: URL? {
        switch self {
        case .anthropic: return nil
        case .openai: return URL(string: "https://api.openai.com/v1")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .xai: return URL(string: "https://api.x.ai/v1")!
        case .zai: return URL(string: "https://api.z.ai/api/paas/v4")!
        case .nvidia: return URL(string: "https://integrate.api.nvidia.com/v1")!
        case .codex: return nil
        }
    }

    /// Prefix used to filter a provider's `/models` listing down to chat-capable ids
    /// (e.g. OpenAI's endpoint also lists embedding, TTS, and image models).
    var modelIDPrefix: String? {
        switch self {
        case .anthropic: return nil
        case .openai: return "gpt-"
        case .gemini: return "gemini-"
        case .xai: return "grok-"
        case .zai: return "glm-"
        // NVIDIA's catalog namespaces ids by publisher (meta/, mistralai/, nvidia/, ...)
        // rather than one shared prefix, so no filter applies.
        case .nvidia: return nil
        case .codex: return nil
        }
    }

    /// Whether this provider publishes an HTTP `/models` listing endpoint. z.ai's API reference
    /// (docs.z.ai) documents no such route, unlike OpenAI/Gemini/x.ai/NVIDIA — so fetching
    /// would just fail; skip straight to the curated fallback list instead. `.codex` publishes a
    /// listing too, but over `CodexServer.listModels()`, not HTTP — `fetchAvailableModels`
    /// routes it separately rather than through this flag.
    var supportsModelListing: Bool {
        switch self {
        case .zai, .codex: return false
        case .anthropic, .openai, .gemini, .xai, .nvidia: return true
        }
    }

    /// Whether this provider exposes OpenAI's Responses API (`/v1/responses`). Some reasoning
    /// models (e.g. gpt-5.6-sol) reject `reasoning_effort` alongside function tools on Chat
    /// Completions and can only combine tool use with reasoning there. The Gemini/xAI/z.ai
    /// OpenAI-compatible endpoints speak Chat Completions only, so this is OpenAI-only.
    var supportsResponsesAPI: Bool {
        self == .openai
    }
}

public struct ProviderConfig: Sendable {
    public var kind: ProviderKind
    public var apiKey: String
    public var model: String
    /// User override for the `codex` binary location (Settings → "Locate Codex…"), mirroring
    /// `PythonRuntime.interpreterOverride`. Ignored by every kind but `.codex`; `nil` falls back
    /// to `CodexBinaryLocator`'s standard search order.
    public var codexBinaryPath: String?

    public init(kind: ProviderKind, apiKey: String, model: String? = nil, codexBinaryPath: String? = nil) {
        self.kind = kind
        self.apiKey = apiKey
        self.model = (model?.isEmpty == false ? model! : kind.defaultModel)
        self.codexBinaryPath = codexBinaryPath
    }
}

// MARK: - Messages

public enum MessageRole: String, Codable, Sendable {
    case user, assistant
}

public enum ContentBlock: Equatable, Sendable, Codable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    /// Model reasoning. The signature must be preserved verbatim — the API verifies it
    /// when the block is replayed in a later turn of a tool loop.
    case thinking(text: String, signature: String?)
    /// Encrypted reasoning the API returns instead of text in rare cases; replayed as-is.
    case redactedThinking(data: String)
    /// OpenAI Responses API reasoning item, carried as its opaque `id` + `encrypted_content`.
    /// Replayed verbatim on later tool-loop turns so the model keeps its chain of thought — the
    /// API pairs a reasoning item with the function_call it precedes. Other providers drop it.
    case reasoningItem(id: String, encryptedContent: String)
    /// A user-attached image (chat composer), stored base64 so saved chats replay it.
    /// mediaType is a MIME type like "image/png".
    case image(mediaType: String, base64: String)
    /// A user-attached text document (md/txt/tex/py or extracted PDF text). Kept as its
    /// own block so the UI can render a pill instead of dumping the text into the bubble.
    case document(name: String, text: String)

    private enum CodingKeys: String, CodingKey {
        case kind, text, id, name, inputJSON, toolUseID, content, isError, signature, data, mediaType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "toolUse":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .inputJSON))
        case "toolResult":
            self = .toolResult(
                toolUseID: try c.decode(String.self, forKey: .toolUseID),
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decode(Bool.self, forKey: .isError))
        case "thinking":
            self = .thinking(
                text: try c.decode(String.self, forKey: .text),
                signature: try c.decodeIfPresent(String.self, forKey: .signature))
        case "redactedThinking":
            self = .redactedThinking(data: try c.decode(String.self, forKey: .data))
        case "reasoningItem":
            self = .reasoningItem(
                id: try c.decode(String.self, forKey: .id),
                encryptedContent: try c.decode(String.self, forKey: .data))
        case "image":
            self = .image(
                mediaType: try c.decode(String.self, forKey: .mediaType),
                base64: try c.decode(String.self, forKey: .data))
        case "document":
            self = .document(
                name: try c.decode(String.self, forKey: .name),
                text: try c.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown block kind '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .kind)
            try c.encode(text, forKey: .text)
        case .toolUse(let id, let name, let inputJSON):
            try c.encode("toolUse", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .inputJSON)
        case .toolResult(let toolUseID, let content, let isError):
            try c.encode("toolResult", forKey: .kind)
            try c.encode(toolUseID, forKey: .toolUseID)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        case .thinking(let text, let signature):
            try c.encode("thinking", forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(signature, forKey: .signature)
        case .redactedThinking(let data):
            try c.encode("redactedThinking", forKey: .kind)
            try c.encode(data, forKey: .data)
        case .reasoningItem(let id, let encryptedContent):
            try c.encode("reasoningItem", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(encryptedContent, forKey: .data)
        case .image(let mediaType, let base64):
            try c.encode("image", forKey: .kind)
            try c.encode(mediaType, forKey: .mediaType)
            try c.encode(base64, forKey: .data)
        case .document(let name, let text):
            try c.encode("document", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(text, forKey: .text)
        }
    }
}

public struct LLMMessage: Equatable, Sendable, Codable {
    public var role: MessageRole
    public var blocks: [ContentBlock]

    public init(role: MessageRole, blocks: [ContentBlock]) {
        self.role = role
        self.blocks = blocks
    }

    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, blocks: [.text(text)])
    }

    public var plainText: String {
        blocks.compactMap {
            if case .text(let t) = $0 { return t }
            return nil
        }.joined(separator: "\n")
    }
}

// MARK: - Tools

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the input, as a JSON object string.
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }

    var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(inputSchemaJSON.utf8))) as? [String: Any]
            ?? ["type": "object", "properties": [:]]
    }
}

public enum AgentToolEffect: String, Codable, Sendable { case none, finish, suspend }

public protocol AgentTool {
    var spec: ToolSpec { get }
    /// Read after a successful call, after its durable effects have been committed.
    var turnEffect: AgentToolEffect { get }
    func execute(inputJSON: String) async throws -> String
    func execute(callID: String, inputJSON: String) async throws -> String
}

public extension AgentTool {
    var turnEffect: AgentToolEffect { .none }
    func execute(callID: String, inputJSON: String) async throws -> String {
        try await execute(inputJSON: inputJSON)
    }
}

// MARK: - Streaming events

public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

public enum LLMEvent: Sendable, Equatable {
    case textDelta(String)
    case thinkingDelta(String)
    /// A completed thinking block, ready to persist and replay (signature included).
    case thinkingFinished(text: String, signature: String?)
    case redactedThinking(data: String)
    /// A completed Responses API reasoning item (opaque id + encrypted_content), ready to
    /// persist and replay on later tool-loop turns.
    case reasoningItemFinished(id: String, encryptedContent: String)
    case toolUseStarted(id: String, name: String)
    case toolUseFinished(id: String, name: String, inputJSON: String)
    case usage(input: Int, output: Int)
    case finished(StopReason)
}

/// How hard the model should think before answering. Provider-generic; each provider
/// maps it to its native parameter (Anthropic adaptive thinking + effort, or
/// budget_tokens on older models; reasoning_effort on OpenAI-compatible APIs).
public enum ThinkingLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, low, medium, high

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// Thinking tokens count against max_tokens; give the model room so a hard think
    /// doesn't truncate the answer. Providers raise the request cap to at least this.
    var recommendedMinimumMaxTokens: Int {
        switch self {
        case .off: return 0
        case .low: return 16_384
        case .medium: return 32_768
        case .high: return 65_536
        }
    }

    /// Token budget for providers/models that still use explicit thinking budgets.
    var budgetTokens: Int {
        switch self {
        case .off: return 0
        case .low: return 4096
        case .medium: return 16_384
        case .high: return 32_768
        }
    }
}

/// A system prompt split at its prompt-cache boundary.
///
/// Caching is by prefix, so one changed byte invalidates every cached token after it.
/// `instructions` holds what stands still for a whole conversation — the prompt fragments,
/// the mode directive, the user profile — and the cache breakpoint goes at its end.
/// `projectContext` holds what a single turn can rewrite: the research memory, access
/// grants, the library outline, fixed goal items. Splitting them means a memory write re-reads
/// the instruction set from cache instead of re-paying for it.
///
/// A prompt built from a bare string is all `instructions` — the pre-split shape, one
/// block with the breakpoint on it.
public struct SystemPrompt: Sendable, Equatable, ExpressibleByStringLiteral {
    /// Stable across the conversation. Ends the cached prefix.
    public var instructions: String
    /// Rewritable by any turn; everything after the breakpoint.
    public var projectContext: String

    public init(instructions: String, projectContext: String = "") {
        self.instructions = instructions
        self.projectContext = projectContext
    }

    public init(_ instructions: String) {
        self.init(instructions: instructions)
    }

    public init(stringLiteral value: String) {
        self.init(instructions: value)
    }

    /// The non-empty parts in wire order. Providers with block-level cache control emit
    /// one block each and mark the first — which is `instructions` whenever there is any.
    public var segments: [String] {
        [instructions, projectContext].filter { !$0.isEmpty }
    }

    /// The whole prompt as one string, for providers that take a single system message.
    public var text: String {
        segments.joined(separator: "\n\n")
    }

    public var isEmpty: Bool { segments.isEmpty }
}

public struct LLMRequest: Sendable {
    public var system: SystemPrompt
    public var messages: [LLMMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int
    public var thinking: ThinkingLevel

    public init(system: SystemPrompt, messages: [LLMMessage], tools: [ToolSpec] = [],
                maxTokens: Int = 8192, thinking: ThinkingLevel = .off) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

public protocol LLMProvider: Sendable {
    var description: String { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

/// `.codex` must never reach here — it has no HTTP dialect at all, and `openAICompatBaseURL ==
/// nil` for it would otherwise fall through to `AnthropicProvider` holding an empty API key,
/// 401ing against the wrong provider with a baffling message. `makeRunner(config:)` is the
/// entry point every call site actually uses; this trap is what makes a future call site that
/// bypasses it (calling this directly) fail loudly instead of silently misrouting.
public func makeProvider(config: ProviderConfig) -> LLMProvider {
    precondition(config.kind != .codex, "makeProvider does not support .codex — use makeRunner(config:)")
    guard let baseURL = config.kind.openAICompatBaseURL else {
        return AnthropicProvider(config: config)
    }
    return OpenAICompatProvider(config: config, baseURL: baseURL)
}

/// The general entry point: every call site that used to build an `AgentLoop` over a
/// `makeProvider(config:)` result now builds a runner over this instead.
///
/// Every `ProviderKind` but `.codex` is a request/response HTTP provider driven through
/// `AgentLoop`'s tool loop. `.codex` runs its own tool loop against a local `codex app-server`
/// subprocess instead of making an HTTP request per turn — see `Codex/CodexRunner.swift`.
public func makeRunner(config: ProviderConfig) -> AgentRunner {
    if config.kind == .codex {
        return CodexRunner(model: config.model, binaryOverride: config.codexBinaryPath)
    }
    return AgentLoop(provider: makeProvider(config: config))
}

/// Queries the provider's `/models` endpoint for the models actually available to this
/// API key, so pickers can stay current without hardcoding every model id.
public func fetchAvailableModels(config: ProviderConfig) async throws -> [ModelOption] {
    if config.kind == .codex {
        return try await fetchCodexModels(binaryOverride: config.codexBinaryPath)
    }
    guard config.kind.supportsModelListing else {
        throw AgentError.api("\(config.kind.displayName) doesn't publish a model list endpoint — showing the built-in list instead.")
    }
    guard let baseURL = config.kind.openAICompatBaseURL else {
        return try await AnthropicProvider.listModels(apiKey: config.apiKey)
    }
    let models = try await OpenAICompatProvider.listModels(apiKey: config.apiKey, baseURL: baseURL)
    guard let prefix = config.kind.modelIDPrefix else { return models }
    let filtered = models.filter { $0.id.hasPrefix(prefix) }
    return filtered.isEmpty ? models : filtered
}

private func fetchCodexModels(binaryOverride: String?) async throws -> [ModelOption] {
    guard let binaryPath = CodexBinaryLocator().locate(override: binaryOverride) else {
        throw AgentError.codexUnavailable("codex binary not found")
    }
    try await CodexEnvironment.requireCompatible(binaryPath: binaryPath)
    let server = CodexEnvironment.sharedServer(binaryPath: binaryPath)
    let raw = try await server.listModels()
    return codexModelOptions(from: raw)
}

func codexModelOptions(from raw: [JSONValue]) -> [ModelOption] {
    raw.compactMap { value -> ModelOption? in
        guard value["hidden"]?.boolValue != true,
              let id = value["model"]?.stringValue ?? value["id"]?.stringValue
        else { return nil }
        let modalities = Set((value["inputModalities"]?.arrayValue ?? []).compactMap {
            $0.stringValue.flatMap(ModelInputModality.init(rawValue:))
        })
        let efforts = (value["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["reasoningEffort"]?.stringValue ?? $0.stringValue
        }
        return ModelOption(
            id: id,
            displayName: value["displayName"]?.stringValue ?? id,
            inputModalities: modalities.isEmpty ? [.text] : modalities,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: value["defaultReasoningEffort"]?.stringValue)
    }
}

// MARK: - Shared JSON helpers

func jsonObject(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

func jsonString(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}
