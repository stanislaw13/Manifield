import Foundation

/// Reading LaTeX well enough to cut it in the right places.
///
/// Two jobs, both previously done by regex and both wrong in the same way. Headings were
/// matched with `\\(chapter|section)\*?\s*\{([^{}]*)\}`, which cannot see
/// `\chapter{The spaces $L^p(\mathbb{R})$}` — a title with braces in it, which in
/// mathematics is most of them — so a book could look heading-free and fall through to
/// blind size splitting. And size splitting cut on blank lines, which land *inside*
/// `\begin{theorem}` and `\begin{proof}` bodies routinely, handing the model half a
/// theorem and inviting it to invent the other half.
///
/// Both are fixed by actually tracking structure: balanced-brace scanning for headings,
/// environment nesting for cut points.
enum LaTeXStructure {

    // MARK: - What counts as the document

    /// The part of a `.tex` file that is actually typeset: everything up to and including
    /// `\end{document}`, with whole-line comments dropped.
    ///
    /// LaTeX stops reading at `\end{document}`, and files in the wild put things after it
    /// — notes, dead drafts, and in one real case a megabyte of base64-encoded PDF that a
    /// `\directlua` block unpacks at compile time. Importing that trailing material means
    /// paying a model to read something the document itself does not contain.
    ///
    /// The preamble is kept: macro definitions live there, and a stray definition stated
    /// in an introduction should not be lost.
    static func documentBody(of tex: String) -> String {
        var lines: [String] = []
        for line in tex.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") { continue }  // whole-line comment
            lines.append(line)
            if trimmed.contains("\\end{document}") { break }
        }
        let body = lines.joined(separator: "\n")

        // Drop the preamble too. `\usepackage`, `\newtheorem` and `\newcommand` state no
        // mathematics; macro definitions are harvested from the raw file separately. Left
        // in, they become a "Front Matter" chunk that costs a model call to be told there
        // is nothing in it — and a preamble is odd enough input that the reply often is
        // not the JSON the parser expects. A file with no `\begin{document}` is a
        // fragment meant to be `\input`, and keeps everything.
        guard let start = body.range(of: "\\begin{document}") else { return body }
        return String(body[start.upperBound...])
    }

    /// The text between `\begin{document}` and `\end{document}` — what the file actually
    /// typesets. Nil when there is no `\begin{document}` at all, which means the file is
    /// a fragment (a chapter meant to be `\input`), and a fragment is a fair import.
    static func typesetBody(of tex: String) -> String? {
        guard let start = tex.range(of: "\\begin{document}") else { return nil }
        let afterStart = tex[start.upperBound...]
        guard let end = afterStart.range(of: "\\end{document}") else { return String(afterStart) }
        return String(afterStart[..<end.lowerBound])
    }

    /// A sectioning command found in the source.
    struct Heading: Equatable {
        enum Level: Equatable {
            case chapter
            case section
            case subsection
        }
        let level: Level
        let title: String
        /// Offset of the command's backslash.
        let start: String.Index
        /// Offset just past the title's closing brace — where the body begins.
        let bodyStart: String.Index
    }

    /// Every `\chapter` / `\section` / `\subsection` (starred or not, with or without a
    /// `[short]` title) in document order. Titles are returned raw; slug them with
    /// `cleanTitle` first so `\mathcal{O}` does not leak into an id.
    static func headings(in text: String, levels: Set<Heading.Level> = [.chapter, .section]) -> [Heading] {
        var result: [Heading] = []
        var search = text.startIndex
        while search < text.endIndex {
            guard let backslash = text[search...].firstIndex(of: "\\") else { break }
            var matched = false
            // Longest name first: \subsection must not be read as \section.
            for (name, level) in [("subsection", Heading.Level.subsection),
                                  ("section", .section),
                                  ("chapter", .chapter)] {
                guard let hit = command(named: name, in: text, at: backslash) else { continue }
                if levels.contains(level) {
                    result.append(Heading(level: level, title: hit.title,
                                          start: backslash, bodyStart: hit.end))
                }
                search = hit.end
                matched = true
                break
            }
            if !matched {
                search = text.index(after: backslash)
            }
        }
        return result
    }

    /// Matches `\<name>{title}`, `\<name>*{title}` or `\<name>[short]{title}` at
    /// `backslash`, returning the balanced title and the index just past its closing brace.
    static func command(
        named name: String, in text: String, at backslash: String.Index
    ) -> (title: String, end: String.Index)? {
        var index = text.index(after: backslash)
        guard text[index...].hasPrefix(name) else { return nil }
        index = text.index(index, offsetBy: name.count)
        // A letter here means a longer command name (rejects \sectioning).
        if index < text.endIndex, text[index].isLetter { return nil }
        if index < text.endIndex, text[index] == "*" { index = text.index(after: index) }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        // Skip an optional short-title argument: \section[Short]{Long}.
        if index < text.endIndex, text[index] == "[" {
            guard let close = text[index...].firstIndex(of: "]") else { return nil }
            index = text.index(after: close)
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        }
        guard index < text.endIndex, text[index] == "{" else { return nil }
        var depth = 0
        var start = index
        var scan = index
        while scan < text.endIndex {
            switch text[scan] {
            case "{":
                if depth == 0 { start = text.index(after: scan) }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return (String(text[start..<scan]), text.index(after: scan))
                }
            default:
                break
            }
            scan = text.index(after: scan)
        }
        return nil
    }

    /// The first `\<name>{…}` anywhere in the text, or nil.
    static func firstCommand(named name: String, in text: String) -> String? {
        var search = text.startIndex
        while let backslash = text[search...].firstIndex(of: "\\") {
            if let hit = command(named: name, in: text, at: backslash) { return hit.title }
            search = text.index(after: backslash)
        }
        return nil
    }

    /// Strips math/command noise from a heading before slugging: `\mathcal` etc. vanish
    /// instead of leaking into slugs.
    static func cleanTitle(_ raw: String) -> String {
        var out = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index]
            if char == "\\" {
                index = raw.index(after: index)
                while index < raw.endIndex, raw[index].isLetter {
                    index = raw.index(after: index)
                }
                continue
            }
            if !"${}^_~".contains(char) { out.append(char) }
            index = raw.index(after: index)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Environment nesting

    /// What one line does to the surrounding nesting state: `\begin{…}` and `\[` open,
    /// `\end{…}` and `\]` close, and an odd number of `$$` flips display math on or off.
    /// Which environment it is never matters — a cut point is safe exactly when nothing
    /// is open.
    struct NestingEffect: Equatable {
        var delta = 0
        var togglesDollarMath = false
    }

    static func nestingEffect(of line: String) -> NestingEffect {
        var effect = NestingEffect()
        var index = line.startIndex
        while index < line.endIndex {
            guard let backslash = line[index...].firstIndex(of: "\\") else { break }
            let after = line.index(after: backslash)
            if after >= line.endIndex { break }
            switch line[after] {
            case "[":
                effect.delta += 1
                index = line.index(after: after)
                continue
            case "]":
                effect.delta -= 1
                index = line.index(after: after)
                continue
            default:
                break
            }
            if line[after...].hasPrefix("begin"), command(named: "begin", in: line, at: backslash) != nil {
                effect.delta += 1
            } else if line[after...].hasPrefix("end"), command(named: "end", in: line, at: backslash) != nil {
                effect.delta -= 1
            }
            index = after
        }
        var dollarRuns = 0
        var scan = line.startIndex
        while scan < line.endIndex, let range = line[scan...].range(of: "$$") {
            dollarRuns += 1
            scan = range.upperBound
        }
        effect.togglesDollarMath = dollarRuns % 2 == 1
        return effect
    }
}
