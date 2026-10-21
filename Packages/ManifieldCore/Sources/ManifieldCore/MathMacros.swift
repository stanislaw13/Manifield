import Foundation

/// Parses LaTeX macro definitions (`\newcommand`, `\def`, `\DeclareMathOperator`, …) into a
/// KaTeX-compatible macros dictionary. Mathematicians' documents almost always carry a
/// preamble of custom macros (e.g. `\newcommand{\A}{\mathcal{A}}`); without them KaTeX
/// fails with "undefined control sequence" on otherwise fine formulas.
public enum MathMacros {

    public struct Definition: Equatable, Sendable {
        /// Command name including the backslash, e.g. `\A`.
        public let name: String
        /// KaTeX expansion, e.g. `\mathcal{A}` (may contain `#1`, `#2`, …).
        public let expansion: String
        /// The original definition text, for re-serialization into macros.tex.
        public let raw: String
    }

    /// KaTeX `macros` option dictionary: name (with backslash) → expansion.
    public static func parse(_ tex: String) -> [String: String] {
        var result: [String: String] = [:]
        for def in definitions(in: tex) {
            result[def.name] = def.expansion
        }
        return result
    }

    /// Scans arbitrary LaTeX (e.g. an imported document) for macro definitions.
    public static func definitions(in tex: String) -> [Definition] {
        let chars = Array(tex)
        var defs: [Definition] = []
        var i = 0

        while i < chars.count {
            guard chars[i] == "\\" else { i += 1; continue }
            var matched = false
            for keyword in Self.keywords {
                if let def = parseDefinition(chars, at: &i, keyword: keyword) {
                    defs.append(def)
                    matched = true
                    break
                }
            }
            if !matched { i += 1 }
        }
        return defs
    }

    /// Merges new definitions into an existing macros.tex text, skipping names already
    /// defined there. Returns (updatedText, numberAdded).
    public static func merge(into existing: String, newSource: String) -> (text: String, added: [String]) {
        let existingNames = Set(definitions(in: existing).map(\.name))
        var added: [String] = []
        var lines: [String] = []
        for def in definitions(in: newSource) where !existingNames.contains(def.name) && !added.contains(def.name) {
            lines.append(def.raw)
            added.append(def.name)
        }
        guard !lines.isEmpty else { return (existing, []) }
        var text = existing
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += lines.joined(separator: "\n") + "\n"
        return (text, added)
    }

    // MARK: - Scanner

    private static let keywords: [String] = [
        "\\newcommand", "\\renewcommand", "\\providecommand",
        "\\DeclareMathOperator", "\\def"
    ]

    private static func parseDefinition(_ chars: [Character], at index: inout Int, keyword: String) -> Definition? {
        let start = index
        var i = index
        let kw = Array(keyword)
        guard i + kw.count <= chars.count, Array(chars[i..<i+kw.count]) == kw else { return nil }
        i += kw.count

        // The next char must not be a letter (avoid matching \newcommandx etc.)
        if i < chars.count, chars[i].isLetter, keyword != "\\def" { return nil }

        var starred = false
        if i < chars.count, chars[i] == "*" { starred = true; i += 1 }
        skipSpaces(chars, &i)

        // Command name: {\name} or \name
        var name: String
        if i < chars.count, chars[i] == "{" {
            guard let (inner, next) = balancedGroup(chars, from: i) else { return nil }
            name = inner.trimmingCharacters(in: .whitespaces)
            i = next
        } else if i < chars.count, chars[i] == "\\" {
            var j = i + 1
            while j < chars.count, chars[j].isLetter { j += 1 }
            guard j > i + 1 else { return nil }
            name = String(chars[i..<j])
            i = j
        } else {
            return nil
        }
        guard name.hasPrefix("\\"), name.count > 1 else { return nil }
        skipSpaces(chars, &i)

        // Optional [nargs]
        if i < chars.count, chars[i] == "[" {
            guard let close = chars[i...].firstIndex(of: "]") else { return nil }
            i = close + 1
            skipSpaces(chars, &i)
            // Optional [default] means an optional argument — KaTeX macros can't express
            // that, so skip such definitions entirely.
            if i < chars.count, chars[i] == "[" { return nil }
        }

        // \def can have parameter text like #1#2 before the body — accept plain #n runs.
        if keyword == "\\def" {
            while i + 1 < chars.count, chars[i] == "#", chars[i+1].isNumber { i += 2 }
            skipSpaces(chars, &i)
        }

        guard i < chars.count, chars[i] == "{",
              let (body, next) = balancedGroup(chars, from: i) else { return nil }
        i = next

        let expansion: String
        if keyword == "\\DeclareMathOperator" {
            expansion = starred ? "\\operatorname*{\(body)}" : "\\operatorname{\(body)}"
        } else {
            expansion = body
        }

        index = i
        return Definition(name: name, expansion: expansion, raw: String(chars[start..<i]))
    }

    private static func skipSpaces(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
    }

    /// Reads a balanced `{...}` group starting at `from` (which must be `{`).
    /// Returns the inner content and the index just past the closing brace.
    /// `\{` and `\}` are treated as escaped characters, not group delimiters.
    private static func balancedGroup(_ chars: [Character], from: Int) -> (String, Int)? {
        guard from < chars.count, chars[from] == "{" else { return nil }
        var depth = 0
        var i = from
        var inner: [Character] = []
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if depth >= 1 { inner.append(c); inner.append(chars[i+1]) }
                i += 2
                continue
            }
            if c == "{" {
                depth += 1
                if depth > 1 { inner.append(c) }
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return (String(inner), i + 1) }
                inner.append(c)
            } else if depth >= 1 {
                inner.append(c)
            }
            i += 1
        }
        return nil
    }
}
