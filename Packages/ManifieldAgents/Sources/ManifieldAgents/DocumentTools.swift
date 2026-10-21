import Foundation
import ManifieldCore

/// Agent access to the files kept with the project itself (`documents/`) — the PDFs an
/// import was made from, or ones the user parked there to read. These are the same shape
/// of thing as an attached source's full text, and gated the same way: the user grants
/// access per file (or standing, for the whole project), and reads are capped per call
/// and per turn so a 400-page book cannot flood the context window.
///
/// The distinction from a literature source is what they are *for*: a source is
/// established work with citable items, while a kept file is raw material of this
/// project — read it, quote its pages, but nothing in it is a citable statement yet.
public enum DocumentTools {

    /// Same gate as source full texts: `isGranted` is consulted per call, so a grant made
    /// mid-turn takes effect immediately.
    public typealias Access = FulltextTools.Access

    public static func tools(store: ProjectStore, access: Access) -> [AgentTool] {
        let readable = store.documents.filter(\.isSearchable)
        guard !readable.isEmpty else { return [] }
        var tools: [AgentTool] = [
            SearchDocumentsTool(store: store, readable: readable, access: access),
            ReadDocumentTool(store: store, readable: readable, access: access, budget: ReadBudget())
        ]
        if access.requestGrant != nil {
            tools.insert(RequestDocumentAccessTool(readable: readable, access: access), at: 0)
        }
        return tools
    }

    static func listing(_ documents: [ProjectDocument]) -> String {
        documents
            .map { "\($0.slug) — \($0.meta.title) (\($0.formatLabel))" }
            .joined(separator: ", ")
    }

    static func handles(_ documents: [ProjectDocument]) -> String {
        documents.map(\.slug).joined(separator: ", ")
    }
}

struct RequestDocumentAccessTool: AgentTool {
    let readable: [ProjectDocument]
    let access: DocumentTools.Access

    var spec: ToolSpec {
        ToolSpec(
            name: "request_document_access",
            description: "Ask the user for permission to read one of the files kept with this project: \(DocumentTools.listing(readable)). Say concretely what you expect to find — the user sees your reason and decides, and a grant lasts for this chat. Use it when the library items and the memory did not answer the question.",
            inputSchemaJSON: #"{"type":"object","properties":{"document":{"type":"string","description":"The file's handle, as listed in the project's files"},"reason":{"type":"string","description":"What you are looking for and why the library items are not enough — shown to the user"}},"required":["document","reason"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let slug = input["document"] as? String,
              let document = readable.first(where: { $0.slug == slug }) else {
            throw AgentError.badResponse("no readable project file named '\(jsonObject(inputJSON)["document"] as? String ?? "?")'; available: \(DocumentTools.handles(readable))")
        }
        let reason = (input["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw AgentError.badResponse("missing 'reason' — the user decides based on it")
        }
        if await access.isGranted(slug) {
            return "Access to '\(slug)' is already granted — use search_documents / read_document."
        }
        guard let requestGrant = access.requestGrant else {
            return "File access requests are not available in this run. Work from the library items, or note in your reply what the user should look up."
        }
        if await requestGrant(slug, reason) {
            return "Access granted — search_documents / read_document now work for '\(slug)' (\(document.formatLabel), segment 0 = table of contents)."
        }
        return "The user declined access to '\(slug)'. Continue from the library items and say what remains unverified — do not re-request for the same question."
    }
}

struct SearchDocumentsTool: AgentTool {
    let store: ProjectStore
    let readable: [ProjectDocument]
    let access: DocumentTools.Access

    /// Each kept file, tagged with the language it is written in — a project can hold
    /// papers in several, and each only answers to its own words.
    private var corpora: [SearchLanguage.Corpus] {
        readable.map {
            SearchLanguage.Corpus(
                label: $0.slug, language: store.index.language(of: .document($0.slug)))
        }
    }

    var spec: ToolSpec {
        let corpora = corpora
        return ToolSpec(
            name: "search_documents",
            description: "Full-text search inside the files kept with this project that the user granted access to (\(SearchLanguage.listing(corpora))). Returns segment numbers (= pages for PDFs) with snippets — follow up with read_document on a narrow range around a hit.\(SearchLanguage.rule(corpora))",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Search terms (plain words), in the language the file is written in"},"document":{"type":"string","description":"Restrict to one file's handle (optional)"}},"required":["query"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let query = input["query"] as? String, !query.isEmpty else {
            throw AgentError.badResponse("missing 'query'")
        }
        var candidates = readable
        if let slug = input["document"] as? String {
            candidates = readable.filter { $0.slug == slug }
            guard !candidates.isEmpty else {
                throw AgentError.badResponse("no readable project file named '\(slug)'; available: \(DocumentTools.handles(readable))")
            }
        }

        var granted: [ProjectDocument] = []
        var locked: [String] = []
        for candidate in candidates {
            if await access.isGranted(candidate.slug) {
                granted.append(candidate)
            } else {
                locked.append(candidate.slug)
            }
        }
        guard !granted.isEmpty else {
            throw AgentError.badResponse("no access to \(locked.joined(separator: ", ")) — ask the user via request_document_access (or in your reply) first")
        }

        var lines: [String] = []
        for document in granted {
            // Search per document rather than once across all of them: an even split of
            // the hit budget keeps a 400-page book from crowding out a 6-page note.
            let hits = (try? store.index.searchDocuments(
                query, document: document.slug,
                limit: granted.count == 1 ? 8 : 4)) ?? []
            for hit in hits {
                lines.append("\(document.slug) segment \(hit.segment) (\(hit.title))\n  …\(hit.snippet)…")
            }
        }
        // Only the files actually searched are worth naming a language for — and the
        // "nothing found" verdict is about hits, not about the locked-files note.
        let searched = granted.map {
            SearchLanguage.Corpus(
                label: $0.slug, language: store.index.language(of: .document($0.slug)))
        }
        var result = lines.isEmpty
            ? "No matches in the granted project files for '\(query)'.\(SearchLanguage.emptyHint(searched))"
            : lines.joined(separator: "\n")
        if !locked.isEmpty {
            result += "\n(not searched — no access: \(locked.joined(separator: ", ")))"
        }
        return result
    }
}

struct ReadDocumentTool: AgentTool {
    let store: ProjectStore
    let readable: [ProjectDocument]
    let access: DocumentTools.Access
    let budget: ReadBudget

    var spec: ToolSpec {
        ToolSpec(
            name: "read_document",
            description: "Read a segment range from a file kept with this project, once the user granted access. One segment = one page (PDFs) or one section (LaTeX); segment 0 is the table of contents — read it first to navigate. Output is capped (~\(FulltextTools.readCap / 1000)k characters per call, ~\(FulltextTools.turnBudget / 1000)k per turn): search_documents first, then read a few segments around the hits instead of paging through the file.",
            inputSchemaJSON: #"{"type":"object","properties":{"document":{"type":"string","description":"The file's handle"},"from":{"type":"integer","description":"First segment (0 = table of contents)"},"to":{"type":"integer","description":"Last segment (inclusive; defaults to 'from')"}},"required":["document","from"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let slug = input["document"] as? String,
              let document = readable.first(where: { $0.slug == slug }) else {
            throw AgentError.badResponse("no readable project file named '\(jsonObject(inputJSON)["document"] as? String ?? "?")'; available: \(DocumentTools.handles(readable))")
        }
        guard await access.isGranted(slug) else {
            throw AgentError.badResponse("no access to '\(slug)' — ask the user via request_document_access (or in your reply) first")
        }
        guard let from = input["from"] as? Int else {
            throw AgentError.badResponse("missing 'from' segment number")
        }
        let to = max(input["to"] as? Int ?? from, from)
        guard from >= 0 else { throw AgentError.badResponse("'from' must be ≥ 0") }
        guard to - from < FulltextTools.maxRangeSpan else {
            throw AgentError.badResponse("range too wide — read at most \(FulltextTools.maxRangeSpan) segments per call, after narrowing with search_documents")
        }

        let remainingBefore = await budget.remaining
        guard remainingBefore > 0 else {
            throw AgentError.badResponse("the file-reading budget for this turn is exhausted — work from what you have read, or tell the user what you still need and why")
        }

        let fulltext = try store.loadDocumentFulltext(slug: slug)
        let total = fulltext.segments.count
        var parts: [String] = []

        if from == 0 {
            if let contents = fulltext.contents, !contents.isEmpty {
                parts.append("— Table of contents —\n\(contents)")
            } else {
                parts.append("— Table of contents — (none stored for this file)")
            }
        }
        let rangeStart = max(from, 1)
        let segments = to >= rangeStart ? fulltext.segments(in: rangeStart...to) : []
        if from > 0 && segments.isEmpty {
            throw AgentError.badResponse("no segments in \(from)–\(to); '\(slug)' has \(total) (1–\(total))")
        }

        var truncatedAt: Int? = nil
        var size = parts.map(\.count).reduce(0, +)
        for segment in segments {
            let text = segment.text.isEmpty ? "(no extractable text)" : segment.text
            let block = "— \(segment.title) [segment \(segment.index) of \(total)] —\n\(text)"
            if size + block.count > FulltextTools.readCap, !parts.isEmpty {
                truncatedAt = segment.index
                break
            }
            parts.append(block)
            size += block.count
        }

        var output = "From the project file '\(slug)' — \(document.meta.title)"
        output += "\n\n" + parts.joined(separator: "\n\n")
        if let truncatedAt {
            output += "\n\n(output capped before segment \(truncatedAt) — call read_document again with from: \(truncatedAt) if you still need it)"
        }

        let remaining = await budget.consume(output.count)
        if remaining < 0 {
            output += "\n\n(NOTE: the file-reading budget for this turn is now exhausted — further reads will be refused)"
        } else if remaining < FulltextTools.readCap {
            output += "\n\n(NOTE: ~\(remaining / 1000)k characters of file-reading budget left this turn — be selective)"
        }
        return output
    }
}
