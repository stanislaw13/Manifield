import Foundation

/// The formal statement a research program is bound to.
///
/// New programs use this as a statement-only research target: the user's verbatim request lives
/// on `ResearchProgram.goal`, while `statement` makes its quantifiers, objects and conventions
/// explicit. The older completion-form fields remain decodable so existing projects keep their
/// provenance, but new drafting deliberately leaves them empty. Predicting proof methods or
/// enumerating acceptable answer shapes before the research starts proved more likely to raise
/// the bar above the user's question than to prevent drift.
public struct SuccessContract: Codable, Equatable, Sendable {

    /// One form in which the user's question would be completely answered.
    ///
    /// Deliberately **not** classified. An earlier design graded progress on a per-goal-kind
    /// ladder; the obvious repair — a positive/negative axis — is the same mistake one layer
    /// down. A classification, an exact-value problem, a hybrid existence-and-optimisation
    /// question, a conditional problem, and an algorithm with a matching impossibility result
    /// do not divide into one affirmative and one negative case. The drafter lists whichever
    /// forms actually apply and argues in `completenessRationale` that the list is exhaustive.
    public struct CompleteAnswer: Codable, Equatable, Sendable, Identifiable {
        /// Short stable label a solution claim can cite: `A1`, `A2`, …
        public var id: String
        /// What would have to be established for the question to be completely answered
        /// this way, in the problem's own mathematical language.
        public var statement: String
        /// How a claim of this form is checked — the exhaustive computation, the verified
        /// witness, the review of a proof. "How would anyone know" is the discipline here.
        public var evidence: String

        public init(id: String, statement: String, evidence: String) {
            self.id = id
            self.statement = statement
            self.evidence = evidence
        }
    }

    /// Legacy defaults retained for decoding and displaying older contracts. New targets do not
    /// copy these into the statement; the reviewer's standing rules carry the corresponding
    /// correctness checks without forbidding an otherwise decisive exact computation or citation.
    public static let standardExclusions = [
        "numerical evidence without a finite-reduction theorem",
        "an argument under unstated stronger assumptions",
        "an equivalent formulation whose equivalence is not proved or sourced",
        "a citation whose hypotheses were not checked",
        "a reduction to another unresolved claim",
        "a novelty claim based on not finding prior work"
    ]

    /// Exact statement, quantifiers and conventions, as normalized before the run.
    public var statement: String
    /// Legacy: every form a complete answer could take. New targets leave this empty.
    public var completeAnswers: [CompleteAnswer]
    /// Legacy rationale for `completeAnswers`. New targets leave this empty.
    ///
    /// Required, and the single guard against the failure this whole type exists to prevent:
    /// a drafter that mirrors the imperative grammar of the request ("find a number with
    /// property P") admits only the answer that grammar suggests, so a branch that correctly
    /// proves no such number exists has to report itself as a failure. Making the drafter
    /// *argue* exhaustiveness applies equally to binary, multi-case, conditional,
    /// classification and hybrid problems — which a fixed two-sided check does not.
    public var completenessRationale: String
    /// Legacy problem-specific exclusions. New targets leave this empty and reviewer prompts
    /// apply general evidence rules directly.
    public var notCounted: [String]
    /// Reading adopted by the goal formalizer when the statement admitted materially different
    /// interpretations. Empty when the request was unambiguous.
    public var recommendedReading: String
    /// Readings the statement audit found materially different. Carried so a later disagreement
    /// about what was asked has something to point at.
    public var ambiguities: [String]
    /// Bumped on every revision. Results are attributed to the version they were achieved
    /// against, so "we clarified the statement after the pilots" cannot quietly weaken a goal.
    public var version: Int
    /// When a human approved it. Nil means the run is proceeding against an unreviewed
    /// contract, which a verdict must say out loud rather than silently inherit.
    public var reviewedAt: Date?

    public init(statement: String,
                completeAnswers: [CompleteAnswer] = [],
                completenessRationale: String = "",
                notCounted: [String] = [],
                recommendedReading: String = "",
                ambiguities: [String] = [],
                version: Int = 1,
                reviewedAt: Date? = nil) {
        self.statement = statement
        self.completeAnswers = completeAnswers
        self.completenessRationale = completenessRationale
        self.notCounted = notCounted
        self.recommendedReading = recommendedReading
        self.ambiguities = ambiguities
        self.version = version
        self.reviewedAt = reviewedAt
    }

    /// Lenient decode: contracts written under the ladder model still load, minus the ladder.
    /// A converter was deliberately not written — a half-migrated contract, with a target rung
    /// promoted to a "complete answer" and no completeness argument behind it, is more
    /// misleading than an absent one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statement = try c.decodeIfPresent(String.self, forKey: .statement) ?? ""
        completeAnswers = try c.decodeIfPresent([CompleteAnswer].self, forKey: .completeAnswers) ?? []
        completenessRationale =
            try c.decodeIfPresent(String.self, forKey: .completenessRationale) ?? ""
        notCounted = try c.decodeIfPresent([String].self, forKey: .notCounted) ?? []
        recommendedReading = try c.decodeIfPresent(String.self, forKey: .recommendedReading) ?? ""
        ambiguities = try c.decodeIfPresent([String].self, forKey: .ambiguities) ?? []
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        reviewedAt = try c.decodeIfPresent(Date.self, forKey: .reviewedAt)
    }

    public var isReviewed: Bool { reviewedAt != nil }

    public func answer(id: String) -> CompleteAnswer? {
        completeAnswers.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Answer ids, for tool schemas and error messages.
    public var citableAnswerIDs: [String] { completeAnswers.map(\.id) }

    /// Shape problems a human (or the drafting tool) should fix before the run starts. Kept as
    /// a list rather than a throw: the drafting flow wants to show all of them at once.
    public var validationProblems: [String] {
        var problems: [String] = []
        if statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("the contract has no statement")
        }
        // Completion forms are legacy metadata, not a requirement on new statement-only targets.
        // When an old contract does carry them, retain the shape checks that make them readable.
        let ids = completeAnswers.map { $0.id.lowercased() }
        if Set(ids).count != ids.count {
            problems.append("complete-answer ids must be unique")
        }
        if completeAnswers.contains(where: { $0.id.trimmingCharacters(in: .whitespaces).isEmpty }) {
            problems.append("every complete answer needs a short id such as 'A1'")
        }
        if completeAnswers.contains(where: {
            $0.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            problems.append("every complete answer needs a statement")
        }
        if completeAnswers.contains(where: {
            $0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            problems.append("every complete answer must say how a claim of that form is checked")
        }
        if !completeAnswers.isEmpty,
           completenessRationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("legacy complete-answer forms need a completeness rationale")
        }
        return problems
    }
}
