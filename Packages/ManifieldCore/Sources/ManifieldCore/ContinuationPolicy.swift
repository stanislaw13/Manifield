import Foundation

/// How much a program is allowed to carry on without a human.
///
/// Every pause in the runner is a button today, which is why one question at 2am costs a whole
/// night. This is the dial that turns those buttons into policy. A counterexample claim is the
/// dangerous one — wrong, it silently corrupts every branch that builds on it — so unattended
/// runs replace the human gate with a fresh-context adjudication: the claim is independently
/// verified before it is allowed to circulate, and the director decides what stops.
public struct ContinuationPolicy: Codable, Equatable, Sendable {

    /// What an unattended run may do about a question only the user could answer.
    public enum QuestionHandling: String, Codable, CaseIterable, Sendable {
        /// Every question stops the branch. The behaviour before this type existed.
        case alwaysPause = "always_pause"
        /// Task-level questions proceed under a stated, journalled assumption; questions about
        /// the problem statement or the success contract still stop the run. An assumption at
        /// contract level poisons everything downstream, which is the one documented failure
        /// this split exists to prevent.
        case assumeTaskLevel = "assume_task_level"
        /// Every question proceeds under an assumption. Fastest, and the least safe.
        case assumeAll = "assume_all"

        public var displayName: String {
            switch self {
            case .alwaysPause: return "Always ask me"
            case .assumeTaskLevel: return "Proceed on task questions, ask on the statement"
            case .assumeAll: return "Always proceed under an assumption"
            }
        }
    }

    /// Continue past a checkpoint without waiting.
    public var autoContinueCheckpoints: Bool
    /// Raise a branch's budget by this many tokens when it runs out, while the program ceiling
    /// allows. Zero disables it.
    public var budgetStepTokens: Int
    /// How many times a branch may be topped up before it stops for a human regardless.
    public var maxBudgetRaises: Int
    public var questionHandling: QuestionHandling
    /// Wall-clock ceiling for the whole program. Tokens alone do not bound a run that is
    /// waiting on slow tools. Zero means no limit.
    public var maxWallClockSeconds: TimeInterval
    /// Verify a claimed counterexample with a fresh-context adjudication turn instead of
    /// pausing for the human. A rejected claim never circulates; a confirmed one hands the
    /// stop-which-branches decision to the director. Off, the claim pauses the program — the
    /// behaviour every manifest written before this field existed keeps.
    public var autoAdjudicateCounterexamples: Bool

    /// Everything off: existing programs behave exactly as they did.
    public static let manual = ContinuationPolicy(
        autoContinueCheckpoints: false, budgetStepTokens: 0, maxBudgetRaises: 0,
        questionHandling: .alwaysPause, maxWallClockSeconds: 0)

    /// The recommended unattended setting — level 2 of the supervision dial: it runs the night.
    /// A counterexample is adjudicated in fresh context and routed to the director; only a
    /// question about the statement itself still stops the run.
    public static let overnight = ContinuationPolicy(
        autoContinueCheckpoints: true, budgetStepTokens: 0, maxBudgetRaises: 0,
        questionHandling: .assumeTaskLevel, maxWallClockSeconds: 12 * 3600,
        autoAdjudicateCounterexamples: true)

    /// Level 3: nothing stops the run but its budgets. Statement-level questions proceed under
    /// a journalled assumption — tolerable only because the success contract was drafted from
    /// pilots and frozen before the run, which is where statement ambiguity is meant to die.
    public static let fullAuto = ContinuationPolicy(
        autoContinueCheckpoints: true, budgetStepTokens: 0, maxBudgetRaises: 0,
        questionHandling: .assumeAll, maxWallClockSeconds: 24 * 3600,
        autoAdjudicateCounterexamples: true)

    public init(autoContinueCheckpoints: Bool = false, budgetStepTokens: Int = 0,
                maxBudgetRaises: Int = 0,
                questionHandling: QuestionHandling = .alwaysPause,
                maxWallClockSeconds: TimeInterval = 0,
                autoAdjudicateCounterexamples: Bool = false) {
        self.autoContinueCheckpoints = autoContinueCheckpoints
        self.budgetStepTokens = max(0, budgetStepTokens)
        self.maxBudgetRaises = max(0, maxBudgetRaises)
        self.questionHandling = questionHandling
        self.maxWallClockSeconds = max(0, maxWallClockSeconds)
        self.autoAdjudicateCounterexamples = autoAdjudicateCounterexamples
    }

    // Decoded by hand so fields added after manifests were written read as their defaults
    // instead of failing the whole program file. `maxGenerations` is read by no case here any
    // more — an old manifest's value for it is simply not looked at, the ordinary behaviour
    // for any JSON key a decoder has no case for.
    private enum CodingKeys: String, CodingKey {
        case autoContinueCheckpoints, budgetStepTokens, maxBudgetRaises, questionHandling,
             maxWallClockSeconds, autoAdjudicateCounterexamples
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            autoContinueCheckpoints: try c.decodeIfPresent(Bool.self, forKey: .autoContinueCheckpoints) ?? false,
            budgetStepTokens: try c.decodeIfPresent(Int.self, forKey: .budgetStepTokens) ?? 0,
            maxBudgetRaises: try c.decodeIfPresent(Int.self, forKey: .maxBudgetRaises) ?? 0,
            questionHandling: try c.decodeIfPresent(QuestionHandling.self, forKey: .questionHandling) ?? .alwaysPause,
            maxWallClockSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .maxWallClockSeconds) ?? 0,
            autoAdjudicateCounterexamples: try c.decodeIfPresent(Bool.self, forKey: .autoAdjudicateCounterexamples) ?? false)
    }

    public var isUnattended: Bool {
        autoContinueCheckpoints || budgetStepTokens > 0 || questionHandling != .alwaysPause
    }

    /// True when the run has been going longer than the policy allows.
    public func hasExceededWallClock(since start: Date, now: Date = Date()) -> Bool {
        maxWallClockSeconds > 0 && now.timeIntervalSince(start) >= maxWallClockSeconds
    }
}

/// What a branch is allowed to assume rather than ask about.
public enum QuestionScope: String, Codable, CaseIterable, Sendable {
    /// About how to do the current task — a parameter, a convention, which of two routes to try.
    /// Safe to assume: the assumption is journalled and the work is re-checkable against it.
    case task
    /// About what is being asked, or what would count as an answer. Never assumed: getting this
    /// wrong invalidates everything built afterwards, and it is the documented failure of
    /// Erdős #728, where the model answered a different question than the one intended.
    case statement

    public var displayName: String {
        switch self {
        case .task: return "About this task"
        case .statement: return "About the problem or what counts as an answer"
        }
    }
}
