import Foundation

/// One renderable unit of a theory item file.
///
/// The unit of comparison is deliberately a block and never a line. Theory items are
/// mathematics: a line diff through
///
///     $$\alpha(G) \ge \frac{n}{\Delta+1}$$
///
/// splits the formula into two fragments, and neither fragment is something KaTeX can
/// typeset — the reader gets two red errors where the change was. A block is always
/// something that renders on its own, so a diff made of blocks is always displayable.
public struct TheoryBlock: Equatable, Sendable {

    public enum Kind: String, Sendable, Equatable {
        /// One frontmatter key. Carried separately from prose because frontmatter is a
        /// record, not text: fields are matched by key, not by position.
        case field
        case heading
        case displayMath
        case code
        /// A list item with everything indented under it — how proof steps are written.
        case listItem
        case paragraph
        case rule
    }

    public let kind: Kind
    /// The frontmatter key, for `.field` blocks; nil for everything else.
    public let label: String?
    /// The block's source, ready to hand to the markdown renderer as-is.
    public let text: String

    public init(kind: Kind, label: String? = nil, text: String) {
        self.kind = kind
        self.label = label
        self.text = text
    }

    /// Whitespace-insensitive form used for matching, so a paragraph that was only
    /// re-wrapped reads as unchanged rather than as a rewrite.
    public var normalized: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Splits a theory item file into `TheoryBlock`s.
public enum TheoryBlocks {

    /// Frontmatter fields (in file order) followed by the body's blocks.
    public static func segment(document: String) -> [TheoryBlock] {
        let (frontmatter, body) = Frontmatter.split(document: document)
        var blocks = frontmatter.map(fieldBlocks) ?? []
        blocks.append(contentsOf: bodyBlocks(body))
        return blocks
    }

    // MARK: Frontmatter

    /// One block per field, in the order the file writes them — `Frontmatter.parseFields`
    /// returns a dictionary, and a diff has to show fields where the reader will look
    /// for them.
    private static func fieldBlocks(_ text: String) -> [TheoryBlock] {
        var blocks: [TheoryBlock] = []
        var listKey: String?
        var listValues: [String] = []

        func flushList() {
            guard let key = listKey else { return }
            blocks.append(TheoryBlock(
                kind: .field, label: key,
                text: "[" + listValues.joined(separator: ", ") + "]"))
            listKey = nil
            listValues = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- "), listKey != nil {
                listValues.append(String(line.dropFirst(2)))
                continue
            }
            flushList()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key           // a block list follows
            } else {
                blocks.append(TheoryBlock(kind: .field, label: key, text: value))
            }
        }
        flushList()
        return blocks
    }

    // MARK: Body

    /// Display-math environments, mirroring the set the renderer typesets whole
    /// (`ENV_RE` in render.js). Anything outside this list is prose to us.
    private static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "alignat", "alignat*",
        "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*", "CD"
    ]

    private static func bodyBlocks(_ body: String) -> [TheoryBlock] {
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [TheoryBlock] = []
        var index = 0

        func push(_ kind: TheoryBlock.Kind, _ collected: [String]) {
            let text = collected.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            blocks.append(TheoryBlock(kind: kind, text: text))
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            // Code first: its contents must never be interpreted as anything else.
            if let fence = fenceMarker(line) {
                var collected = [line]
                index += 1
                while index < lines.count {
                    collected.append(lines[index])
                    let closed = closesFence(lines[index], marker: fence)
                    index += 1
                    if closed { break }
                }
                push(.code, collected)
                continue
            }

            if let opener = displayMathOpener(trimmed) {
                var collected = [line]
                var closed = opener.closedOnOpeningLine
                index += 1
                while !closed, index < lines.count {
                    collected.append(lines[index])
                    closed = lines[index].contains(opener.terminator)
                    index += 1
                }
                push(.displayMath, collected)
                continue
            }

            if isHeading(trimmed) { push(.heading, [line]); index += 1; continue }
            if isThematicBreak(trimmed) { push(.rule, [line]); index += 1; continue }

            if isListItem(line) {
                var collected = [line]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A blank line only continues the item if indented content follows.
                        guard index + 1 < lines.count,
                              !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                              indentWidth(lines[index + 1]) >= 2 else { break }
                        collected.append(next)
                        index += 1
                        continue
                    }
                    // Indented continuation — including any display math the step contains,
                    // which stays inside the item so the list structure survives rendering.
                    guard indentWidth(next) >= 2 else { break }
                    collected.append(next)
                    index += 1
                }
                push(.listItem, collected)
                continue
            }

            // Prose runs to the next blank line, or to whatever starts a block of its own —
            // an equation set off mid-paragraph becomes its own block rather than being
            // swallowed by the sentence that introduces it.
            var collected: [String] = []
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if !collected.isEmpty, startsItsOwnBlock(next, trimmed: nextTrimmed) { break }
                collected.append(next)
                index += 1
            }
            push(.paragraph, collected)
        }
        return blocks
    }

    private static func startsItsOwnBlock(_ line: String, trimmed: String) -> Bool {
        fenceMarker(line) != nil
            || displayMathOpener(trimmed) != nil
            || isHeading(trimmed)
            || isThematicBreak(trimmed)
            || isListItem(line)
    }

    // MARK: Line classification

    private static func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 }
            else if character == "\t" { width += 4 }
            else { break }
        }
        return width
    }

    /// The opening run of a fenced code block, or nil.
    private static func fenceMarker(_ line: String) -> String? {
        guard indentWidth(line) <= 3 else { return nil }
        let rest = line.drop { $0 == " " }
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string may not itself contain a backtick.
        if first == "`", rest.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    /// A fence closes on a run of the same character, at least as long, and nothing else.
    private static func closesFence(_ line: String, marker: String) -> Bool {
        guard let first = marker.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == first }
        return run.count >= marker.count && run.count == trimmed.count
    }

    private static func isHeading(_ trimmed: String) -> Bool {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        let rest = trimmed.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " "
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        let marks = trimmed.filter { !$0.isWhitespace }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    private static func isListItem(_ line: String) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        let rest = line.drop { $0 == " " }
        if let first = rest.first, first == "-" || first == "*" || first == "+" {
            return rest.dropFirst().first == " "
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return false }
        return after.dropFirst().first == " "
    }

    /// If the line opens display math, what closes it — and whether it already did.
    private static func displayMathOpener(
        _ trimmed: String
    ) -> (terminator: String, closedOnOpeningLine: Bool)? {
        if trimmed.hasPrefix("$$") {
            return ("$$", trimmed.dropFirst(2).contains("$$"))
        }
        if trimmed.hasPrefix("\\[") {
            return ("\\]", trimmed.dropFirst(2).contains("\\]"))
        }
        if trimmed.hasPrefix("\\begin{") {
            let afterBrace = trimmed.dropFirst("\\begin{".count)
            guard let close = afterBrace.firstIndex(of: "}") else { return nil }
            let environment = String(afterBrace[..<close])
            guard mathEnvironments.contains(environment) else { return nil }
            let terminator = "\\end{\(environment)}"
            return (terminator, trimmed.contains(terminator))
        }
        return nil
    }
}

// MARK: - Diff

/// What happened to one block between two versions of an item.
public struct BlockChange: Equatable, Sendable {

    public enum Kind: String, Sendable, Equatable {
        case unchanged, added, removed, changed
    }

    public let kind: Kind
    /// The block as it was; nil for an addition.
    public let before: TheoryBlock?
    /// The block as it is now; nil for a removal.
    public let after: TheoryBlock?

    public init(kind: Kind, before: TheoryBlock?, after: TheoryBlock?) {
        self.kind = kind
        self.before = before
        self.after = after
    }

    public var blockKind: TheoryBlock.Kind { (after ?? before)?.kind ?? .paragraph }
    public var label: String? { (after ?? before)?.label }
}

/// One run of words inside a changed block.
public struct WordRun: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable { case same, removed, added }

    public let kind: Kind
    /// The source text of the run, including the whitespace that preceded it —
    /// concatenating a side's runs reproduces that side exactly.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum BlockDiff {

    /// How much two blocks of the same kind must have in common to read as one block that
    /// was edited rather than as a removal followed by an unrelated addition.
    private static let rewriteThreshold = 0.35

    /// Block-level diff of two item files. `before` is nil for a create, where every
    /// block is new.
    public static func compare(before: String?, after: String) -> [BlockChange] {
        let afterBlocks = TheoryBlocks.segment(document: after)
        guard let before else {
            return afterBlocks.map { BlockChange(kind: .added, before: nil, after: $0) }
        }
        let beforeBlocks = TheoryBlocks.segment(document: before)

        // Frontmatter is matched by key and prose by content, so they are aligned
        // separately: renaming a field is not the same event as rewriting a paragraph.
        let fields = align(
            beforeBlocks.filter { $0.kind == .field },
            afterBlocks.filter { $0.kind == .field },
            key: { $0.label ?? "" })
        let body = align(
            beforeBlocks.filter { $0.kind != .field },
            afterBlocks.filter { $0.kind != .field },
            key: { $0.normalized })
        return fields + body
    }

    /// Aligns two block lists on `key`, then turns each unmatched stretch into
    /// removals, additions, and — where a removal and an addition are recognisably the
    /// same block edited — single `changed` entries.
    private static func align(
        _ before: [TheoryBlock],
        _ after: [TheoryBlock],
        key: (TheoryBlock) -> String
    ) -> [BlockChange] {
        var changes: [BlockChange] = []
        var beforeIndex = 0
        var afterIndex = 0
        var removed: [TheoryBlock] = []
        var added: [TheoryBlock] = []

        func flush() {
            changes.append(contentsOf: pair(removed: removed, added: added))
            removed = []
            added = []
        }

        for (matchedBefore, matchedAfter) in lcs(before.map(key), after.map(key)) {
            while beforeIndex < matchedBefore { removed.append(before[beforeIndex]); beforeIndex += 1 }
            while afterIndex < matchedAfter { added.append(after[afterIndex]); afterIndex += 1 }
            flush()
            // Body blocks match on their content, so a match there is always unchanged.
            // Fields match on their key, so a matched field may still have a new value.
            let old = before[beforeIndex], new = after[afterIndex]
            changes.append(BlockChange(
                kind: old.normalized == new.normalized ? .unchanged : .changed,
                before: old, after: new))
            beforeIndex += 1
            afterIndex += 1
        }
        while beforeIndex < before.count { removed.append(before[beforeIndex]); beforeIndex += 1 }
        while afterIndex < after.count { added.append(after[afterIndex]); afterIndex += 1 }
        flush()
        return changes
    }

    /// Greedily marries removals to additions of the same kind that still look like the
    /// same block, so an edited paragraph shows once in amber rather than twice in red
    /// and green.
    private static func pair(removed: [TheoryBlock], added: [TheoryBlock]) -> [BlockChange] {
        var partner: [Int: Int] = [:]
        var claimed: Set<Int> = []
        for (removedIndex, old) in removed.enumerated() {
            var best: (index: Int, score: Double)?
            for (addedIndex, new) in added.enumerated()
            where !claimed.contains(addedIndex) && new.kind == old.kind {
                let score = similarity(old.normalized, new.normalized)
                guard score >= rewriteThreshold, score > (best?.score ?? 0) else { continue }
                best = (addedIndex, score)
            }
            if let best {
                claimed.insert(best.index)
                partner[removedIndex] = best.index
            }
        }

        var changes: [BlockChange] = []
        for (removedIndex, old) in removed.enumerated() {
            if let addedIndex = partner[removedIndex] {
                changes.append(BlockChange(kind: .changed, before: old, after: added[addedIndex]))
            } else {
                changes.append(BlockChange(kind: .removed, before: old, after: nil))
            }
        }
        for (addedIndex, new) in added.enumerated() where !claimed.contains(addedIndex) {
            changes.append(BlockChange(kind: .added, before: nil, after: new))
        }
        return changes
    }

    /// Share of words the two texts have in common, against the longer of them.
    private static func similarity(_ old: String, _ new: String) -> Double {
        let oldWords = old.lowercased().split(separator: " ")
        let newWords = new.lowercased().split(separator: " ")
        guard !oldWords.isEmpty, !newWords.isEmpty else { return 0 }
        var pool: [Substring: Int] = [:]
        for word in oldWords { pool[word, default: 0] += 1 }
        var common = 0
        for word in newWords where (pool[word] ?? 0) > 0 {
            pool[word]! -= 1
            common += 1
        }
        return Double(common) / Double(max(oldWords.count, newWords.count))
    }

    // MARK: Word level

    /// Word-level runs for one changed block, computed over the block's *source*. The
    /// diff view offers this inside a changed block on demand: rendered output cannot
    /// carry the highlight through KaTeX, but the source can.
    public static func words(before: String, after: String) -> (before: [WordRun], after: [WordRun]) {
        let oldTokens = tokenize(before)
        let newTokens = tokenize(after)
        var beforeRuns: [WordRun] = []
        var afterRuns: [WordRun] = []

        func append(_ runs: inout [WordRun], _ kind: WordRun.Kind, _ text: String) {
            if let last = runs.last, last.kind == kind {
                runs[runs.count - 1] = WordRun(kind: kind, text: last.text + text)
            } else {
                runs.append(WordRun(kind: kind, text: text))
            }
        }

        var oldIndex = 0
        var newIndex = 0
        for (matchedOld, matchedNew) in lcs(oldTokens.map(\.key), newTokens.map(\.key)) {
            while oldIndex < matchedOld {
                append(&beforeRuns, .removed, oldTokens[oldIndex].text)
                oldIndex += 1
            }
            while newIndex < matchedNew {
                append(&afterRuns, .added, newTokens[newIndex].text)
                newIndex += 1
            }
            append(&beforeRuns, .same, oldTokens[oldIndex].text)
            append(&afterRuns, .same, newTokens[newIndex].text)
            oldIndex += 1
            newIndex += 1
        }
        while oldIndex < oldTokens.count {
            append(&beforeRuns, .removed, oldTokens[oldIndex].text)
            oldIndex += 1
        }
        while newIndex < newTokens.count {
            append(&afterRuns, .added, newTokens[newIndex].text)
            newIndex += 1
        }
        return (beforeRuns, afterRuns)
    }

    private struct Token {
        /// The word plus the whitespace that came before it, so the runs reassemble losslessly.
        let text: String
        /// What the word is compared on.
        let key: String
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var pendingSpace = ""
        var word = ""
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty {
                    tokens.append(Token(text: pendingSpace + word, key: word))
                    pendingSpace = ""
                    word = ""
                }
                pendingSpace.append(character)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty {
            tokens.append(Token(text: pendingSpace + word, key: word))
        } else if !pendingSpace.isEmpty {
            // Trailing whitespace rides along on the last token rather than being dropped.
            if let last = tokens.popLast() {
                tokens.append(Token(text: last.text + pendingSpace, key: last.key))
            } else {
                tokens.append(Token(text: pendingSpace, key: ""))
            }
        }
        return tokens
    }

    // MARK: LCS

    /// Above this many differing elements per side the quadratic table is not worth
    /// building: the result would be a wall of colour either way, so fall back to
    /// "all of this went, all of that arrived".
    private static let alignmentLimit = 1_500

    /// Longest common subsequence as index pairs into the two inputs.
    ///
    /// The shared head and tail are matched directly — for the usual edit, a word or a
    /// sentence inside otherwise identical text, that leaves the table with almost
    /// nothing to do.
    private static func lcs(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        var matches = (0..<head).map { ($0, $0) }
        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])

        if !oldMiddle.isEmpty, !newMiddle.isEmpty,
           oldMiddle.count <= alignmentLimit, newMiddle.count <= alignmentLimit {
            let rows = oldMiddle.count + 1
            let columns = newMiddle.count + 1
            var table = [Int32](repeating: 0, count: rows * columns)
            for i in stride(from: oldMiddle.count - 1, through: 0, by: -1) {
                for j in stride(from: newMiddle.count - 1, through: 0, by: -1) {
                    table[i * columns + j] = oldMiddle[i] == newMiddle[j]
                        ? table[(i + 1) * columns + (j + 1)] + 1
                        : max(table[(i + 1) * columns + j], table[i * columns + (j + 1)])
                }
            }
            var i = 0, j = 0
            while i < oldMiddle.count, j < newMiddle.count {
                if oldMiddle[i] == newMiddle[j] {
                    matches.append((head + i, head + j))
                    i += 1
                    j += 1
                } else if table[(i + 1) * columns + j] >= table[i * columns + (j + 1)] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }

        for offset in 0..<tail {
            matches.append((old.count - tail + offset, new.count - tail + offset))
        }
        return matches
    }
}
