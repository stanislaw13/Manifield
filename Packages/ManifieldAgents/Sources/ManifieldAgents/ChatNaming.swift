import Foundation

/// Generates a short, quirky title for a new chat from its opening message. A separate,
/// cheap round-trip (AgentTask.chatNaming) rather than folding into the main chat turn,
/// so it never delays or complicates Prismo's actual reply.
public enum ChatNaming {
    public static var systemPrompt: String { PromptLibrary.text("chat_naming") }

    /// Best-effort cleanup of a model's raw title output: strips wrapping quotes and a
    /// trailing period, then caps length as a safety net against a model that ignores
    /// the "title only" instruction.
    public static func sanitize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        while t.hasSuffix(".") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(60))
    }
}
