import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class FulltextToolsTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldagents-fulltext-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeSource(pages: [String] = [
        "The Weierstrass division theorem, stated and proved.",
        "Applications to analytic geometry.",
        "Exercises on polynomial rings."
    ]) throws -> ProjectStore {
        let store = try ProjectStore.create(at: tempDir, name: "Book")
        try store.updateMeta { $0.kind = .source; $0.citation = "Author, 1991" }
        try store.saveFulltext(FullTextDocument(
            unit: .page,
            contents: "- Chapter 1 — p. 1",
            segments: pages.enumerated().map {
                .init(index: $0.offset + 1, title: "Page \($0.offset + 1)", text: $0.element)
            }
        ))
        return store
    }

    private func access(
        granted: Set<String>,
        onRequest: (@Sendable (String, String) async -> Bool)? = nil
    ) -> FulltextTools.Access {
        FulltextTools.Access(
            isGranted: { granted.contains($0) },
            requestGrant: onRequest
        )
    }

    private func tool(named name: String, in tools: [AgentTool]) throws -> AgentTool {
        try XCTUnwrap(tools.first { $0.spec.name == name }, "missing tool \(name)")
    }

    // MARK: - Tool availability

    func testNoToolsWithoutFulltext() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Plain")
        let tools = FulltextTools.tools(
            attached: [(slug: "plain", store: store)],
            access: access(granted: []))
        XCTAssertTrue(tools.isEmpty)
    }

    func testRequestToolOnlyWithInteractiveHandler() throws {
        let store = try makeSource()
        let without = FulltextTools.tools(
            attached: [(slug: "book", store: store)], access: access(granted: []))
        XCTAssertEqual(without.map(\.spec.name).sorted(), ["read_fulltext", "search_fulltext"])

        let with = FulltextTools.tools(
            attached: [(slug: "book", store: store)],
            access: access(granted: [], onRequest: { _, _ in true }))
        XCTAssertEqual(with.first?.spec.name, "request_fulltext_access")
    }

    // MARK: - Gating

    func testSearchAndReadRefuseWithoutGrant() async throws {
        let store = try makeSource()
        let tools = FulltextTools.tools(
            attached: [(slug: "book", store: store)], access: access(granted: []))

        do {
            _ = try await tool(named: "search_fulltext", in: tools)
                .execute(inputJSON: #"{"query":"weierstrass"}"#)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("request_fulltext_access"))
        }
        do {
            _ = try await tool(named: "read_fulltext", in: tools)
                .execute(inputJSON: #"{"source":"book","from":1}"#)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("no full-text access"))
        }
    }

    func testRequestFlowGrantsAndDenies() async throws {
        let store = try makeSource()
        let granting = FulltextTools.tools(
            attached: [(slug: "book", store: store)],
            access: access(granted: [], onRequest: { slug, reason in
                slug == "book" && reason.contains("division")
            }))
        let request = try tool(named: "request_fulltext_access", in: granting)

        let granted = try await request.execute(
            inputJSON: #"{"source":"book","reason":"need the proof of the division theorem"}"#)
        XCTAssertTrue(granted.contains("Access granted"))
        XCTAssertTrue(granted.contains("3 pages"))

        let denied = try await request.execute(
            inputJSON: #"{"source":"book","reason":"just browsing"}"#)
        XCTAssertTrue(denied.contains("declined"))

        do {
            _ = try await request.execute(inputJSON: #"{"source":"book","reason":""}"#)
            XCTFail("expected missing-reason error")
        } catch { }
    }

    // MARK: - Search & read

    func testSearchFindsSegments() async throws {
        let store = try makeSource()
        let tools = FulltextTools.tools(
            attached: [(slug: "book", store: store)], access: access(granted: ["book"]))
        let result = try await tool(named: "search_fulltext", in: tools)
            .execute(inputJSON: #"{"query":"analytic geometry"}"#)
        XCTAssertTrue(result.contains("book segment 2 (Page 2)"))
    }

    func testReadRangeAndTableOfContents() async throws {
        let store = try makeSource()
        let tools = FulltextTools.tools(
            attached: [(slug: "book", store: store)], access: access(granted: ["book"]))
        let read = try tool(named: "read_fulltext", in: tools)

        let toc = try await read.execute(inputJSON: #"{"source":"book","from":0}"#)
        XCTAssertTrue(toc.contains("Table of contents"))
        XCTAssertTrue(toc.contains("Chapter 1"))
        XCTAssertFalse(toc.contains("[segment 1"), "from:0 alone reads only the TOC")

        let range = try await read.execute(inputJSON: #"{"source":"book","from":2,"to":3}"#)
        XCTAssertTrue(range.contains("Page 2 [segment 2 of 3]"))
        XCTAssertTrue(range.contains("Exercises on polynomial rings."))
        XCTAssertTrue(range.contains("Author, 1991"))
        XCTAssertFalse(range.contains("Weierstrass division theorem"))

        do {
            _ = try await read.execute(inputJSON: #"{"source":"book","from":7,"to":9}"#)
            XCTFail("expected out-of-range error")
        } catch {
            XCTAssertTrue("\(error)".contains("1–3"))
        }
    }

    func testReadCapsAndTurnBudget() async throws {
        // Pages big enough that two exceed the per-call cap.
        let bigPage = String(repeating: "lorem ipsum weierstrass ", count: 800)  // ~19k chars
        let store = try makeSource(pages: [bigPage, bigPage, bigPage, bigPage,
                                           bigPage, bigPage, bigPage, bigPage, bigPage])
        let tools = FulltextTools.tools(
            attached: [(slug: "book", store: store)], access: access(granted: ["book"]))
        let read = try tool(named: "read_fulltext", in: tools)

        let capped = try await read.execute(inputJSON: #"{"source":"book","from":1,"to":9}"#)
        XCTAssertLessThan(capped.count, FulltextTools.readCap + 2_000)
        XCTAssertTrue(capped.contains("output capped before segment 2"))

        // Eight more reads exhaust the 160k turn budget; the next refuses.
        var sawExhaustion = false
        for from in 2...9 {
            let output = try await read.execute(
                inputJSON: #"{"source":"book","from":\#(from)}"#)
            if output.contains("now exhausted") { sawExhaustion = true }
        }
        XCTAssertTrue(sawExhaustion, "budget warning should appear as the cap is crossed")
        do {
            _ = try await read.execute(inputJSON: #"{"source":"book","from":1}"#)
            XCTFail("expected budget refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("budget"))
        }
    }

    // MARK: - Briefing lines

    func testSourcesSectionShowsFulltextState() throws {
        let store = try makeSource()
        let attached = [(slug: "book", store: store)]

        let locked = ContextAssembly.sourcesSection(
            attached: attached, fulltextGranted: [], fulltextToolsAvailable: true)
        // The language rides along with the unit label: it is what search_fulltext has to
        // be queried in, and this listing is where relevance gets judged.
        XCTAssertTrue(locked.contains("full text on file (3 pages, in English) — locked, ask via request_fulltext_access"))
        XCTAssertTrue(locked.contains("Full-text access"), "rules paragraph rides along when tools exist")

        let granted = ContextAssembly.sourcesSection(
            attached: attached, fulltextGranted: ["book"], fulltextToolsAvailable: true)
        XCTAssertTrue(granted.contains("access GRANTED"))

        let inert = ContextAssembly.sourcesSection(attached: attached)
        XCTAssertTrue(inert.contains("not accessible in this run"))
        XCTAssertFalse(inert.contains("Full-text access"), "no rules when no tools")
    }

    func testFulltextPreviewForOverview() throws {
        let store = try makeSource()
        let preview = SourceOverview.fulltextPreview(try store.loadFulltext())
        XCTAssertTrue(preview.hasPrefix("Table of contents:"))
        XCTAssertTrue(preview.contains("— Page 1 —"))

        let message = SourceOverview.userMessage(
            name: "Book", citation: nil, chunkNotes: [],
            outline: "(the library is empty)", fulltextPreview: preview)
        XCTAssertTrue(message.contains("Excerpt of the stored full text"))
    }
}
