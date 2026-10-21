import Foundation

/// `[LLMMessage] -> Responses API item`, for `thread/inject_items`.
///
/// **These are true OpenAI Responses API items, not Codex `ThreadItem`s.** The two shapes are
/// easy to conflate because `item/completed` emits `ThreadItem`s (`agentMessage`,
/// `dynamicToolCall`, `reasoning`, …) on the way *out* — but `ThreadInjectItemsParams.items` is
/// documented as "raw Responses API items to append to the thread's model-visible history" and
/// typed as an untyped passthrough, so a `ThreadItem`-shaped payload would be accepted here
/// without complaint and only fail later, at the model call, far from the cause.
///
/// Reuses `responsesItems(for:)` — the exact mapping `OpenAIResponsesProvider` already sends over
/// HTTP — rather than a second implementation of the same translation.
///
/// `CodexRunner` uses this for every compatible binary. Older binaries that lack
/// `thread/inject_items` retain the flattened replay compatibility path.
enum CodexHistoryReplay {

    /// Responses API items ready for `thread/inject_items`. Assistant reasoning is dropped rather
    /// than replayed: `.reasoningItem` carries a Responses-API `rs_*` id bound to a *different*
    /// thread and Codex would reject a foreign one; `.thinking`/`.redactedThinking` have no
    /// Responses-API channel to begin with (the shared mapper already drops them, this just makes
    /// the omission explicit here too, in case that mapper ever changes).
    static func items(for messages: [LLMMessage]) -> [[String: Any]] {
        responsesItems(for: messages.map(strippedOfReasoning))
    }

    private static func strippedOfReasoning(_ message: LLMMessage) -> LLMMessage {
        LLMMessage(role: message.role, blocks: message.blocks.filter {
            switch $0 {
            case .reasoningItem, .thinking, .redactedThinking: return false
            default: return true
            }
        })
    }
}
