import Foundation
import ManifieldCore

/// Two fresh-context gates for a challenge to the fixed goal Statement.
///
/// The first checks the alleged mathematical defect. The second is a scope/necessity check:
/// even a true observation does not license changing a valid request merely because another
/// question would be easier or more natural. Neither pass sees the branch transcript.
public enum ProblemChallengeReviewer {

    public static func review(
        challenge: ProblemChallenge,
        target: ResearchTargetRevision,
        items: [TheoryItem],
        tools: [AgentTool],
        runner: AgentRunner,
        thinking: ThinkingLevel = .off,
        programID: String = "",
        record: RecordTurn? = nil,
        onProgress: (@Sendable (ProblemChallenge) async throws -> Void)? = nil,
        onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }
    ) async throws -> ProblemChallenge {
        var challenge = challenge
        let resumesAcceptedMathematicalGate = challenge.status == .scopeReview
            && challenge.mathematicalRuling?.accepted == true
            && challenge.scopeRuling == nil

        if !resumesAcceptedMathematicalGate {
            // Only `.scopeReview` is a durable handoff between the independent gates. Any
            // other invocation is a fresh review, including a corrected target snapshot.
            challenge.mathematicalRuling = nil
            challenge.scopeRuling = nil
            challenge.status = .mathematicalReview
            try await onProgress?(challenge)
            let mathematical = try await runGate(
                runner: runner,
                role: .challengeMathReview,
                title: "Problem challenge — mathematical review",
                system: mathematicalSystem(target: target),
                message: challengeMessage(challenge, items: items),
                tools: tools,
                thinking: thinking,
                programID: programID,
                record: record,
                onActivity: onActivity)
            challenge.mathematicalRuling = mathematical
            guard mathematical.accepted else {
                challenge.status = .mathematicalRejected
                try await onProgress?(challenge)
                return challenge
            }

            challenge.status = .scopeReview
            try await onProgress?(challenge)
        }

        guard let mathematical = challenge.mathematicalRuling else {
            throw ResearchError(message: "problem challenge scope review has no accepted mathematical ruling")
        }
        let scope = try await runGate(
            runner: runner,
            role: .challengeScopeReview,
            title: "Problem challenge — scope necessity review",
            system: scopeSystem(target: target, mathematicalNote: mathematical.note),
            message: challengeMessage(challenge, items: items),
            tools: tools,
            thinking: thinking,
            programID: programID,
            record: record,
            onActivity: onActivity)
        challenge.scopeRuling = scope
        challenge.status = scope.accepted ? .accepted : .scopeRejected
        try await onProgress?(challenge)
        return challenge
    }

    public static func mathematicalSystem(target: ResearchTargetRevision) -> String {
        """
        You are the fresh-context mathematical reviewer of a challenge to a fixed research-goal
        Statement. You are not reviewing whether the branch made progress and you are not being
        asked to find a nicer problem.

        Check the concrete defect described by the challenger against the exact frozen goal item
        and the filed evidence snapshots embedded in the message. Those filed bytes are
        authoritative for this review; a later live-library edit cannot repair the challenge.
        Accept only if the alleged defect is mathematically sound
        and genuinely prevents the request from being solved as written. Difficulty, cost,
        missing literature, an inconvenient formulation, or failure of the branch's preferred
        method are not defects in the request.

        Do not assume every request is a true/false thesis. “Classify all groups”, construction,
        computation and open-ended requests can be defective without asserting a proposition,
        and can also be perfectly valid despite lacking a thesis. Describe the issue in its own
        mathematical terms; do not force it into a fixed taxonomy. Report exactly one ruling
        with `report_problem_challenge_review`.

        \(ContextAssembly.pinnedTargetSection(target))

        \(ContextAssembly.researchTargetSection(originalRequest: target.requestText, contract: nil))
        """
    }

    public static func scopeSystem(
        target: ResearchTargetRevision,
        mathematicalNote: String
    ) -> String {
        """
        You are the fresh-context scope and necessity reviewer of a challenge to a fixed
        research-goal Statement. A separate mathematical pass accepted the alleged defect:

        \(mathematicalNote)

        Decide whether the challenge actually requires changing the user's request. Accept
        only when the request is impossible as written and any proposed replacement is the
        smallest correction forced by that defect. Reject a change that merely makes the work
        easier, fits the branch's method, reduces cost, narrows an ambitious but valid request,
        broadens a precise request, or swaps in a nearby known theorem. A challenge may be valid
        without proposing a corrected request; the director can preserve unaffected parts and
        decide what needs replanning. Report exactly one ruling with
        `report_problem_challenge_review`.

        In the scope ruling set target_disposition: fullInvalidity only if this disposes of the
        whole fixed goal with no unaffected obligations and no unresolved intended convention;
        partialInvalidity when valid parts remain; needsClarification when an interpretation or
        convention must be settled by the user. Explain the remaining scope in the note. An empty
        set or a non-onto map is not automatically a defect if the source's conventions exclude it.

        \(ContextAssembly.pinnedTargetSection(target))

        \(ContextAssembly.researchTargetSection(originalRequest: target.requestText, contract: nil))
        """
    }

    private static func challengeMessage(
        _ challenge: ProblemChallenge,
        items: [TheoryItem]
    ) -> String {
        var sections = [
            "Challenge id: `\(challenge.id)`",
            "Filed by branch: `\(challenge.branchPlanID)`",
            "Challenge (freeform):\n\(challenge.description)"
        ]
        if let replacement = challenge.proposedReplacementRequest {
            sections.append("Proposed corrected request:\n\(replacement)")
        } else {
            sections.append("No replacement request was proposed.")
        }
        if let itemID = challenge.proposedTargetItemID {
            var proposed = "Proposed corrected target item: `\(itemID)`"
            if let type = challenge.proposedTargetItemType {
                proposed += " [\(type.rawValue)]"
            }
            if let data = challenge.proposedTargetItemData,
               let markdown = String(data: data, encoding: .utf8) {
                let digest = challenge.proposedTargetItemSHA256
                    ?? ResearchTargetRevision.sha256(data)
                proposed += "\nFiled SHA-256: `\(digest)`\n\n" + String(markdown.prefix(8_000))
            } else {
                proposed += "\nNo pinned corrected-item bytes were filed."
            }
            sections.append(proposed)
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let evidence = challenge.evidenceItemIDs.compactMap { id -> String? in
            if let raw = challenge.evidenceItemData?[id],
               let markdown = String(data: raw, encoding: .utf8) {
                let digest = challenge.evidenceItemSnapshots[id]
                    ?? ResearchTargetRevision.sha256(raw)
                return """
                ### `\(id)` [filed snapshot, SHA-256 `\(digest)`]
                \(markdown.prefix(8_000))
                """
            }
            guard let item = byID[id] else { return "- `\(id)` — MISSING" }
            return """
            ### `\(id)` [live fallback; \(item.type.rawValue), \(item.status.rawValue)] \(item.name)
            \(item.body.prefix(8_000))
            """
        }
        sections.append(evidence.isEmpty
            ? "No durable evidence items were cited."
            : "Cited evidence:\n\n" + evidence.joined(separator: "\n\n"))
        return sections.joined(separator: "\n\n")
    }

    private static func runGate(
        runner: AgentRunner,
        role: AgentTurnRecord.Role,
        title: String,
        system: String,
        message: String,
        tools: [AgentTool],
        thinking: ThinkingLevel,
        programID: String,
        record: RecordTurn?,
        onActivity: @escaping @Sendable (AgentActivity) -> Void
    ) async throws -> ProblemChallenge.ReviewRuling {
        let signals = ProblemChallengeReviewSignals()
        let config = AgentConfig(
            systemPrompt: SystemPrompt(system),
            tools: tools + [ReportProblemChallengeReviewTool(signals: signals)],
            maxIterations: 8,
            thinking: thinking)
        _ = try await runRecordedTurn(
            runner: runner, config: config, history: [.user(message)],
            programID: programID, role: role, title: title, record: record,
            outcome: { _ in
                signals.ruling.map {
                    "\($0.accepted ? "accepted" : "rejected") — \($0.note.prefix(180))"
                } ?? "no ruling"
            },
            onActivity: onActivity)
        guard let ruling = signals.ruling else {
            throw ResearchError(message: "problem challenge review ended without a ruling")
        }
        return ruling
    }
}

private final class ProblemChallengeReviewSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var _ruling: ProblemChallenge.ReviewRuling?
    var ruling: ProblemChallenge.ReviewRuling? {
        lock.lock(); defer { lock.unlock() }; return _ruling
    }
    func set(_ ruling: ProblemChallenge.ReviewRuling) {
        lock.lock(); _ruling = ruling; lock.unlock()
    }
}

private struct ReportProblemChallengeReviewTool: AgentTool {
    var turnEffect: AgentToolEffect { .finish }
    let signals: ProblemChallengeReviewSignals

    var spec: ToolSpec {
        ToolSpec(
            name: "report_problem_challenge_review",
            description: "Report this independent gate's ruling. The note must identify the concrete evidence and criterion used.",
            inputSchemaJSON: #"{"type":"object","properties":{"accepted":{"type":"boolean"},"note":{"type":"string"},"target_disposition":{"type":"string","enum":["fullInvalidity","partialInvalidity","needsClarification"]}},"required":["accepted","note"]}"#)
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let accepted = input["accepted"] as? Bool else {
            throw ResearchError(message: "missing 'accepted'")
        }
        guard let note = (input["note"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            throw ResearchError(message: "missing 'note' — cite the concrete evidence and criterion")
        }
        signals.set(.init(accepted: accepted, note: String(note.prefix(2_000)),
            targetDisposition: (input["target_disposition"] as? String).flatMap(ProblemChallenge.ReviewRuling.TargetDisposition.init(rawValue:))))
        return "Ruling recorded. End your turn."
    }
}
