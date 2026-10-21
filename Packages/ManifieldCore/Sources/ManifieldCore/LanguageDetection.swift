import Foundation
import NaturalLanguage

/// Which natural language a body of text is written in.
///
/// This exists because full-text search is literal: a Polish paper's index matches
/// nothing at all for English terms, and an agent that reasons in the language of the
/// *conversation* silently concludes the source says nothing on the subject. Every search
/// surface therefore reports the language of the corpus it queries, so the agent can
/// translate its terms before searching.
public enum LanguageDetection {

    public struct Language: Equatable, Sendable {
        /// BCP-47 code, e.g. "pl".
        public let code: String
        /// English name, e.g. "Polish" — this is what agents are told.
        public let name: String

        public init(code: String, name: String) {
            self.code = code
            self.name = name
        }
    }

    /// Below this the recognizer is guessing. Mathematical prose is full of shared
    /// vocabulary (proper names, Latin, symbols), so near-ties are common and a confident
    /// wrong answer is worse than saying nothing.
    static let minimumConfidence = 0.55
    /// Fewer prose words than this and the sample is noise — a page of pure formulas, or
    /// an item that is a bare statement of symbols.
    static let minimumWords = 12
    /// Detection saturates long before this; the cap keeps a book-sized sample cheap.
    static let maxSampleLength = 20_000

    /// The dominant language of `samples` taken together, or nil when there is too little
    /// prose to tell.
    public static func detect(_ samples: [String]) -> Language? {
        var text = ""
        for sample in samples {
            text += prose(from: sample) + "\n"
            if text.count >= maxSampleLength { break }
        }
        return detectProse(String(text.prefix(maxSampleLength)))
    }

    public static func detect(_ text: String) -> Language? {
        detect([text])
    }

    /// English name for a BCP-47 code, falling back to the code itself for ones the
    /// system has no name for.
    public static func displayName(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    private static func detectProse(_ text: String) -> Language? {
        guard wordCount(text) >= minimumWords else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 3)
            .max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence,
              best.key != .undetermined else { return nil }
        let code = best.key.rawValue
        return Language(code: code, name: displayName(for: code))
    }

    /// Strips what would skew the recognizer — math, LaTeX commands, code, URLs and
    /// identifiers — leaving the natural-language words the index is really made of.
    static func prose(from text: String) -> String {
        var stripped = text
        for pattern in strippedPatterns {
            stripped = pattern.stringByReplacingMatches(
                in: stripped,
                range: NSRange(stripped.startIndex..., in: stripped),
                withTemplate: " ")
        }
        return stripped
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 2 }
            .count
    }

    private static let strippedPatterns: [NSRegularExpression] = [
        "```[\\s\\S]*?```",              // fenced code
        "\\$\\$[\\s\\S]*?\\$\\$",        // display math
        "\\\\\\[[\\s\\S]*?\\\\\\]",      // \[ … \]
        "\\\\\\([\\s\\S]*?\\\\\\)",      // \( … \)
        "\\$[^$\\n]*\\$",                // inline math
        "\\\\[a-zA-Z]+",                 // leftover LaTeX commands
        "https?://\\S+",
        "[A-Za-z0-9-]*[0-9_][A-Za-z0-9_-]*", // numbered labels, snake_case
        "[A-Za-z]+(?:-[A-Za-z]+)+"           // item ids and slugs (thm-division)
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}
