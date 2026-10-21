import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class LinkPassTests: XCTestCase {

    private func makeStore() throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkpass-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "Source")
        try store.save(TheoryItem(id: "def-ring", type: .definition, name: "Ring",
                                  section: "ch-1", order: 0, body: "## Statement\nA ring."))
        try store.save(TheoryItem(id: "thm-main", type: .theorem, name: "Main",
                                  dependsOn: ["def-ring"],
                                  section: "ch-2", order: 1000, body: "## Statement\nBig."))
        try store.save(TheoryItem(id: "cor-easy", type: .corollary, name: "Easy",
                                  section: "ch-2", order: 1001, body: "## Statement\nFollows."))
        return store
    }

    func testParseToleratesFenceAndSkipsEmptyAdds() throws {
        let response = """
        ```json
        [{"id": "cor-easy", "add_depends_on": ["thm-main"]},
         {"id": "thm-main", "add_depends_on": []}]
        ```
        """
        let edits = try LinkPass.parse(response)
        XCTAssertEqual(edits, [LinkPass.Edit(itemID: "cor-easy", addDependsOn: ["thm-main"])])
        XCTAssertThrowsError(try LinkPass.parse("no array"))
    }

    func testApplyValidatesEdges() throws {
        let store = try makeStore()
        let (added, warnings) = LinkPass.apply([
            .init(itemID: "cor-easy", addDependsOn: ["thm-main", "def-ring"]),
            .init(itemID: "thm-main", addDependsOn: ["thm-main"]),        // self
            .init(itemID: "thm-main", addDependsOn: ["def-ring"]),        // duplicate
            .init(itemID: "thm-main", addDependsOn: ["lem-ghost"]),       // unknown target
            .init(itemID: "lem-nowhere", addDependsOn: ["def-ring"]),     // unknown item
        ], store: store)

        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.item(id: "cor-easy")?.dependsOn, ["thm-main", "def-ring"])
        XCTAssertEqual(store.item(id: "thm-main")?.dependsOn, ["def-ring"], "dupe not re-added")
        XCTAssertEqual(warnings.count, 3)
    }

    func testApplyRevertsCycleCreatingEdge() throws {
        let store = try makeStore()
        // thm-main already depends on def-ring; def-ring → thm-main closes a cycle.
        let (added, warnings) = LinkPass.apply(
            [.init(itemID: "def-ring", addDependsOn: ["thm-main"])], store: store)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(store.item(id: "def-ring")?.dependsOn, [])
        XCTAssertTrue(warnings.contains { $0.contains("cycle") })
    }

    func testBatchesFollowDocumentOrder() throws {
        let items = (0..<60).map { (i: Int) in
            TheoryItem(id: "thm-\(i)", type: .theorem, name: "T\(i)",
                       section: "s", order: i)
        }
        let batches = LinkPass.batches(items: items.shuffled(), maxBatch: 25)
        XCTAssertEqual(batches.map(\.count), [25, 25, 10])
        XCTAssertEqual(batches[0].first?.id, "thm-0")
        XCTAssertEqual(batches[2].last?.id, "thm-59")
    }

    func testEstimateCountsCallsAndTokens() {
        let items = (0..<30).map {
            TheoryItem(id: "thm-\($0)", type: .theorem, name: "T\($0)",
                       body: "## Statement\n" + String(repeating: "x", count: 400))
        }
        let estimate = LinkPass.estimate(items: items)
        XCTAssertEqual(estimate.calls, 2)
        XCTAssertGreaterThan(estimate.approxInputTokens, 1_000)
    }
}
