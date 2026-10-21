import Foundation
import ManifieldCore

/// The Organizer turns a LaTeX/PDF-text source into structured theory item proposals.
/// It is a one-shot generation (no tools): the model returns a JSON array which the app
/// parses and presents in the import-review UI for the user to confirm.
public enum Organizer {

    /// One line per item type for the organizer prompts, generated from the enum so
    /// prompts can never drift from the types the parser accepts. Types the import
    /// pipeline cannot produce (figures need image bytes) are left out — offering them
    /// would only get us items with nothing in them.
    static var typeListText: String {
        ItemType.allCases
            .filter(\.isImportable)
            .map { "- \($0.rawValue) (prefix \($0.idPrefix)-) — \($0.summary)" }
            .joined(separator: "\n")
    }

    public static func systemPrompt(
        existingItems: [TheoryItem],
        notation: String,
        instructions: String? = nil
    ) -> String {
        var parts: [String] = []
        parts.append(PromptLibrary.text("organizer_system", ["TYPE_LIST": typeListText]))
        if !existingItems.isEmpty {
            parts.append(PromptLibrary.text("organizer_existing_items", [
                "OUTLINE": ContextAssembly.outline(items: existingItems)
            ]))
        }
        if !notation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Project notation registry:\n\(notation)")
        }
        appendInstructions(instructions, to: &parts)
        return parts.joined(separator: "\n\n")
    }

    static func appendInstructions(_ instructions: String?, to parts: inout [String]) {
        guard let instructions,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parts.append(PromptLibrary.text("organizer_instructions", [
            "USER_INSTRUCTIONS": instructions
        ]))
    }

    /// Per-chunk prompt builder for the CHUNKED project import: the (possibly large)
    /// base prompt — existing items, notation, instructions — is assembled once; each
    /// chunk appends its section hint and the live taken-ids list.
    public static func projectSystemPromptBuilder(
        existingItems: [TheoryItem],
        notation: String,
        instructions: String?
    ) -> @Sendable (_ takenIDs: [String], _ chunk: SourceImport.Chunk) -> String {
        let base = systemPrompt(
            existingItems: existingItems, notation: notation, instructions: instructions)
        return { takenIDs, chunk in
            var parts = [base]
            parts.append("""
            You are given ONE chunk of a larger document (chunk section slug: \
            "\(chunk.section)", title: "\(chunk.title)"). Use that slug as the default \
            "section" unless the text clearly belongs deeper. Other chunks are processed \
            separately — extract only what this chunk states. The cut can land mid-sentence: \
            never complete or invent the missing part of a statement or proof, and never \
            emit an opening fragment whose beginning lies in the previous chunk.
            """)
            if let boundary = chunkBoundaryNotice(
                startsMidStructure: chunk.startsMidStructure,
                endsMidStructure: chunk.endsMidStructure) {
                parts.append(boundary)
            }
            if let taken = takenIDsSection(takenIDs) { parts.append(taken) }
            return parts.joined(separator: "\n\n")
        }
    }

    /// The same request, with the parser's complaint attached. Sent when a reply could
    /// not be read: naming the fault is what makes the second attempt different from the
    /// first, which is why a plain retry of a malformed reply tends to fail the same way.
    public static func correctedUserMessage(_ message: String, parseError: String) -> String {
        """
        Your previous reply could not be parsed: \(parseError)

        Almost always this is an unescaped backslash: inside a JSON string, LaTeX must be \
        written with every backslash doubled ("\\\\alpha", not "\\alpha"), and a literal \
        newline must be written \\n. Send the array again, complete and valid, with no \
        text before "[" or after "]".

        \(message)
        """
    }

    public static func userMessage(source: String) -> String {
        var parts: [String] = []
        if let outline = sectionOutline(from: source) {
            parts.append("""
            Document outline detected from the LaTeX sectioning commands. Assign each item \
            the "section" slug of the part of the document it appears in — use exactly \
            these slugs:
            \(outline)
            """)
        }
        parts.append("Organize the following source into theory items:\n\n\(source)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Deterministic section outline

    /// Extracts the `\chapter` / `\section` / `\subsection` structure of a LaTeX source
    /// as pre-computed section slugs (max two levels, matching TheoryItem sections), so
    /// imported items land in sections mirroring the document instead of whatever
    /// grouping the model invents. Returns nil when the source has no sectioning.
    public static func sectionOutline(from source: String) -> String? {
        // Two-level mapping: with \chapter present, chapters are the top level and both
        // \section and \subsection map to the second; otherwise \section is the top.
        let hasChapters = LaTeXStructure.firstCommand(named: "chapter", in: source) != nil
        var lines: [String] = []
        var currentTop: String?
        var seen: Set<String> = []

        for heading in LaTeXStructure.headings(in: source, levels: [.chapter, .section, .subsection]) {
            let cleaned = LaTeXStructure.cleanTitle(heading.title)
            guard !cleaned.isEmpty else { continue }
            let slugPart = TheoryItem.sanitizeID(cleaned)
            let isTop = hasChapters ? heading.level == .chapter : heading.level == .section
            let slug: String
            if isTop {
                currentTop = slugPart
                slug = slugPart
            } else if let top = currentTop {
                slug = "\(top)/\(slugPart)"
            } else {
                slug = slugPart  // subsection before any parent: promote to top level
            }
            guard seen.insert(slug).inserted else { continue }
            lines.append("- \(slug) — “\(cleaned)”")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Prompt variant for chunked literature import (books/articles → source libraries).
    /// `detectSections` relaxes the fixed-section rule for synthetic part-N chunks so
    /// the model may derive real chapter slugs from in-text headings.
    public static func sourceSystemPrompt(
        existingIDs: [String],
        chunkSection: String,
        citation: String?,
        instructions: String? = nil,
        detectSections: Bool = false,
        knownSections: [String] = [],
        startsMidStructure: Bool = false,
        endsMidStructure: Bool = false
    ) -> String {
        var parts: [String] = []
        parts.append(PromptLibrary.text("organizer_source_system", [
            "CITATION_SUFFIX": citation.map { " (\($0))" } ?? "",
            "CHUNK_SECTION": chunkSection,
            "TYPE_LIST": typeListText
        ]))
        if detectSections {
            parts.append(PromptLibrary.text("organizer_section_detect", [
                "CHUNK_SECTION": chunkSection,
                "KNOWN_SECTIONS": knownSections.isEmpty
                    ? "none yet" : knownSections.joined(separator: ", ")
            ]))
        }
        if let boundary = chunkBoundaryNotice(
            startsMidStructure: startsMidStructure, endsMidStructure: endsMidStructure) {
            parts.append(boundary)
        }
        appendInstructions(instructions, to: &parts)
        if let taken = takenIDsSection(existingIDs) { parts.append(taken) }
        return parts.joined(separator: "\n\n")
    }

    /// Characters of prompt that ride along with every source chunk, at their worst
    /// (full taken-ids list, section detection, boundary warning). `ImportBudget`
    /// subtracts this from the context window, so it is measured rather than guessed.
    public static func sourceSystemPromptOverheadCharacters(instructions: String? = nil) -> Int {
        sourceSystemPrompt(
            existingIDs: Array(repeating: "thm-placeholder-identifier", count: maxTakenIDsInPrompt),
            chunkSection: "chapter/section",
            citation: "A Citation (2024)",
            instructions: instructions,
            detectSections: true,
            startsMidStructure: true,
            endsMidStructure: true).count
    }

    /// Ids already used are listed so the model does not reuse one. A book-length import
    /// accumulates thousands of them; past a few hundred the list has stopped preventing
    /// collisions and started eating the chunk's own budget — and the store renames a
    /// duplicate on save anyway. Keep the most recent, say how many were dropped.
    static let maxTakenIDsInPrompt = 400

    static func takenIDsSection(_ ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let shown = ids.suffix(maxTakenIDsInPrompt)
        var text = PromptLibrary.text("organizer_taken_ids", [
            "IDS": shown.joined(separator: ", ")
        ])
        if ids.count > shown.count {
            text += "\n(\(ids.count - shown.count) earlier ids omitted — make new ids specific enough not to collide.)"
        }
        return text
    }

    /// The warning block for a chunk the splitter had to cut inside a theorem or proof
    /// (a single environment larger than the whole chunk budget). Nil for clean chunks,
    /// which is the overwhelming majority — the standing rules already cover ordinary
    /// page-boundary raggedness.
    static func chunkBoundaryNotice(startsMidStructure: Bool, endsMidStructure: Bool) -> String? {
        var notes: [String] = []
        if startsMidStructure {
            notes.append("- The chunk BEGINS in the middle of a statement, proof, or display that started in the previous chunk.")
        }
        if endsMidStructure {
            notes.append("- The chunk ENDS in the middle of a statement, proof, or display that continues in the next chunk.")
        }
        guard !notes.isEmpty else { return nil }
        return PromptLibrary.text("organizer_chunk_boundary", [
            "BOUNDARY_NOTES": notes.joined(separator: "\n")
        ])
    }

    /// Extracts theory items from the model response. Tolerates prose or code fences around
    /// the JSON array, unknown fields, and unknown types (skipped with a warning).
    public static func parseProposals(from response: String) throws -> (items: [TheoryItem], warnings: [String]) {
        let (objects, parseWarnings) = try objectArray(from: response)
        let (items, warnings) = mapItems(objects)
        return (items, parseWarnings + warnings)
    }

    /// Variant for chunked literature import: also extracts the chapter note the source
    /// Organizer appends as a {"type": "summary", "content": ...} element (used to build
    /// the source's overview.md). Returns nil when the model omitted the note.
    public static func parseSourceChunk(
        from response: String
    ) throws -> (items: [TheoryItem], summary: String?, warnings: [String]) {
        let (array, parseWarnings) = try objectArray(from: response)
        let notes = array
            .filter { ($0["type"] as? String) == "summary" }
            .compactMap { ($0["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let (items, warnings) = mapItems(array.filter { ($0["type"] as? String) != "summary" })
        return (items, notes.isEmpty ? nil : notes.joined(separator: "\n\n"),
                parseWarnings + warnings)
    }

    /// Turns the model's reply into objects, tolerating the ways a reply carrying
    /// mathematics goes wrong.
    ///
    /// The Organizer is asked for JSON containing LaTeX, and those two escape each other
    /// differently: every `\` in `\frac` must be doubled to survive as JSON, and a reply
    /// that forgets once is rejected in full — losing a chapter's worth of correctly
    /// extracted theorems to one character. The parser therefore repairs invalid escapes
    /// (a repair that cannot alter valid JSON, where every backslash already begins a
    /// legal escape), does not assume the array starts at the first `[` in the reply —
    /// prose above it may contain brackets of its own — and, when the reply was cut off
    /// mid-array, keeps the objects that did arrive.
    static func objectArray(from response: String) throws -> (objects: [[String: Any]], warnings: [String]) {
        for candidate in jsonArrayCandidates(in: response) {
            if let array = parseObjectArray(candidate) { return (array, []) }
            // Only repair a reply that demonstrably did not escape its LaTeX; a reply
            // that failed to parse for some other reason must not be rewritten.
            guard hasInvalidEscape(candidate) else { continue }
            if let array = parseObjectArray(repairingLaTeXEscapes(in: candidate)) {
                return (array, [])
            }
        }
        if let (salvaged, dropped) = salvageTruncatedArray(from: response) {
            return (salvaged, ["The model's reply was cut off after \(salvaged.count) item(s); \(dropped) incomplete trailing item(s) were dropped."])
        }
        throw AgentError.badResponse("Organizer response is not a valid JSON array of objects")
    }

    private static func parseObjectArray(_ text: String) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]]
    }

    /// Bracket spans worth trying, best first: a fenced block's contents, then every
    /// balanced `[…]` in the reply. A model that writes "Here are the items [see the
    /// note below]:" before its JSON puts a perfectly balanced decoy first.
    private static func jsonArrayCandidates(in response: String) -> [String] {
        var candidates: [String] = []
        if let fenced = fencedBlock(in: response), let span = balancedArray(in: fenced, from: fenced.startIndex) {
            candidates.append(span)
        }
        var search = response.startIndex
        while let open = response[search...].firstIndex(of: "["), candidates.count < 6 {
            if let span = balancedArray(in: response, from: open) { candidates.append(span) }
            search = response.index(after: open)
        }
        return candidates
    }

    private static func fencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        let afterOpen = text[open.upperBound...]
        // Skip an optional language tag on the fence line.
        let body = afterOpen.drop { $0 != "\n" }
        guard let close = body.range(of: "```") else { return String(body) }
        return String(body[..<close.lowerBound])
    }

    /// The balanced `[…]` span starting at `start`, respecting strings and escapes.
    private static func balancedArray(in text: String, from start: String.Index) -> String? {
        guard start < text.endIndex else { return nil }
        var index = start
        // Allow the caller to pass a position before the opening bracket.
        while index < text.endIndex, text[index] != "[" { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        let open = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return String(text[open...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Characters that may legally follow a backslash in JSON.
    private static let legalEscapes: Set<Character> = ["\"", "\\", "/", "b", "f", "n", "r", "t", "u"]

    /// True when some backslash inside a string does not begin a legal escape — proof
    /// that the reply is raw LaTeX rather than escaped JSON.
    static func hasInvalidEscape(_ json: String) -> Bool {
        var inString = false
        var index = json.startIndex
        while index < json.endIndex {
            let char = json[index]
            if char == "\"" && !inString { inString = true; index = json.index(after: index); continue }
            if !inString { index = json.index(after: index); continue }
            if char == "\"" { inString = false; index = json.index(after: index); continue }
            guard char == "\\" else { index = json.index(after: index); continue }
            let next = json.index(after: index)
            guard next < json.endIndex else { return true }
            if !legalEscapes.contains(json[next]) { return true }
            if json[next] == "u", !isHexEscape(json, after: next) { return true }
            index = json.index(after: next)
        }
        return false
    }

    /// Rewrites a reply that wrote its LaTeX raw, doubling each backslash so the JSON
    /// parser hands the mathematics back exactly as the model meant it.
    ///
    /// The subtlety is that half the LaTeX alphabet collides with JSON's escapes: `\frac`
    /// opens with `\f`, `\nu` with `\n`, `\times` with `\t`, `\beta` with `\b`. Treating
    /// those as escapes parses without complaint and silently drops a formfeed or a tab
    /// into the middle of a theorem — a corruption nobody would ever notice. So in a reply
    /// already proven to be unescaped, a backslash is LaTeX unless it introduces a real
    /// control escape, which is recognisable because a control escape is not followed by
    /// more letters: `\n"` ends a line, `\nu$` is the Greek letter.
    static func repairingLaTeXEscapes(in json: String) -> String {
        var out = ""
        out.reserveCapacity(json.count + json.count / 4)
        var inString = false
        var index = json.startIndex

        func isControlEscape(at next: String.Index) -> Bool {
            let char = json[next]
            if char == "u" { return isHexEscape(json, after: next) }
            guard "ntrbf".contains(char) else { return false }
            let after = json.index(after: next)
            return after >= json.endIndex || !json[after].isLetter
        }

        while index < json.endIndex {
            let char = json[index]
            if !inString {
                if char == "\"" { inString = true }
                out.append(char)
                index = json.index(after: index)
                continue
            }
            if char == "\"" {
                inString = false
                out.append(char)
                index = json.index(after: index)
                continue
            }
            guard char == "\\" else {
                out.append(char)
                index = json.index(after: index)
                continue
            }
            let next = json.index(after: index)
            guard next < json.endIndex else {
                out.append("\\\\")
                index = next
                continue
            }
            // A quote must stay escaped or the string ends early; real control escapes
            // stay as they are; everything else is LaTeX and gets its backslash doubled.
            if json[next] == "\"" || isControlEscape(at: next) {
                out.append(char)
                out.append(json[next])
                index = json.index(after: next)
            } else {
                out.append("\\\\")
                index = next  // re-examine the next character in its own right
            }
        }
        return out
    }

    private static func isHexEscape(_ text: String, after u: String.Index) -> Bool {
        var index = text.index(after: u)
        for _ in 0..<4 {
            guard index < text.endIndex, text[index].isHexDigit else { return false }
            index = text.index(after: index)
        }
        return true
    }

    /// A reply cut off by the output limit ends mid-object. The complete objects before
    /// that point are perfectly good items — recovering them beats discarding the chunk.
    private static func salvageTruncatedArray(from response: String) -> (objects: [[String: Any]], dropped: Int)? {
        guard let open = response.firstIndex(of: "[") else { return nil }
        var objects: [String] = []
        var current: String?
        var depth = 0
        var inString = false
        var escaped = false
        var truncated = false

        for char in response[response.index(after: open)...] {
            if current != nil { current?.append(char) }
            if escaped { escaped = false; continue }
            if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{":
                if depth == 0 { current = "{" }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0, let object = current {
                    objects.append(object)
                    current = nil
                }
            default: break
            }
        }
        truncated = current != nil || inString
        guard !objects.isEmpty, truncated else { return nil }
        let rebuilt = "[\(objects.joined(separator: ","))]"
        let parsed = parseObjectArray(rebuilt) ?? parseObjectArray(repairingLaTeXEscapes(in: rebuilt))
        guard let parsed else { return nil }
        return (parsed, 1)
    }

    private static func mapItems(_ array: [[String: Any]]) -> (items: [TheoryItem], warnings: [String]) {
        var items: [TheoryItem] = []
        var warnings: [String] = []

        for obj in array {
            guard let name = obj["name"] as? String ?? obj["id"] as? String else {
                warnings.append("Skipped an entry without name or id")
                continue
            }
            let typeRaw = obj["type"] as? String ?? ""
            let type: ItemType
            if let match = ItemType.bestMatch(typeRaw), match.type.isImportable {
                type = match.type
                if !match.exact {
                    warnings.append("Imported '\(name)' as \(match.type.displayName) (source said '\(typeRaw)')")
                }
            } else {
                type = .remark
                warnings.append("Imported '\(name)' as Remark (source said '\(typeRaw.isEmpty ? "nothing" : typeRaw)')")
            }
            guard let statement = obj["statement"] as? String,
                  !statement.trimmingCharacters(in: .whitespaces).isEmpty else {
                warnings.append("Skipped '\(name)': empty statement")
                continue
            }

            let rawID = obj["id"] as? String ?? ""
            let id = rawID.isEmpty
                ? "\(type.idPrefix)-\(TheoryItem.sanitizeID(name))"
                : TheoryItem.sanitizeID(rawID)
            let status = (obj["status"] as? String).flatMap { ItemStatus(rawValue: $0) }
                ?? (type.isOpenLike ? .conjecture : .proofDrafted)

            var body = "## Statement\n\(statement.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let proof = obj["proof"] as? String,
               !proof.trimmingCharacters(in: .whitespaces).isEmpty {
                body += "\n\n## Proof\n\(proof.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            items.append(TheoryItem(
                id: id,
                type: type,
                name: name,
                status: status,
                dependsOn: (obj["depends_on"] as? [String] ?? []).map(TheoryItem.sanitizeID),
                tags: obj["tags"] as? [String] ?? [],
                source: obj["source"] as? String,
                section: TheoryItem.sanitizeSection(obj["section"] as? String),
                body: body
            ))
        }
        return (items, warnings)
    }

    /// Finds the first top-level JSON array in the text, respecting strings and escapes.
    static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
