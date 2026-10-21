import Foundation
import ManifieldCore

/// Splits large documents (books, long articles) into Organizer-sized chunks. Whole
/// books exceed model context, so import runs chapter-by-chapter: LaTeX splits on
/// \chapter/\section, PDFs on page batches. Chapter/section titles become the section
/// slugs of the imported items.
public enum SourceImport {

    /// Chunk size used when no model budget is supplied — fulltext segmentation, tests,
    /// and any caller that just wants the document's natural structure. Live imports
    /// pass `ImportBudget.maxChunkCharacters` instead.
    public static let defaultMaxChunkSize = 24_000

    public struct Chunk: Equatable, Sendable {
        /// Human-readable title, e.g. "Weierstrass Theory — Division".
        public let title: String
        /// Section slug assigned to items from this chunk, e.g. "weierstrass-theory/division".
        public let section: String
        public let text: String
        /// The cut that opened this chunk fell inside a theorem/proof/environment, so
        /// its first lines are the tail of something the previous chunk began. Only ever
        /// set when a single environment was itself larger than the chunk budget.
        public let startsMidStructure: Bool
        /// Symmetrically: this chunk's last lines are the head of something the next
        /// chunk finishes. Both flags reach the Organizer as an explicit instruction
        /// not to invent the missing half.
        public let endsMidStructure: Bool

        public init(title: String, section: String, text: String,
                    startsMidStructure: Bool = false, endsMidStructure: Bool = false) {
            self.title = title
            self.section = section
            self.text = text
            self.startsMidStructure = startsMidStructure
            self.endsMidStructure = endsMidStructure
        }
    }

    // MARK: - LaTeX

    public static func splitLaTeX(_ tex: String, maxChunkSize: Int = defaultMaxChunkSize) -> [Chunk] {
        let tex = LaTeXStructure.documentBody(of: tex)
        let headings = LaTeXStructure.headings(in: tex)
        guard !headings.isEmpty else {
            return structuredSplit(
                Chunk(title: "Document", section: "imported", text: tex), maxChunkSize)
        }

        var chunks: [Chunk] = []

        // Front matter before the first heading (usually preamble; macros are harvested
        // separately, but definitions stated in an introduction should not be lost).
        let head = String(tex[tex.startIndex..<headings[0].start])
        if meaningfulLength(head) > 400 {
            chunks.append(contentsOf: structuredSplit(
                Chunk(title: "Front Matter", section: "front-matter", text: head), maxChunkSize))
        }

        var currentChapterSlug: String? = nil
        for (index, heading) in headings.enumerated() {
            let title = LaTeXStructure.cleanTitle(heading.title)
            let slug = TheoryItem.sanitizeID(title)
            let bodyEnd = index + 1 < headings.count ? headings[index + 1].start : tex.endIndex
            let body = String(tex[heading.bodyStart..<bodyEnd])

            let section: String
            if heading.level == .chapter {
                currentChapterSlug = slug
                section = slug
            } else {
                section = currentChapterSlug.map { "\($0)/\(slug)" } ?? slug
            }
            guard meaningfulLength(body) > 80 else { continue }  // heading directly followed by subheading
            chunks.append(contentsOf: structuredSplit(
                Chunk(title: title.isEmpty ? "Section" : title, section: section, text: body),
                maxChunkSize))
        }
        return chunks
    }

    // MARK: - PDF / plain text

    public static func splitPages(_ pages: [String], pagesPerChunk: Int = 8) -> [Chunk] {
        guard !pages.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var start = 0
        while start < pages.count {
            let end = min(start + pagesPerChunk, pages.count)
            let text = pages[start..<end].joined(separator: "\n\n")
            let part = chunks.count + 1
            chunks.append(Chunk(
                title: "Part \(part) (pages \(start + 1)–\(end))",
                section: "part-\(part)",
                text: text
            ))
            start = end
        }
        return chunks
    }

    // MARK: - PDF with a bookmark outline

    /// A PDF bookmark, flattened: `depth` 0 becomes a top-level section slug,
    /// depth 1 a `parent/child` slug (deeper levels are pre-clamped by the caller).
    public struct OutlineEntry: Equatable, Sendable {
        public let title: String
        /// 0-based index of the section's first page.
        public let pageIndex: Int
        public let depth: Int

        public init(title: String, pageIndex: Int, depth: Int) {
            self.title = title
            self.pageIndex = pageIndex
            self.depth = depth
        }
    }

    /// Splits by the document's real structure: each outline entry becomes a section
    /// whose pages are batched `pagesPerChunk` at a time — chunk boundaries never
    /// straddle a section. `pages` must keep their original positions (blank pages
    /// included) so bookmark page numbers line up. Returns nil for degenerate
    /// outlines — the caller falls back to plain `part-N` batching.
    public static func splitPages(
        _ pages: [String],
        outline: [OutlineEntry],
        pagesPerChunk: Int = 8
    ) -> [Chunk]? {
        let entries = outline
            .filter { (0..<pages.count).contains($0.pageIndex) }
            .sorted { ($0.pageIndex, $0.depth) < ($1.pageIndex, $1.depth) }
        guard entries.count >= 2, entries.count <= 200 else { return nil }

        var chunks: [Chunk] = []
        var currentTopSlug: String?
        var seenSlugs: Set<String> = []

        // Pages before the first bookmark: title pages, preface — keep when substantial.
        let head = pages[..<entries[0].pageIndex].joined(separator: "\n\n")
        if head.trimmingCharacters(in: .whitespacesAndNewlines).count > 400 {
            chunks += batches(pages: pages, range: 0..<entries[0].pageIndex,
                              title: "Front Matter", section: "front-matter",
                              pagesPerChunk: pagesPerChunk)
        }

        for (position, entry) in entries.enumerated() {
            let slugPart = TheoryItem.sanitizeID(entry.title)
            var slug: String
            if entry.depth == 0 {
                currentTopSlug = slugPart
                slug = slugPart
            } else {
                slug = currentTopSlug.map { "\($0)/\(slugPart)" } ?? slugPart
            }
            var counter = 2
            while !seenSlugs.insert(slug).inserted {
                slug = entry.depth == 0 || currentTopSlug == nil
                    ? "\(slugPart)-\(counter)"
                    : "\(currentTopSlug!)/\(slugPart)-\(counter)"
                counter += 1
            }
            let end = position + 1 < entries.count ? entries[position + 1].pageIndex : pages.count
            let range = entry.pageIndex..<max(end, entry.pageIndex)
            let text = pages[range].joined(separator: "\n\n")
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).count > 80 else {
                continue  // a bookmark right before its first child, or a blank stub
            }
            chunks += batches(pages: pages, range: range, title: entry.title,
                              section: slug, pagesPerChunk: pagesPerChunk)
        }
        // An outline that discards nearly everything is worse than page batching.
        let covered = chunks.reduce(0) { $0 + $1.text.count }
        let total = pages.joined().count
        guard !chunks.isEmpty, total == 0 || covered * 2 >= total else { return nil }
        return chunks
    }

    private static func batches(
        pages: [String], range: Range<Int>, title: String, section: String, pagesPerChunk: Int
    ) -> [Chunk] {
        var result: [Chunk] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(start + pagesPerChunk, range.upperBound)
            result.append(Chunk(
                title: "\(title) (pages \(start + 1)–\(end))",
                section: section,
                text: pages[start..<end].joined(separator: "\n\n")
            ))
            start = end
        }
        return result
    }

    // MARK: - Screening

    /// What a screening pass concluded about a set of chunks.
    public struct Screening: Sendable {
        public var chunks: [Chunk]
        public var warnings: [String]
        /// Why nothing is left, phrased for the user. Nil when something survived.
        public var emptyReason: String?
    }

    /// Drops chunks that hold no readable text before any of them is paid for.
    ///
    /// Encoded payloads reach the importer more often than one would hope: PDFs embedded
    /// in a `.tex` wrapper, inlined images, uuencoded attachments. Every one is a chunk
    /// the Organizer will read, be rate-limited over, and correctly find nothing in — and
    /// the user is left with an import that ran for ten minutes and produced an empty
    /// source with no explanation. Catching it here costs one pass over the text.
    public static func screen(_ chunks: [Chunk]) -> Screening {
        var kept: [Chunk] = []
        var droppedChars = 0
        var sawPDFPayload = false

        for chunk in chunks {
            if isEncodedPayload(chunk.text) {
                droppedChars += chunk.text.count
                sawPDFPayload = sawPDFPayload || chunk.text.contains("JVBERi")  // base64 "%PDF"
            } else {
                kept.append(chunk)
            }
        }

        var warnings: [String] = []
        if droppedChars > 0 {
            warnings.append("Skipped \(droppedChars / 1_000)k characters of encoded data (not readable text) — no model calls were spent on it.")
        }
        guard kept.isEmpty, droppedChars > 0 else {
            return Screening(chunks: kept, warnings: warnings, emptyReason: nil)
        }
        return Screening(
            chunks: [],
            warnings: warnings,
            emptyReason: sawPDFPayload
                ? "This file has no importable content: its text is a PDF encoded as base64 inside a LaTeX wrapper, which LaTeX unpacks at compile time. Import the PDF itself instead — the wrapper carries no mathematics."
                : "This file has no importable content: its text is encoded data rather than readable prose or LaTeX.")
    }

    /// Why this `.tex` cannot yield items, decided from the file alone — nil when it can.
    ///
    /// A file can be perfectly valid LaTeX, chunk cleanly, and still contain no
    /// mathematics: the content may live in `\input` files, or the file may be a shell
    /// that reconstructs a PDF at compile time. Read as prose by an importer, all of it
    /// is chunks the Organizer will dutifully find nothing in. Each of these has a
    /// specific answer, and the answer is worth more than an empty source.
    public static func rejectionReason(forLaTeX tex: String, fileName: String) -> String? {
        // No \begin{document} at all: a fragment meant to be included. Importable.
        guard let typeset = LaTeXStructure.typesetBody(of: tex) else { return nil }

        let includes = typeset.components(separatedBy: "\n")
            .filter { $0.contains("\\input{") || $0.contains("\\include{") }
        let substance = typeset
            .replacingOccurrences(of: #"\\(input|include)\{[^}]*\}"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Only a body with essentially nothing in it can be diagnosed from here. A short
        // document is still a document — one theorem is a legitimate import — so anything
        // with real text in it goes through untouched.
        guard substance.count < 200 else { return nil }

        if !includes.isEmpty {
            return "'\(fileName)' is a master file: its document body only pulls in \(includes.count) other file(s) with \\input/\\include, which are not present here. Import those files, or the compiled PDF."
        }
        guard substance.isEmpty else { return nil }
        // An empty body with the file's bulk sitting outside it: the classic wrapper that
        // rebuilds an embedded document at compile time.
        let outside = tex.count - typeset.count
        if outside > tex.count / 2, isEncodedPayload(tex) {
            return tex.contains("JVBERi")  // base64 "%PDF"
                ? "'\(fileName)' contains no mathematics to import: its \\begin{document} body is empty, and the rest of the file is a PDF encoded as base64 that LaTeX unpacks when compiled. Import that PDF itself instead — this wrapper only carries the encoded bytes."
                : "'\(fileName)' contains no mathematics to import: its \\begin{document} body is empty and the rest of the file is encoded data rather than readable text."
        }
        return "'\(fileName)' has an empty \\begin{document} body — there is nothing to import from it."
    }

    /// True when the text is overwhelmingly base64-ish: long unbroken runs of the base64
    /// alphabet with no whitespace and, tellingly, no backslashes — real mathematical
    /// LaTeX is full of them.
    static func isEncodedPayload(_ text: String) -> Bool {
        var encoded = 0
        var readable = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 40 else { continue }  // short lines decide nothing
            if trimmed.count >= 60, !trimmed.contains("\\"), !trimmed.contains(" "),
               trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }) {
                encoded += 1
            } else {
                readable += 1
            }
        }
        return encoded > 0 && encoded > (encoded + readable) * 3 / 4
    }

    // MARK: - Normalization

    /// Enforces source-import invariants on Organizer output: everything established gets
    /// the `source` status (open problems stay conjectures), items land in the chunk's
    /// section unless the Organizer refined it, the citation is recorded, and each item
    /// gets a document-order stamp so parallel chunk completion cannot scramble the list.
    public static func normalize(
        _ items: [TheoryItem],
        chunkSection: String,
        citation: String?,
        chunkIndex: Int? = nil
    ) -> [TheoryItem] {
        items.enumerated().map { position, item in
            var normalized = item
            normalized.status = item.type.isOpenLike ? .conjecture : .source
            if normalized.section == nil {
                normalized.section = TheoryItem.sanitizeSection(chunkSection)
            }
            if normalized.source == nil { normalized.source = citation }
            if let chunkIndex {
                normalized.order = chunkIndex * 1000 + position
            }
            return normalized
        }
    }

    /// Project-import variant: keeps the Organizer's proposed statuses (the review or
    /// direct-save decides trust), only filling missing sections and the order stamp.
    public static func normalizeForProject(
        _ items: [TheoryItem],
        chunkSection: String,
        chunkIndex: Int? = nil
    ) -> [TheoryItem] {
        items.enumerated().map { position, item in
            var normalized = item
            if normalized.section == nil {
                normalized.section = TheoryItem.sanitizeSection(chunkSection)
            }
            if let chunkIndex {
                normalized.order = chunkIndex * 1000 + position
            }
            return normalized
        }
    }

    // MARK: - Helpers

    private static func meaningfulLength(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Splits an over-budget chunk at the most structural boundary available, and — the
    /// part that matters — *never* returns a piece larger than `maxSize`.
    ///
    /// The old size split had two failure modes, both hit by real books. It cut on blank
    /// lines, which fall inside `\begin{theorem}` and `\begin{proof}` bodies all the
    /// time, so statements arrived at the model in halves. And it only ever cut
    /// *between* paragraphs: a document whose body held no blank line at all — one
    /// `\input`-flattened chapter, a bibliography, a table — came back as a single
    /// paragraph and was emitted whole, at whatever size it happened to be. A 1 MB
    /// paragraph became a 250k-token request that the provider rejected outright, and
    /// the surrounding scraps produced no items, so the import "finished" with nothing
    /// in it.
    ///
    /// Cut points are ranked: a `\subsection` heading, then a blank line, both only
    /// where no environment is open; then any line break; then, for a single line longer
    /// than the budget, raw characters. The last two set the continuation flags so the
    /// Organizer is told what it is looking at.
    static func structuredSplit(_ chunk: Chunk, _ maxSize: Int) -> [Chunk] {
        let budget = max(maxSize, 1_000)
        guard chunk.text.count > budget else { return [chunk] }

        let pieces = splitText(chunk.text, budget: budget)
        return pieces.enumerated().map { position, piece in
            // Splitting a chunk that was already ragged keeps it ragged at that end.
            Chunk(
                title: position == 0 ? chunk.title : "\(chunk.title) (part \(position + 1))",
                section: chunk.section,
                text: piece.text,
                startsMidStructure: piece.startsMidStructure
                    || (position == 0 && chunk.startsMidStructure),
                endsMidStructure: piece.endsMidStructure
                    || (position == pieces.count - 1 && chunk.endsMidStructure))
        }
    }

    private struct Piece {
        var text: String
        var startsMidStructure = false
        var endsMidStructure = false
    }

    /// Greedy pack of the text's lines into budget-sized pieces, preferring the highest-
    /// ranked cut point seen since the current piece started.
    private static func splitText(_ text: String, budget: Int) -> [Piece] {
        let lines = text.components(separatedBy: "\n")

        // Nesting depth *before* each line, so a cut at line i is safe iff nothing is open.
        var safe = [Bool](repeating: false, count: lines.count)
        var depth = 0
        var inDollarMath = false
        for (index, line) in lines.enumerated() {
            safe[index] = depth <= 0 && !inDollarMath
            let effect = LaTeXStructure.nestingEffect(of: line)
            depth = max(0, depth + effect.delta)
            if effect.togglesDollarMath { inDollarMath.toggle() }
        }

        // Character offset of each line, so "how much would this cut waste?" is exact.
        var offsets = [Int](repeating: 0, count: lines.count + 1)
        for (index, line) in lines.enumerated() {
            offsets[index + 1] = offsets[index] + line.count + 1
        }

        var pieces: [Piece] = []
        var start = 0                 // first line of the piece being built
        var lastHeading: Int?         // latest safe heading seen since `start`
        var lastParagraph: Int?       // latest safe blank-line break seen since `start`
        var carriedMidStructure = false

        /// Where to cut, in order of preference: a heading, then a paragraph break — but
        /// only ones far enough along to leave a piece worth sending; then wherever we
        /// stand, if nothing is open there (splitting a paragraph is cheap, splitting a
        /// theorem is not); then the best boundary at any distance. Nil means no safe
        /// cut exists and the caller must break here and flag both sides.
        func chosenCut(at index: Int) -> Int? {
            let floor = offsets[start] + budget / 2
            if let heading = lastHeading, offsets[heading] >= floor { return heading }
            if let paragraph = lastParagraph, offsets[paragraph] >= floor { return paragraph }
            if safe[index] { return index }
            return lastHeading ?? lastParagraph
        }

        func flush(upTo end: Int, midStructure: Bool) {
            defer { carriedMidStructure = midStructure }
            let body = lines[start..<end].joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pieces.append(Piece(text: body,
                                startsMidStructure: carriedMidStructure,
                                endsMidStructure: midStructure))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]

            // A line that alone blows the budget has no internal structure left to
            // respect — flush what precedes it, then hard-split it by characters.
            if line.count + 1 > budget {
                if index > start { flush(upTo: index, midStructure: !safe[index]) }
                let slices = hardSlices(of: line, budget: budget)
                for (position, slice) in slices.enumerated() {
                    // Every cut inside a line is mid-structure except the one at its end,
                    // which is only clean if the next line starts outside everything.
                    let isLast = position == slices.count - 1
                    let endsMid = !isLast || !(index + 1 >= lines.count || safe[index + 1])
                    pieces.append(Piece(text: slice,
                                        startsMidStructure: carriedMidStructure,
                                        endsMidStructure: endsMid))
                    carriedMidStructure = endsMid
                }
                start = index + 1
                lastHeading = nil
                lastParagraph = nil
                index += 1
                continue
            }

            if offsets[index] - offsets[start] + line.count + 1 > budget, index > start {
                // Cut at the best boundary recorded for this piece; with none available
                // the cut lands here and both sides are flagged as partial.
                let cut = chosenCut(at: index) ?? index
                flush(upTo: cut, midStructure: !safe[cut])
                start = cut
                lastHeading = nil
                lastParagraph = nil
                continue  // re-test the current line against the fresh piece
            }

            // Record this line as a candidate boundary for the next overflow.
            if index > start, safe[index] {
                if isHeadingLine(line) {
                    lastHeading = index
                } else if lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lastParagraph = index
                }
            }
            index += 1
        }
        flush(upTo: lines.count, midStructure: false)
        return pieces
    }

    /// Last resort for a single line longer than the whole budget (a flattened
    /// paragraph, a giant table row): break it on whitespace near the budget mark.
    private static func hardSlices(of line: String, budget: Int) -> [String] {
        var slices: [String] = []
        var remainder = Substring(line)
        while remainder.count > budget {
            let limit = remainder.index(remainder.startIndex, offsetBy: budget)
            // Prefer the last space in the final 10% so words survive the cut.
            let searchFrom = remainder.index(
                remainder.startIndex, offsetBy: max(budget - budget / 10, 1))
            let cut = remainder[searchFrom..<limit].lastIndex(of: " ").map { remainder.index(after: $0) }
                ?? limit
            slices.append(String(remainder[remainder.startIndex..<cut]))
            remainder = remainder[cut...]
        }
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            slices.append(String(remainder))
        }
        return slices
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("\\subsection") || trimmed.hasPrefix("\\section")
            || trimmed.hasPrefix("\\chapter") || trimmed.hasPrefix("\\subsubsection")
    }
}
