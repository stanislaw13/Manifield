import XCTest
@testable import ManifieldCore

final class MemoryDocumentTests: XCTestCase {

    func testParseAndSerializeRoundTrip() {
        let markdown = """
        ## Goal
        Prove conj-gamma2-doubling for connected graphs with δ ≥ 2.

        ## Current Status
        - Lower bound settled (lem-gamma2-lower).

        ## Eliminated Strategies
        - [S1] Direct induction on n — no control of γ₂ when removing a vertex.

        ## Next Steps
        - Formalize discharging rules.
        """
        let document = MemoryDocument.parse(markdown: markdown)
        XCTAssertEqual(document.sections[.goal],
                       "Prove conj-gamma2-doubling for connected graphs with δ ≥ 2.")
        XCTAssertTrue(document.sections[.eliminatedStrategies]?.contains("Direct induction") ?? false)
        XCTAssertNil(document.sections[.activeStrategies])

        // Round-trip: parse(serialized) is stable.
        let reparsed = MemoryDocument.parse(markdown: document.serialized())
        XCTAssertEqual(reparsed.sections[.goal], document.sections[.goal])
        XCTAssertEqual(reparsed.sections[.eliminatedStrategies], document.sections[.eliminatedStrategies])
        XCTAssertEqual(reparsed.sections[.nextSteps], document.sections[.nextSteps])
    }

    func testUnknownHeadingsAndPreambleArePreserved() {
        let markdown = """
        <!-- a human note -->

        ## Goal
        The goal.

        ## Scratchpad
        Human-added section content.
        """
        let document = MemoryDocument.parse(markdown: markdown)
        XCTAssertEqual(document.sections[.goal], "The goal.")
        XCTAssertTrue(document.extra.contains("a human note"))
        XCTAssertTrue(document.extra.contains("## Scratchpad"))
        XCTAssertTrue(document.extra.contains("Human-added section content."))
        XCTAssertTrue(document.serialized().contains("## Scratchpad"))
    }

    func testEmptyAndPromptRendering() {
        let empty = MemoryDocument.parse(markdown: "")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.promptRendering.contains("empty"))

        let stub = MemoryDocument.parse(markdown: MemoryDocument.stub())
        XCTAssertFalse(stub.isEmpty, "the stub comment counts as extra content")

        var document = MemoryDocument()
        document.sections[.goal] = "G"
        XCTAssertEqual(document.promptRendering, "## Goal\nG")
        XCTAssertFalse(document.promptRendering.contains("Next Steps"),
                       "empty sections are omitted from the prompt rendering")
    }

    func testFrontmatterIsSkipped() {
        let markdown = """
        ---
        kind: memory
        ---

        ## Goal
        G
        """
        XCTAssertEqual(MemoryDocument.parse(markdown: markdown).sections[.goal], "G")
    }

    func testHeadingMatchIsCaseInsensitive() {
        let document = MemoryDocument.parse(markdown: "## key insights\nfoo")
        XCTAssertEqual(document.sections[.keyInsights], "foo")
    }
}

final class ProjectStoreMemoryTests: XCTestCase {

    func testCreateWritesStubAndSaveMemoryPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try ProjectStore.create(at: dir, name: "M")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.memoryURL.path))
        XCTAssertTrue(store.memory.contains("## Goal"))

        try store.saveMemory("## Goal\nNew goal\n")
        XCTAssertEqual(store.memory, "## Goal\nNew goal\n")

        let reopened = try ProjectStore(opening: dir)
        XCTAssertEqual(reopened.memory, "## Goal\nNew goal\n")
    }
}
