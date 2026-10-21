import Foundation

/// Textually expands zero-argument project macros (`\newcommand{\A}{\mathcal{A}}`) inside
/// a LaTeX snippet. The native list renderer (SwiftMath) knows nothing about the project's
/// macros.tex, so names are substituted before rendering; macros taking arguments (`#1`)
/// are left untouched — the renderer's failure path shows those names as plain text.
public enum MathExpansion {

    public static func expand(_ latex: String, macros: [String: String], maxDepth: Int = 8) -> String {
        let zeroArg = macros.filter { !$0.value.contains("#") && $0.key.hasPrefix("\\") }
        guard !zeroArg.isEmpty, latex.contains("\\") else { return latex }
        // Longest names first so \Ab never gets clobbered by \A.
        let names = zeroArg.keys.sorted { $0.count > $1.count }

        var text = latex
        for _ in 0..<maxDepth {
            var changed = false
            for name in names {
                guard text.contains(name), let expansion = zeroArg[name] else { continue }
                text = replace(name, with: expansion, in: text, changed: &changed)
            }
            if !changed { break }
        }
        return text
    }

    /// Replaces occurrences of `name` that are not a prefix of a longer command
    /// (i.e. the next character is not a letter).
    private static func replace(
        _ name: String, with expansion: String, in text: String, changed: inout Bool
    ) -> String {
        var result = ""
        var index = text.startIndex
        while let range = text.range(of: name, range: index..<text.endIndex) {
            result += text[index..<range.lowerBound]
            let after = range.upperBound
            if after == text.endIndex || !text[after].isLetter {
                result += expansion
                changed = true
            } else {
                result += text[range]
            }
            index = after
        }
        result += text[index...]
        return result
    }
}
