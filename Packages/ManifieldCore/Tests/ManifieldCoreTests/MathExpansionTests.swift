import XCTest
@testable import ManifieldCore

final class MathExpansionTests: XCTestCase {

    func testExpandsZeroArgMacrosWithBoundaries() {
        let macros = ["\\A": "\\mathcal{A}", "\\Ab": "\\mathbf{A}"]
        XCTAssertEqual(MathExpansion.expand("\\A + \\Ab", macros: macros),
                       "\\mathcal{A} + \\mathbf{A}")
        // \A must not fire inside \Alpha.
        XCTAssertEqual(MathExpansion.expand("\\Alpha", macros: macros), "\\Alpha")
        XCTAssertEqual(MathExpansion.expand("\\A{x}", macros: macros), "\\mathcal{A}{x}")
    }

    func testLeavesArgumentMacrosAlone() {
        let macros = ["\\norm": "\\left\\lVert #1 \\right\\rVert"]
        XCTAssertEqual(MathExpansion.expand("\\norm{x}", macros: macros), "\\norm{x}")
    }

    func testNestedExpansionAndCycleGuard() {
        XCTAssertEqual(
            MathExpansion.expand("\\B", macros: ["\\B": "\\A^2", "\\A": "\\mathcal{A}"]),
            "\\mathcal{A}^2")
        // A self-referential macro must terminate at the depth limit.
        let cyclic = MathExpansion.expand("\\loop", macros: ["\\loop": "\\loop x"], maxDepth: 4)
        XCTAssertTrue(cyclic.hasPrefix("\\loop"))
        XCTAssertTrue(cyclic.count < 100)
    }
}
