import XCTest
@testable import ManifieldCore

final class OrderingTests: XCTestCase {

    private func item(_ id: String, _ type: ItemType = .theorem,
                      section: String? = nil, order: Int? = nil) -> TheoryItem {
        TheoryItem(id: id, type: type, name: id, section: section, order: order)
    }

    func testSectionSlugOrderIsNumeric() {
        XCTAssertTrue(TheoryItem.sectionSlugOrder("part-2", "part-10"))
        XCTAssertFalse(TheoryItem.sectionSlugOrder("part-10", "part-2"))
        XCTAssertTrue(TheoryItem.sectionSlugOrder("chapter-1/part-9", "chapter-1/part-11"))
    }

    func testDocumentOrderPutsUnorderedLast() {
        let sorted = [
            item("thm-b", order: nil),
            item("thm-a", order: 2001),
            item("def-x", .definition, order: 0),
        ].sorted(by: TheoryItem.documentOrder)
        XCTAssertEqual(sorted.map(\.id), ["def-x", "thm-a", "thm-b"])
    }

    func testDocumentOrderFallsBackToTypeThenID() {
        let sorted = [
            item("thm-z"), item("def-a", .definition), item("thm-a"), item("rem-r", .remark),
        ].sorted(by: TheoryItem.documentOrder)
        XCTAssertEqual(sorted.map(\.id), ["def-a", "thm-a", "thm-z", "rem-r"])
    }

    func testGroupedBySectionOrdersSectionsByMinItemOrder() {
        // part-5 finished importing before part-2; item order must still win.
        let groups = TheoryItem.groupedBySection([
            item("thm-late", section: "part-5", order: 5000),
            item("thm-early", section: "part-2", order: 2000),
            item("def-first", .definition, section: "part-2", order: 2001),
            item("rem-hand-made", .remark, section: "notes"),
            item("thm-loose"),
        ])
        XCTAssertEqual(groups.map(\.section), ["part-2", "part-5", "notes", nil])
        XCTAssertEqual(groups[0].items.map(\.id), ["thm-early", "def-first"])
    }

    func testGroupedBySectionNaturalSlugTiebreakAndFlatCase() {
        let groups = TheoryItem.groupedBySection([
            item("a", section: "part-10"),
            item("b", section: "part-2"),
        ])
        XCTAssertEqual(groups.map(\.section), ["part-2", "part-10"])

        let flat = TheoryItem.groupedBySection([item("a"), item("b")])
        XCTAssertEqual(flat.count, 1)
        XCTAssertNil(flat[0].section)
        XCTAssertEqual(flat[0].items.count, 2)
    }

    func testGroupedBySectionPreservesInputOrderWithinGroup() {
        // Search results arrive rank-ordered; grouping must not re-sort them.
        let groups = TheoryItem.groupedBySection([
            item("thm-second-hit", section: "s", order: 9),
            item("thm-first-hit", section: "s", order: 1),
        ])
        XCTAssertEqual(groups[0].items.map(\.id), ["thm-second-hit", "thm-first-hit"])
    }

    func testOrderFrontmatterRoundTrip() throws {
        let original = item("thm-x", section: "part-1", order: 3007)
        let reparsed = try TheoryItem.parse(markdown: original.serialized())
        XCTAssertEqual(reparsed.order, 3007)

        let unordered = try TheoryItem.parse(markdown: item("thm-y").serialized())
        XCTAssertNil(unordered.order)
        XCTAssertFalse(item("thm-y").serialized().contains("order:"))
    }
}
