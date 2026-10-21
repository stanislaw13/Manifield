import Foundation

/// Turns raw per-page PDF text extraction into markdown-ish plain text fit for agents:
/// running headers/footers and page numbers stripped, end-of-line hyphenation undone,
/// hard-wrapped lines reflowed into paragraphs. Deliberately conservative — math-heavy
/// PDFs extract messily, and a cleanup that guesses structure would corrupt more than
/// it fixes. Pure string processing; PDFKit extraction stays in the app layer.
public enum PDFTextCleanup {

    /// Cleans every page. The result has the same count and order as the input, so
    /// page numbers remain valid segment addresses.
    public static func clean(pages: [String]) -> [String] {
        let normalized = pages.map(normalize)
        let furniture = furnitureFingerprints(pages: normalized)
        return normalized.map { reflow(stripEdges(of: $0, furniture: furniture)) }
    }

    // MARK: - Normalization

    /// Uniform line endings, control characters dropped, per-line trailing space removed.
    static func normalize(_ page: String) -> String {
        var text = page.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = String(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).isEmpty ? "" : String($0).trimmingTrailing() }
            .joined(separator: "\n")
    }

    // MARK: - Running headers/footers

    /// Fingerprints of lines that repeat at page edges across a large share of pages
    /// (book titles, chapter names, author names in headers/footers). Page numbers vary
    /// per page, so digits are masked before counting. Only the outermost line of each
    /// edge is considered, and only if it looks like a heading (short, no sentence
    /// punctuation) — masked digits would otherwise make body lines like "Theorem 4.2
    /// holds." collide across pages.
    static func furnitureFingerprints(pages: [String]) -> Set<String> {
        guard pages.count >= 6 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            let lines = page.split(separator: "\n").map(String.init)
            let edges = [lines.first, lines.last].compactMap { $0 }
            let candidates = edges.filter { line in
                line.count <= 60 && !".,:;?!".contains(line.last ?? " ")
            }
            for line in Set(candidates.map(fingerprint)) where line.count >= 5 {
                counts[line, default: 0] += 1
            }
        }
        let threshold = max(3, (pages.count * 2) / 5)
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    static func fingerprint(_ line: String) -> String {
        String(line.lowercased().map { $0.isNumber ? "#" : $0 })
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Drops furniture and standalone page numbers from the first and last few lines
    /// of a page; stops at the first line of real content from either edge.
    static func stripEdges(of page: String, furniture: Set<String>) -> String {
        var lines = page.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func isDroppable(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if isPageNumber(trimmed) { return true }
            return furniture.contains(fingerprint(trimmed))
        }

        var dropped = 0
        while let first = lines.first, isDroppable(first), dropped < 4 {
            if !first.trimmingCharacters(in: .whitespaces).isEmpty { dropped += 1 }
            lines.removeFirst()
        }
        dropped = 0
        while let last = lines.last, isDroppable(last), dropped < 4 {
            if !last.trimmingCharacters(in: .whitespaces).isEmpty { dropped += 1 }
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// "12", "Page 12", "12 / 400" — never bare roman numerals ("xi" is a variable in
    /// half the math literature).
    static func isPageNumber(_ line: String) -> Bool {
        line.range(of: #"^(?:[Pp]age\s+)?\d{1,4}(?:\s*/\s*\d{1,4})?$"#,
                   options: .regularExpression) != nil
    }

    // MARK: - Reflow

    /// Undoes end-of-line hyphenation, joins hard-wrapped lines into paragraphs
    /// (blank lines remain paragraph breaks), collapses runs of blanks and spaces.
    static func reflow(_ page: String) -> String {
        var text = page
        // "exam-\nple" → "example"; "Navier-\nStokes" keeps its hyphen.
        text = text.replacingOccurrences(
            of: #"([\p{L}])-[ \t]*\n[ \t]*(\p{Ll})"#,
            with: "$1$2", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"([\p{L}])-[ \t]*\n[ \t]*(\p{Lu})"#,
            with: "$1-$2", options: .regularExpression)
        // Single newline = hard wrap; double = paragraph break.
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var text = self
        while let last = text.last, last == " " || last == "\t" {
            text.removeLast()
        }
        return text
    }
}
