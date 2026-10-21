import XCTest
import ManifieldCore
@testable import ManifieldAgents

/// Agent access to the files kept with a project: which tools exist, what the gate
/// refuses, and the caps that keep a long document from flooding the context.
final class DocumentToolsTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldagents-documents-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeProject(files: [(name: String, pages: [String])]) throws -> ProjectStore {
        let store = try ProjectStore.create(at: tempDir.appendingPathComponent("P"), name: "P")
        let incoming = tempDir.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        for (i, file) in files.enumerated() {
            let url = incoming.appendingPathComponent(file.name)
            try "filler \(i)".write(to: url, atomically: true, encoding: .utf8)
            try store.addDocument(
                from: url,
                fulltext: file.pages.isEmpty ? nil : FullTextDocument(
                    unit: .page,
                    contents: "- Chapter 1 — p. 1",
                    segments: file.pages.enumerated().map {
                        .init(index: $0.offset + 1, title: "Page \($0.offset + 1)", text: $0.element)
                    }),
                pageCount: file.pages.isEmpty ? nil : file.pages.count)
        }
        return store
    }

    private func access(
        granted: Set<String>,
        onRequest: (@Sendable (String, String) async -> Bool)? = nil
    ) -> DocumentTools.Access {
        DocumentTools.Access(isGranted: { granted.contains($0) }, requestGrant: onRequest)
    }

    private func tool(named name: String, in tools: [AgentTool]) throws -> AgentTool {
        try XCTUnwrap(tools.first { $0.spec.name == name }, "missing tool \(name)")
    }

    // MARK: - Availability

    func testNoToolsWithoutReadableFiles() throws {
        let empty = try ProjectStore.create(at: tempDir.appendingPathComponent("E"), name: "E")
        XCTAssertTrue(DocumentTools.tools(store: empty, access: access(granted: [])).isEmpty)

        // A scanned PDF is stored but has no text, so there is still nothing to offer.
        let scanned = try makeProject(files: [(name: "scan.pdf", pages: [])])
        XCTAssertTrue(DocumentTools.tools(store: scanned, access: access(granted: [])).isEmpty)
    }

    func testRequestToolOnlyWithInteractiveHandler() throws {
        let store = try makeProject(files: [(name: "notes.pdf", pages: ["alpha"])])
        let names = { (access: DocumentTools.Access) in
            DocumentTools.tools(store: store, access: access).map { $0.spec.name }
        }
        XCTAssertEqual(names(access(granted: [])), ["search_documents", "read_document"])
        XCTAssertEqual(names(access(granted: [], onRequest: { _, _ in true })),
                       ["request_document_access", "search_documents", "read_document"])
    }

    /// The listing an agent sees has to name the handle it must pass back.
    func testToolDescriptionsListHandles() throws {
        let store = try makeProject(files: [(name: "Weierstrass Notes.pdf", pages: ["alpha"])])
        let tools = DocumentTools.tools(store: store, access: access(granted: [], onRequest: { _, _ in true }))
        let request = try tool(named: "request_document_access", in: tools).spec.description
        XCTAssertTrue(request.contains("weierstrass-notes"), request)
        XCTAssertTrue(request.contains("Weierstrass Notes.pdf"), request)
        XCTAssertTrue(try tool(named: "search_documents", in: tools)
            .spec.description.contains("weierstrass-notes"))
    }

    // MARK: - The gate

    func testSearchAndReadRefusedWithoutAGrant() async throws {
        let store = try makeProject(files: [(name: "notes.pdf", pages: ["the counterexample"])])
        let tools = DocumentTools.tools(store: store, access: access(granted: []))

        await XCTAssertThrowsErrorAsync(
            try await self.tool(named: "search_documents", in: tools)
                .execute(inputJSON: #"{"query":"counterexample"}"#))
        await XCTAssertThrowsErrorAsync(
            try await self.tool(named: "read_document", in: tools)
                .execute(inputJSON: #"{"document":"notes","from":1}"#))
    }

    func testGrantedSearchAndRead() async throws {
        let store = try makeProject(files: [
            (name: "notes.pdf", pages: ["the counterexample is on a 5-cycle", "further remarks"])
        ])
        let tools = DocumentTools.tools(store: store, access: access(granted: ["notes"]))

        let hits = try await tool(named: "search_documents", in: tools)
            .execute(inputJSON: #"{"query":"counterexample"}"#)
        XCTAssertTrue(hits.contains("notes segment 1"), hits)

        let read = try await tool(named: "read_document", in: tools)
            .execute(inputJSON: #"{"document":"notes","from":1,"to":2}"#)
        XCTAssertTrue(read.contains("5-cycle"), read)
        XCTAssertTrue(read.contains("further remarks"), read)
        XCTAssertTrue(read.contains("notes.pdf"), "the reply should say which file it came from")

        // Segment 0 is the table of contents.
        let toc = try await tool(named: "read_document", in: tools)
            .execute(inputJSON: #"{"document":"notes","from":0}"#)
        XCTAssertTrue(toc.contains("Table of contents"), toc)
        XCTAssertTrue(toc.contains("Chapter 1"), toc)
    }

    func testSearchSkipsFilesWithoutAGrantButStillReportsThem() async throws {
        let store = try makeProject(files: [
            (name: "open.pdf", pages: ["shared keyword here"]),
            (name: "closed.pdf", pages: ["shared keyword there"])
        ])
        let tools = DocumentTools.tools(store: store, access: access(granted: ["open"]))
        let hits = try await tool(named: "search_documents", in: tools)
            .execute(inputJSON: #"{"query":"shared"}"#)
        XCTAssertTrue(hits.contains("open segment 1"), hits)
        XCTAssertFalse(hits.contains("closed segment"), hits)
        XCTAssertTrue(hits.contains("no access: closed"), hits)
    }

    /// A kept file is queried in its own language, not the conversation's — and only the
    /// files actually searched are named in the hint.
    func testEmptySearchNamesEachFileLanguage() async throws {
        let store = try makeProject(files: [
            (name: "praca.pdf", pages: ["""
             Rozdział pierwszy poświęcony jest przestrzeniom zwartym oraz odwzorowaniom
             ciągłym pomiędzy nimi, wraz z dowodem twierdzenia o wartości pośredniej.
             """]),
            (name: "closed.pdf", pages: ["Locked away, an English chapter about compact spaces."])
        ])
        let tools = DocumentTools.tools(store: store, access: access(granted: ["praca"]))
        let search = try tool(named: "search_documents", in: tools)

        XCTAssertTrue(search.spec.description.contains("praca [Polish]"), search.spec.description)

        let empty = try await search.execute(inputJSON: #"{"query":"compact spaces"}"#)
        XCTAssertTrue(empty.contains("praca is written in Polish"), empty)
        XCTAssertFalse(empty.contains("closed is written"), "not searched, not described")
    }

    func testUnknownFileAndOutOfRangeAreRejected() async throws {
        let store = try makeProject(files: [(name: "notes.pdf", pages: ["one"])])
        let tools = DocumentTools.tools(store: store, access: access(granted: ["notes"]))
        let read = try tool(named: "read_document", in: tools)

        await XCTAssertThrowsErrorAsync(
            try await read.execute(inputJSON: #"{"document":"nope","from":1}"#))
        await XCTAssertThrowsErrorAsync(
            try await read.execute(inputJSON: #"{"document":"notes","from":9,"to":9}"#))
        // A range wider than the cap must be refused rather than silently truncated.
        await XCTAssertThrowsErrorAsync(
            try await read.execute(inputJSON: #"{"document":"notes","from":1,"to":900}"#))
    }

    func testRequestFlowGrantsAndDenies() async throws {
        let store = try makeProject(files: [(name: "notes.pdf", pages: ["alpha"])])

        let granting = DocumentTools.tools(
            store: store, access: access(granted: [], onRequest: { _, _ in true }))
        let allowed = try await tool(named: "request_document_access", in: granting)
            .execute(inputJSON: #"{"document":"notes","reason":"looking for the counterexample"}"#)
        XCTAssertTrue(allowed.contains("Access granted"), allowed)

        let denying = DocumentTools.tools(
            store: store, access: access(granted: [], onRequest: { _, _ in false }))
        let refused = try await tool(named: "request_document_access", in: denying)
            .execute(inputJSON: #"{"document":"notes","reason":"looking for the counterexample"}"#)
        XCTAssertTrue(refused.contains("declined"), refused)

        // A reason is what the user decides on, so it is required.
        await XCTAssertThrowsErrorAsync(
            try await self.tool(named: "request_document_access", in: granting)
                .execute(inputJSON: #"{"document":"notes","reason":"  "}"#))
    }

    // MARK: - Caps

    func testReadIsCappedPerCall() async throws {
        let long = String(repeating: "x", count: 20_000)
        let store = try makeProject(files: [(name: "big.pdf", pages: [long, long, long])])
        let tools = DocumentTools.tools(store: store, access: access(granted: ["big"]))
        let read = try await tool(named: "read_document", in: tools)
            .execute(inputJSON: #"{"document":"big","from":1,"to":3}"#)
        XCTAssertTrue(read.contains("output capped"), "three 20k pages exceed the per-call cap")
        XCTAssertLessThan(read.count, FulltextTools.readCap + 2_000)
    }

    // MARK: - Prompt section

    func testBriefingSaysWhatCanBeRead() throws {
        let store = try makeProject(files: [
            (name: "readable.pdf", pages: ["alpha"]),
            (name: "scan.pdf", pages: [])
        ])
        let locked = ContextAssembly.documentsSection(
            documents: store.documents, granted: [], toolsAvailable: true)
        XCTAssertTrue(locked.contains("request_document_access"), locked)
        XCTAssertTrue(locked.contains("no extractable text"), locked)

        let granted = ContextAssembly.documentsSection(
            documents: store.documents, granted: ["readable"], toolsAvailable: true)
        XCTAssertTrue(granted.contains("access GRANTED"), granted)

        let noTools = ContextAssembly.documentsSection(documents: store.documents)
        XCTAssertTrue(noTools.contains("not accessible in this run"), noTools)
        XCTAssertFalse(noTools.contains("request_document_access"),
                       "reading rules only belong where the tools exist")
    }
}
