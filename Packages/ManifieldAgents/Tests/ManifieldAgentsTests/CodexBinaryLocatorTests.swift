import XCTest
@testable import ManifieldAgents

final class CodexBinaryLocatorTests: XCTestCase {

    func testOverrideIsCheckedFirstWhenPresent() {
        let locator = CodexBinaryLocator(
            isExecutable: { $0 == "/custom/codex" }, homeDirectory: "/Users/test", pathEnvironment: nil)
        XCTAssertEqual(locator.locate(override: "/custom/codex"), "/custom/codex")
    }

    func testEmptyOverrideIsIgnored() {
        let locator = CodexBinaryLocator(
            isExecutable: { $0 == "/Applications/ChatGPT.app/Contents/Resources/codex" },
            homeDirectory: "/Users/test", pathEnvironment: nil)
        XCTAssertEqual(locator.locate(override: ""), "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    func testFallsBackThroughTheSearchOrderToTheBundledApp() {
        let locator = CodexBinaryLocator(
            isExecutable: { $0 == "/Applications/ChatGPT.app/Contents/Resources/codex" },
            homeDirectory: "/Users/test", pathEnvironment: nil)
        XCTAssertEqual(locator.locate(), "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    func testFallsBackToHomeDirectoryCandidates() {
        let locator = CodexBinaryLocator(
            isExecutable: { $0 == "/Users/test/.codex/bin/codex" },
            homeDirectory: "/Users/test", pathEnvironment: nil)
        XCTAssertEqual(locator.locate(), "/Users/test/.codex/bin/codex")
    }

    func testPATHIsCheckedLastAfterEveryOtherCandidate() {
        let locator = CodexBinaryLocator(
            isExecutable: { $0 == "/some/custom/dir/codex" },
            homeDirectory: "/Users/test", pathEnvironment: "/some/custom/dir:/another/dir")
        XCTAssertEqual(locator.locate(), "/some/custom/dir/codex")
        // Confirm ordering: every non-PATH candidate is tried before any PATH entry.
        let candidates = locator.candidates(override: nil)
        let pathIndex = try! XCTUnwrap(candidates.firstIndex(of: "/some/custom/dir/codex"))
        XCTAssertGreaterThan(pathIndex, 5, "PATH candidates must come after the fixed search list")
    }

    func testReturnsNilWhenNothingIsExecutable() {
        let locator = CodexBinaryLocator(isExecutable: { _ in false }, homeDirectory: "/Users/test", pathEnvironment: nil)
        XCTAssertNil(locator.locate(override: "/custom/codex"))
    }

    func testNoFilesystemAccessHappensDuringCandidateEnumeration() {
        // Enumerating candidates must not itself touch disk — only `locate` probes, one path at
        // a time, via the injected closure.
        var probed: [String] = []
        let locator = CodexBinaryLocator(
            isExecutable: { probed.append($0); return false }, homeDirectory: "/Users/test", pathEnvironment: nil)
        _ = locator.candidates(override: "/x")
        XCTAssertTrue(probed.isEmpty)
    }

    func testFindsCodexInNewerChatGPTCodexCliFolder() {
        let path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let locator = CodexBinaryLocator(isExecutable: { $0 == path }, homeDirectory: "/Users/x", pathEnvironment: nil)
        XCTAssertEqual(locator.locate(), path)
    }
}
