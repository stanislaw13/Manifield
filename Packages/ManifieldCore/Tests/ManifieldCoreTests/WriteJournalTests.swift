import XCTest
@testable import ManifieldCore

final class WriteJournalTests: XCTestCase {

    private func write(
        turn: UUID,
        id: String,
        action: TheoryWrite.Action,
        before: String? = nil,
        type: ItemType = .lemma
    ) -> TheoryWrite {
        TheoryWrite(
            turnID: turn, itemID: id, itemName: id, itemType: type,
            action: action, before: before, after: "after-\(id)")
    }

    func testWritesGroupIntoTurnsNewestFirst() {
        let t1 = UUID(), t2 = UUID()
        var journal = WriteJournal()
        journal.record(write(turn: t1, id: "a", action: .create))
        journal.record(write(turn: t1, id: "b", action: .create))
        journal.record(write(turn: t2, id: "c", action: .update, before: "old-c"))

        let turns = journal.turns
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].turnID, t2)                       // newest first
        XCTAssertEqual(turns[1].writes.map(\.itemID), ["a", "b"]) // in-turn order preserved
    }

    /// A revert must undo newest-first, so an item written twice in one turn lands back
    /// on the state it had before the turn began — not on its mid-turn value.
    func testRevertPlanIsNewestFirstAndRestoresOldestState() {
        let turn = UUID()
        var journal = WriteJournal()
        journal.record(write(turn: turn, id: "x", action: .create))
        journal.record(write(turn: turn, id: "x", action: .update, before: "after-x"))

        let plan = journal.revertPlan(turnID: turn)
        XCTAssertEqual(plan.count, 2)
        // Newest write undone first: restore its `before`…
        XCTAssertEqual(plan[0], .restore(itemID: "x", markdown: "after-x"))
        // …then the create is undone by deleting, leaving nothing behind.
        XCTAssertEqual(plan[1], .delete(itemID: "x"))
    }

    func testCreatesAreRevertedByDeletion() {
        let turn = UUID()
        var journal = WriteJournal()
        journal.record(write(turn: turn, id: "new", action: .create))
        XCTAssertEqual(journal.revertPlan(turnID: turn), [.delete(itemID: "new")])
    }

    func testForgettingATurnStopsItBeingRevertedTwice() {
        let turn = UUID()
        var journal = WriteJournal()
        journal.record(write(turn: turn, id: "a", action: .create))
        journal.forget(turnID: turn)
        XCTAssertTrue(journal.revertPlan(turnID: turn).isEmpty)
        XCTAssertTrue(journal.turns.isEmpty)
    }

    func testJournalIsCappedAndDropsOldestFirst() {
        var journal = WriteJournal()
        for i in 0...(WriteJournal.maxWrites + 10) {
            journal.record(write(turn: UUID(), id: "item-\(i)", action: .create))
        }
        XCTAssertEqual(journal.writes.count, WriteJournal.maxWrites)
        XCTAssertEqual(journal.writes.first?.itemID, "item-11")
    }

    func testSummaryBreaksDownByTypeWhenFewKinds() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "d1", action: .create, type: .definition),
            write(turn: turn, id: "d2", action: .create, type: .definition),
            write(turn: turn, id: "t1", action: .create, type: .theorem)
        ]
        XCTAssertEqual(WriteJournal.summary(for: writes), "Created 2 definitions and 1 theorem")
    }

    func testSummaryFallsBackToItemCountWhenManyKinds() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "a", action: .create, type: .definition),
            write(turn: turn, id: "b", action: .create, type: .theorem),
            write(turn: turn, id: "c", action: .create, type: .lemma)
        ]
        XCTAssertEqual(WriteJournal.summary(for: writes), "Created 3 theory items")
    }

    func testSummarySeparatesCreatesFromEdits() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "a", action: .create, type: .lemma),
            write(turn: turn, id: "b", action: .update, before: "old", type: .lemma)
        ]
        XCTAssertEqual(WriteJournal.summary(for: writes), "Created 1 lemma · Edited 1 lemma")
    }

    /// The revert button deletes files. Its confirmation has to say so, in items rather
    /// than in writes — two writes to one item are still one file to put back.
    func testRevertPhraseCountsItemsNotWrites() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "a", action: .create),
            write(turn: turn, id: "b", action: .update, before: "old-b"),
            write(turn: turn, id: "b", action: .update, before: "mid-b")
        ]
        XCTAssertEqual(WriteJournal.revertPhrase(for: writes),
                       "delete 1 new item and restore 1 item to its previous contents")
        XCTAssertEqual(WriteJournal.revertedLabel(for: writes), "Reverted — 1 deleted, 1 restored")
    }

    /// An item created and then edited in the same turn is put back by deleting it, so it
    /// must not also be counted among the items that get restored.
    func testAnItemCreatedThenEditedCountsOnlyAsADeletion() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "x", action: .create),
            write(turn: turn, id: "x", action: .update, before: "after-x")
        ]
        XCTAssertEqual(WriteJournal.revertPhrase(for: writes), "delete 1 new item")
        XCTAssertEqual(WriteJournal.revertedLabel(for: writes), "Reverted — 1 deleted")
    }

    func testRevertPhrasePluralisesEditsOnly() {
        let turn = UUID()
        let writes = [
            write(turn: turn, id: "a", action: .update, before: "old-a"),
            write(turn: turn, id: "b", action: .update, before: "old-b")
        ]
        XCTAssertEqual(WriteJournal.revertPhrase(for: writes),
                       "restore 2 items to their previous contents")
    }

    func testRoundTripsThroughJSON() throws {
        let turn = UUID()
        var journal = WriteJournal()
        journal.record(write(turn: turn, id: "a", action: .update, before: "old-a"))
        let data = try JSONEncoder().encode(journal)
        let decoded = try JSONDecoder().decode(WriteJournal.self, from: data)
        XCTAssertEqual(decoded.writes, journal.writes)
    }
}
