import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class SourceOverviewTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifieldagents-overview-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Chunk parsing

    func testParseSourceChunkExtractsSummaryAndItems() throws {
        let response = """
        [
          {"id": "thm-hex", "type": "theorem", "name": "Hexagon classification",
           "statement": "Every convex hexagon tile belongs to one of three families."},
          {"type": "summary", "content": "Classifies convex hexagon tiles (thm-hex) via angle sums."}
        ]
        """
        let (items, summary, warnings) = try Organizer.parseSourceChunk(from: response)
        XCTAssertEqual(items.map(\.id), ["thm-hex"])
        XCTAssertEqual(summary, "Classifies convex hexagon tiles (thm-hex) via angle sums.")
        XCTAssertTrue(warnings.isEmpty, "summary element must not produce a skip warning")
    }

    func testParseSourceChunkWithoutSummary() throws {
        let response = #"[{"id": "def-tile", "type": "definition", "name": "Tile", "statement": "A tile is…"}]"#
        let (items, summary, warnings) = try Organizer.parseSourceChunk(from: response)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(summary)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testParseSourceChunkJoinsMultipleSummariesAndIgnoresEmpty() throws {
        let response = """
        [
          {"type": "summary", "content": "First part."},
          {"id": "lem-a", "type": "lemma", "name": "A", "statement": "S"},
          {"type": "summary", "content": "  "},
          {"type": "summary", "content": "Second part."}
        ]
        """
        let (items, summary, _) = try Organizer.parseSourceChunk(from: response)
        XCTAssertEqual(items.map(\.id), ["lem-a"])
        XCTAssertEqual(summary, "First part.\n\nSecond part.")
    }

    // MARK: - Synthesis prompt building

    func testUserMessageIncludesNotesAndOutline() {
        let message = SourceOverview.userMessage(
            name: "Tilings and Patterns",
            citation: "Grünbaum & Shephard, 1987",
            chunkNotes: [(title: "Chapter 1", note: "Basic notions of tilings.")],
            outline: "- def-tiling [definition, status: source] Tiling"
        )
        XCTAssertTrue(message.contains("Work: Tilings and Patterns"))
        XCTAssertTrue(message.contains("Citation: Grünbaum & Shephard, 1987"))
        XCTAssertTrue(message.contains("### Chapter 1\nBasic notions of tilings."))
        XCTAssertTrue(message.contains("Outline of the imported items:\n- def-tiling"))
    }

    func testUserMessageOmitsNotesSectionWhenEmpty() {
        let message = SourceOverview.userMessage(
            name: "Paper", citation: nil, chunkNotes: [], outline: "(the library is empty)"
        )
        XCTAssertFalse(message.contains("Chapter notes"))
        XCTAssertFalse(message.contains("Citation:"))
        XCTAssertTrue(message.contains("Outline of the imported items:"))
    }

    func testNormalizeStripsCodeFenceAndCapsLength() {
        let fenced = "```markdown\n## What This Work Is\nA study of tilings.\n```"
        XCTAssertEqual(SourceOverview.normalize(fenced),
                       "## What This Work Is\nA study of tilings.")

        let long = String(repeating: "x", count: SourceOverview.maxLength + 500)
        let capped = SourceOverview.normalize(long)
        XCTAssertTrue(capped.hasSuffix("… (truncated)"))
        XCTAssertLessThan(capped.count, SourceOverview.maxLength + 50)
    }

    // MARK: - Context assembly

    func testSourcesSectionIncludesOverview() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Tilings and Patterns")
        try store.updateMeta { $0.kind = .source; $0.citation = "Grünbaum & Shephard, 1987" }
        try store.save(TheoryItem(id: "thm-hex", type: .theorem, name: "Hexagons",
                                  status: .source, section: "hexagons"))
        try store.saveOverview("## What This Work Is\nThe reference work on plane tilings.")

        let section = ContextAssembly.sourcesSection(attached: [(slug: "tilings", store: store)])
        XCTAssertTrue(section.contains("- tilings — Tilings and Patterns (Grünbaum & Shephard, 1987) — 1 items"))
        XCTAssertTrue(section.contains("  Overview:\n  ## What This Work Is\n  The reference work on plane tilings."))
    }

    func testSourcesSectionWithoutOverviewHasNoOverviewBlock() throws {
        let store = try ProjectStore.create(at: tempDir, name: "Bare Source")
        let section = ContextAssembly.sourcesSection(attached: [(slug: "bare", store: store)])
        XCTAssertFalse(section.contains("Overview:"))
    }

    // MARK: - Prompt characterization

    func testSourceOverviewSystemPromptAnchors() {
        let prompt = SourceOverview.systemPrompt()
        XCTAssertTrue(prompt.contains("You are the Librarian agent in Manifield."))
        XCTAssertTrue(prompt.contains("a mathematician agent that has NOT read the work"))
        XCTAssertTrue(prompt.contains("never invent results or ids"))
        XCTAssertTrue(prompt.contains("## When To Consult"))
    }

    func testOrganizerSourceSystemPromptRequestsChapterNote() {
        let prompt = Organizer.sourceSystemPrompt(existingIDs: [], chunkSection: "s", citation: nil)
        XCTAssertTrue(prompt.contains(#"append {"type": "summary", "content": "..."}"#))
        XCTAssertTrue(prompt.contains("This element is not a theory item"))
    }
}
