import Foundation
import ManifieldCore

/// Where a program stands, computed from durable state.
///
/// Deliberately a **projection, not a summary**: every field here is derived from the manifest,
/// the plans and the run records. A generated summary is an extra call that drifts from what
/// actually happened; a projection cannot drift, because there is nothing to drift from. The
/// only model-written strings it carries are ones some other turn already produced — the
/// director's status line, a route's mechanism — never a narration written for this view.
public struct ProgramStatus: Equatable, Sendable {

    /// One form of complete answer the contract admits, and where any claim on it stands.
    ///
    /// Not a progress scale. The contract's entries are alternatives — any one of them settles
    /// the problem — so there is no "current" one and nothing is partially reached. A form is
    /// either claimed, accepted, or neither.
    public struct CompletionLine: Equatable, Sendable, Identifiable {
        public var id: String
        public var statement: String
        /// How a claim of this form is checked.
        public var evidence: String
        /// A candidate has been filed against this form and is still in play.
        public var claimed: Bool
        /// A candidate for this form passed contract adjudication and review.
        public var accepted: Bool
    }

    /// One route with what it cost.
    public struct RouteLine: Equatable, Sendable, Identifiable {
        public var id: String
        public var mechanism: String
        public var status: ResearchRoute.Status
        public var obstruction: String?
        public var nextTest: String?
        public var generation: Int
        public var tokensSpent: Int
        /// Findings this route's branch published. With `tokensSpent`, this is cost per
        /// finding — a better question than cost per answer, and the live diagnostic for a
        /// route that is burning budget without learning anything.
        public var findings: Int
    }

    public var goal: String
    /// The director's last status line, when there has been one.
    public var headline: String?
    public var completions: [CompletionLine]
    /// Candidates filed against the contract, newest last. Carries the rejected ones too —
    /// a claim that did not survive is part of what the program learned.
    public var solutions: [SolutionCandidate]
    public var routes: [RouteLine]
    public var generation: Int
    public var tokensSpent: Int
    public var tokensBudget: Int
    /// Claims being leaned on that are not themselves established.
    public var openObligations: [ProofObligation]
    /// True when the contract has never been approved by a human — a verdict against it has
    /// to say so rather than quietly inherit the authority of one that was.
    public var contractUnreviewed: Bool

    public var tokensRemaining: Int { max(0, tokensBudget - tokensSpent) }

    public static func make(
        program: ResearchProgram,
        records: [String: RunRecord],
        items: [TheoryItem],
        programRecord: ProgramRunRecord? = nil,
        tokensSpent authoritativeTokensSpent: Int? = nil
    ) -> ProgramStatus {
        // A form counts as claimed or accepted only through a candidate's *effective* ids —
        // the adjudicator's finding where it ruled, the claimant's guess only until then.
        var claimedIDs = Set<String>()
        var acceptedIDs = Set<String>()
        for candidate in program.solutions {
            let ids = candidate.effectiveCompletionIDs.map { $0.lowercased() }
            if candidate.status == .accepted {
                acceptedIDs.formUnion(ids)
            } else if !candidate.status.isRejected {
                claimedIDs.formUnion(ids)
            }
        }
        let completions = (program.contract?.completeAnswers ?? []).map { answer in
            CompletionLine(
                id: answer.id,
                statement: answer.statement,
                evidence: answer.evidence,
                claimed: claimedIDs.contains(answer.id.lowercased()),
                accepted: acceptedIDs.contains(answer.id.lowercased()))
        }

        let findingsByBranch = Dictionary(grouping: program.findings.filter { !$0.isRejected },
                                          by: \.branchPlanID)
        let routes = (program.routes ?? []).map { route in
            RouteLine(
                id: route.id,
                mechanism: route.mechanism,
                status: route.status,
                obstruction: route.obstruction,
                nextTest: route.nextTest,
                generation: route.generation,
                tokensSpent: route.planID.flatMap { records[$0]?.tokensUsed } ?? 0,
                findings: route.planID.flatMap { findingsByBranch[$0]?.count } ?? 0)
        }.sorted { ($0.generation, $0.mechanism) < ($1.generation, $1.mechanism) }

        return ProgramStatus(
            goal: program.researchRequest,
            headline: programRecord?.lastStatus,
            completions: completions,
            solutions: program.solutions,
            routes: routes,
            generation: programRecord?.generation ?? 1,
            tokensSpent: authoritativeTokensSpent ?? (program.planningTokensUsed
                + records.values.reduce(0) { $0 + $1.tokensUsed }),
            tokensBudget: program.programTokenBudget,
            openObligations: ProofObligations.open(items: items),
            contractUnreviewed: program.contract.map { !$0.isReviewed } ?? false)
    }

    /// The three-second read: where the program stands, in one paragraph.
    public var oneLiner: String {
        var parts: [String] = []
        if let answered = completions.first(where: \.accepted) {
            parts.append("Answered — \(answered.statement)")
        } else if solutions.contains(where: { !$0.status.isRejected }) {
            parts.append("A solution candidate is being checked")
        } else if !completions.isEmpty {
            parts.append("No complete answer yet")
        }
        let dead = routes.filter { $0.status == .falsified }.count
        let live = routes.filter { !$0.status.isClosed }.count
        parts.append("\(live) route(s) live, \(dead) ruled out")
        if generation > 1 { parts.append("generation \(generation)") }
        if !openObligations.isEmpty {
            parts.append("\(openObligations.count) open obligation(s)")
        }
        return parts.joined(separator: " — ")
    }
}
