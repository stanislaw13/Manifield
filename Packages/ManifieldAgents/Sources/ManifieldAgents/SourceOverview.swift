import Foundation
import ManifieldCore

/// Builds the source overview (overview.md) written at the end of a literature import:
/// a one-shot synthesis of the per-chunk chapter notes into a briefing — goal, approach,
/// main results, gaps — that lets agents judge whether a source can answer their
/// question before searching it.
public enum SourceOverview {

    /// Cap on the overview as injected into agent prompts. Every attached source's
    /// overview rides along in every agent context, so they must stay compact.
    public static let maxLength = 6_000

    static let maxNotesLength = 60_000
    static let maxOutlineLength = 20_000
    public static let maxPreviewLength = 20_000

    public static func systemPrompt() -> String {
        PromptLibrary.text("source_overview_system")
    }

    /// - Parameters:
    ///   - chunkNotes: chapter notes collected during the import, in reading order.
    ///     Empty when regenerating an overview for a source imported without notes —
    ///     the synthesis then works from the outline alone.
    ///   - outline: the imported items as rendered by `ContextAssembly.outline`.
    ///   - fulltextPreview: contents + opening pages of the stored full text — the
    ///     only material available for sources imported without item extraction.
    public static func userMessage(
        name: String,
        citation: String?,
        chunkNotes: [(title: String, note: String)],
        outline: String,
        fulltextPreview: String? = nil
    ) -> String {
        var parts: [String] = []
        var header = "Work: \(name)"
        if let citation { header += "\nCitation: \(citation)" }
        parts.append(header)
        if !chunkNotes.isEmpty {
            let notes = chunkNotes
                .map { "### \($0.title)\n\($0.note)" }
                .joined(separator: "\n\n")
            parts.append("Chapter notes from the import:\n\n\(truncate(notes, maxNotesLength))")
        }
        parts.append("Outline of the imported items:\n\(truncate(outline, maxOutlineLength))")
        if let fulltextPreview, !fulltextPreview.isEmpty {
            parts.append("Excerpt of the stored full text (table of contents + opening pages):\n\n\(truncate(fulltextPreview, maxPreviewLength))")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Builds the excerpt fed to overview generation when a source carries a full
    /// text: the table of contents plus as many opening segments as fit the cap.
    public static func fulltextPreview(_ document: FullTextDocument, cap: Int = maxPreviewLength) -> String {
        var parts: [String] = []
        var size = 0
        if let contents = document.contents, !contents.isEmpty {
            parts.append("Table of contents:\n\(contents)")
            size += contents.count
        }
        for segment in document.segments {
            guard size < cap else { break }
            guard !segment.text.isEmpty else { continue }
            parts.append("— \(segment.title) —\n\(segment.text)")
            size += segment.text.count
        }
        return truncate(parts.joined(separator: "\n\n"), cap)
    }

    /// Strips a wrapping code fence (models sometimes add one despite instructions)
    /// and enforces the length cap before the overview is saved.
    public static func normalize(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return truncate(text, maxLength)
    }

    static func truncate(_ text: String, _ cap: Int) -> String {
        text.count <= cap ? text : String(text.prefix(cap)) + "\n… (truncated)"
    }
}
