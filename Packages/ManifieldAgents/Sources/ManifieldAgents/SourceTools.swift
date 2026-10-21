import Foundation
import ManifieldCore

/// Agent tools over the literature sources attached to a project. Item references are
/// namespaced `slug:item-id`. Search is federated over each source's own FTS index —
/// the same shape a future Researcher agent will use against a large shared library
/// (where a global aggregate index can slot in behind the same tool interface).
public enum SourceTools {

    public static func tools(attached: [(slug: String, store: ProjectStore)]) -> [AgentTool] {
        guard !attached.isEmpty else { return [] }
        return [
            SearchSourcesTool(attached: attached),
            ReadSourceItemTool(attached: attached)
        ]
    }
}

struct SearchSourcesTool: AgentTool {
    let attached: [(slug: String, store: ProjectStore)]

    /// The items of each source, tagged with the language they are written in — a source
    /// is only searchable in its own words.
    private var corpora: [SearchLanguage.Corpus] {
        attached.map {
            SearchLanguage.Corpus(label: $0.slug, language: $0.store.index.language(of: .items))
        }
    }

    var spec: ToolSpec {
        let corpora = corpora
        return ToolSpec(
            name: "search_sources",
            description: "Full-text search across the literature sources attached to this project (\(SearchLanguage.listing(corpora))). Returns namespaced ids 'source-slug:item-id' with snippets. Use before relying on or citing any published result.\(SearchLanguage.rule(corpora))",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Search terms (plain words), in the language the source is written in"}},"required":["query"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        guard let query = jsonObject(inputJSON)["query"] as? String, !query.isEmpty else {
            throw AgentError.badResponse("missing 'query'")
        }
        var lines: [String] = []
        for (slug, store) in attached {
            let hits = (try? store.index.search(query, limit: 5)) ?? []
            for hit in hits {
                lines.append("\(slug):\(hit.id) — \(hit.name)\n  …\(hit.snippet)…")
            }
        }
        return lines.isEmpty
            ? "No matches in attached sources for '\(query)'.\(SearchLanguage.emptyHint(corpora))"
            : lines.joined(separator: "\n")
    }
}

struct ReadSourceItemTool: AgentTool {
    let attached: [(slug: String, store: ProjectStore)]

    var spec: ToolSpec {
        ToolSpec(
            name: "read_source_item",
            description: "Read one literature item in full by its namespaced reference 'source-slug:item-id' (as returned by search_sources). Read the exact statement before relying on it — never cite from memory.",
            inputSchemaJSON: #"{"type":"object","properties":{"ref":{"type":"string","description":"Namespaced reference, e.g. lojasiewicz-book:thm-weierstrass-division"}},"required":["ref"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        guard let ref = jsonObject(inputJSON)["ref"] as? String,
              let colon = ref.firstIndex(of: ":") else {
            throw AgentError.badResponse("ref must have the form 'source-slug:item-id'")
        }
        let slug = String(ref[..<colon])
        let itemID = String(ref[ref.index(after: colon)...])
        guard let source = attached.first(where: { $0.slug == slug }) else {
            throw AgentError.badResponse("no attached source '\(slug)'; attached: \(attached.map(\.slug).joined(separator: ", "))")
        }
        guard let item = source.store.item(id: itemID) else {
            throw CoreError.itemNotFound(ref)
        }
        var header = "From source '\(slug)'"
        if let citation = source.store.meta.citation { header += " — \(citation)" }
        return header + "\nCite as: \(ref)\n\n" + item.serialized()
    }
}
