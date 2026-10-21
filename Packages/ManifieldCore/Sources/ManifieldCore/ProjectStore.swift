import Foundation

/// Distinguishes working theories from imported reference literature.
public enum ProjectKind: String, Codable, Sendable {
    case workspace
    case source
}

/// A literature source attached to a project. `slug` namespaces item references
/// (`slug:item-id`); `path` locates the source folder on this machine.
public struct SourceRef: Codable, Equatable, Sendable, Identifiable {
    public var slug: String
    public var path: String
    public var id: String { slug }

    public init(slug: String, path: String) {
        self.slug = slug
        self.path = path
    }
}

public struct ProjectMeta: Codable, Equatable, Sendable {
    public var name: String
    public var createdAt: Date
    public var formatVersion: Int
    /// Sources attached to this project (workspaces only).
    public var sources: [SourceRef]?
    // Publishing metadata — filled in when a project/source is shared as a package.
    public var kind: ProjectKind?
    public var authors: [String]?
    public var license: String?
    /// How to cite this work, e.g. "Łojasiewicz, Introduction to Complex Analytic Geometry, 1991".
    public var citation: String?

    public init(
        name: String,
        createdAt: Date = Date(),
        formatVersion: Int = 1,
        kind: ProjectKind? = nil,
        authors: [String]? = nil,
        license: String? = nil,
        citation: String? = nil,
        sources: [SourceRef]? = nil
    ) {
        self.name = name
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.kind = kind
        self.authors = authors
        self.license = license
        self.citation = citation
        self.sources = sources
    }
}

/// A project is a plain folder on disk:
///
///     MyProject/
///       project.json     — metadata
///       notation.md      — definitions & notation registry (always in agent context)
///       theory/          — one markdown file per item, named `<id>.md`
///       figures/         — figure images (and their generator scripts), named `<id>.<ext>`
///       documents/       — files kept with the project (one folder per file)
///       graph.json       — derived dependency edges (rebuilt on save)
///       sessions/        — chat transcripts
///       artifacts/       — agent-run scripts + outputs (Phase 2+)
///       index.sqlite     — derived FTS index (rebuilt on open)
public final class ProjectStore {

    public let rootURL: URL
    public private(set) var meta: ProjectMeta
    public private(set) var items: [TheoryItem] = []
    public private(set) var notation: String = ""
    /// Persistent research memory (memory.md): goals, strategies, eliminations, insights.
    public private(set) var memory: String = ""
    /// Literature overview (overview.md) — written by the source import flow for
    /// `kind: source` projects: goal, approach, main results, gaps. Injected into agent
    /// contexts so agents can judge a source's relevance before searching it.
    public private(set) var overview: String = ""
    /// LaTeX macro definitions (macros.tex) applied to all math rendering.
    public private(set) var macros: String = ""
    /// Header info of fulltext.md when this source stores its document's full text
    /// (nil otherwise). The text itself is multi-megabyte and loaded lazily.
    public private(set) var fulltextInfo: FullTextDocument.Info?
    /// The verbatim imported document (`original.pdf` / `original.tex` / …), kept so
    /// users can read the real thing in-app; nil when none was stored. A LaTeX import
    /// that later had a typeset PDF added has both — this is then the PDF, since that
    /// is the one the in-app viewer can render.
    public private(set) var originalDocumentURL: URL?
    /// Files kept with the project (`documents/`), oldest first. A source stores the one
    /// document it was made from; a workspace collects as many as the user adds.
    public private(set) var documents: [ProjectDocument] = []
    public private(set) var loadWarnings: [String] = []
    public let index: SearchIndex

    private var cachedFulltext: FullTextDocument?
    /// Single-entry cache: reading a document walks several segments in a row, but the
    /// parsed files are multi-megabyte, so only the last one stays resident.
    private var cachedDocumentFulltext: (slug: String, document: FullTextDocument)?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    public var theoryURL: URL { rootURL.appendingPathComponent("theory", isDirectory: true) }
    public var sessionsURL: URL { rootURL.appendingPathComponent("sessions", isDirectory: true) }
    /// One JSON file per saved chat, so the sidebar's chat history is scoped to this project.
    public var chatsURL: URL { sessionsURL.appendingPathComponent("chats", isDirectory: true) }
    public var artifactsURL: URL { rootURL.appendingPathComponent("artifacts", isDirectory: true) }
    public var notationURL: URL { rootURL.appendingPathComponent("notation.md") }
    public var memoryURL: URL { rootURL.appendingPathComponent("memory.md") }
    public var overviewURL: URL { rootURL.appendingPathComponent("overview.md") }
    public var fulltextURL: URL { rootURL.appendingPathComponent(FullTextDocument.fileName) }
    public var documentsURL: URL {
        rootURL.appendingPathComponent(ProjectDocument.folderName, isDirectory: true)
    }
    public var figuresURL: URL {
        rootURL.appendingPathComponent(FigureAsset.folderName, isDirectory: true)
    }
    public var macrosURL: URL { rootURL.appendingPathComponent("macros.tex") }
    private var metaURL: URL { rootURL.appendingPathComponent("project.json") }
    private var graphURL: URL { rootURL.appendingPathComponent("graph.json") }
    private var indexURL: URL { rootURL.appendingPathComponent("index.sqlite") }

    public var graph: DependencyGraph { DependencyGraph(items: items) }

    // MARK: - Lifecycle

    public static func isProject(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
    }

    /// Creates a new project skeleton at `url` (the folder itself is created if needed).
    @discardableResult
    public static func create(at url: URL, name: String) throws -> ProjectStore {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for sub in ["theory", "sessions", "artifacts", FigureAsset.folderName] {
            try fm.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let meta = ProjectMeta(name: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: url.appendingPathComponent("project.json"))

        let notationStub = """
        # Notation & Conventions

        <!-- This file is injected into every agent's context. Record the project's
             definitions, notation, and standing assumptions here. -->

        """
        try notationStub.write(to: url.appendingPathComponent("notation.md"), atomically: true, encoding: .utf8)
        try MemoryDocument.stub().write(
            to: url.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)
        return try ProjectStore(opening: url)
    }

    public init(opening url: URL) throws {
        self.rootURL = url
        let metaURL = url.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw CoreError.notAProject(url)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.meta = try decoder.decode(ProjectMeta.self, from: Data(contentsOf: metaURL))

        // A corrupt on-disk index must never block opening a project: fall back to in-memory.
        let indexURL = url.appendingPathComponent("index.sqlite")
        if let diskIndex = try? SearchIndex(at: indexURL) {
            self.index = diskIndex
        } else {
            try? FileManager.default.removeItem(at: indexURL)
            self.index = try SearchIndex()
        }
        try reload()
    }

    deinit { stopWatching() }

    /// Re-reads every item from `theory/`, rebuilds the index and graph.json.
    public func reload() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: theoryURL, withIntermediateDirectories: true)
        var loaded: [TheoryItem] = []
        var warnings: [String] = []

        let files = try fm.contentsOfDirectory(at: theoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                let fallbackID = file.deletingPathExtension().lastPathComponent
                loaded.append(try TheoryItem.parse(markdown: text, fallbackID: fallbackID))
            } catch {
                warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        items = loaded.sorted(by: TheoryItem.documentOrder)
        // A figure whose image is gone (deleted outside the app, or never packaged) still
        // loads — the caption is content worth keeping — but it renders as a placeholder,
        // so say so rather than showing an empty frame with no explanation.
        for item in items where item.isFigure {
            if FigureAsset.resolve(item.image, in: rootURL) == nil {
                warnings.append("\(item.id).md: image '\(item.image ?? "none")' is missing from \(FigureAsset.folderName)/")
            }
        }
        loadWarnings = warnings
        notation = (try? String(contentsOf: notationURL, encoding: .utf8)) ?? ""
        memory = (try? String(contentsOf: memoryURL, encoding: .utf8)) ?? ""
        overview = (try? String(contentsOf: overviewURL, encoding: .utf8)) ?? ""
        macros = (try? String(contentsOf: macrosURL, encoding: .utf8)) ?? ""
        cachedFulltext = nil
        cachedDocumentFulltext = nil
        fulltextInfo = FullTextDocument.quickInfo(at: fulltextURL)
        originalDocumentURL = findOriginalDocument()
        documents = ProjectDocument.loadAll(from: documentsURL)
        try index.rebuild(items: items)
        syncFulltextIndex()
        syncDocumentIndex()
        try? writeGraphJSON()
    }

    public func item(id: String) -> TheoryItem? {
        items.first { $0.id == id }
    }

    public func save(_ item: TheoryItem) throws {
        let url = theoryURL.appendingPathComponent("\(item.id).md")
        try item.serialized().write(to: url, atomically: true, encoding: .utf8)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.append(item)
            items.sort(by: TheoryItem.documentOrder)
        }
        try index.upsert(item)
        try? writeGraphJSON()
    }

    public func delete(id: String) throws {
        guard let existing = item(id: id) else { throw CoreError.itemNotFound(id) }
        try? FileManager.default.removeItem(at: theoryURL.appendingPathComponent("\(id).md"))
        // The item owns its assets: leaving them behind would accumulate orphans in
        // `figures/` that nothing in the app can see, name or clean up.
        removeFigureAssets(of: existing)
        items.removeAll { $0.id == id }
        try index.remove(id: id)
        try? writeGraphJSON()
    }

    // MARK: - Figure assets (figures/)

    /// The image file backing a figure, or nil when the item has none or its `image`
    /// points anywhere other than a real file inside `figures/`.
    public func figureImageURL(for item: TheoryItem) -> URL? {
        FigureAsset.resolve(item.image, in: rootURL)
    }

    public func figureGeneratorURL(for item: TheoryItem) -> URL? {
        FigureAsset.resolve(item.generator, in: rootURL)
    }

    /// Copies `url` into `figures/<id>.<ext>` and returns the project-relative path to
    /// store in the item's `image` field. Replaces any image the id already had, so
    /// "replace the picture" does not leave the old one behind under a stale extension.
    @discardableResult
    public func addFigureImage(from url: URL, for id: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard FigureAsset.allowedExtensions.contains(ext) else {
            let allowed = FigureAsset.allowedExtensions.sorted().joined(separator: ", ")
            throw CoreError.io("'\(url.lastPathComponent)' is not a supported figure format (\(allowed)).")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: figuresURL, withIntermediateDirectories: true)
        // Stage first, then swap: a failed read of the new file must not be able to
        // leave the figure with no image at all.
        let staged = figuresURL.appendingPathComponent(".\(id).incoming.\(ext)")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: url, to: staged)
        for existing in figureFiles(id: id, extensions: FigureAsset.allowedExtensions) {
            try? fm.removeItem(at: existing)
        }
        let relative = FigureAsset.relativePath(id: id, extension: ext)
        let destination = rootURL.appendingPathComponent(relative)
        do {
            try fm.moveItem(at: staged, to: destination)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return relative
    }

    /// Stores the script a generated figure came from, beside its image.
    @discardableResult
    public func addFigureGenerator(from url: URL, for id: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard FigureAsset.generatorExtensions.contains(ext) else {
            throw CoreError.io("'\(url.lastPathComponent)' is not a supported generator script.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: figuresURL, withIntermediateDirectories: true)
        let relative = FigureAsset.relativePath(id: id, extension: ext)
        let destination = rootURL.appendingPathComponent(relative)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: url, to: destination)
        return relative
    }

    /// Promotes a sandbox render into a figure's assets: the PNG becomes the image, and
    /// the script the run recorded becomes the generator, so a figure an agent produced
    /// carries the code that produced it. Returns the two frontmatter paths.
    ///
    /// The run folder is left alone — it is the audit trail for the run, and it is
    /// personal state that a package strips; the figure needs its own copy to travel.
    @discardableResult
    public func adoptArtifactRender(
        _ render: FigureAsset.ArtifactRender, for id: String
    ) throws -> (image: String, generator: String?) {
        let image = try addFigureImage(from: render.imageURL, for: id)
        let generator = render.generatorURL.flatMap { try? addFigureGenerator(from: $0, for: id) }
        return (image, generator)
    }

    /// Deletes every asset belonging to an item (image and generator alike).
    public func removeFigureAssets(of item: TheoryItem) {
        let fm = FileManager.default
        for url in [figureImageURL(for: item), figureGeneratorURL(for: item)].compactMap({ $0 }) {
            try? fm.removeItem(at: url)
        }
        // Also sweep any file the id owns by convention but the frontmatter no longer
        // names — e.g. a .png left over after the image was replaced by a .jpg.
        let owned = FigureAsset.allowedExtensions.union(FigureAsset.generatorExtensions)
        for url in figureFiles(id: item.id, extensions: owned) {
            try? fm.removeItem(at: url)
        }
    }

    private func figureFiles(id: String, extensions: Set<String>) -> [URL] {
        extensions
            .map { figuresURL.appendingPathComponent("\(id).\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func saveNotation(_ text: String) throws {
        notation = text
        try text.write(to: notationURL, atomically: true, encoding: .utf8)
    }

    public func saveMemory(_ text: String) throws {
        memory = text
        try text.write(to: memoryURL, atomically: true, encoding: .utf8)
    }

    public func saveOverview(_ text: String) throws {
        overview = text
        try text.write(to: overviewURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Full text & original document

    public var hasFulltext: Bool { fulltextInfo != nil }

    /// Parses fulltext.md on first use (the file can be megabytes; the parse is cached
    /// until the next reload or save).
    public func loadFulltext() throws -> FullTextDocument {
        if let cachedFulltext { return cachedFulltext }
        guard FileManager.default.fileExists(atPath: fulltextURL.path) else {
            throw CoreError.io("This source has no stored full text (\(FullTextDocument.fileName)).")
        }
        let document = try FullTextDocument.parse(
            markdown: try String(contentsOf: fulltextURL, encoding: .utf8))
        cachedFulltext = document
        return document
    }

    public func saveFulltext(_ document: FullTextDocument) throws {
        try document.serialized().write(to: fulltextURL, atomically: true, encoding: .utf8)
        cachedFulltext = document
        fulltextInfo = document.info
        try index.rebuildFulltext(segments: document.segments)
    }

    /// Copies the imported file into the project verbatim as `original.<ext>`,
    /// replacing any previous one (an import defines the source's original).
    @discardableResult
    public func storeOriginalDocument(from url: URL) throws -> URL {
        let fm = FileManager.default
        for existing in originalDocuments() {
            try fm.removeItem(at: existing)
        }
        let ext = url.pathExtension.isEmpty ? "txt" : url.pathExtension.lowercased()
        let destination = rootURL.appendingPathComponent("original.\(ext)")
        try fm.copyItem(at: url, to: destination)
        originalDocumentURL = destination
        return destination
    }

    /// Adds a typeset PDF for a source whose import left nothing the in-app viewer can
    /// render — a `.tex` import stores the LaTeX itself. Unlike `storeOriginalDocument`
    /// this keeps any existing original: that file is what `fulltext.md` was extracted
    /// from, so it stays the record of what was imported.
    @discardableResult
    public func addOriginalPDF(from url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "pdf" else {
            throw CoreError.io("Only a PDF can be added as a source's original document.")
        }
        let fm = FileManager.default
        let destination = rootURL.appendingPathComponent("original.pdf")
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: url, to: destination)
        originalDocumentURL = findOriginalDocument()
        return destination
    }

    /// Every stored `original.*`, name-sorted. Normally one; a LaTeX import with an
    /// added PDF has two.
    private func originalDocuments() -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("original.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The stored document to offer the reader: a PDF whenever one exists, since that is
    /// the only format the in-app viewer renders.
    private func findOriginalDocument() -> URL? {
        let originals = originalDocuments()
        return originals.first { $0.pathExtension.lowercased() == "pdf" } ?? originals.first
    }

    /// index.sqlite is derived state — a source attached on a new machine (or restored
    /// from a package/git) arrives with fulltext.md but an empty fulltext table.
    private func syncFulltextIndex() {
        guard let fulltextInfo, index.fulltextSegmentCount() != fulltextInfo.segmentCount else { return }
        guard let document = try? loadFulltext() else { return }
        try? index.rebuildFulltext(segments: document.segments)
    }

    // MARK: - Kept files (documents/)

    public func document(slug: String) -> ProjectDocument? {
        documents.first { $0.slug == slug }
    }

    /// Copies `url` into `documents/<slug>/` verbatim and — when text could be extracted —
    /// stores it as that document's `fulltext.md` and indexes it. Extraction itself is the
    /// caller's job: PDFKit lives in the app layer.
    ///
    /// Re-adding the identical file (same name and size) returns the document already
    /// stored instead of a near-duplicate the user would have to clean up.
    @discardableResult
    public func addDocument(
        from url: URL,
        title: String? = nil,
        fulltext: FullTextDocument? = nil,
        pageCount: Int? = nil,
        note: String? = nil
    ) throws -> ProjectDocument {
        let fm = FileManager.default
        let originalFileName = url.lastPathComponent
        let byteSize = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let byteSize, let existing = documents.first(where: {
            $0.meta.originalFileName == originalFileName && $0.meta.byteSize == byteSize
        }) {
            return existing
        }

        let base = TheoryItem.sanitizeID(url.deletingPathExtension().lastPathComponent)
        let slug = availableDocumentSlug(base.isEmpty ? "document" : base)
        let folder = documentsURL.appendingPathComponent(slug, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension.lowercased()
            let destination = folder.appendingPathComponent("original.\(ext)")
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: url, to: destination)

            var document = ProjectDocument(
                slug: slug,
                meta: ProjectDocument.Meta(
                    title: (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                        $0.isEmpty ? nil : $0
                    } ?? originalFileName,
                    originalFileName: originalFileName,
                    pageCount: pageCount,
                    byteSize: byteSize,
                    note: note),
                folderURL: folder,
                fileURL: destination)
            try document.saveMeta()
            if let fulltext {
                try fulltext.serialized().write(to: document.fulltextURL, atomically: true, encoding: .utf8)
                document.fulltextInfo = fulltext.info
                try? index.replaceDocument(slug: slug, segments: fulltext.segments)
            }
            documents.append(document)
            return document
        } catch {
            try? fm.removeItem(at: folder)  // never leave a half-written document behind
            throw error
        }
    }

    /// Deletes a kept file, its extracted text and its index rows. The theory items an
    /// import produced from it are untouched — they are the project's own content now.
    public func removeDocument(slug: String) throws {
        guard let document = document(slug: slug) else {
            throw CoreError.io("No file '\(slug)' in this project.")
        }
        try FileManager.default.removeItem(at: document.folderURL)
        documents.removeAll { $0.slug == slug }
        if cachedDocumentFulltext?.slug == slug { cachedDocumentFulltext = nil }
        try? index.removeDocument(slug: slug)
    }

    /// Renames the human-readable title only; the slug agents cite stays put.
    public func renameDocument(slug: String, title: String) throws {
        guard let index = documents.firstIndex(where: { $0.slug == slug }) else {
            throw CoreError.io("No file '\(slug)' in this project.")
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoreError.io("A file needs a name.") }
        documents[index].meta.title = trimmed
        try documents[index].saveMeta()
    }

    /// Parses a kept file's extracted text (cached until the next reload or a save).
    public func loadDocumentFulltext(slug: String) throws -> FullTextDocument {
        if let cachedDocumentFulltext, cachedDocumentFulltext.slug == slug {
            return cachedDocumentFulltext.document
        }
        guard let document = document(slug: slug) else {
            throw CoreError.io("No file '\(slug)' in this project.")
        }
        guard FileManager.default.fileExists(atPath: document.fulltextURL.path) else {
            throw CoreError.io("No text was extracted from '\(document.meta.title)' — if it is a scanned PDF, OCR it and add it again.")
        }
        let parsed = try FullTextDocument.parse(
            markdown: try String(contentsOf: document.fulltextURL, encoding: .utf8))
        cachedDocumentFulltext = (slug, parsed)
        return parsed
    }

    /// Stores (or replaces) a kept file's extracted text — used when text is extracted
    /// after the fact, e.g. after OCR.
    public func saveDocumentFulltext(slug: String, _ fulltext: FullTextDocument) throws {
        guard let position = documents.firstIndex(where: { $0.slug == slug }) else {
            throw CoreError.io("No file '\(slug)' in this project.")
        }
        try fulltext.serialized().write(
            to: documents[position].fulltextURL, atomically: true, encoding: .utf8)
        documents[position].fulltextInfo = fulltext.info
        cachedDocumentFulltext = (slug, fulltext)
        try index.replaceDocument(slug: slug, segments: fulltext.segments)
    }

    private func availableDocumentSlug(_ base: String) -> String {
        var candidate = base
        var n = 2
        let taken = Set(documents.map(\.slug))
        let fm = FileManager.default
        while taken.contains(candidate)
            || fm.fileExists(atPath: documentsURL.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Same contract as `syncFulltextIndex` for kept files: the index is derived, so a
    /// project cloned or unpacked elsewhere reindexes the documents whose row counts
    /// don't match their files, and forgets those that are gone.
    private func syncDocumentIndex() {
        try? index.pruneDocuments(keeping: Set(documents.map(\.slug)))
        for document in documents {
            guard let info = document.fulltextInfo,
                  index.documentSegmentCount(document: document.slug) != info.segmentCount,
                  let parsed = try? loadDocumentFulltext(slug: document.slug) else { continue }
            try? index.replaceDocument(slug: document.slug, segments: parsed.segments)
        }
        cachedDocumentFulltext = nil
    }

    public func saveMacros(_ text: String) throws {
        macros = text
        try text.write(to: macrosURL, atomically: true, encoding: .utf8)
    }

    /// KaTeX-ready dictionary parsed from macros.tex.
    public var macroDictionary: [String: String] { MathMacros.parse(macros) }

    /// Extracts macro definitions from an imported source and appends unknown ones to
    /// macros.tex. Returns the names of newly added macros.
    @discardableResult
    public func importMacros(from source: String) -> [String] {
        let (updated, added) = MathMacros.merge(into: macros, newSource: source)
        if !added.isEmpty { try? saveMacros(updated) }
        return added
    }

    public func writeGraphJSON() throws {
        try graph.fileJSON().write(to: graphURL)
    }

    // MARK: - Meta & attached sources

    public func saveMeta() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL)
    }

    public func attachSource(_ ref: SourceRef) throws {
        var sources = meta.sources ?? []
        guard !sources.contains(where: { $0.slug == ref.slug }) else { return }
        sources.append(ref)
        meta.sources = sources
        try saveMeta()
    }

    public func detachSource(slug: String) throws {
        meta.sources = (meta.sources ?? []).filter { $0.slug != slug }
        try saveMeta()
    }

    /// Updates publishing metadata fields (used by the source import flow).
    public func updateMeta(_ mutate: (inout ProjectMeta) -> Void) throws {
        mutate(&meta)
        try saveMeta()
    }

    /// Breakage propagation: when `id` is invalidated (status downgraded), these
    /// transitive dependents can no longer claim review/approval — their proofs relied on
    /// it. Only items at reviewed-no-errors or above are affected; literature items are
    /// never touched.
    public func breakageAffected(of id: String) -> [TheoryItem] {
        graph.transitiveDependents(of: id)
            .compactMap { item(id: $0) }
            .filter { $0.status.rank >= ItemStatus.reviewedNoErrors.rank && $0.status != .source }
            .sorted { $0.id < $1.id }
    }

    /// A unique id with the conventional type prefix, e.g. `lem-degree-bound`.
    public func availableID(for type: ItemType, name: String) -> String {
        let base = "\(type.idPrefix)-\(TheoryItem.sanitizeID(name))"
        var candidate = base
        var n = 2
        while item(id: candidate) != nil {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - Sessions

    public func saveSession(named name: String, json: Data) throws {
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try json.write(to: sessionsURL.appendingPathComponent("\(name).json"))
    }

    public func loadSession(named name: String) -> Data? {
        try? Data(contentsOf: sessionsURL.appendingPathComponent("\(name).json"))
    }

    // MARK: - Chats

    /// Chats live in their own `sessions/chats/` subfolder (one file each), which the
    /// generic `saveSession` doesn't create — hence the dedicated mkdir here.
    public func saveChat(id: String, json: Data) throws {
        try FileManager.default.createDirectory(at: chatsURL, withIntermediateDirectories: true)
        try json.write(to: chatsURL.appendingPathComponent("\(id).json"))
    }

    public func loadChat(id: String) -> Data? {
        try? Data(contentsOf: chatsURL.appendingPathComponent("\(id).json"))
    }

    public func deleteChat(id: String) {
        try? FileManager.default.removeItem(at: chatsURL.appendingPathComponent("\(id).json"))
    }

    /// Ids of every saved chat in this project (file basenames, no ordering guarantee).
    public func chatIDs() -> [String] {
        (try? FileManager.default.contentsOfDirectory(at: chatsURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
    }

    // MARK: - Watching

    /// Watches the `theory/` directory for external changes (e.g. edits in a text editor or git).
    /// The callback fires on the main queue; the caller decides when to `reload()`.
    public func startWatching(onChange: @escaping () -> Void) {
        stopWatching()
        watchedFD = open(theoryURL.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedFD, fd >= 0 { close(fd) }
            self?.watchedFD = -1
        }
        source.resume()
        watcher = source
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }
}
