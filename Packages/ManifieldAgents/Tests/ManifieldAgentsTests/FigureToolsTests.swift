import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class FigureToolsTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!
    /// Proposals the tool handed back, in order — the stand-in for the review sheet.
    private var recorded: [TheoryProposal] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("figure-tool-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "FT")
        recorded = []
        try store.save(TheoryItem(
            id: "thm-a", type: .theorem, name: "A bound", status: .proofDrafted,
            body: "## Statement\n$x \\le y$."))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRun(_ name: String, script: Bool = true) throws {
        let run = store.artifactsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
            """))
        try png.write(to: run.appendingPathComponent("viz.png"))
        if script {
            try Data("import matplotlib".utf8).write(to: run.appendingPathComponent("script.py"))
        }
    }

    private func saveFigureTool() -> AgentTool {
        FigureTools.writeTools(store: store) { [self] proposal in
            recorded.append(proposal)
            return "recorded \(proposal.item.id)"
        }[0]
    }

    private func readFigureTool() -> AgentTool {
        FigureTools.readTools(store: store)[0]
    }

    // MARK: - save_figure

    func testSaveFigureProposesAFigureWithoutWritingAnything() async throws {
        try makeRun("run-a")
        let reply = try await saveFigureTool().execute(inputJSON: #"""
        {"artifact":"artifacts/run-a/viz.png","name":"Tight example",
         "caption":"The bound is attained at $x = y$.","illustrates":["thm-a"],
         "section":"preliminaries"}
        """#)

        XCTAssertEqual(reply, "recorded fig-tight-example")
        let proposal = try XCTUnwrap(recorded.first)
        XCTAssertEqual(proposal.action, .create)
        XCTAssertEqual(proposal.figureSource, "run-a")

        let item = proposal.item
        XCTAssertEqual(item.type, .figure)
        XCTAssertEqual(item.status, .illustration)
        XCTAssertEqual(item.dependsOn, ["thm-a"])
        XCTAssertEqual(item.section, "preliminaries")
        XCTAssertEqual(item.image, "figures/fig-tight-example.png")
        XCTAssertEqual(item.generator, "figures/fig-tight-example.py")
        XCTAssertEqual(item.caption, "The bound is attained at $x = y$.")

        // Proposing must not touch the project: no item, and figures/ still empty.
        XCTAssertNil(store.item(id: "fig-tight-example"))
        let figures = try FileManager.default.contentsOfDirectory(
            at: store.figuresURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(figures, [], "proposing must not copy anything into figures/")
    }

    func testSaveFigureWithoutAScriptCarriesNoGenerator() async throws {
        try makeRun("run-b", script: false)
        _ = try await saveFigureTool().execute(inputJSON: #"""
        {"artifact":"run-b","name":"Sketch","caption":"A sketch."}
        """#)
        XCTAssertNil(try XCTUnwrap(recorded.first).item.generator)
    }

    func testSaveFigureRejectsAnUnknownRender() async throws {
        do {
            _ = try await saveFigureTool().execute(inputJSON: #"""
            {"artifact":"artifacts/never-rendered/viz.png","name":"X","caption":"Y"}
            """#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue("\(error)".contains("create_visualization"),
                          "the error should point at the fix, got: \(error)")
        }
        XCTAssertTrue(recorded.isEmpty)
    }

    /// The tool must not be usable to reach outside a run folder, whatever the model sends.
    func testSaveFigureRejectsPathEscapes() async throws {
        try makeRun("run-c")
        for artifact in ["../../../etc", "artifacts/../theory", "/etc/passwd",
                         "artifacts/run-c/../../theory/thm-a.md"] {
            do {
                let json = "{\"artifact\":\"\(artifact)\",\"name\":\"X\",\"caption\":\"Y\"}"
                _ = try await saveFigureTool().execute(inputJSON: json)
                XCTFail("expected '\(artifact)' to be rejected")
            } catch {
                // expected
            }
        }
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSaveFigureRequiresACaption() async throws {
        try makeRun("run-d")
        do {
            _ = try await saveFigureTool().execute(inputJSON: #"""
            {"artifact":"run-d","name":"X","caption":"   "}
            """#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue("\(error)".contains("caption"), "got: \(error)")
        }
    }

    /// A dangling id would draw a stub node in the graph, so it is refused up front —
    /// but a citation into an attached source (`slug:id`) is legitimate and must pass.
    func testSaveFigureRejectsUnknownIllustratesButAllowsSourceCitations() async throws {
        try makeRun("run-e")
        do {
            _ = try await saveFigureTool().execute(inputJSON: #"""
            {"artifact":"run-e","name":"X","caption":"Y","illustrates":["thm-a","lem-ghost"]}
            """#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue("\(error)".contains("lem-ghost"), "got: \(error)")
        }

        _ = try await saveFigureTool().execute(inputJSON: #"""
        {"artifact":"run-e","name":"Cited","caption":"Y","illustrates":["ahlfors:thm-3-1"]}
        """#)
        XCTAssertEqual(try XCTUnwrap(recorded.first).item.dependsOn, ["ahlfors:thm-3-1"])
    }

    // MARK: - The tool/host seam

    /// `save_figure` writes the asset paths the item *will* have, and the host fills them
    /// in for real on acceptance. Those two must agree: if they drift, a figure lands with
    /// frontmatter pointing at a file that is not there, and nothing fails loudly.
    /// This mirrors what `AppState.accept` does, which lives in the app target.
    func testAcceptingAProposalProducesExactlyThePathsTheToolPredicted() async throws {
        try makeRun("run-accept")
        _ = try await saveFigureTool().execute(inputJSON: #"""
        {"artifact":"artifacts/run-accept/viz.png","name":"Promoted",
         "caption":"A promoted render.","illustrates":["thm-a"]}
        """#)
        let proposal = try XCTUnwrap(recorded.first)

        // --- the host's side of the contract ---
        var item = proposal.item
        let render = try XCTUnwrap(
            FigureAsset.resolveArtifactRender(try XCTUnwrap(proposal.figureSource),
                                              in: store.rootURL))
        let paths = try store.adoptArtifactRender(render, for: item.id)
        item.image = paths.image
        item.generator = paths.generator
        try store.save(item)

        XCTAssertEqual(paths.image, proposal.item.image)
        XCTAssertEqual(paths.generator, proposal.item.generator)

        // And the figure is whole: reload from disk, resolve both assets, no warnings.
        try store.reload()
        let reloaded = try XCTUnwrap(store.item(id: "fig-promoted"))
        XCTAssertNotNil(store.figureImageURL(for: reloaded))
        XCTAssertNotNil(store.figureGeneratorURL(for: reloaded))
        XCTAssertEqual(store.loadWarnings, [])
        XCTAssertEqual(reloaded.dependsOn, ["thm-a"])
    }

    /// Rejecting must leave nothing behind — and the render stays in its run folder, so
    /// the user can change their mind without a re-render.
    func testRejectingAProposalLeavesTheProjectUntouched() async throws {
        try makeRun("run-reject")
        _ = try await saveFigureTool().execute(inputJSON: #"""
        {"artifact":"run-reject","name":"Discarded","caption":"Not kept."}
        """#)
        XCTAssertFalse(recorded.isEmpty)

        // Rejection is just dropping the proposal; no host-side cleanup runs.
        try store.reload()
        XCTAssertNil(store.item(id: "fig-discarded"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: store.figuresURL, includingPropertiesForKeys: nil), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.artifactsURL
                .appendingPathComponent("run-reject/viz.png").path))
    }

    // MARK: - read_figure

    func testReadFigureReportsCaptionGeneratorAndThatItCannotBeSeen() async throws {
        try makeRun("run-f")
        let render = try XCTUnwrap(
            FigureAsset.resolveArtifactRender("run-f", in: store.rootURL))
        let paths = try store.adoptArtifactRender(render, for: "fig-x")
        try store.save(TheoryItem(
            id: "fig-x", type: .figure, name: "A picture", status: .illustration,
            dependsOn: ["thm-a"], image: paths.image, generator: paths.generator,
            body: "## Caption\nWhat the bound looks like."))

        let reply = try await readFigureTool().execute(inputJSON: #"{"id":"fig-x"}"#)
        XCTAssertTrue(reply.contains("fig-x — A picture"))
        XCTAssertTrue(reply.contains("illustrates: thm-a"))
        XCTAssertTrue(reply.contains("What the bound looks like"))
        XCTAssertTrue(reply.contains("import matplotlib"), "generator source should be included")
        XCTAssertTrue(reply.contains("not shown to you"),
                      "the model must be told it has not seen the image")
    }

    func testReadFigureSaysWhenTheImageIsMissing() async throws {
        try store.save(TheoryItem(
            id: "fig-gone", type: .figure, name: "Gone", status: .illustration,
            image: "figures/fig-gone.png", body: "## Caption\nGone."))
        let reply = try await readFigureTool().execute(inputJSON: #"{"id":"fig-gone"}"#)
        XCTAssertTrue(reply.contains("MISSING"), "got: \(reply)")
    }

    func testReadFigureRefusesNonFigures() async throws {
        do {
            _ = try await readFigureTool().execute(inputJSON: #"{"id":"thm-a"}"#)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue("\(error)".contains("read_theory_item"), "got: \(error)")
        }
    }

    // MARK: - The generic write tools must not mint imageless figures

    private func proposeTool() -> AgentTool {
        TheoryTools.chatTools(store: store) { [self] proposal in recorded.append(proposal) }
            .first { $0.spec.name == "propose_theory_edit" }!
    }

    func testProposeCannotCreateAFigure() async throws {
        let markdown = """
        ---
        id: fig-invented
        type: figure
        name: Invented
        image: figures/fig-invented.png
        ---
        ## Caption
        A picture that does not exist.
        """
        let json = try String(
            data: JSONSerialization.data(withJSONObject: ["action": "create", "markdown": markdown]),
            encoding: .utf8)!
        do {
            _ = try await proposeTool().execute(inputJSON: json)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertTrue("\(error)".contains("save_figure"),
                          "the error should point at the tool that works, got: \(error)")
        }
        XCTAssertTrue(recorded.isEmpty)
    }

    /// Editing a caption is fine; silently repointing (or dropping) the image is not.
    func testUpdatingAFigureKeepsItsAssetsWhateverTheModelWrites() async throws {
        try store.save(TheoryItem(
            id: "fig-y", type: .figure, name: "Y", status: .illustration,
            image: "figures/fig-y.png", generator: "figures/fig-y.py",
            body: "## Caption\nOld caption."))

        let markdown = """
        ---
        id: fig-y
        type: figure
        name: Y
        status: human-approved
        image: figures/something-else.png
        ---
        ## Caption
        A better caption.
        """
        let json = try String(
            data: JSONSerialization.data(withJSONObject: ["action": "update", "markdown": markdown]),
            encoding: .utf8)!
        _ = try await proposeTool().execute(inputJSON: json)

        let item = try XCTUnwrap(recorded.first).item
        XCTAssertEqual(item.caption, "A better caption.")
        XCTAssertEqual(item.image, "figures/fig-y.png", "the backing file must not move")
        XCTAssertEqual(item.generator, "figures/fig-y.py")
        XCTAssertEqual(item.status, .illustration, "a figure never climbs the trust ladder")
    }
}
