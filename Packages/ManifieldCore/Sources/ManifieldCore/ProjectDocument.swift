import Foundation

/// A file kept verbatim inside a project — the PDF an import was made from, or one the
/// user parked here to read and let agents search. A literature source stores its single
/// `original.*` next to `fulltext.md`; a workspace can hold many files, so each gets its
/// own folder under `documents/`:
///
///     MyProject/documents/<slug>/
///       document.json     title, original file name, when it was added
///       original.pdf      the file, byte for byte
///       fulltext.md       extracted text — one segment per page, with the PDF's outline
///                         as a table of contents (absent when nothing was extractable)
///
/// `slug` is both the folder name and the handle agents address the file by, so it stays
/// stable across renames of the human-readable title.
public struct ProjectDocument: Identifiable, Equatable, Sendable {

    public static let folderName = "documents"
    public static let metaFileName = "document.json"

    public struct Meta: Codable, Equatable, Sendable {
        /// Human-readable name shown in the sidebar; defaults to the file name.
        public var title: String
        public var originalFileName: String
        public var addedAt: Date
        /// Pages, for formats that have them (PDF). nil otherwise.
        public var pageCount: Int?
        /// Size of the stored file — lets a re-add of the same file be recognized
        /// instead of silently creating a near-duplicate.
        public var byteSize: Int?
        /// Where the file came from, e.g. "imported into the library on 2026-07-27".
        public var note: String?

        public init(
            title: String,
            originalFileName: String,
            addedAt: Date = Date(),
            pageCount: Int? = nil,
            byteSize: Int? = nil,
            note: String? = nil
        ) {
            self.title = title
            self.originalFileName = originalFileName
            self.addedAt = addedAt
            self.pageCount = pageCount
            self.byteSize = byteSize
            self.note = note
        }
    }

    public let slug: String
    public var meta: Meta
    public let folderURL: URL
    /// The stored file itself (`original.<ext>`); nil when the folder lost it.
    public var fileURL: URL?
    /// Header info of this document's `fulltext.md`, when text could be extracted.
    public var fulltextInfo: FullTextDocument.Info?

    public var id: String { slug }

    public init(
        slug: String,
        meta: Meta,
        folderURL: URL,
        fileURL: URL?,
        fulltextInfo: FullTextDocument.Info? = nil
    ) {
        self.slug = slug
        self.meta = meta
        self.folderURL = folderURL
        self.fileURL = fileURL
        self.fulltextInfo = fulltextInfo
    }

    public var fulltextURL: URL { folderURL.appendingPathComponent(FullTextDocument.fileName) }
    public var metaURL: URL { folderURL.appendingPathComponent(Self.metaFileName) }

    /// Whether agents can search and read this file's text at all.
    public var isSearchable: Bool { fulltextInfo != nil }

    public var isPDF: Bool { fileURL?.pathExtension.lowercased() == "pdf" }

    /// e.g. "PDF · 412 pages" — the one-line description used in lists and prompts.
    public var formatLabel: String {
        var parts: [String] = []
        if let ext = fileURL?.pathExtension, !ext.isEmpty { parts.append(ext.uppercased()) }
        if let info = fulltextInfo {
            parts.append(info.unitLabel)
        } else if let pages = meta.pageCount {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Disk

    /// Reads one document folder. Returns nil when it holds no `document.json` — the
    /// folder is then not a document of ours and is left alone.
    public static func load(folderURL: URL) -> ProjectDocument? {
        let slug = folderURL.lastPathComponent
        let metaURL = folderURL.appendingPathComponent(metaFileName)
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let meta = try? decoder.decode(Meta.self, from: data) else { return nil }
        var document = ProjectDocument(
            slug: slug,
            meta: meta,
            folderURL: folderURL,
            fileURL: storedFileURL(in: folderURL))
        document.fulltextInfo = FullTextDocument.quickInfo(at: document.fulltextURL)
        return document
    }

    public func saveMeta() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL)
    }

    /// The `original.*` inside a document folder (the stored file keeps its extension so
    /// Finder, Preview and the in-app viewer all recognize it).
    static func storedFileURL(in folderURL: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("original.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Documents in `documents/`, oldest first — the order they were added, which is what
    /// a list of files a user has been collecting should look like.
    public static func loadAll(from documentsURL: URL) -> [ProjectDocument] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { load(folderURL: $0) }
            .sorted {
                $0.meta.addedAt == $1.meta.addedAt
                    ? $0.slug < $1.slug
                    : $0.meta.addedAt < $1.meta.addedAt
            }
    }
}
