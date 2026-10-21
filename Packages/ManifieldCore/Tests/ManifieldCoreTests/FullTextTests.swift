import XCTest
@testable import ManifieldCore

final class FullTextDocumentTests: XCTestCase {

    private func sample() -> FullTextDocument {
        FullTextDocument(
            unit: .page,
            contents: "- Chapter 1. Preliminaries — p. 1\n- Chapter 2. Division — p. 2",
            segments: [
                .init(index: 1, title: "Page 1", text: "First page about Weierstrass division."),
                .init(index: 2, title: "Page 2", text: "Second page: the preparation theorem.")
            ]
        )
    }

    func testRoundTrip() throws {
        let original = sample()
        let parsed = try FullTextDocument.parse(markdown: original.serialized())
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.info.unitLabel, "2 pages")
    }

    func testRoundTripWithoutContents() throws {
        var document = sample()
        document.contents = nil
        document.unit = .section
        let parsed = try FullTextDocument.parse(markdown: document.serialized())
        XCTAssertNil(parsed.contents)
        XCTAssertEqual(parsed.unit, .section)
        XCTAssertEqual(parsed.segments.count, 2)
    }

    func testHostileTitlesAndBodiesSurviveRoundTrip() throws {
        let document = FullTextDocument(unit: .page, segments: [
            .init(index: 1, title: "Sneaky --> title | with pipe", text: "Body."),
            .init(index: 2, title: "Page 2", text: "Text containing <!-- manifield:segment 9 | fake --> marker.")
        ])
        let parsed = try FullTextDocument.parse(markdown: document.serialized())
        XCTAssertEqual(parsed.segments.count, 2, "escaped marker in a body must not create a segment")
        XCTAssertEqual(parsed.segments[0].title, "Sneaky — title / with pipe")
        XCTAssertTrue(parsed.segments[1].text.contains("fake"))
    }

    func testMissingHeaderThrows() {
        XCTAssertThrowsError(try FullTextDocument.parse(markdown: "no header here"))
    }

    func testQuickInfoReadsOnlyHeader() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fulltext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(FullTextDocument.fileName)
        try sample().serialized().write(to: url, atomically: true, encoding: .utf8)

        let info = FullTextDocument.quickInfo(at: url)
        XCTAssertEqual(info, FullTextDocument.Info(unit: .page, segmentCount: 2))
        XCTAssertNil(FullTextDocument.quickInfo(at: dir.appendingPathComponent("missing.md")))
    }

    func testSegmentsInRange() {
        let document = sample()
        XCTAssertEqual(document.segments(in: 2...9).map(\.index), [2])
        XCTAssertTrue(document.segments(in: 5...9).isEmpty)
    }
}

final class PDFTextCleanupTests: XCTestCase {

    func testHyphenationAndReflow() {
        let cleaned = PDFTextCleanup.clean(pages: [
            "The Weierstrass divi-\nsion theorem applies to the Navier-\nStokes case.\n\nNew paragraph."
        ])
        XCTAssertEqual(
            cleaned[0],
            "The Weierstrass division theorem applies to the Navier-Stokes case.\n\nNew paragraph.")
    }

    func testRunningHeadersAndPageNumbersStripped() {
        // Six pages sharing a running header and carrying bare page numbers.
        let pages = (1...6).map { n in
            "INTRODUCTION TO GEOMETRY\nReal content of page \(n) differs every time.\n\(n)"
        }
        let cleaned = PDFTextCleanup.clean(pages: pages)
        for (i, page) in cleaned.enumerated() {
            XCTAssertEqual(page, "Real content of page \(i + 1) differs every time.")
        }
    }

    func testShortDocumentsKeepTheirEdges() {
        // Below the furniture threshold nothing repeated should be guessed away.
        let pages = ["Title line\nBody one.", "Title line\nBody two."]
        let cleaned = PDFTextCleanup.clean(pages: pages)
        XCTAssertTrue(cleaned[0].contains("Title line"))
    }

    func testPageNumberDetection() {
        XCTAssertTrue(PDFTextCleanup.isPageNumber("12"))
        XCTAssertTrue(PDFTextCleanup.isPageNumber("Page 12"))
        XCTAssertTrue(PDFTextCleanup.isPageNumber("12 / 400"))
        XCTAssertFalse(PDFTextCleanup.isPageNumber("xi"), "roman numerals are variables in math texts")
        XCTAssertFalse(PDFTextCleanup.isPageNumber("Lemma 12"))
    }

    func testControlCharactersRemoved() {
        let cleaned = PDFTextCleanup.clean(pages: ["Text\u{0C} with form feed."])
        XCTAssertEqual(cleaned[0], "Text with form feed.")
    }
}

final class FulltextIndexAndStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-fulltext-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleDocument() -> FullTextDocument {
        FullTextDocument(unit: .page, contents: "- Chapter 1 — p. 1", segments: [
            .init(index: 1, title: "Page 1", text: "The Weierstrass division theorem, stated."),
            .init(index: 2, title: "Page 2", text: "Applications to analytic geometry."),
            .init(index: 3, title: "Page 3", text: "Exercises on polynomial rings.")
        ])
    }

    func testSearchFulltext() throws {
        let index = try SearchIndex()
        try index.rebuildFulltext(segments: sampleDocument().segments)
        let hits = try index.searchFulltext("weierstrass division")
        XCTAssertEqual(hits.first?.segment, 1)
        XCTAssertTrue(hits.first?.snippet.contains("[") ?? false)
        XCTAssertEqual(index.fulltextSegmentCount(), 3)
        // Hostile FTS syntax must not throw.
        _ = try index.searchFulltext("NEAR(")
        _ = try index.searchFulltext("\"unbalanced")
    }

    func testStoreSaveLoadAndReopen() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Book")
        XCTAssertFalse(store.hasFulltext)
        try store.saveFulltext(sampleDocument())
        XCTAssertEqual(store.fulltextInfo?.segmentCount, 3)
        XCTAssertEqual(try store.index.searchFulltext("analytic geometry").first?.segment, 2)

        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(reopened.fulltextInfo, FullTextDocument.Info(unit: .page, segmentCount: 3))
        XCTAssertEqual(try reopened.loadFulltext().contents, "- Chapter 1 — p. 1")
    }

    func testIndexRebuiltAfterIndexLoss() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Book")
        try store.saveFulltext(sampleDocument())
        store.stopWatching()

        // Simulate arrival on a new machine: derived index gone, fulltext.md intact.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("index.sqlite"))
        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(try reopened.index.searchFulltext("polynomial rings").first?.segment, 3)
    }

    func testStoreOriginalDocument() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Book")
        XCTAssertNil(store.originalDocumentURL)

        let incoming = tempDir.appendingPathComponent("incoming.PDF")
        try Data("pdf-bytes".utf8).write(to: incoming)
        let stored = try store.storeOriginalDocument(from: incoming)
        XCTAssertEqual(stored.lastPathComponent, "original.pdf")

        // Replacing with a different extension leaves exactly one original behind.
        let tex = tempDir.appendingPathComponent("incoming.tex")
        try Data("tex".utf8).write(to: tex)
        XCTAssertEqual(try store.storeOriginalDocument(from: tex).lastPathComponent, "original.tex")
        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(reopened.originalDocumentURL?.lastPathComponent, "original.tex")
    }

    func testAddOriginalPDFKeepsTheImportedOriginal() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Notes")
        let tex = tempDir.appendingPathComponent("incoming.tex")
        try Data("tex".utf8).write(to: tex)
        try store.storeOriginalDocument(from: tex)

        let pdf = tempDir.appendingPathComponent("typeset.pdf")
        try Data("pdf-bytes".utf8).write(to: pdf)
        XCTAssertEqual(try store.addOriginalPDF(from: pdf).lastPathComponent, "original.pdf")
        XCTAssertEqual(store.originalDocumentURL?.lastPathComponent, "original.pdf",
                       "the PDF is what the viewer can render, so it wins")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("original.tex").path),
            "the imported .tex the full text came from must survive")

        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(reopened.originalDocumentURL?.lastPathComponent, "original.pdf")
        XCTAssertThrowsError(try reopened.addOriginalPDF(from: tex))

        // A later re-import still defines the original on its own — no PDF left behind.
        try store.storeOriginalDocument(from: tex)
        XCTAssertEqual(store.originalDocumentURL?.lastPathComponent, "original.tex")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("original.pdf").path))
    }

    func testPackageCarriesFulltextAndOriginal() throws {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("proj"), name: "Book")
        try store.saveFulltext(sampleDocument())
        let incoming = tempDir.appendingPathComponent("doc.pdf")
        try Data("pdf-bytes".utf8).write(to: incoming)
        try store.storeOriginalDocument(from: incoming)

        let pack = tempDir.appendingPathComponent("book.manifieldpack")
        try ProjectPackage.export(projectAt: store.rootURL, to: pack)
        let imported = try ProjectPackage.importPackage(
            at: pack, to: tempDir.appendingPathComponent("imported"))
        XCTAssertEqual(imported.fulltextInfo?.segmentCount, 3)
        XCTAssertEqual(imported.originalDocumentURL?.lastPathComponent, "original.pdf")
        XCTAssertEqual(try imported.index.searchFulltext("weierstrass").first?.segment, 1,
                       "fulltext index is rebuilt on import")
    }
}
