import Foundation
import ManifieldCore

/// Chat-triggered proof review: one fresh-context reviewer pass over an item's proof.
/// The verdict comes back to the chat model as JSON, and it decides how to present
/// the findings (and whether to propose a status change).
public enum ReviewTools {

    public static func reviewProofTool(
        store: ProjectStore,
        verifier: ProofVerifier,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) -> AgentTool {
        ReviewProofTool(store: store, verifier: verifier, onActivity: onActivity)
    }
}

struct ReviewProofTool: AgentTool {
    let store: ProjectStore
    let verifier: ProofVerifier
    let onActivity: @Sendable (AgentActivity) -> Void

    var spec: ToolSpec {
        ToolSpec(
            name: "review_proof",
            description: "Run a skeptical fresh-context review over one item's proof (a separate reviewer model checks every step and citation). Use when a proof's correctness actually matters — a central lemma, a user request, a proof you just helped draft — not for routine algebra. Returns the reviewer's verdict; present the findings honestly and propose a status change if warranted.",
            inputSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Item id whose '## Proof' section should be reviewed"}},"required":["id"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let id = jsonObject(inputJSON)["id"] as? String ?? ""
        guard let item = store.item(id: id) else { throw CoreError.itemNotFound(id) }
        guard let proof = item.proof, !proof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResearchError(message: "'\(id)' has no '## Proof' section to review")
        }
        let review = try await verifier.review(target: item, proofMarkdown: proof, onActivity: onActivity)
        switch review.verdict {
        case .noErrorsFound:
            return """
            {"verdict": "no-errors-found"}
            Reviewer found no errors in '\(id)'. Remember: evidence, not certainty — \
            the item may honestly carry status 'reviewed-no-errors'.
            """
        case .issues:
            let issues = review.issues
                .map { "- [\($0.severity)] \($0.location): \($0.description)" }
                .joined(separator: "\n")
            return """
            Reviewer found \(review.issues.count) issue(s) in '\(id)':
            \(issues)
            Present these honestly; if any is fatal, the proof's status should not \
            exceed 'proof-drafted'.
            """
        }
    }
}
