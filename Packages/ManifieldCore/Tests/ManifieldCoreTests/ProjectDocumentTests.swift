import XCTest
@testable import ManifieldCore

/// Files kept with a project: the on-disk layout, the per-file search index, and what
/// survives a reopen (the index is derived, so it has to rebuild itself).
final class ProjectDocumentTests: XCTestCase {

    private var tempDir: URL!
    private var incoming: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-docs-\(UUID().uuidString)")
        incoming = tempDir.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A file the user is about to add, with `bytes` of filler so byte sizes differ.
    private func makeFile(named name: String, contents: String = "hello") throws -> URL {
        let url = incoming.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fulltext(_ texts: [String]) -> FullTextDocument {
        FullTextDocument(
            unit: .page,
            contents: "- Chapter 1 — p. 1",
            segments: texts.enumerated().map {
                .init(index: $0.offset + 1, title: "Page \($0.offset + 1)", text: $0.element)
            })
    }

    func testAddStoresFileTextAndMetadata() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        let file = try makeFile(named: "Weierstrass Notes.pdf")

        let document = try store.addDocument(
            from: file, fulltext: fulltext(["division theorem", "preparation theorem"]),
            pageCount: 2, note: "imported into the library")

        XCTAssertEqual(document.slug, "weierstrass-notes")
        XCTAssertEqual(document.meta.title, "Weierstrass Notes.pdf")
        XCTAssertEqual(document.meta.pageCount, 2)
        XCTAssertEqual(document.fulltextInfo?.segmentCount, 2)
        XCTAssertTrue(document.isPDF)
        XCTAssertTrue(document.isSearchable)
        XCTAssertEqual(document.formatLabel, "PDF · 2 pages")
        XCTAssertEqual(store.documents.map(\.slug), ["weierstrass-notes"])

        let folder = store.documentsURL.appendingPathComponent("weierstrass-notes")
        for name in ["document.json", "original.pdf", FullTextDocument.fileName] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                "\(name) should be stored")
        }
        XCTAssertEqual(try store.index.searchDocuments("preparation").first?.segment, 2)
    }

    func testAddingTheSameFileTwiceReusesItButDifferentFilesGetUniqueSlugs() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        let file = try makeFile(named: "notes.tex", contents: "\\section{A}\ntext")

        let first = try store.addDocument(from: file)
        let again = try store.addDocument(from: file)
        XCTAssertEqual(first.slug, again.slug, "re-adding the identical file must not duplicate it")
        XCTAssertEqual(store.documents.count, 1)

        // Same name, different content — a genuinely different file gets its own slug.
        let other = try makeFile(named: "notes.tex", contents: "\\section{A}\nquite different text")
        let second = try store.addDocument(from: other)
        XCTAssertEqual(second.slug, "notes-2")
        XCTAssertEqual(store.documents.count, 2)
    }

    func testRenameKeepsSlugAndRemoveDeletesEverything() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        let document = try store.addDocument(
            from: try makeFile(named: "draft.pdf"), fulltext: fulltext(["counterexample"]))

        try store.renameDocument(slug: document.slug, title: "Counterexample hunt")
        XCTAssertEqual(store.document(slug: document.slug)?.meta.title, "Counterexample hunt")
        XCTAssertEqual(store.documents.first?.slug, "draft", "the handle agents cite stays put")
        XCTAssertThrowsError(try store.renameDocument(slug: document.slug, title: "  "))

        try store.removeDocument(slug: document.slug)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.folderURL.path))
        XCTAssertTrue(try store.index.searchDocuments("counterexample").isEmpty)
        XCTAssertThrowsError(try store.removeDocument(slug: document.slug))
    }

    func testSearchIsNamespacedPerFile() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        try store.addDocument(from: try makeFile(named: "a.pdf", contents: "a"),
                              fulltext: fulltext(["shared word and alpha"]))
        try store.addDocument(from: try makeFile(named: "b.pdf", contents: "bb"),
                              fulltext: fulltext(["shared word and beta"]))

        XCTAssertEqual(try store.index.searchDocuments("shared").count, 2)
        let onlyA = try store.index.searchDocuments("shared", document: "a")
        XCTAssertEqual(onlyA.map(\.document), ["a"])
        XCTAssertTrue(try store.index.searchDocuments("alpha", document: "b").isEmpty)
    }

    /// index.sqlite is derived: a project copied to another machine (or unpacked from a
    /// package) arrives with the files but no rows, and must reindex itself on open.
    func testReopenRebuildsTheIndexAndForgetsDeletedFiles() throws {
        let projectDir = tempDir.appendingPathComponent("P")
        let store = try ProjectStore.create(at: projectDir, name: "P")
        let kept = try store.addDocument(from: try makeFile(named: "kept.pdf", contents: "k"),
                                        fulltext: fulltext(["weierstrass division"]))
        let removed = try store.addDocument(from: try makeFile(named: "gone.pdf", contents: "gg"),
                                           fulltext: fulltext(["obsolete text"]))

        // Delete one behind the app's back, and drop the index entirely.
        try FileManager.default.removeItem(at: removed.folderURL)
        try FileManager.default.removeItem(at: projectDir.appendingPathComponent("index.sqlite"))

        let reopened = try ProjectStore(opening: projectDir)
        XCTAssertEqual(reopened.documents.map(\.slug), [kept.slug])
        XCTAssertEqual(try reopened.index.searchDocuments("division").first?.document, kept.slug)
        XCTAssertTrue(try reopened.index.searchDocuments("obsolete").isEmpty)
        XCTAssertEqual(reopened.index.documentSegmentCount(document: removed.slug), 0)
    }

    func testLoadFulltextAndItsAbsence() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        let searchable = try store.addDocument(from: try makeFile(named: "text.pdf", contents: "t"),
                                              fulltext: fulltext(["page one", "page two"]))
        let scanned = try store.addDocument(from: try makeFile(named: "scan.pdf", contents: "ss"))

        XCTAssertEqual(try store.loadDocumentFulltext(slug: searchable.slug).segments.count, 2)
        XCTAssertEqual(try store.loadDocumentFulltext(slug: searchable.slug).contents,
                       "- Chapter 1 — p. 1", "the parse is cached, not corrupted")
        XCTAssertFalse(scanned.isSearchable)
        XCTAssertEqual(scanned.formatLabel, "PDF")
        XCTAssertThrowsError(try store.loadDocumentFulltext(slug: scanned.slug))
        XCTAssertThrowsError(try store.loadDocumentFulltext(slug: "nope"))

        // Extraction after the fact (the OCR path) makes it searchable.
        try store.saveDocumentFulltext(slug: scanned.slug, fulltext(["now readable"]))
        XCTAssertTrue(store.document(slug: scanned.slug)?.isSearchable ?? false)
        XCTAssertEqual(try store.index.searchDocuments("readable").first?.document, scanned.slug)
    }

    func testKeptFilesTravelInAPackage() throws {
        let projectDir = tempDir.appendingPathComponent("P")
        let store = try ProjectStore.create(at: projectDir, name: "P")
        try store.addDocument(from: try makeFile(named: "paper.pdf", contents: "p"),
                              fulltext: fulltext(["main theorem"]))

        let pack = tempDir.appendingPathComponent("P.manifieldpack")
        try ProjectPackage.export(projectAt: projectDir, to: pack)
        let imported = try ProjectPackage.importPackage(
            at: pack, to: tempDir.appendingPathComponent("Unpacked"))

        XCTAssertEqual(imported.documents.map(\.slug), ["paper"])
        XCTAssertEqual(imported.documents.first?.fulltextInfo?.segmentCount, 1)
        XCTAssertEqual(try imported.index.searchDocuments("theorem").first?.document, "paper")
    }
}
