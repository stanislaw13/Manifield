import XCTest
@testable import ManifieldCore

final class BlockDiffTests: XCTestCase {

    private func item(status: String = "proof-drafted", body: String) -> String {
        """
        ---
        id: lem-greedy-bound
        type: lemma
        name: Greedy independence bound
        status: \(status)
        depends_on: [def-independent-set]
        tags: []
        ---
        \(body)
        """
    }

    // MARK: - Segmentation

    /// The reason this diff is block-level at all: a display equation must survive as one
    /// piece, or what the reader gets where the change was is two halves of a formula
    /// that no renderer can typeset.
    func testDisplayEquationStaysOneBlock() {
        let blocks = TheoryBlocks.segment(document: item(body: """
        ## Statement

        For every graph $G$,
        $$
        \\alpha(G) \\ge \\frac{n}{\\Delta + 1}
        $$
        with equality for disjoint cliques.
        """))

        let math = blocks.filter { $0.kind == .displayMath }
        XCTAssertEqual(math.count, 1)
        XCTAssertEqual(math[0].text, "$$\n\\alpha(G) \\ge \\frac{n}{\\Delta + 1}\n$$")
        // The prose that surrounds it splits off on either side rather than absorbing it.
        let paragraphs = blocks.filter { $0.kind == .paragraph }.map(\.text)
        XCTAssertEqual(paragraphs, ["For every graph $G$,", "with equality for disjoint cliques."])
    }

    func testSingleLineAndEnvironmentMathAreWholeBlocks() {
        let blocks = TheoryBlocks.segment(document: item(body: """
        $$x^2 + y^2 = z^2$$

        \\begin{align}
        a &= b \\\\
        c &= d
        \\end{align}
        """))

        let math = blocks.filter { $0.kind == .displayMath }.map(\.text)
        XCTAssertEqual(math, [
            "$$x^2 + y^2 = z^2$$",
            "\\begin{align}\na &= b \\\\\nc &= d\n\\end{align}"
        ])
    }

    func testProofStepsSegmentPerListItemAndKeepTheirIndentedMath() {
        let blocks = TheoryBlocks.segment(document: item(body: """
        ## Proof

        1. Order the vertices by degree.
        2. Greedily select, which gives
           $$|S| \\ge \\sum_v \\frac{1}{d(v) + 1}$$
           by a counting argument.
        3. Apply Jensen's inequality.
        """))

        let steps = blocks.filter { $0.kind == .listItem }
        XCTAssertEqual(steps.count, 3)
        // The step's own display math stays inside it — pulling it out would break the list.
        XCTAssertTrue(steps[1].text.contains("$$|S| \\ge"))
        XCTAssertTrue(steps[1].text.hasSuffix("by a counting argument."))
        XCTAssertEqual(blocks.filter { $0.kind == .displayMath }.count, 0)
    }

    func testFencedCodeIsOneBlockAndIsNotReadAsProse() {
        let blocks = TheoryBlocks.segment(document: item(body: """
        ```python
        # not a heading
        x = 1

        y = 2
        ```
        """))

        let code = blocks.filter { $0.kind == .code }
        XCTAssertEqual(code.count, 1)
        XCTAssertTrue(code[0].text.contains("# not a heading"))
        XCTAssertTrue(code[0].text.contains("y = 2"))
        XCTAssertEqual(blocks.filter { $0.kind == .heading }.count, 0)
    }

    func testFrontmatterBecomesOneBlockPerFieldInFileOrder() {
        let blocks = TheoryBlocks.segment(document: item(body: "Body."))
            .filter { $0.kind == .field }
        XCTAssertEqual(blocks.map { $0.label }, ["id", "type", "name", "status", "depends_on", "tags"])
        XCTAssertEqual(blocks.first { $0.label == "status" }?.text, "proof-drafted")
        XCTAssertEqual(blocks.first { $0.label == "depends_on" }?.text, "[def-independent-set]")
    }

    // MARK: - Diff

    func testCreateMarksEveryBlockAdded() {
        let changes = BlockDiff.compare(before: nil, after: item(body: "## Statement\n\nAll new."))
        XCTAssertFalse(changes.isEmpty)
        XCTAssertTrue(changes.allSatisfy { $0.kind == .added })
        XCTAssertTrue(changes.allSatisfy { $0.before == nil })
    }

    func testAFieldChangeShowsAsOneChangedFieldAndNothingElse() {
        let before = item(status: "conjecture", body: "## Statement\n\nSame text.")
        let after = item(status: "proof-drafted", body: "## Statement\n\nSame text.")

        let changes = BlockDiff.compare(before: before, after: after)
        let changed = changes.filter { $0.kind != .unchanged }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].kind, .changed)
        XCTAssertEqual(changed[0].label, "status")
        XCTAssertEqual(changed[0].before?.text, "conjecture")
        XCTAssertEqual(changed[0].after?.text, "proof-drafted")
    }

    func testAnEditedParagraphIsOneChangedBlockNotARemovalAndAnAddition() {
        let before = item(body: "## Proof\n\nThe greedy algorithm selects a vertex of minimum degree.")
        let after = item(body: "## Proof\n\nThe greedy algorithm selects a vertex of minimum degree first.")

        let changed = BlockDiff.compare(before: before, after: after).filter { $0.kind != .unchanged }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].kind, .changed)
        XCTAssertEqual(changed[0].blockKind, .paragraph)
    }

    /// An equation that was corrected must read as one changed equation, so the view can
    /// render the old and the new whole, side by side.
    func testACorrectedEquationIsOneChangedMathBlock() {
        let before = item(body: "$$\\alpha(G) \\ge \\frac{n}{\\Delta}$$")
        let after = item(body: "$$\\alpha(G) \\ge \\frac{n}{\\Delta + 1}$$")

        let changed = BlockDiff.compare(before: before, after: after).filter { $0.kind != .unchanged }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].kind, .changed)
        XCTAssertEqual(changed[0].blockKind, .displayMath)
        XCTAssertEqual(changed[0].after?.text, "$$\\alpha(G) \\ge \\frac{n}{\\Delta + 1}$$")
    }

    func testAnUnrelatedReplacementStaysARemovalAndAnAddition() {
        let before = item(body: "## Proof\n\nBy induction on the number of vertices.")
        let after = item(body: "## Proof\n\nSuppose towards a contradiction that no such colouring exists.")

        let changed = BlockDiff.compare(before: before, after: after).filter { $0.kind != .unchanged }
        XCTAssertEqual(Set(changed.map(\.kind)), [.removed, .added])
    }

    func testAnInsertedStepLeavesTheOthersUnchanged() {
        let before = item(body: """
        1. Order the vertices.
        2. Apply Jensen's inequality.
        """)
        let after = item(body: """
        1. Order the vertices.
        2. Select greedily.
        3. Apply Jensen's inequality.
        """)

        let changes = BlockDiff.compare(before: before, after: after)
        let added = changes.filter { $0.kind == .added }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0].after?.text, "2. Select greedily.")
        // Renumbering means step 2 → 3 is a text change, but step 1 must not move.
        XCTAssertTrue(changes.contains { $0.kind == .unchanged && $0.after?.text == "1. Order the vertices." })
    }

    func testRewrappingAParagraphIsNotAChange() {
        let before = item(body: "## Statement\n\nEvery graph has an independent set of this size.")
        let after = item(body: "## Statement\n\nEvery graph has an independent\nset of this size.")

        XCTAssertTrue(BlockDiff.compare(before: before, after: after).allSatisfy { $0.kind == .unchanged })
    }

    func testIdenticalFilesProduceNoChanges() {
        let document = item(body: "## Statement\n\nStable.\n\n$$e^{i\\pi} + 1 = 0$$")
        XCTAssertTrue(BlockDiff.compare(before: document, after: document).allSatisfy { $0.kind == .unchanged })
    }

    // MARK: - Word level

    func testWordRunsIsolateTheEditAndReassembleLosslessly() {
        let before = "The greedy algorithm selects a vertex of minimum degree."
        let after = "The greedy algorithm selects a vertex of maximum degree."

        let runs = BlockDiff.words(before: before, after: after)
        XCTAssertEqual(runs.before.map(\.text).joined(), before)
        XCTAssertEqual(runs.after.map(\.text).joined(), after)
        XCTAssertEqual(runs.before.filter { $0.kind == .removed }.map { $0.text.trimmingCharacters(in: .whitespaces) },
                       ["minimum"])
        XCTAssertEqual(runs.after.filter { $0.kind == .added }.map { $0.text.trimmingCharacters(in: .whitespaces) },
                       ["maximum"])
    }

    func testWordRunsPreserveIndentationAndTrailingSpace() {
        let before = "   indented tail \n"
        let after = "   indented edit \n"
        let runs = BlockDiff.words(before: before, after: after)
        XCTAssertEqual(runs.before.map(\.text).joined(), before)
        XCTAssertEqual(runs.after.map(\.text).joined(), after)
    }

    func testWordRunsOnIdenticalTextAreAllSame() {
        let runs = BlockDiff.words(before: "no change here", after: "no change here")
        XCTAssertEqual(runs.before.map(\.kind), [.same])
        XCTAssertEqual(runs.after.map(\.kind), [.same])
    }
}
