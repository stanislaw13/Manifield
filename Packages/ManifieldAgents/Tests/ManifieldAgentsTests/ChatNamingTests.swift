import XCTest
@testable import ManifieldAgents

final class ChatNamingTests: XCTestCase {
    func testSanitizeStripsQuotesAndTrailingPeriod() {
        XCTAssertEqual(ChatNaming.sanitize("\"Prime Time Puzzler.\""), "Prime Time Puzzler")
    }

    func testSanitizeTrimsWhitespaceAndCapsLength() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(ChatNaming.sanitize("  \(long)  ").count, 60)
    }

    func testSanitizeKeepsPlainTitleUnchanged() {
        XCTAssertEqual(ChatNaming.sanitize("Graph Coloring Gambit"), "Graph Coloring Gambit")
    }

    func testSystemPromptIsRegistered() {
        XCTAssertFalse(ChatNaming.systemPrompt.contains("PROMPT TEMPLATE ERROR"))
    }
}
