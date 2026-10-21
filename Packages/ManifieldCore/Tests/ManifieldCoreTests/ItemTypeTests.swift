import XCTest
@testable import ManifieldCore

final class ItemTypeTests: XCTestCase {

    func testIDPrefixesAreUnique() {
        let prefixes = ItemType.allCases.map(\.idPrefix)
        XCTAssertEqual(Set(prefixes).count, prefixes.count,
                       "duplicate id prefixes: \(prefixes.sorted())")
    }

    func testRawValuesAreUnique() {
        let raws = ItemType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    /// The original five raw values must never change — existing project files use them.
    func testLegacyRawValuesUnchanged() {
        XCTAssertEqual(ItemType(rawValue: "definition"), .definition)
        XCTAssertEqual(ItemType(rawValue: "lemma"), .lemma)
        XCTAssertEqual(ItemType(rawValue: "theorem"), .theorem)
        XCTAssertEqual(ItemType(rawValue: "conjecture"), .conjecture)
        XCTAssertEqual(ItemType(rawValue: "remark"), .remark)
    }

    func testBestMatchExactAndFormatting() {
        XCTAssertEqual(ItemType.bestMatch("proposition")?.type, .proposition)
        XCTAssertEqual(ItemType.bestMatch("proposition")?.exact, true)
        // Formatting-only differences still count as exact.
        XCTAssertEqual(ItemType.bestMatch("Main Theorem")?.type, .mainTheorem)
        XCTAssertEqual(ItemType.bestMatch("Main Theorem")?.exact, true)
        XCTAssertEqual(ItemType.bestMatch("open_problem")?.type, .openProblem)
        XCTAssertEqual(ItemType.bestMatch("open_problem")?.exact, true)
    }

    func testBestMatchAliases() {
        XCTAssertEqual(ItemType.bestMatch("open question")?.type, .openProblem)
        XCTAssertEqual(ItemType.bestMatch("open question")?.exact, false)
        XCTAssertEqual(ItemType.bestMatch("Notation")?.type, .definition)
        XCTAssertEqual(ItemType.bestMatch("assumption")?.type, .hypothesis)
        XCTAssertEqual(ItemType.bestMatch("prop")?.type, .proposition)
    }

    func testBestMatchSubstringFallbackPrefersLongestType() {
        // "main-theorem" must win over its substring "theorem".
        XCTAssertEqual(ItemType.bestMatch("the main theorems")?.type, .mainTheorem)
        XCTAssertEqual(ItemType.bestMatch("sublemma")?.type, .lemma)
        XCTAssertEqual(ItemType.bestMatch("key-theorem")?.type, .theorem)
    }

    func testBestMatchUnknownReturnsNil() {
        XCTAssertNil(ItemType.bestMatch("porism"))
        XCTAssertNil(ItemType.bestMatch(""))
    }

    /// `sortRank` is a position in `allCases` and it decides display order, so a new type
    /// has to be appended. Inserting one anywhere else silently renumbers every type after it.
    func testNewTypesAreAppended() {
        XCTAssertEqual(ItemType.allCases.last, .figure)
        XCTAssertEqual(ItemType.definition.sortRank, 0)
        XCTAssertEqual(ItemType.exercise.sortRank, ItemType.figure.sortRank - 1)
    }

    func testFamiliesAndDefaults() {
        XCTAssertEqual(ItemType.mainTheorem.shapeFamily, .mainResult)
        XCTAssertEqual(ItemType.example.shapeFamily, .meta)
        XCTAssertTrue(ItemType.openProblem.isOpenLike)
        XCTAssertTrue(ItemType.hypothesis.isOpenLike)
        XCTAssertFalse(ItemType.theorem.isOpenLike)
        XCTAssertTrue(ItemType.inequality.isProvable)
        XCTAssertFalse(ItemType.definition.isProvable)
        XCTAssertFalse(ItemType.example.isProvable)
    }

    func testDisplayAndPluralNames() {
        XCTAssertEqual(ItemType.mainTheorem.displayName, "Main Theorem")
        XCTAssertEqual(ItemType.openProblem.pluralName, "Open Problems")
        XCTAssertEqual(ItemType.corollary.pluralName, "Corollaries")
        XCTAssertEqual(ItemType.hypothesis.pluralName, "Hypotheses")
        XCTAssertEqual(ItemType.inequality.pluralName, "Inequalities")
    }

    /// New-type items round-trip through frontmatter, and open-like types default
    /// to conjecture status when the file has no status field.
    func testNewTypeFrontmatterRoundTrip() throws {
        let item = TheoryItem(
            id: "prop-density", type: .proposition, name: "Density bound",
            status: .source, body: "## Statement\nDense."
        )
        let reparsed = try TheoryItem.parse(markdown: item.serialized())
        XCTAssertEqual(reparsed.type, .proposition)
        XCTAssertEqual(reparsed.status, .source)

        let openDoc = """
        ---
        id: oprob-riemann
        type: open-problem
        name: Riemann
        ---
        ## Statement
        All zeros.
        """
        let open = try TheoryItem.parse(markdown: openDoc)
        XCTAssertEqual(open.type, .openProblem)
        XCTAssertEqual(open.status, .conjecture)
    }
}
