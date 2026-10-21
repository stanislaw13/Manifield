import Foundation
import ManifieldCore

/// Agent access to the stored full text of attached sources (fulltext.md — the whole
/// document, converted). Unlike the extracted items, full texts are long and mostly
/// irrelevant to any one question, so access is opt-in per source: the user grants it
/// in chat (or the agent asks via `request_fulltext_access`), and reads are capped per
/// call and per turn so a long book cannot flood the context window.
public enum FulltextTools {

    /// Cap on characters returned by a single read_fulltext call (~6k tokens).
    public static let readCap = 24_000
    /// Cumulative read_fulltext output cap per tool instance (≈ one agent turn).
    public static let turnBudget = 160_000
    /// Widest segment range one read may request.
    public static let maxRangeSpan = 50

    public struct Access: Sendable {
        /// Whether the agent may read this source's full text right now (checked per
        /// call — the user can grant access mid-turn via the request tool).
        public var isGranted: @Sendable (_ slug: String) async -> Bool
        /// Presents an access request to the user and awaits the decision. nil when
        /// this agent surface has no interactive approval UI — the request tool is
        /// then not offered at all.
        public var requestGrant: (@Sendable (_ slug: String, _ reason: String) async -> Bool)?

        public init(
            isGranted: @escaping @Sendable (_ slug: String) async -> Bool,
            requestGrant: (@Sendable (_ slug: String, _ reason: String) async -> Bool)? = nil
        ) {
            self.isGranted = isGranted
            self.requestGrant = requestGrant
        }
    }

    public static func tools(
        attached: [(slug: String, store: ProjectStore)],
        access: Access
    ) -> [AgentTool] {
        let withFulltext = attached.filter { $0.store.hasFulltext }
        guard !withFulltext.isEmpty else { return [] }
        var tools: [AgentTool] = [
            SearchFulltextTool(attached: withFulltext, access: access),
            ReadFulltextTool(attached: withFulltext, access: access, budget: ReadBudget())
        ]
        if access.requestGrant != nil {
            tools.insert(RequestFulltextAccessTool(attached: withFulltext, access: access), at: 0)
        }
        return tools
    }

    static func describe(_ store: ProjectStore) -> String {
        store.fulltextInfo?.unitLabel ?? "no full text"
    }
}

/// Serializes budget accounting; tool calls run sequentially today, but that is an
/// AgentLoop implementation detail.
actor ReadBudget {
    private var used = 0

    /// Records `amount` and returns how much of the turn budget remains afterwards
    /// (negative = exceeded).
    func consume(_ amount: Int) -> Int {
        used += amount
        return FulltextTools.turnBudget - used
    }

    var remaining: Int { FulltextTools.turnBudget - used }
}

struct RequestFulltextAccessTool: AgentTool {
    let attached: [(slug: String, store: ProjectStore)]
    let access: FulltextTools.Access

    var spec: ToolSpec {
        let listing = attached
            .map { "\($0.slug) (\(FulltextTools.describe($0.store)))" }
            .joined(separator: ", ")
        return ToolSpec(
            name: "request_fulltext_access",
            description: "Ask the user for permission to read the stored full text of one source: \(listing). Use only after the library outline, search_sources and the memory did not answer the question — and say concretely what you expect to find. The user sees your reason and decides; a grant lasts for this chat.",
            inputSchemaJSON: #"{"type":"object","properties":{"source":{"type":"string","description":"Source slug"},"reason":{"type":"string","description":"What you are looking for and why the extracted items are not enough — shown to the user"}},"required":["source","reason"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let slug = input["source"] as? String,
              let source = attached.first(where: { $0.slug == slug }) else {
            throw AgentError.badResponse("no attached source with full text named '\(jsonObject(inputJSON)["source"] as? String ?? "?")'; available: \(attached.map(\.slug).joined(separator: ", "))")
        }
        let reason = (input["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw AgentError.badResponse("missing 'reason' — the user decides based on it")
        }
        if await access.isGranted(slug) {
            return "Access to '\(slug)' is already granted — use search_fulltext / read_fulltext."
        }
        guard let requestGrant = access.requestGrant else {
            return "Full-text access requests are not available in this run. Work from the extracted items, or note in your reply what the user should look up."
        }
        if await requestGrant(slug, reason) {
            return "Access granted — search_fulltext / read_fulltext now work for '\(slug)' (\(FulltextTools.describe(source.store)), segment 0 = table of contents)."
        }
        return "The user declined access to '\(slug)'. Continue from the extracted items and say what remains unverified — do not re-request for the same question."
    }
}

struct SearchFulltextTool: AgentTool {
    let attached: [(slug: String, store: ProjectStore)]
    let access: FulltextTools.Access

    /// The stored text of each source, tagged with the language it is written in — which
    /// can differ from its extracted items (an English abstract over a Polish body).
    private var corpora: [SearchLanguage.Corpus] {
        attached.map {
            SearchLanguage.Corpus(label: $0.slug, language: $0.store.index.language(of: .fulltext))
        }
    }

    var spec: ToolSpec {
        let corpora = corpora
        return ToolSpec(
            name: "search_fulltext",
            description: "Full-text search inside the stored complete text of sources the user granted access to (\(SearchLanguage.listing(corpora))). Complements search_sources, which only sees the extracted items. Returns segment numbers (= pages for PDFs) with snippets — follow up with read_fulltext on a narrow range around a hit.\(SearchLanguage.rule(corpora))",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Search terms (plain words), in the language the source is written in"},"source":{"type":"string","description":"Restrict to one source slug (optional)"}},"required":["query"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let query = input["query"] as? String, !query.isEmpty else {
            throw AgentError.badResponse("missing 'query'")
        }
        var candidates = attached
        if let slug = input["source"] as? String {
            candidates = attached.filter { $0.slug == slug }
            guard !candidates.isEmpty else {
                throw AgentError.badResponse("no attached source with full text named '\(slug)'; available: \(attached.map(\.slug).joined(separator: ", "))")
            }
        }

        var granted: [(slug: String, store: ProjectStore)] = []
        var locked: [String] = []
        for candidate in candidates {
            if await access.isGranted(candidate.slug) {
                granted.append(candidate)
            } else {
                locked.append(candidate.slug)
            }
        }
        guard !granted.isEmpty else {
            throw AgentError.badResponse("no full-text access to \(locked.joined(separator: ", ")) — ask the user via request_fulltext_access (or in your reply) first")
        }

        var lines: [String] = []
        for (slug, store) in granted {
            let hits = (try? store.index.searchFulltext(query, limit: 6)) ?? []
            for hit in hits {
                lines.append("\(slug) segment \(hit.segment) (\(hit.title))\n  …\(hit.snippet)…")
            }
        }
        // Only the texts actually searched are worth naming a language for — and the
        // "nothing found" verdict is about hits, not about the locked-sources note.
        let searched = granted.map {
            SearchLanguage.Corpus(label: $0.slug, language: $0.store.index.language(of: .fulltext))
        }
        var result = lines.isEmpty
            ? "No matches in the granted full texts for '\(query)'.\(SearchLanguage.emptyHint(searched))"
            : lines.joined(separator: "\n")
        if !locked.isEmpty {
            result += "\n(not searched — no access: \(locked.joined(separator: ", ")))"
        }
        return result
    }
}

struct ReadFulltextTool: AgentTool {
    let attached: [(slug: String, store: ProjectStore)]
    let access: FulltextTools.Access
    let budget: ReadBudget

    var spec: ToolSpec {
        ToolSpec(
            name: "read_fulltext",
            description: "Read a segment range from the full text of a source the user granted access to. One segment = one page (PDFs) or one section (LaTeX); segment 0 is the table of contents — read it first to navigate. Output is capped (~\(FulltextTools.readCap / 1000)k characters per call, ~\(FulltextTools.turnBudget / 1000)k per turn): search_fulltext first, then read a few segments around the hits instead of paging through the document.",
            inputSchemaJSON: #"{"type":"object","properties":{"source":{"type":"string","description":"Source slug"},"from":{"type":"integer","description":"First segment (0 = table of contents)"},"to":{"type":"integer","description":"Last segment (inclusive; defaults to 'from')"}},"required":["source","from"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let slug = input["source"] as? String,
              let source = attached.first(where: { $0.slug == slug }) else {
            throw AgentError.badResponse("no attached source with full text named '\(jsonObject(inputJSON)["source"] as? String ?? "?")'; available: \(attached.map(\.slug).joined(separator: ", "))")
        }
        guard await access.isGranted(slug) else {
            throw AgentError.badResponse("no full-text access to '\(slug)' — ask the user via request_fulltext_access (or in your reply) first")
        }
        guard let from = input["from"] as? Int else {
            throw AgentError.badResponse("missing 'from' segment number")
        }
        let to = max(input["to"] as? Int ?? from, from)
        guard from >= 0 else { throw AgentError.badResponse("'from' must be ≥ 0") }
        guard to - from < FulltextTools.maxRangeSpan else {
            throw AgentError.badResponse("range too wide — read at most \(FulltextTools.maxRangeSpan) segments per call, after narrowing with search_fulltext")
        }

        let remainingBefore = await budget.remaining
        guard remainingBefore > 0 else {
            throw AgentError.badResponse("the full-text reading budget for this turn is exhausted — work from what you have read, or tell the user what you still need and why")
        }

        let document = try source.store.loadFulltext()
        let total = document.segments.count
        var parts: [String] = []

        if from == 0 {
            if let contents = document.contents, !contents.isEmpty {
                parts.append("— Table of contents —\n\(contents)")
            } else {
                parts.append("— Table of contents — (none stored for this source)")
            }
        }
        let rangeStart = max(from, 1)
        let segments = to >= rangeStart ? document.segments(in: rangeStart...to) : []
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

        var output = "From '\(slug)'"
        if let citation = source.store.meta.citation { output += " — \(citation)" }
        output += "\n\n" + parts.joined(separator: "\n\n")
        if let truncatedAt {
            output += "\n\n(output capped before segment \(truncatedAt) — call read_fulltext again with from: \(truncatedAt) if you still need it)"
        }

        let remaining = await budget.consume(output.count)
        if remaining < 0 {
            output += "\n\n(NOTE: the full-text reading budget for this turn is now exhausted — further reads will be refused)"
        } else if remaining < FulltextTools.readCap {
            output += "\n\n(NOTE: ~\(remaining / 1000)k characters of full-text budget left this turn — be selective)"
        }
        return output
    }
}
