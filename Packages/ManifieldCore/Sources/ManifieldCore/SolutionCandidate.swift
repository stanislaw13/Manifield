import Foundation

/// A branch's claim that specific durable results completely answer the user's question.
///
/// A claim is not a settlement. The branch that did the work is the last context that should
/// judge whether the work answers the question — it has spent its whole run believing its own
/// route, and "we reached the target" is exactly the assertion a research agent is most likely
/// to make too early. So a claim creates a *candidate*, and two independent passes decide:
/// contract adjudication (does this answer the question that was asked?) and review (is the
/// mathematics right, and does it actually assemble?).
///
/// Contract adjudication runs first and is cheap. Only a candidate that would answer the right
/// question if its mathematics held is worth pausing a branch and paying for review.
public struct SolutionCandidate: Codable, Equatable, Sendable, Identifiable {

    public enum Status: String, Codable, CaseIterable, Sendable {
        /// Filed by the branch, nothing checked yet.
        case filed
        /// Contract adjudication in flight.
        case contractChecking
        /// It does not answer the question as asked. The branch resumes with the reason.
        case contractRejected
        /// Contract-complete; the mathematics is being reviewed and the branch is paused.
        case underReview
        /// The mathematics or the assembly did not hold. The branch resumes with the reason.
        case reviewRejected
        /// Both passes cleared it. Only the director may act on this.
        case accepted

        public var displayName: String {
            switch self {
            case .filed: return "Filed"
            case .contractChecking: return "Checking against contract"
            case .contractRejected: return "Does not answer the question"
            case .underReview: return "Under review"
            case .reviewRejected: return "Review found errors"
            case .accepted: return "Accepted"
            }
        }

        /// Terminal for this candidate — the branch is free to carry on.
        public var isRejected: Bool { self == .contractRejected || self == .reviewRejected }

        /// The branch is parked while this runs.
        public var pausesBranch: Bool { self == .underReview }
    }

    /// Does the cited result, assuming its mathematics is correct, answer the question?
    public struct ContractRuling: Codable, Equatable, Sendable {
        public var accepted: Bool
        public var note: String
        /// Which complete-answer forms the adjudicator judges are satisfied. Its own finding —
        /// deliberately not an echo of `claimedCompletionIDs`, since one result can span
        /// several forms and a claimant can name the wrong one while still being right.
        public var satisfiedCompletionIDs: [String]

        public init(accepted: Bool, note: String, satisfiedCompletionIDs: [String] = []) {
            self.accepted = accepted
            self.note = note
            self.satisfiedCompletionIDs = satisfiedCompletionIDs
        }
    }

    /// Is the mathematics right, and does the assembled argument close?
    public struct ReviewRuling: Codable, Equatable, Sendable {
        public var accepted: Bool
        public var note: String
        /// Items whose own review ran or was reused for this candidate.
        public var itemsReviewed: [String]
        /// The assembly reviewer's verdict on the combination. Always populated: item reviews
        /// certify the parts and say nothing about whether they fit together.
        public var assemblyNote: String

        public init(accepted: Bool, note: String, itemsReviewed: [String] = [],
                    assemblyNote: String = "") {
            self.accepted = accepted
            self.note = note
            self.itemsReviewed = itemsReviewed
            self.assemblyNote = assemblyNote
        }
    }

    /// Hard cap on the claimant's argument — an explanation, not a paper.
    public static let maxArgumentLength = 1500

    public var id: String
    /// Plan id of the branch that filed it.
    public var branchPlanID: String
    /// The immutable request revision this candidate claims to answer.
    public var targetRevisionID: String?
    /// The result being claimed.
    public var primaryItemID: String
    /// Everything else the claim rests on that is not reachable through `primaryItemID`.
    public var supportingItemIDs: [String]
    /// Which complete-answer forms the claimant believes it satisfies. Optional and
    /// non-binding: a claimant may name none, or name the wrong ones and still be right.
    public var claimedCompletionIDs: [String]?
    /// Why this completely answers the user's question, in ordinary mathematical language.
    public var argument: String
    /// Item id → content hash at claim time. A review is reusable only against this snapshot;
    /// an item edited afterwards invalidates the review that was done on it.
    public var itemSnapshots: [String: String]
    public var contractRuling: ContractRuling?
    public var reviewRuling: ReviewRuling?
    public var status: Status
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                branchPlanID: String,
                targetRevisionID: String? = nil,
                primaryItemID: String,
                supportingItemIDs: [String] = [],
                claimedCompletionIDs: [String]? = nil,
                argument: String,
                itemSnapshots: [String: String] = [:],
                contractRuling: ContractRuling? = nil,
                reviewRuling: ReviewRuling? = nil,
                status: Status = .filed,
                createdAt: Date = Date()) {
        self.id = id
        self.branchPlanID = branchPlanID
        self.targetRevisionID = targetRevisionID
        self.primaryItemID = primaryItemID
        self.supportingItemIDs = supportingItemIDs
        self.claimedCompletionIDs = claimedCompletionIDs
        self.argument = String(argument.prefix(Self.maxArgumentLength))
        self.itemSnapshots = itemSnapshots
        self.contractRuling = contractRuling
        self.reviewRuling = reviewRuling
        self.status = status
        self.createdAt = createdAt
    }

    /// Every item the claim rests on directly, primary first.
    public var citedItemIDs: [String] {
        [primaryItemID] + supportingItemIDs.filter { $0 != primaryItemID }
    }

    /// What the completion is recorded as satisfying — the adjudicator's finding where one
    /// exists, the claimant's guess only until then.
    public var effectiveCompletionIDs: [String] {
        contractRuling?.satisfiedCompletionIDs ?? claimedCompletionIDs ?? []
    }
}

/// Who gets told about a published finding.
///
/// Findings used to cross to every sibling automatically. That is right when a finding is a
/// hard fact everyone needs and wrong when it is route-specific progress: a proof branch's
/// promising intermediate lemma injected into a refutation branch does not help it refute, it
/// pulls it toward the proof. Broadcasting collapses a portfolio of deliberately contradictory
/// approaches back into one line of thought, which is the failure the portfolio exists to
/// prevent. So the director — the one context that sees every branch's route and none of their
/// transcripts — decides recipients per finding.
public struct FindingRouting: Codable, Equatable, Sendable, Identifiable {

    public enum Decision: String, Codable, CaseIterable, Sendable {
        /// Relevant to how a named branch should act now.
        case sendNow = "send_now"
        /// Real, but immature or independence-sensitive. Kept for a later decision.
        case hold
        /// Branch-local, distracting or unrelated. Stays searchable, never injected.
        case doNotSend = "do_not_send"
        /// Every branch must have it: a statement correction, a fatal shared obstruction,
        /// a settled target.
        case global

        public var displayName: String {
            switch self {
            case .sendNow: return "Send now"
            case .hold: return "Hold"
            case .doNotSend: return "Do not send"
            case .global: return "Global"
            }
        }

        /// Whether this decision puts the finding into any branch's active context.
        public var circulates: Bool { self == .sendNow || self == .global }
    }

    public var findingID: String
    public var decision: Decision
    /// Recipients for `sendNow`. Ignored for every other decision — `global` reaches all
    /// branches but the originator, and the other two reach none.
    public var recipientPlanIDs: [String]
    public var rationale: String
    public var decidedAt: Date

    public var id: String { findingID }

    public init(findingID: String, decision: Decision, recipientPlanIDs: [String] = [],
                rationale: String = "", decidedAt: Date = Date()) {
        self.findingID = findingID
        self.decision = decision
        self.recipientPlanIDs = recipientPlanIDs
        self.rationale = rationale
        self.decidedAt = decidedAt
    }

    /// Whether this routing puts the finding in front of `planID`.
    public func reaches(_ planID: String) -> Bool {
        switch decision {
        case .global: return true
        case .sendNow: return recipientPlanIDs.contains(planID)
        case .hold, .doNotSend: return false
        }
    }
}
