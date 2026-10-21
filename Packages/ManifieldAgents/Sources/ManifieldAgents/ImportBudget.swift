import Foundation

/// How much source text one Organizer call may carry.
///
/// A chunk has to fit twice over: into the model's context window *alongside* the
/// organizer prompts, and — the tighter of the two in practice — into the reply, since
/// the Organizer re-emits most of what it reads as JSON items. A whole chapter of dense
/// mathematics comes back as statements and proofs at close to its original length, so
/// a chunk the model can read but not restate is useless: the reply truncates and the
/// chunk fails.
///
/// Providers do not publish context windows through `/models` (the listing is ids only),
/// so the window comes from `ModelContextWindow`'s table with a conservative default for
/// ids it doesn't recognise.
public struct ImportBudget: Sendable, Equatable {

    /// Share of the context window a chunk request may occupy, prompts included.
    public static let contextShare = 0.75

    /// Share of the reply a chunk's organized items may need. The Organizer gives back
    /// statements and proofs close to verbatim and adds JSON structure on top, so a
    /// chunk of dense mathematics can come back at roughly its own token count — the
    /// margin here is what keeps a theorem-dense chapter from truncating mid-array,
    /// which fails the chunk outright (an unterminated array will not parse).
    public static let replyShare = 0.75

    /// Assumed characters per token. LaTeX tokenizes worse than prose — backslashes,
    /// braces and math symbols rarely merge — so this stays below the ~4.0 of English.
    public static let charactersPerToken = 3.5

    /// Chunk sizes outside this range are not worth producing: below the floor every
    /// theorem gets cut apart, above the ceiling a single failure wastes too much.
    static let minChunkTokens = 3_000
    static let maxChunkTokens = 40_000

    public let model: String
    public let contextWindowTokens: Int
    public let maxOutputTokens: Int
    /// Prompt tokens that ride along with every chunk (organizer rules, taken ids,
    /// user instructions, the detected outline).
    public let promptOverheadTokens: Int
    /// The answer: the largest chunk this model should be handed, in characters.
    public let maxChunkCharacters: Int
    /// True when the model's context window — not its reply capacity — is what limits
    /// the chunk. Worth saying out loud in the UI: it means smaller chunks than usual.
    public let limitedByContextWindow: Bool

    public init(
        model: String,
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        promptOverheadCharacters: Int
    ) {
        self.model = model
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        let overhead = Self.tokens(inCharacters: promptOverheadCharacters)
        self.promptOverheadTokens = overhead

        // What the window leaves for source text once the prompts and the reserved
        // reply have been subtracted from the usable share.
        let windowAllowance =
            Int(Double(contextWindowTokens) * Self.contextShare) - overhead - maxOutputTokens
        // What the model can restate — the binding constraint for every current model,
        // whose windows all dwarf what one reply can hold.
        let replyAllowance = Int(Double(maxOutputTokens) * Self.replyShare)

        let allowance = min(windowAllowance, replyAllowance)
        self.limitedByContextWindow = windowAllowance < replyAllowance
        let clamped = min(max(allowance, Self.minChunkTokens), Self.maxChunkTokens)
        self.maxChunkCharacters = Int(Double(clamped) * Self.charactersPerToken)
    }

    /// The budget for a model id, resolving its context window from the table.
    public static func forModel(
        _ model: String,
        kind: ProviderKind,
        maxOutputTokens: Int = 16_384,
        promptOverheadCharacters: Int
    ) -> ImportBudget {
        ImportBudget(
            model: model,
            contextWindowTokens: ModelContextWindow.tokens(for: model, kind: kind),
            maxOutputTokens: maxOutputTokens,
            promptOverheadCharacters: promptOverheadCharacters)
    }

    public static func tokens(inCharacters characters: Int) -> Int {
        Int(Double(characters) / charactersPerToken)
    }

    /// One line for the import log / cost warning.
    public var summary: String {
        let thousands = maxChunkCharacters / 1_000
        let chunkTokens = Self.tokens(inCharacters: maxChunkCharacters) / 1_000
        return limitedByContextWindow
            ? "\(model): ~\(contextWindowTokens / 1_000)k-token context → chunks up to ~\(thousands)k characters (context-limited)"
            : "\(model): chunks up to ~\(thousands)k characters (~\(chunkTokens)k tokens)"
    }
}

/// Context windows for the model ids Manifield can be pointed at, matched by family
/// prefix so a new dated or minor revision of a known family inherits its window.
///
/// This is a table and not an API call on purpose: none of the supported providers
/// expose per-model limits on their listing endpoints, so the alternative to a table
/// is a guess made at request time — with a 429 as the feedback channel.
public enum ModelContextWindow {

    /// Applied to ids that match nothing below. Every current frontier model is at or
    /// above this, and being wrong low costs extra chunks rather than failed requests.
    public static let fallbackTokens = 128_000

    /// Longest prefix wins, so "gpt-5" does not shadow a more specific "gpt-5-nano".
    private static let families: [(prefix: String, tokens: Int)] = [
        // Anthropic
        ("claude-", 200_000),
        // OpenAI — the GPT-5 family carries 400k total (272k in / 128k out).
        ("gpt-5", 400_000),
        ("gpt-4.1", 1_000_000),
        ("gpt-4o", 128_000),
        ("o3", 200_000),
        ("o4", 200_000),
        // Google
        ("gemini-1.5-flash", 1_000_000),
        ("gemini-", 1_000_000),
        // xAI
        ("grok-4", 256_000),
        ("grok-code", 256_000),
        ("grok-3", 131_072),
        // z.ai
        ("glm-4.5", 128_000),
        ("glm-", 200_000),
        // NVIDIA build catalog (mixed publishers, mostly 128k)
        ("nvidia/", 128_000),
        ("meta/llama-3", 128_000),
        ("openai/gpt-oss", 128_000),
    ]

    public static func tokens(for model: String, kind: ProviderKind) -> Int {
        let id = model.lowercased()
        let match = families
            .filter { id.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }
        if let match { return match.tokens }
        // An unrecognised id from a provider whose whole catalog shares a floor still
        // gets that floor rather than the global fallback.
        switch kind {
        case .anthropic: return 200_000
        case .gemini: return 1_000_000
        default: return fallbackTokens
        }
    }
}
