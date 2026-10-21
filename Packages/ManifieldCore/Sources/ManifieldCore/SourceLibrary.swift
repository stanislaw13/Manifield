import Foundation

/// The machine-local library of processed literature sources. Each source is a folder in
/// the standard project format with `kind: source`; one source can be attached to many
/// projects. Every source carries its own FTS index, so cross-source search today is a
/// federated query over attached sources — and a future large library can add one global
/// aggregate index (for the planned Researcher agent) without changing this format.
public struct SourceLibrary {

    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Manifield/Sources", isDirectory: true)
    }

    public struct Entry: Identifiable, Sendable {
        public let slug: String
        public let url: URL
        public let meta: ProjectMeta
        public var id: String { slug }
    }

    /// All valid sources in the library folder.
    public func list() -> [Entry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return children.compactMap { url in
            guard ProjectStore.isProject(url),
                  let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
                  let meta = try? decoder.decode(ProjectMeta.self, from: data) else { return nil }
            return Entry(slug: url.lastPathComponent, url: url, meta: meta)
        }.sorted { $0.slug < $1.slug }
    }

    /// Creates an empty source project in the library and returns its store.
    public func createSource(
        name: String,
        authors: [String] = [],
        citation: String? = nil,
        license: String? = nil
    ) throws -> ProjectStore {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var slug = TheoryItem.sanitizeID(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(slug).path) {
            slug = "\(TheoryItem.sanitizeID(name))-\(counter)"
            counter += 1
        }
        let store = try ProjectStore.create(at: rootURL.appendingPathComponent(slug), name: name)
        try store.updateMeta { meta in
            meta.kind = .source
            meta.authors = authors.isEmpty ? nil : authors
            meta.citation = citation
            meta.license = license
        }
        return store
    }
}
