import XCTest
@testable import ManifieldCore

final class LibraryChangeTests: XCTestCase {

    private func item(_ id: String, _ name: String, _ status: ItemStatus,
                      type: ItemType = .lemma) -> TheoryItem {
        TheoryItem(id: id, type: type, name: name, status: status, body: "## Statement\n$x$.")
    }

    func testDetectsCreationsStatusChangesAndRemovals() {
        let before = LibrarySnapshot(items: [
            item("lem-a", "A", .conjecture),
            item("lem-b", "B", .proofDrafted),
            item("lem-gone", "Gone", .tested)
        ])
        let after = LibrarySnapshot(items: [
            item("lem-a", "A", .tested),
            item("lem-b", "B", .proofDrafted),
            item("lem-new", "New", .conjecture)
        ])

        let changes = before.changes(to: after)
        XCTAssertEqual(Set(changes.map(\.itemID)), ["lem-a", "lem-new", "lem-gone"],
                       "an unchanged item produces no entry")

        let created = changes.first { $0.itemID == "lem-new" }
        XCTAssertEqual(created?.kind, .created)
        XCTAssertEqual(created?.toStatus, .conjecture)
        XCTAssertNil(created?.fromStatus)

        let moved = changes.first { $0.itemID == "lem-a" }
        XCTAssertEqual(moved?.kind, .statusChanged)
        XCTAssertEqual(moved?.fromStatus, .conjecture)
        XCTAssertEqual(moved?.toStatus, .tested)

        let removed = changes.first { $0.itemID == "lem-gone" }
        XCTAssertEqual(removed?.kind, .removed)
        XCTAssertEqual(removed?.fromStatus, .tested)
        XCTAssertNil(removed?.toStatus)
    }

    func testNoChangesBetweenIdenticalSnapshots() {
        let snapshot = LibrarySnapshot(items: [item("lem-a", "A", .tested)])
        XCTAssertTrue(snapshot.changes(to: snapshot).isEmpty)
    }

    /// A downgrade usually means a counterexample or a failed review landed — it is the
    /// line the mathematician most needs to see, so it sorts first.
    func testDowngradesAreFlaggedAndSortFirst() {
        let before = LibrarySnapshot(items: [
            item("lem-a", "A", .conjecture),
            item("thm-b", "B", .reviewedNoErrors)
        ])
        let after = LibrarySnapshot(items: [
            item("lem-a", "A", .proofDrafted),
            item("thm-b", "B", .conjecture),
            item("lem-c", "C", .conjecture)
        ])

        let changes = before.changes(to: after)
        XCTAssertEqual(changes.first?.itemID, "thm-b")
        XCTAssertTrue(changes.first?.isDowngrade ?? false)
        XCTAssertFalse(changes.first(where: { $0.itemID == "lem-a" })?.isDowngrade ?? true,
                       "an upgrade is not a downgrade")
        XCTAssertFalse(changes.first(where: { $0.itemID == "lem-c" })?.isDowngrade ?? true,
                       "a new item has nothing to be downgraded from")
    }

    func testChangeOrderIsStable() {
        let before = LibrarySnapshot(items: [])
        let after = LibrarySnapshot(items: [
            item("lem-z", "Z", .conjecture),
            item("lem-a", "A", .conjecture)
        ])
        XCTAssertEqual(before.changes(to: after).map(\.itemID), ["lem-a", "lem-z"])
    }

    func testChangesRoundTripThroughJSON() throws {
        let changes = LibrarySnapshot(items: [item("lem-a", "A", .conjecture)])
            .changes(to: LibrarySnapshot(items: [item("lem-a", "A", .humanApproved)]))
        let data = try JSONEncoder().encode(changes)
        XCTAssertEqual(try JSONDecoder().decode([LibraryChange].self, from: data), changes)
    }
}
