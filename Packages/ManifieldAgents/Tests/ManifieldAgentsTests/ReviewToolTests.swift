import XCTest
import ManifieldCore
@testable import ManifieldAgents

private struct StubVerifier: ProofVerifier {
    let result: ReviewResult

    func review(
        target: TheoryItem,
        proofMarkdown: String,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> ReviewResult {
        result
    }
}

final class ReviewToolTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-tool-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "RT")
        try store.save(TheoryItem(
            id: "lem-a", type: .lemma, name: "A", status: .proofDrafted,
            body: "## Statement\n$x = x$.\n\n## Proof\nTrivial by reflexivity."))
        try store.save(TheoryItem(
            id: "conj-noproof", type: .conjecture, name: "N", status: .conjecture,
            body: "## Statement\n$P$."))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCleanVerdict() async throws {
        let tool = ReviewTools.reviewProofTool(
            store: store,
            verifier: StubVerifier(result: ReviewResult(verdict: .noErrorsFound, issues: [])))
        let reply = try await tool.execute(inputJSON: #"{"id": "lem-a"}"#)
        XCTAssertTrue(reply.contains("no-errors-found"))
        XCTAssertTrue(reply.contains("evidence, not certainty"))
    }

    func testIssuesAreListed() async throws {
        let tool = ReviewTools.reviewProofTool(
            store: store,
            verifier: StubVerifier(result: ReviewResult(
                verdict: .issues,
                issues: [ReviewIssue(location: "step 2", severity: "fatal",
                                     description: "cites lem-b for more than it states")])))
        let reply = try await tool.execute(inputJSON: #"{"id": "lem-a"}"#)
        XCTAssertTrue(reply.contains("1 issue(s)"))
        XCTAssertTrue(reply.contains("[fatal] step 2"))
        XCTAssertTrue(reply.contains("should not exceed 'proof-drafted'"))
    }

    func testMissingProofIsAnInstructiveError() async {
        let tool = ReviewTools.reviewProofTool(
            store: store,
            verifier: StubVerifier(result: ReviewResult(verdict: .noErrorsFound, issues: [])))
        do {
            _ = try await tool.execute(inputJSON: #"{"id": "conj-noproof"}"#)
            XCTFail("expected error for proof-less item")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no '## Proof'"))
        }
    }
}
