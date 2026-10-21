import XCTest
@testable import ManifieldCore

final class LanguageDetectionTests: XCTestCase {

    private let polishTheorem = """
    ## Twierdzenie
    Niech $X$ będzie przestrzenią topologiczną zwartą i spójną. Wówczas każde ciągłe
    odwzorowanie $f \\colon X \\to \\mathbb{R}$ osiąga swoje kresy, a obraz $f(X)$ jest
    przedziałem domkniętym. Dowód opiera się na pokryciu otwartym przestrzeni $X$ oraz
    na wyborze skończonej podrodziny tego pokrycia.
    """

    private let englishTheorem = """
    ## Statement
    Let $X$ be a compact connected topological space. Then every continuous map
    $f \\colon X \\to \\mathbb{R}$ attains its bounds, and the image $f(X)$ is a closed
    interval. The proof rests on an open cover of the space $X$ and on choosing a finite
    subfamily of that cover.
    """

    func testDetectsPolishMathematicalProse() throws {
        let language = try XCTUnwrap(LanguageDetection.detect(polishTheorem))
        XCTAssertEqual(language.code, "pl")
        XCTAssertEqual(language.name, "Polish")
    }

    func testDetectsEnglishMathematicalProse() throws {
        let language = try XCTUnwrap(LanguageDetection.detect(englishTheorem))
        XCTAssertEqual(language.code, "en")
        XCTAssertEqual(language.name, "English")
    }

    func testSeveralSamplesAreJudgedTogether() throws {
        let language = try XCTUnwrap(LanguageDetection.detect([
            "Lemat 1. Zbiór domknięty i ograniczony w $\\mathbb{R}^n$ jest zwarty.",
            "Wniosek. Każda funkcja ciągła na takim zbiorze jest jednostajnie ciągła."
        ]))
        XCTAssertEqual(language.code, "pl")
    }

    func testFormulaOnlyTextIsUndetermined() {
        XCTAssertNil(LanguageDetection.detect("""
        $$\\int_0^1 f(x)\\,dx = \\sum_{k=1}^n a_k \\qquad (n \\geq 1)$$
        $$\\lim_{n \\to \\infty} x_n = 0$$
        """), "a page of formulas carries no language — better silent than confidently wrong")
    }

    func testTooShortToTell() {
        XCTAssertNil(LanguageDetection.detect("Lemat 3."))
    }

    func testProseStripsMathCodeAndIdentifiers() {
        let stripped = LanguageDetection.prose(from: """
        See `thm-division` at https://example.com/paper.pdf where $f(x) = x^2$ and
        \\begin{align} a &= b \\end{align} appear.
        """)
        XCTAssertFalse(stripped.contains("example.com"))
        XCTAssertFalse(stripped.contains("$"))
        XCTAssertFalse(stripped.contains("begin"))
        XCTAssertFalse(stripped.contains("thm-division"))
        XCTAssertTrue(stripped.contains("appear"))
    }
}
