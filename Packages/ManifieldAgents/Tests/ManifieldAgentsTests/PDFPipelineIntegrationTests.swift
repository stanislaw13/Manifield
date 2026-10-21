import XCTest
import PDFKit
import ManifieldCore
@testable import ManifieldAgents

/// End-to-end over a real PDF: draw one with CoreGraphics, extract text with PDFKit
/// (exactly what the import sheet does), clean it, store it as a source's full text,
/// and read it back through the gated agent tools.
final class PDFPipelineIntegrationTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldagents-pdfpipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A 6-page PDF with a running header, page numbers, and distinct body text.
    private func makePDF() throws -> URL {
        let url = tempDir.appendingPathComponent("paper.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CoreError.io("could not create PDF context")
        }
        let bodies = [
            "The Weierstrass division theorem is stated on this page.",
            "A proof by induction on the degree of the divisor.",
            "Applications to analytic geometry follow.",
            "The preparation theorem as a corollary.",
            "Counterexamples in the non-analytic case.",
            "Exercises on polynomial rings conclude the paper."
        ]
        for (i, body) in bodies.enumerated() {
            context.beginPDFPage(nil)
            let draw: (String, CGFloat) -> Void = { text, y in
                let attributed = NSAttributedString(
                    string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(line, context)
            }
            draw("A STUDY OF DIVISION THEOREMS", 270)  // running header
            draw(body, 150)
            draw("\(i + 1)", 20)  // page number
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testPDFToGatedToolsRoundTrip() async throws {
        // 1. Extract + clean, as SourceImportSheet does.
        let pdf = try XCTUnwrap(PDFDocument(url: makePDF()))
        XCTAssertEqual(pdf.pageCount, 6)
        let pages = PDFTextCleanup.clean(
            pages: (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" })

        XCTAssertTrue(pages[0].contains("Weierstrass division theorem"))
        XCTAssertFalse(pages[0].contains("A STUDY OF DIVISION THEOREMS"),
                       "running header must be stripped")
        XCTAssertFalse(pages[3].trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasSuffix("4"), "page number must be stripped")

        // 2. Store as a document-only source.
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("src"), name: "Paper")
        try store.updateMeta { $0.kind = .source }
        try store.storeOriginalDocument(from: pdf.documentURL!)
        try store.saveFulltext(FullTextDocument(
            unit: .page,
            segments: pages.enumerated().map {
                .init(index: $0.offset + 1, title: "Page \($0.offset + 1)", text: $0.element)
            }))
        XCTAssertEqual(store.originalDocumentURL?.lastPathComponent, "original.pdf")
        XCTAssertEqual(store.fulltextInfo?.unitLabel, "6 pages")

        // 3. Agent tools over it, with the gate.
        let tools = FulltextTools.tools(
            attached: [(slug: "paper", store: store)],
            access: FulltextTools.Access(isGranted: { $0 == "paper" }))
        let search = try XCTUnwrap(tools.first { $0.spec.name == "search_fulltext" })
        let read = try XCTUnwrap(tools.first { $0.spec.name == "read_fulltext" })

        let hits = try await search.execute(inputJSON: #"{"query":"preparation theorem"}"#)
        XCTAssertTrue(hits.contains("paper segment 4"), "unexpected search result: \(hits)")

        let text = try await read.execute(inputJSON: #"{"source":"paper","from":4,"to":4}"#)
        XCTAssertTrue(text.contains("The preparation theorem as a corollary."))
    }
}
