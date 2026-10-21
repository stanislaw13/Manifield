import XCTest
@testable import ManifieldAgents

/// The Organizer is asked for JSON carrying LaTeX, and the two escape each other
/// differently. A real import of an arXiv paper lost two chunks — 27k characters of
/// theorems and proofs each — to "not a valid JSON array of objects".
final class OrganizerParsingTests: XCTestCase {

    func testUnescapedLaTeXBackslashesAreRepaired() throws {
        // What a model actually sends: `\delta`, `\ge`, `\frac` raw inside a JSON string.
        // `\d` is not a legal JSON escape, so strict parsing rejects the whole array.
        let reply = #"""
        [{"id": "thm-semidegree", "type": "theorem", "name": "Semidegree threshold",
          "statement": "Every $n$-vertex digraph with $\delta^\pm(H) \ge \frac{n}{4}-o(n)$ contains $C_\ell$.",
          "proof": "Apply the stability argument to $\Gamma$ and conclude."}]
        """#
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(reply.utf8)),
                     "the fixture must be the strictly-invalid JSON the model really sends")

        let (items, warnings) = try Organizer.parseProposals(from: reply)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].type, .theorem)
        XCTAssertTrue(items[0].body.contains(#"\delta^\pm(H) \ge \frac{n}{4}"#),
                      "the LaTeX must survive the repair byte for byte")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testValidJSONIsNeverRewritten() throws {
        let valid = #"[{"type":"lemma","name":"L","statement":"$a \\le b$\nnext line, a quote \" and é"}]"#
        XCTAssertFalse(Organizer.hasInvalidEscape(valid),
                       "properly escaped JSON must never enter the repair path")

        let (items, _) = try Organizer.parseProposals(from: valid)
        XCTAssertTrue(items[0].body.contains(#"$a \le b$"#))
        XCTAssertTrue(items[0].body.contains("\nnext line"), "a real newline escape survives")
        XCTAssertTrue(items[0].body.contains("\"") && items[0].body.contains("é"))
    }

    /// Half the LaTeX alphabet collides with JSON's control escapes. Reading `\frac` as a
    /// formfeed parses without complaint and silently corrupts the mathematics — the worst
    /// possible outcome, because nothing reports it.
    func testLaTeXCommandsCollidingWithControlEscapesSurvive() throws {
        let reply = #"""
        [{"type":"theorem","name":"Collisions",
          "statement":"$\frac{a}{b}$, $\nu$, $\tau$, $\times$, $\beta$, $\rho$, $\upsilon$, $\to$"}]
        """#
        let (items, _) = try Organizer.parseProposals(from: reply)
        let body = items[0].body
        for command in [#"\frac{a}{b}"#, #"\nu"#, #"\tau"#, #"\times"#, #"\beta"#, #"\rho"#, #"\upsilon"#, #"\to"#] {
            XCTAssertTrue(body.contains(command), "lost \(command)")
        }
        XCTAssertFalse(body.contains("\u{0C}"), "no formfeed smuggled in by \\frac")
        XCTAssertFalse(body.contains("\t"), "no tab smuggled in by \\times or \\tau")
        XCTAssertFalse(body.contains("\u{08}"), "no backspace smuggled in by \\beta")
    }

    /// A LaTeX display break inside an unescaped reply is two real backslashes.
    func testLaTeXLineBreaksSurviveTheRepair() throws {
        let reply = #"[{"type":"lemma","name":"Align","statement":"\begin{align} a &= b \\ c &= d \end{align}"}]"#
        let (items, _) = try Organizer.parseProposals(from: reply)
        XCTAssertTrue(items[0].body.contains(#"a &= b \\ c &= d"#))
        XCTAssertTrue(items[0].body.contains(#"\begin{align}"#))
    }

    /// The array does not always start at the first `[` in the reply: prose above it can
    /// carry brackets of its own, and a paper full of `[12]`-style citations invites them.
    func testBracketsInProseBeforeTheArrayDoNotDerailTheParser() throws {
        let reply = """
        Here are the items [note: the front matter states no theorems of its own]:

        [{"type": "definition", "name": "Semidegree", "statement": "The minimum of the in- and out-degrees."}]
        """
        let (items, _) = try Organizer.parseProposals(from: reply)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Semidegree")
    }

    func testFencedCodeBlockIsUnwrapped() throws {
        let reply = """
        ```json
        [{"type": "lemma", "name": "Fenced", "statement": "A statement inside a fence."}]
        ```
        """
        let (items, _) = try Organizer.parseProposals(from: reply)
        XCTAssertEqual(items[0].name, "Fenced")
    }

    /// A reply cut off by the output limit used to lose every item in the chunk. The
    /// complete objects before the cut are perfectly good.
    func testTruncatedReplyKeepsTheItemsThatArrived() throws {
        let reply = """
        [{"type": "theorem", "name": "First", "statement": "The first result, complete."},
         {"type": "lemma", "name": "Second", "statement": "The second result, complete."},
         {"type": "lemma", "name": "Third", "statement": "Cut off mid-sent
        """
        let (items, warnings) = try Organizer.parseProposals(from: reply)
        XCTAssertEqual(items.map(\.name), ["First", "Second"])
        XCTAssertTrue(warnings.contains { $0.contains("cut off") }, "the loss must be reported, not hidden")
    }

    func testGenuinelyUnusableRepliesStillThrow() {
        XCTAssertThrowsError(try Organizer.parseProposals(from: "I cannot help with that."))
        XCTAssertThrowsError(try Organizer.parseProposals(from: ""))
    }

    /// The chunk-boundary and summary handling must survive the new parsing path.
    func testSourceChunkParsingKeepsSummaryAndRepairsEscapes() throws {
        let reply = #"""
        [{"id":"lem-walk","type":"lemma","name":"Walk lemma","statement":"If $\delta^0(G) \ge n/3$ then $G$ has a closed walk."},
         {"type":"summary","content":"This section proves the walk lemma for $k \ge 5$."}]
        """#
        let (items, summary, _) = try Organizer.parseSourceChunk(from: reply)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "lem-walk")
        XCTAssertEqual(summary, #"This section proves the walk lemma for $k \ge 5$."#)
    }
}
