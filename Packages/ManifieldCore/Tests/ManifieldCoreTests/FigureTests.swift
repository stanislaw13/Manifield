import XCTest
@testable import ManifieldCore

final class FigureTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("figure-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> ProjectStore {
        try ProjectStore.create(at: root, name: "Figures")
    }

    /// Writes a tiny real PNG (1×1, black) so copies and MIME lookups work on actual bytes.
    private func writePNG(named name: String) throws -> URL {
        let base64 = """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    // MARK: - Path sanitization

    func testSanitizedPathAcceptsOnlyFilesDirectlyInFigures() {
        XCTAssertEqual(FigureAsset.sanitizedPath("figures/fig-a.png"), "figures/fig-a.png")
        XCTAssertEqual(FigureAsset.sanitizedPath("figures/fig-a.JPG"), "figures/fig-a.JPG")
        XCTAssertEqual(FigureAsset.sanitizedPath("  figures/fig-a.py  "), "figures/fig-a.py")
    }

    func testSanitizedPathRejectsEscapesAndOddities() {
        let rejected = [
            "/etc/passwd",
            "/Users/someone/.ssh/id_rsa",
            "figures/../../../etc/passwd",
            "../figures/fig-a.png",
            "figures/nested/fig-a.png",
            "theory/fig-a.png",
            "fig-a.png",
            "figures/",
            "figures/.hidden.png",
            "figures/fig-a",                       // no extension
            "figures/fig-a.svg",                   // not an allowed format
            "figures/fig-a.pdf",
            "figures/fig-a.png\\..\\secret",
            "file:///etc/passwd",
            "https://example.com/a.png",
            "figures/a.png/../../b.png",
            ""
        ]
        for path in rejected {
            XCTAssertNil(FigureAsset.sanitizedPath(path), "should have rejected '\(path)'")
        }
        XCTAssertNil(FigureAsset.sanitizedPath(nil))
    }

    /// `resolve` is the call that hands bytes to a web view, so it re-checks containment
    /// after symlinks — a link inside figures/ pointing out of the project must not resolve.
    func testResolveRefusesSymlinkOutOfFigures() throws {
        let store = try makeStore()
        let secret = root.appendingPathComponent("secret.png")
        try Data("not a figure".utf8).write(to: secret)
        let link = store.figuresURL.appendingPathComponent("fig-escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        XCTAssertNotNil(FigureAsset.sanitizedPath("figures/fig-escape.png"))
        XCTAssertNil(FigureAsset.resolve("figures/fig-escape.png", in: root))
    }

    func testResolveReturnsNilForMissingFile() throws {
        _ = try makeStore()
        XCTAssertNil(FigureAsset.resolve("figures/fig-absent.png", in: root))
    }

    func testMimeTypes() {
        XCTAssertEqual(FigureAsset.mimeType(forExtension: "PNG"), "image/png")
        XCTAssertEqual(FigureAsset.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertNil(FigureAsset.mimeType(forExtension: "svg"))
    }

    // MARK: - Frontmatter

    func testFigureRoundTripsThroughFrontmatter() throws {
        let item = TheoryItem(
            id: "fig-hat-tile", type: .figure, name: "The hat tile",
            status: .illustration,
            dependsOn: ["thm-aperiodicity"],
            section: "preliminaries",
            image: "figures/fig-hat-tile.png",
            generator: "figures/fig-hat-tile.py",
            body: "## Caption\nThe hat and its reflection."
        )
        let reparsed = try TheoryItem.parse(markdown: item.serialized())
        XCTAssertEqual(reparsed.type, .figure)
        XCTAssertEqual(reparsed.status, .illustration)
        XCTAssertEqual(reparsed.image, "figures/fig-hat-tile.png")
        XCTAssertEqual(reparsed.generator, "figures/fig-hat-tile.py")
        XCTAssertEqual(reparsed.dependsOn, ["thm-aperiodicity"])
        XCTAssertEqual(reparsed.caption, "The hat and its reflection.")
        XCTAssertTrue(reparsed.isFigure)
    }

    func testFigureWithoutStatusDefaultsToIllustration() throws {
        let doc = """
        ---
        id: fig-plot
        type: figure
        name: A plot
        image: figures/fig-plot.png
        ---
        ## Caption
        A plot.
        """
        let item = try TheoryItem.parse(markdown: doc)
        XCTAssertEqual(item.status, .illustration)
    }

    /// The parser is what agent-written frontmatter goes through, so a traversal in
    /// `image:` has to be dropped rather than carried into the item.
    func testParseDropsUnsafeImagePath() throws {
        let doc = """
        ---
        id: fig-evil
        type: figure
        name: Evil
        image: ../../../../etc/passwd
        generator: /bin/sh
        ---
        ## Caption
        Nope.
        """
        let item = try TheoryItem.parse(markdown: doc)
        XCTAssertNil(item.image)
        XCTAssertNil(item.generator)
    }

    // MARK: - Type & status wiring

    func testFigureTypeProperties() {
        XCTAssertEqual(ItemType.figure.shapeFamily, .figure)
        XCTAssertEqual(ItemType.figure.idPrefix, "fig")
        XCTAssertEqual(ItemType.figure.pluralName, "Figures")
        XCTAssertFalse(ItemType.figure.isProvable)
        XCTAssertFalse(ItemType.figure.isImportable)
        XCTAssertTrue(ItemType.figure.isAsset)
        // Everything else stays importable — the filter must not catch bystanders.
        XCTAssertEqual(ItemType.allCases.filter { !$0.isImportable }, [.figure])
    }

    /// Rank 0 is what keeps figures out of breakage propagation; the ladder helper is
    /// what keeps `illustration` out of the status menus.
    func testIllustrationStatusIsOffTheLadder() {
        XCTAssertEqual(ItemStatus.illustration.rank, 0)
        XCTAssertFalse(ItemStatus.ladder.contains(.illustration))
        XCTAssertEqual(ItemStatus.ladder.count, ItemStatus.allCases.count - 1)
    }

    func testFiguresAreNeverBreakageAffected() throws {
        let store = try makeStore()
        try store.save(TheoryItem(id: "thm-a", type: .theorem, name: "A",
                                  status: .humanApproved, body: "## Statement\nA."))
        try store.save(TheoryItem(id: "fig-a", type: .figure, name: "Picture of A",
                                  status: .illustration, dependsOn: ["thm-a"],
                                  image: "figures/fig-a.png", body: "## Caption\nA."))
        try store.save(TheoryItem(id: "cor-a", type: .corollary, name: "C",
                                  status: .humanApproved, dependsOn: ["thm-a"],
                                  body: "## Statement\nC."))

        let affected = store.breakageAffected(of: "thm-a").map(\.id)
        XCTAssertEqual(affected, ["cor-a"], "a figure has no proof to invalidate")
    }

    // MARK: - Store

    func testAddFigureImageStoresAndReplaces() throws {
        let store = try makeStore()
        let png = try writePNG(named: "first.png")

        let relative = try store.addFigureImage(from: png, for: "fig-a")
        XCTAssertEqual(relative, "figures/fig-a.png")

        var item = TheoryItem(id: "fig-a", type: .figure, name: "A", status: .illustration,
                              image: relative, body: "## Caption\nA.")
        try store.save(item)
        XCTAssertNotNil(store.figureImageURL(for: item))

        // Replacing with a different format must not leave the old file behind.
        let jpg = try writePNG(named: "second.jpg")
        item.image = try store.addFigureImage(from: jpg, for: "fig-a")
        try store.save(item)
        XCTAssertEqual(item.image, "figures/fig-a.jpg")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.figuresURL.appendingPathComponent("fig-a.png").path))
        XCTAssertNotNil(store.figureImageURL(for: item))
    }

    func testAddFigureImageRejectsUnsupportedFormat() throws {
        let store = try makeStore()
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).svg")
        try Data("<svg/>".utf8).write(to: text)
        XCTAssertThrowsError(try store.addFigureImage(from: text, for: "fig-a"))
    }

    func testDeletingAFigureRemovesItsAssets() throws {
        let store = try makeStore()
        let png = try writePNG(named: "a.png")
        let relative = try store.addFigureImage(from: png, for: "fig-a")
        try store.save(TheoryItem(id: "fig-a", type: .figure, name: "A", status: .illustration,
                                  image: relative, body: "## Caption\nA."))

        try store.delete(id: "fig-a")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.figuresURL.appendingPathComponent("fig-a.png").path))
    }

    func testReloadWarnsAboutMissingImage() throws {
        let store = try makeStore()
        try store.save(TheoryItem(id: "fig-gone", type: .figure, name: "Gone",
                                  status: .illustration, image: "figures/fig-gone.png",
                                  body: "## Caption\nGone."))
        try store.reload()
        XCTAssertTrue(store.loadWarnings.contains { $0.contains("fig-gone") },
                      "expected a warning, got \(store.loadWarnings)")
        // The item itself still loads — the caption is content worth keeping.
        XCTAssertNotNil(store.item(id: "fig-gone"))
    }

    func testFiguresTravelInAPackage() throws {
        let store = try makeStore()
        let png = try writePNG(named: "a.png")
        let relative = try store.addFigureImage(from: png, for: "fig-a")
        try store.save(TheoryItem(id: "fig-a", type: .figure, name: "A", status: .illustration,
                                  image: relative, body: "## Caption\nA."))

        let pack = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).manifieldpack")
        let restored = FileManager.default.temporaryDirectory
            .appendingPathComponent("restored-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: pack)
            try? FileManager.default.removeItem(at: restored)
        }

        try ProjectPackage.export(projectAt: root, to: pack)
        let reopened = try ProjectPackage.importPackage(at: pack, to: restored)

        let item = try XCTUnwrap(reopened.item(id: "fig-a"))
        XCTAssertEqual(item.image, "figures/fig-a.png")
        XCTAssertNotNil(reopened.figureImageURL(for: item), "the image should have travelled")
        XCTAssertTrue(reopened.loadWarnings.isEmpty, "got \(reopened.loadWarnings)")
    }

    // MARK: - Promoting a sandbox render

    private func makeRun(_ name: String, in store: ProjectStore, script: Bool = true) throws -> URL {
        let run = store.artifactsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let png = try writePNG(named: "viz.png")
        try FileManager.default.copyItem(at: png, to: run.appendingPathComponent("viz.png"))
        if script {
            try Data("print('hi')".utf8).write(to: run.appendingPathComponent("script.py"))
        }
        return run
    }

    func testArtifactRunNameAcceptsTheFormsAModelWillSend() {
        XCTAssertEqual(FigureAsset.artifactRunName("artifacts/2026-run-a/viz.png"), "2026-run-a")
        XCTAssertEqual(FigureAsset.artifactRunName("2026-run-a/viz.png"), "2026-run-a")
        XCTAssertEqual(FigureAsset.artifactRunName("artifacts/2026-run-a"), "2026-run-a")
        XCTAssertEqual(FigureAsset.artifactRunName("2026-run-a"), "2026-run-a")
        XCTAssertEqual(FigureAsset.artifactRunName(" artifacts/2026-run-a/ "), "2026-run-a")
    }

    func testArtifactRunNameRejectsAnythingThatCouldLeaveTheRunFolder() {
        for raw in ["../secrets", "artifacts/../theory", "artifacts/a/b/viz.png",
                    "/etc", "artifacts//viz.png", "artifacts/.hidden", "",
                    "artifacts/a/../../b", "file:///etc"] {
            XCTAssertNil(FigureAsset.artifactRunName(raw), "should have rejected '\(raw)'")
        }
        XCTAssertNil(FigureAsset.artifactRunName(nil))
    }

    func testResolveArtifactRenderFindsImageAndScript() throws {
        let store = try makeStore()
        _ = try makeRun("run-a", in: store)

        let render = try XCTUnwrap(
            FigureAsset.resolveArtifactRender("artifacts/run-a/viz.png", in: root))
        XCTAssertEqual(render.run, "run-a")
        XCTAssertEqual(render.imageURL.lastPathComponent, "viz.png")
        XCTAssertEqual(render.generatorURL?.lastPathComponent, "script.py")
    }

    func testResolveArtifactRenderWithoutAScript() throws {
        let store = try makeStore()
        _ = try makeRun("run-b", in: store, script: false)
        let render = try XCTUnwrap(FigureAsset.resolveArtifactRender("run-b", in: root))
        XCTAssertNil(render.generatorURL)
    }

    func testResolveArtifactRenderReturnsNilForUnknownRun() throws {
        _ = try makeStore()
        XCTAssertNil(FigureAsset.resolveArtifactRender("run-does-not-exist", in: root))
    }

    func testAdoptArtifactRenderCopiesBothAndLeavesTheRunIntact() throws {
        let store = try makeStore()
        let run = try makeRun("run-c", in: store)
        let render = try XCTUnwrap(FigureAsset.resolveArtifactRender("run-c", in: root))

        let paths = try store.adoptArtifactRender(render, for: "fig-promoted")
        XCTAssertEqual(paths.image, "figures/fig-promoted.png")
        XCTAssertEqual(paths.generator, "figures/fig-promoted.py")

        let item = TheoryItem(id: "fig-promoted", type: .figure, name: "Promoted",
                              status: .illustration, image: paths.image,
                              generator: paths.generator, body: "## Caption\nC.")
        try store.save(item)
        XCTAssertNotNil(store.figureImageURL(for: item))
        XCTAssertNotNil(store.figureGeneratorURL(for: item))
        // The run folder is the audit trail for the run; promoting copies, never moves.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("viz.png").path))
    }

    // MARK: - The shipped sample project

    /// The sample project is what the README tells a new user to open, so its figure has
    /// to actually resolve — a missing PNG would make the feature's one demo a grey box.
    /// Skipped when the package is built outside the repo checkout.
    func testSampleProjectFigureResolves() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ManifieldCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ManifieldCore
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo root
        let sample = repoRoot.appendingPathComponent("SampleProject")
        try XCTSkipUnless(ProjectStore.isProject(sample), "SampleProject not present")

        let store = try ProjectStore(opening: sample)
        XCTAssertTrue(store.loadWarnings.isEmpty, "got \(store.loadWarnings)")

        let figure = try XCTUnwrap(store.item(id: "fig-2-dominating-set"))
        XCTAssertEqual(figure.type, .figure)
        XCTAssertEqual(figure.status, .illustration)
        XCTAssertNotNil(store.figureImageURL(for: figure), "the sample figure's PNG is missing")
        XCTAssertNotNil(store.figureGeneratorURL(for: figure))
        XCTAssertNotNil(figure.caption)
        // It illustrates real items, not dangling ids — otherwise the graph shows a stub.
        for id in figure.dependsOn {
            XCTAssertNotNil(store.item(id: id), "fig-2-dominating-set illustrates unknown '\(id)'")
        }
        // And it is findable by what the caption says, not just by its id.
        let hits = try store.index.search("dominating set shaded")
        XCTAssertTrue(hits.contains { $0.id == "fig-2-dominating-set" },
                      "caption text is not indexed; hits: \(hits.map(\.id))")
    }

    // MARK: - Graph

    func testGraphUsesCaptionAndDrawsFiguresSolid() throws {
        let items = [
            TheoryItem(id: "thm-a", type: .theorem, name: "A", status: .proofDrafted,
                       body: "## Statement\nA."),
            TheoryItem(id: "fig-a", type: .figure, name: "Picture", status: .illustration,
                       dependsOn: ["thm-a"], image: "figures/fig-a.png",
                       body: "## Caption\nWhat A looks like.")
        ]
        let json = try DependencyGraph(items: items).webJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        let figure = try XCTUnwrap(nodes.first { $0["id"] as? String == "fig-a" })

        XCTAssertEqual(figure["family"] as? String, "figure")
        XCTAssertEqual(figure["statement"] as? String, "What A looks like.")
        XCTAssertEqual(figure["statusRank"] as? Int, ItemStatus.reviewedNoErrors.rank,
                       "a figure must not fade out like an unproved conjecture")

        // The edge runs theorem → figure: the picture is derived from the result.
        let edges = try XCTUnwrap(object["edges"] as? [[String: Any]])
        XCTAssertTrue(edges.contains {
            $0["source"] as? String == "thm-a" && $0["target"] as? String == "fig-a"
        }, "got \(edges)")
    }
}
