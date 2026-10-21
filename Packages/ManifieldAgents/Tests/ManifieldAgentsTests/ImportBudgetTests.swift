import XCTest
@testable import ManifieldAgents

final class ImportBudgetTests: XCTestCase {

    func testContextWindowLookupPrefersTheLongestMatchingFamily() {
        XCTAssertEqual(ModelContextWindow.tokens(for: "gpt-5.6-luna", kind: .openai), 400_000)
        XCTAssertEqual(ModelContextWindow.tokens(for: "gpt-4o-mini", kind: .openai), 128_000)
        XCTAssertEqual(ModelContextWindow.tokens(for: "claude-opus-4-8", kind: .anthropic), 200_000)
        XCTAssertEqual(ModelContextWindow.tokens(for: "gemini-2.5-pro", kind: .gemini), 1_000_000)
        XCTAssertEqual(ModelContextWindow.tokens(for: "glm-4.5-air", kind: .zai), 128_000,
                       "the more specific glm-4.5 entry wins over glm-")
    }

    func testUnknownModelFallsBackToItsProvidersFloor() {
        XCTAssertEqual(ModelContextWindow.tokens(for: "claude-something-new", kind: .anthropic), 200_000)
        XCTAssertEqual(ModelContextWindow.tokens(for: "mystery-model", kind: .nvidia),
                       ModelContextWindow.fallbackTokens)
    }

    /// A big-context model is limited by what it can write back, not by what it can read:
    /// the Organizer re-emits most of a chunk as JSON items, so a chunk it cannot restate
    /// inside one reply is useless however comfortably it fits the window.
    func testLargeContextModelIsLimitedByReplyCapacityNotWindow() {
        let budget = ImportBudget(
            model: "gpt-5.6-luna", contextWindowTokens: 400_000,
            maxOutputTokens: 16_384, promptOverheadCharacters: 12_000)
        XCTAssertFalse(budget.limitedByContextWindow)
        XCTAssertEqual(ImportBudget.tokens(inCharacters: budget.maxChunkCharacters),
                       Int(16_384 * ImportBudget.replyShare), accuracy: 2)
        // The failing import sent ~250k tokens in one chunk; the budget for the same
        // model now tops out two orders of magnitude below that.
        XCTAssertLessThan(budget.maxChunkCharacters, 60_000)
    }

    /// The user's stated rule — at most 75% of the window, prompts and reply included —
    /// binds on models whose window is small.
    func testSmallContextModelIsLimitedByTheWindowShare() {
        let budget = ImportBudget(
            model: "tiny", contextWindowTokens: 32_000,
            maxOutputTokens: 16_384, promptOverheadCharacters: 7_000)
        XCTAssertTrue(budget.limitedByContextWindow)
        // 75% of 32k = 24k, less 16,384 of reply and 2k of prompt → ~5.6k of source text.
        let chunkTokens = ImportBudget.tokens(inCharacters: budget.maxChunkCharacters)
        XCTAssertEqual(chunkTokens, 5_616, accuracy: 200)

        let total = chunkTokens + budget.promptOverheadTokens + budget.maxOutputTokens
        XCTAssertLessThanOrEqual(
            Double(total), Double(budget.contextWindowTokens) * ImportBudget.contextShare + 1,
            "a request must stay inside the share the budget promises")
    }

    func testBudgetNeverCollapsesBelowTheUsableFloor() {
        let budget = ImportBudget(
            model: "cramped", contextWindowTokens: 8_000,
            maxOutputTokens: 4_000, promptOverheadCharacters: 8_000)
        XCTAssertGreaterThanOrEqual(
            ImportBudget.tokens(inCharacters: budget.maxChunkCharacters),
            ImportBudget.minChunkTokens - 1)
    }
}

final class ImportRetryClassificationTests: XCTestCase {

    /// The 429 from the report — a per-minute limit lower than the request — is not a
    /// wait-and-retry error: the same request fails identically a minute later.
    func testRequestTooLargeIsNotRetriedButIsSubdivided() {
        let body = """
        {"error": {"message": "Request too large for gpt-5.6-luna in organization org-3q on \
        tokens per min (TPM): Limit 200000, Requested 266020.", "code": "rate_limit_exceeded"}}
        """
        let error = AgentError.http(429, body)
        XCTAssertNil(SourceImportRunner.retryDelay(for: error, attempt: 0))
        XCTAssertTrue(SourceImportRunner.isOversizeRejection(error))
    }

    func testOrdinaryRateLimitsAndOverloadsAreRetriedWithBackoff() {
        let rateLimited = AgentError.http(429, #"{"error":{"message":"Rate limit reached"}}"#)
        XCTAssertEqual(SourceImportRunner.retryDelay(for: rateLimited, attempt: 0), 5)
        XCTAssertEqual(SourceImportRunner.retryDelay(for: rateLimited, attempt: 2), 40)
        XCTAssertFalse(SourceImportRunner.isOversizeRejection(rateLimited))

        XCTAssertNotNil(SourceImportRunner.retryDelay(for: .http(503, "overloaded"), attempt: 0))
        XCTAssertNil(SourceImportRunner.retryDelay(for: .http(401, "bad key"), attempt: 0),
                     "an auth failure must not be waited out three times")
    }

    func testOversizeFailureExplainsItselfInTheChunkMessage() {
        let chunk = SourceImport.Chunk(title: "Part 2", section: "part-2", text: "x")
        let message = SourceImportRunner.describe(
            AgentError.http(429, "Request too large ... TPM"), chunk: chunk)
        XCTAssertTrue(message.contains("Part 2"))
        XCTAssertTrue(message.contains("per-minute token limit"))
    }
}
