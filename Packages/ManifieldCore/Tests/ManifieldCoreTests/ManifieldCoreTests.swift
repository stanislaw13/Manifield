import XCTest
@testable import ManifieldCore

final class FrontmatterTests: XCTestCase {

    func testParseInlineListsAndScalars() throws {
        let doc = """
        ---
        id: lem-degree-bound
        type: lemma
        name: "Degree bound: the tricky, quoted case"
        status: reviewed-no-errors
        depends_on: [def-k-domination, thm-handshake]
        tags: [domination, degrees]
        ---
        ## Statement
        For every graph $G$ with $\\delta(G) \\ge k$ ...

        ## Proof
        Consider a minimal set $D$ ...
        """
        let item = try TheoryItem.parse(markdown: doc)
        XCTAssertEqual(item.id, "lem-degree-bound")
        XCTAssertEqual(item.type, .lemma)
        XCTAssertEqual(item.name, "Degree bound: the tricky, quoted case")
        XCTAssertEqual(item.status, .reviewedNoErrors)
        XCTAssertEqual(item.dependsOn, ["def-k-domination", "thm-handshake"])
        XCTAssertEqual(item.tags, ["domination", "degrees"])
        XCTAssertTrue(item.statement?.contains("\\delta(G)") ?? false)
        XCTAssertTrue(item.proof?.contains("minimal set") ?? false)
    }

    func testParseBlockListAndComments() throws {
        let doc = """
        ---
        id: thm-main
        type: theorem
        name: Main theorem
        status: proof-drafted   # still being reviewed
        depends_on:
          - lem-a
          - lem-b
        ---
        ## Statement
        Something.
        """
        let item = try TheoryItem.parse(markdown: doc)
        XCTAssertEqual(item.status, .proofDrafted)
        XCTAssertEqual(item.dependsOn, ["lem-a", "lem-b"])
    }

    func testRoundTrip() throws {
        let original = TheoryItem(
            id: "conj-main",
            type: .conjecture,
            name: "Bound with: colon, and [brackets]",
            status: .tested,
            dependsOn: ["def-a"],
            resolves: ["prob-sharp-bound"],
            tags: ["open"],
            source: "notes.tex",
            section: "main-results/bounds",
            body: "## Statement\nFor all $G$, $\\gamma_2(G) \\le 2\\gamma(G)$."
        )
        let reparsed = try TheoryItem.parse(markdown: original.serialized())
        XCTAssertEqual(reparsed, original)
    }

    func testLegacyCodableTheoryItemDefaultsResolvesToEmpty() throws {
        let json = Data(###"{"id":"lem-old","type":"lemma","name":"Old lemma","status":"proof-drafted","dependsOn":[],"tags":[],"body":"## Statement\nOld statement."}"###.utf8)

        let decoded = try JSONDecoder().decode(TheoryItem.self, from: json)

        XCTAssertEqual(decoded.id, "lem-old")
        XCTAssertEqual(decoded.resolves, [String]())
    }

    func testSectionSanitizationAndDisplay() {
        XCTAssertEqual(TheoryItem.sanitizeSection("Main Results / Sharp Bounds!"), "main-results/sharp-bounds")
        XCTAssertEqual(TheoryItem.sanitizeSection("a/b/c"), "a/b", "at most two levels")
        XCTAssertNil(TheoryItem.sanitizeSection(nil))
        XCTAssertNil(TheoryItem.sanitizeSection("   "))
        XCTAssertEqual(TheoryItem.sectionDisplayName("weierstrass-theory/division"),
                       "Weierstrass Theory ▸ Division")
        XCTAssertEqual(TheoryItem.sectionDisplayName(nil), "Unsorted")
    }

    func testMissingFrontmatterThrows() {
        XCTAssertThrowsError(try TheoryItem.parse(markdown: "just text"))
    }

    func testUnknownTypeThrows() {
        let doc = "---\nid: x\ntype: porism\nname: X\n---\nbody"
        XCTAssertThrowsError(try TheoryItem.parse(markdown: doc))
    }

    func testUnknownStatusThrowsInsteadOfSilentlyDefaulting() {
        let doc = "---\nid: x\ntype: algorithm\nname: X\nstatus: open\n---\nbody"
        XCTAssertThrowsError(try TheoryItem.parse(markdown: doc)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unknown 'status' 'open'"))
        }
    }

    func testFallbackIDFromFilename() throws {
        let doc = "---\ntype: remark\nname: A remark\n---\ntext"
        let item = try TheoryItem.parse(markdown: doc, fallbackID: "rem-a-remark")
        XCTAssertEqual(item.id, "rem-a-remark")
        XCTAssertEqual(item.status, .proofDrafted)
    }

    func testSanitizeID() {
        XCTAssertEqual(TheoryItem.sanitizeID("Ore's Theorem (1962)!"), "ore-s-theorem-1962")
        XCTAssertEqual(TheoryItem.sanitizeID("   "), "item")
    }

    /// Regression: a caller that feeds a raw, unbounded problem statement (rather than a
    /// short, human-authored title) must never again produce a slug long enough for the OS
    /// to refuse the resulting filename. The 900+ character statement this reproduces from —
    /// a full research problem, LaTeX and all — is the shape of input that broke this.
    func testSanitizeIDCapsLengthForUnboundedInput() {
        let essay = String(repeating: "define functions f and g on the upper half plane ", count: 20)
        let id = TheoryItem.sanitizeID(essay)
        XCTAssertLessThanOrEqual(id.utf8.count, TheoryItem.sanitizedIDMaxLength,
                                 "must stay well under any filesystem's per-component byte limit")
        XCTAssertFalse(id.hasSuffix("-"), "a mid-word truncation must not leave a dangling dash")
        XCTAssertTrue(id.hasPrefix("define-functions-f-and-g"))
    }

    func testSanitizeIDLeavesShortInputUntouched() {
        XCTAssertEqual(TheoryItem.sanitizeID("kelly-kühn-osthus threshold gap"),
                       "kelly-kühn-osthus-threshold-gap")
    }
}

final class MathMacrosTests: XCTestCase {

    func testNewcommandForms() {
        let tex = """
        \\newcommand{\\A}{\\mathcal{A}}
        \\newcommand{\\norm}[1]{\\lVert #1 \\rVert}
        \\renewcommand{\\phi}{\\varphi}
        \\providecommand{\\eps}{\\varepsilon}
        \\newcommand\\bb{\\mathbb{B}}
        """
        let macros = MathMacros.parse(tex)
        XCTAssertEqual(macros["\\A"], "\\mathcal{A}")
        XCTAssertEqual(macros["\\norm"], "\\lVert #1 \\rVert")
        XCTAssertEqual(macros["\\phi"], "\\varphi")
        XCTAssertEqual(macros["\\eps"], "\\varepsilon")
        XCTAssertEqual(macros["\\bb"], "\\mathbb{B}")
    }

    func testDefAndDeclareMathOperator() {
        let tex = """
        \\def\\R{\\mathbb{R}}
        \\def\\pair#1#2{\\langle #1, #2 \\rangle}
        \\DeclareMathOperator{\\rank}{rank}
        \\DeclareMathOperator*{\\esssup}{ess\\,sup}
        """
        let macros = MathMacros.parse(tex)
        XCTAssertEqual(macros["\\R"], "\\mathbb{R}")
        XCTAssertEqual(macros["\\pair"], "\\langle #1, #2 \\rangle")
        XCTAssertEqual(macros["\\rank"], "\\operatorname{rank}")
        XCTAssertEqual(macros["\\esssup"], "\\operatorname*{ess\\,sup}")
    }

    func testSkipsOptionalDefaultsAndHandlesNesting() {
        let tex = """
        \\newcommand{\\opt}[2][x]{#1 + #2}
        \\newcommand{\\nested}{\\frac{a}{\\sqrt{b}}}
        """
        let macros = MathMacros.parse(tex)
        XCTAssertNil(macros["\\opt"], "optional-default macros are not expressible in KaTeX")
        XCTAssertEqual(macros["\\nested"], "\\frac{a}{\\sqrt{b}}")
    }

    func testExtractionFromFullDocumentAndMerge() {
        let doc = """
        \\documentclass{article}
        \\newcommand{\\A}{\\mathcal{A}}
        \\newcommand{\\B}{\\mathcal{B}}
        \\begin{document}
        Text with $\\A_x$ inline.
        \\end{document}
        """
        let existing = "\\newcommand{\\A}{\\mathcal{OLD}}\n"
        let (merged, added) = MathMacros.merge(into: existing, newSource: doc)
        XCTAssertEqual(added, ["\\B"], "existing \\A must not be overwritten")
        XCTAssertTrue(merged.contains("\\newcommand{\\B}{\\mathcal{B}}"))
        XCTAssertTrue(merged.contains("\\mathcal{OLD}"))
    }
}

final class GraphTests: XCTestCase {

    private func makeItems(_ deps: [String: [String]]) -> [TheoryItem] {
        deps.map { id, dependsOn in
            TheoryItem(id: id, type: .lemma, name: id, dependsOn: dependsOn)
        }
    }

    func testDependentsAndTransitiveClosure() {
        // thm-c uses lem-b, lem-b uses lem-a
        let graph = DependencyGraph(items: makeItems([
            "lem-a": [], "lem-b": ["lem-a"], "thm-c": ["lem-b"], "rem-d": []
        ]))
        XCTAssertEqual(Set(graph.dependents(of: "lem-a")), ["lem-b"])
        XCTAssertEqual(graph.transitiveDependents(of: "lem-a"), ["lem-b", "thm-c"])
        XCTAssertEqual(graph.transitiveDependents(of: "rem-d"), [])
    }

    func testCycleDetection() {
        let cyclic = DependencyGraph(items: makeItems([
            "a": ["b"], "b": ["c"], "c": ["a"], "d": []
        ]))
        XCTAssertNotNil(cyclic.findCycle())

        let acyclic = DependencyGraph(items: makeItems([
            "a": ["b"], "b": ["c"], "c": [], "d": ["a", "c"]
        ]))
        XCTAssertNil(acyclic.findCycle())
    }

    func testMissingReferences() {
        let graph = DependencyGraph(items: makeItems(["a": ["ghost"], "b": ["a"]]))
        XCTAssertEqual(graph.missingReferences.count, 1)
        XCTAssertEqual(graph.missingReferences.first?.to, "ghost")
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testExternalReferencesAreNotMissing() throws {
        let items = [
            TheoryItem(id: "thm-a", type: .theorem, name: "A",
                       dependsOn: ["lojasiewicz-book:thm-weierstrass", "ghost"]),
        ]
        let graph = DependencyGraph(items: items)
        XCTAssertEqual(graph.externalReferences.map(\.to), ["lojasiewicz-book:thm-weierstrass"])
        XCTAssertEqual(graph.missingReferences.map(\.to), ["ghost"])

        // Resolved external refs become literature nodes with statement + edge.
        let json = try graph.webJSON { ref in
            ref == "lojasiewicz-book:thm-weierstrass"
                ? TheoryItem(id: "thm-weierstrass", type: .theorem, name: "Weierstrass",
                             status: .source, body: "## Statement\nDivision holds.")
                : nil
        }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let nodes = obj?["nodes"] as? [[String: Any]] ?? []
        let sourceNode = nodes.first { $0["type"] as? String == "source-ref" }
        XCTAssertNotNil(sourceNode)
        XCTAssertEqual(sourceNode?["statement"] as? String, "Division holds.")
        let edges = obj?["edges"] as? [[String: Any]] ?? []
        XCTAssertTrue(edges.contains { $0["source"] as? String == "lojasiewicz-book:thm-weierstrass" })
    }

    func testWebJSONIsValid() throws {
        let graph = DependencyGraph(items: makeItems(["a": [], "b": ["a"]]))
        let json = try graph.webJSON()
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual((obj?["nodes"] as? [[String: Any]])?.count, 2)
        let edges = obj?["edges"] as? [[String: Any]]
        // Edge direction is dependency → dependent (derivation order).
        XCTAssertEqual(edges?.first?["source"] as? String, "a")
        XCTAssertEqual(edges?.first?["target"] as? String, "b")
    }
}

final class IndexTests: XCTestCase {

    func testSearchFindsByBodyAndName() throws {
        let index = try SearchIndex()
        try index.rebuild(items: [
            TheoryItem(id: "def-dom", type: .definition, name: "Dominating set",
                       body: "A set $D$ such that every vertex is in $N[D]$."),
            TheoryItem(id: "thm-ore", type: .theorem, name: "Ore bound",
                       body: "If $\\delta(G) \\ge 1$ then $\\gamma(G) \\le n/2$.")
        ])
        XCTAssertEqual(try index.search("dominating").first?.id, "def-dom")
        XCTAssertEqual(try index.search("ore").first?.id, "thm-ore")
        // Prefix matching
        XCTAssertEqual(try index.search("domin").first?.id, "def-dom")
    }

    /// Saving an item must not move it in the results. `upsert` is a delete + insert, so
    /// the edited row gets the highest rowid — and FTS5 orders tied ranks by rowid, which
    /// used to drop the item to the back of the list and out of the caller's limit.
    func testSearchOrderSurvivesReindexing() throws {
        let index = try SearchIndex()
        // Uniform items, so every rank ties and ordering rests entirely on the tiebreak.
        let items = (1...30).map { n in
            TheoryItem(id: String(format: "def-topologia-%02d", n), type: .definition,
                       name: "Topologia numer \(n)", body: "Definicja topologii numer \(n).")
        }
        try index.rebuild(items: items)

        let before = try index.search("topologia", limit: 10).map(\.id)
        XCTAssertEqual(before.count, 10)
        let target = before[4]

        // Exactly what changing an item's trust status does — status is not even indexed.
        var edited = items.first { $0.id == target }!
        edited.status = .humanApproved
        try index.upsert(edited)

        XCTAssertEqual(try index.search("topologia", limit: 10).map(\.id), before,
                       "an edit must not reorder or drop results")
    }

    func testHostileQueryDoesNotThrow() throws {
        let index = try SearchIndex()
        try index.rebuild(items: [TheoryItem(id: "a", type: .lemma, name: "A", body: "text")])
        XCTAssertNoThrow(try index.search("AND OR \"unbalanced ( NEAR"))
        XCTAssertEqual(try index.search("   "), [])
    }

    /// Each corpus reports the language it is indexed in — what a query has to be written
    /// in, since FTS matching is literal.
    func testCorpusLanguage() throws {
        let index = try SearchIndex()
        try index.rebuild(items: [
            TheoryItem(id: "thm-zwartosc", type: .theorem, name: "Twierdzenie o zwartości",
                       body: """
                       ## Statement
                       Niech $X$ będzie przestrzenią topologiczną zwartą i spójną. Wówczas
                       każde odwzorowanie ciągłe osiąga swoje kresy na tej przestrzeni.
                       """)
        ])
        XCTAssertEqual(index.language(of: .items)?.name, "Polish")
        XCTAssertNil(index.language(of: .fulltext), "nothing indexed, nothing to report")

        try index.replaceDocument(slug: "notes", segments: [
            .init(index: 1, title: "Page 1", text: """
                  Let $X$ be a compact connected space. Then every continuous map attains
                  its bounds, and the image is a closed interval of the real line.
                  """)
        ])
        XCTAssertEqual(index.language(of: .document("notes"))?.name, "English",
                       "a file's language is its own, not the library's")

        // The cached answer must not survive the corpus it described.
        try index.rebuild(items: [
            TheoryItem(id: "thm-compact", type: .theorem, name: "Compactness",
                       body: """
                       ## Statement
                       Let $X$ be a compact connected topological space. Then every
                       continuous real map on it attains its bounds.
                       """)
        ])
        XCTAssertEqual(index.language(of: .items)?.name, "English")
        try index.removeDocument(slug: "notes")
        XCTAssertNil(index.language(of: .document("notes")))
    }

    /// A resumed research program starts queued assignments before the director finishes
    /// assembling its own tools. Both paths ask the shared index for corpus languages, so
    /// first-time cache population must be safe across concurrent tool-spec construction.
    func testConcurrentLanguageAndSearchAccessIsSerialized() throws {
        let index = try SearchIndex()
        try index.rebuild(items: [
            TheoryItem(id: "thm-compact", type: .theorem, name: "Compactness",
                       body: "A compact connected space has useful continuous-image properties.")
        ])

        let documentCount = 32
        let prose = """
            Let X be a compact connected topological space. Every continuous real-valued
            function on X attains its bounds, and its image is a closed interval.
            """
        for number in 0..<documentCount {
            try index.replaceDocument(slug: "notes-\(number)", segments: [
                .init(index: 1, title: "Compactness", text: prose)
            ])
        }

        let resultLock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: documentCount * 8) { iteration in
            let slug = "notes-\(iteration % documentCount)"
            do {
                let language = index.language(of: .document(slug))?.name
                let hits = try index.searchDocuments("compact", document: slug)
                if language != "English" || hits.count != 1 {
                    resultLock.lock()
                    failures.append("\(slug): language=\(language ?? "nil"), hits=\(hits.count)")
                    resultLock.unlock()
                }
            } catch {
                resultLock.lock()
                failures.append("\(slug): \(error.localizedDescription)")
                resultLock.unlock()
            }
        }

        XCTAssertEqual(failures, [])
    }

    func testUpsertAndRemove() throws {
        let index = try SearchIndex()
        try index.upsert(TheoryItem(id: "x", type: .lemma, name: "Handshake", body: "degrees"))
        XCTAssertEqual(try index.search("handshake").count, 1)
        try index.upsert(TheoryItem(id: "x", type: .lemma, name: "Renamed", body: "degrees"))
        XCTAssertEqual(try index.search("handshake").count, 0)
        try index.remove(id: "x")
        XCTAssertEqual(try index.search("renamed").count, 0)
    }
}

final class StoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateSaveReopen() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Test Theory")
        XCTAssertEqual(store.meta.name, "Test Theory")

        let item = TheoryItem(
            id: "lem-first", type: .lemma, name: "First lemma",
            dependsOn: [], body: "## Statement\n$1+1=2$."
        )
        try store.save(item)

        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.item(id: "lem-first")?.name, "First lemma")
        XCTAssertEqual(try reopened.index.search("lemma").first?.id, "lem-first")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("graph.json").path))
    }

    func testOpenNonProjectThrows() {
        XCTAssertThrowsError(try ProjectStore(opening: tempDir))
    }

    func testOverviewRoundTrip() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Source Work")
        XCTAssertEqual(store.overview, "")
        try store.saveOverview("## What This Work Is\nA study of tilings.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("overview.md").path))
        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(reopened.overview, "## What This Work Is\nA study of tilings.")
    }

    func testChatSaveLoadListDelete() throws {
        let store = try ProjectStore.create(at: tempDir, name: "T")
        XCTAssertEqual(store.chatIDs(), [], "no chats before any are saved")
        XCTAssertNil(store.loadChat(id: "a"))

        try store.saveChat(id: "a", json: Data(#"{"n":1}"#.utf8))
        try store.saveChat(id: "b", json: Data(#"{"n":2}"#.utf8))
        XCTAssertEqual(Set(store.chatIDs()), ["a", "b"])
        XCTAssertEqual(store.loadChat(id: "a"), Data(#"{"n":1}"#.utf8))

        // Chats live in the project folder, so they survive a reopen (per-project history).
        let reopened = try ProjectStore(opening: tempDir)
        XCTAssertEqual(Set(reopened.chatIDs()), ["a", "b"])

        reopened.deleteChat(id: "a")
        XCTAssertEqual(reopened.chatIDs(), ["b"])
        XCTAssertNil(reopened.loadChat(id: "a"))
    }

    func testDeleteAndAvailableID() throws {
        let store = try ProjectStore.create(at: tempDir, name: "T")
        try store.save(TheoryItem(id: "lem-x", type: .lemma, name: "X"))
        XCTAssertEqual(store.availableID(for: .lemma, name: "X"), "lem-x-2")
        try store.delete(id: "lem-x")
        XCTAssertNil(store.item(id: "lem-x"))
        XCTAssertEqual(store.availableID(for: .lemma, name: "X"), "lem-x")
    }

    func testSourceLibraryAndAttachment() throws {
        let libraryDir = tempDir.appendingPathComponent("library")
        let library = SourceLibrary(rootURL: libraryDir)
        let source = try library.createSource(
            name: "Complex Analytic Geometry",
            authors: ["S. Łojasiewicz"],
            citation: "Łojasiewicz, Introduction to Complex Analytic Geometry, 1991",
            license: "personal-use"
        )
        XCTAssertEqual(source.meta.kind, .source)
        try source.save(TheoryItem(id: "thm-w", type: .theorem, name: "W", status: .source))

        // Slug collision gets a suffix.
        let second = try library.createSource(name: "Complex Analytic Geometry")
        XCTAssertEqual(second.rootURL.lastPathComponent, "complex-analytic-geometry-2")
        XCTAssertEqual(library.list().count, 2)

        // Attach/detach persists through reopen.
        let projectDir = tempDir.appendingPathComponent("project")
        let project = try ProjectStore.create(at: projectDir, name: "Work")
        try project.attachSource(SourceRef(slug: "complex-analytic-geometry", path: source.rootURL.path))
        try project.attachSource(SourceRef(slug: "complex-analytic-geometry", path: "dup"))  // ignored
        let reopened = try ProjectStore(opening: projectDir)
        XCTAssertEqual(reopened.meta.sources?.count, 1)
        XCTAssertEqual(reopened.meta.sources?.first?.slug, "complex-analytic-geometry")
        try reopened.detachSource(slug: "complex-analytic-geometry")
        XCTAssertEqual(try ProjectStore(opening: projectDir).meta.sources?.count, 0)
    }

    func testPackageExportImportRoundTrip() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Shareable Theory")
        try store.save(TheoryItem(
            id: "thm-share", type: .theorem, name: "Shared theorem",
            section: "main", body: "## Statement\n$x = x$."))
        try store.saveMacros("\\newcommand{\\A}{\\mathcal{A}}\n")
        try store.saveOverview("## What This Work Is\nShareable overview.")
        // Personal state that must NOT travel in the package:
        try store.saveSession(named: "current", json: Data("[]".utf8))
        try store.saveMemory("## Goal\nPrivate working notes.")

        let packURL = tempDir.deletingLastPathComponent()
            .appendingPathComponent("share-test-\(UUID().uuidString).manifieldpack")
        defer { try? FileManager.default.removeItem(at: packURL) }
        try ProjectPackage.export(projectAt: tempDir, to: packURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.path))

        let destination = tempDir.deletingLastPathComponent()
            .appendingPathComponent("imported-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let imported = try ProjectPackage.importPackage(at: packURL, to: destination)

        XCTAssertEqual(imported.meta.name, "Shareable Theory")
        XCTAssertEqual(imported.item(id: "thm-share")?.section, "main")
        XCTAssertEqual(imported.macros, "\\newcommand{\\A}{\\mathcal{A}}\n")
        XCTAssertEqual(try imported.index.search("shared").first?.id, "thm-share", "index rebuilt on import")
        XCTAssertNil(imported.loadSession(named: "current"), "sessions must not travel")
        XCTAssertEqual(imported.overview, "## What This Work Is\nShareable overview.",
                       "the source overview is shareable content")
        XCTAssertTrue(imported.memory.isEmpty || imported.memory == MemoryDocument.stub(),
                      "memory must not travel")
    }

    func testImportPackageRefusesExistingDestinationAndGarbage() throws {
        try ProjectStore.create(at: tempDir, name: "T")
        let pack = tempDir.deletingLastPathComponent()
            .appendingPathComponent("bad-\(UUID().uuidString).manifieldpack")
        defer { try? FileManager.default.removeItem(at: pack) }
        try Data("not a zip".utf8).write(to: pack)

        let destination = tempDir.deletingLastPathComponent()
            .appendingPathComponent("garbage-import-\(UUID().uuidString)")
        XCTAssertThrowsError(try ProjectPackage.importPackage(at: pack, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "failed import must clean up after itself")
        XCTAssertThrowsError(try ProjectPackage.importPackage(at: pack, to: tempDir),
                             "existing destination must be refused")
    }

    func testBreakageAffected() throws {
        let store = try ProjectStore.create(at: tempDir, name: "T")
        // lem-base ← thm-mid (reviewed) ← thm-top (human-approved); rem-side (proof-drafted)
        try store.save(TheoryItem(id: "lem-base", type: .lemma, name: "Base", status: .reviewedNoErrors))
        try store.save(TheoryItem(id: "thm-mid", type: .theorem, name: "Mid",
                                  status: .reviewedNoErrors, dependsOn: ["lem-base"]))
        try store.save(TheoryItem(id: "thm-top", type: .theorem, name: "Top",
                                  status: .humanApproved, dependsOn: ["thm-mid"]))
        try store.save(TheoryItem(id: "rem-side", type: .remark, name: "Side",
                                  status: .proofDrafted, dependsOn: ["lem-base"]))
        try store.save(TheoryItem(id: "thm-lit", type: .theorem, name: "Lit",
                                  status: .source, dependsOn: ["lem-base"]))

        let affected = store.breakageAffected(of: "lem-base").map(\.id)
        XCTAssertEqual(affected, ["thm-mid", "thm-top"],
                       "proof-drafted needs no downgrade; literature is never touched")
        XCTAssertEqual(store.breakageAffected(of: "thm-top").count, 0)
    }

    func testMalformedFileBecomesWarningNotCrash() throws {
        let store = try ProjectStore.create(at: tempDir, name: "T")
        let bad = tempDir.appendingPathComponent("theory/broken.md")
        try "no frontmatter here".write(to: bad, atomically: true, encoding: .utf8)
        try store.reload()
        XCTAssertEqual(store.items.count, 0)
        XCTAssertEqual(store.loadWarnings.count, 1)
    }
}
