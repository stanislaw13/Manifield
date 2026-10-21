import Foundation

// `GoalKind` and `BranchStance` used to live here. They classified every goal as decide /
// determine / construct and every branch as one of seven stances derived from that kind, and
// the classification was load-bearing: it picked the success contract's ladder shape, gated
// which finding kinds a branch could publish, and ordered the queue. It was also wrong often
// enough to matter — a classification, a hybrid existence-and-optimisation question, an
// algorithm with a matching lower bound, or a conditional problem fits none of the three, and
// forcing one on it made every branch answer a question nobody asked.
//
// What the taxonomy was really for survives directly. "A portfolio must contain something
// attacking the leading answer" is now `Branch.challengesLeadingAnswer`, enforced on the
// activated slice of a proposal. Attack order is no longer derived from a stance either:
// whichever agent authored the generation ranks it, and `Branch.priority` carries the ranking.

/// Rough execution cost of a branch, as the planner estimated it. A hint and a display field:
/// it no longer orders the queue, because the agent that authored the generation ranks the
/// branches itself and knows more than a three-way cost bucket does.
public enum CostClass: String, Codable, CaseIterable, Sendable, Identifiable {
    case cheap
    case standard
    case expensive

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    public var order: Int {
        switch self {
        case .cheap: return 0
        case .standard: return 1
        case .expensive: return 2
        }
    }
}

/// A typed hard result one branch publishes for its siblings. Branches are deliberately
/// isolated — their reasoning never crosses, because shared reasoning is what collapses
/// a portfolio back into one line of thought. Only facts cross, and only through this type.
public struct ProgramFinding: Codable, Equatable, Identifiable, Sendable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A concrete counterexample. Pauses the program for the user to decide.
        case counterexample
        /// A proposed answer to a determination or construction goal — the value or object
        /// itself, with how it was reached. Siblings need it: an adversary branch cannot
        /// attack a candidate it has not been told.
        case candidateAnswer = "candidate_answer"
        /// A target was proved (review found no errors) or definitively failed.
        case proofOutcome = "proof_outcome"
        /// A structural reason an approach cannot work.
        case obstruction
        /// The problem was reduced to (or shown equivalent to) another one.
        case reduction
        /// Decisive computational or empirical evidence.
        case evidence
        /// The branch abandoned its lens — the prior lost to the evidence, with why.
        case lensAbandoned = "lens_abandoned"

        public var displayName: String {
            switch self {
            case .counterexample: return "Counterexample"
            case .candidateAnswer: return "Candidate answer"
            case .proofOutcome: return "Proof outcome"
            case .obstruction: return "Obstruction"
            case .reduction: return "Reduction"
            case .evidence: return "Evidence"
            case .lensAbandoned: return "Lens abandoned"
            }
        }
    }

    /// A ruling on a finding — the user's, or the fresh-context adjudicator's on an
    /// unattended run (`verdictNote` says which). A branch's claim is evidence, not
    /// truth — and a wrong one that keeps circulating corrupts every sibling that
    /// builds on it.
    public enum Verdict: String, Codable, CaseIterable, Sendable {
        /// Reviewed and believed — siblings see it marked as confirmed.
        case confirmed
        /// Wrong or not established — withheld from siblings entirely.
        case rejected
    }

    /// Hard cap on a finding's statement — findings are facts, not essays.
    public static let maxStatementLength = 600

    public var id: String
    /// Plan id of the branch that published it.
    public var branchPlanID: String
    /// The immutable request revision under which this fact was established.
    public var targetRevisionID: String?
    public var kind: Kind
    public var statement: String
    /// Theory item ids the finding concerns.
    public var itemIDs: [String]
    /// Project-relative path of supporting evidence, e.g. `artifacts/<run>/stdout.txt`.
    public var artifactPath: String?
    public var createdAt: Date
    /// The user's ruling; nil means unreviewed (and in manifests written before verdicts
    /// existed). Unreviewed findings still cross — the default is to trust the branch.
    public var verdict: Verdict?
    /// Why it was confirmed or rejected — shown to siblings when it is a confirmation.
    public var verdictNote: String?

    public var isRejected: Bool { verdict == .rejected }
    public var isConfirmed: Bool { verdict == .confirmed }
    /// Trust state, spelled out: a finding is provisional exactly when it has crossed (it is
    /// not rejected) but nothing has independently checked it. Circulates by default — the
    /// point of naming this explicitly is that a recipient is told so, not that the finding
    /// is held back until reviewed.
    public var isProvisional: Bool { verdict == nil }

    public init(id: String = UUID().uuidString, branchPlanID: String,
                targetRevisionID: String? = nil, kind: Kind,
                statement: String, itemIDs: [String] = [], artifactPath: String? = nil,
                createdAt: Date = Date(), verdict: Verdict? = nil, verdictNote: String? = nil) {
        self.id = id
        self.branchPlanID = branchPlanID
        self.targetRevisionID = targetRevisionID
        self.kind = kind
        self.statement = String(statement.prefix(Self.maxStatementLength))
        self.itemIDs = itemIDs
        self.artifactPath = artifactPath
        self.createdAt = createdAt
        self.verdict = verdict
        self.verdictNote = verdictNote
    }
}

/// A portfolio of research branches attacking one goal from deliberately contradictory
/// priors. Stored as `programs/<id>.json`; each branch is an ordinary `PlanDocument`
/// under `plans/`, so every existing plan mechanism (tasks, run records, budgets)
/// applies to a branch unchanged.
public struct ResearchProgram: Codable, Equatable, Identifiable, Sendable {

    public enum Status: String, Codable, CaseIterable, Sendable {
        case active, paused, done, abandoned
        /// Every approach was tried and none worked — a verdict, not a shrug. Kept apart
        /// from `abandoned` (dropped without deciding) because the archive is read to
        /// learn what has already been ruled out.
        case failed

        public var displayName: String {
            switch self {
            case .active: return "Active"
            case .paused: return "Paused"
            case .done: return "Done"
            case .abandoned: return "Discarded"
            case .failed: return "Failed"
            }
        }

        /// Closed-out programs collapse into the archive section.
        public var isArchived: Bool {
            switch self {
            case .done, .abandoned, .failed: return true
            case .active, .paused: return false
            }
        }
    }

    /// One branch of the portfolio: the plan plus how it is scheduled and modelled.
    public struct Branch: Codable, Equatable, Sendable, Identifiable {
        public var planID: String
        public var title: String
        /// True when this branch's job is explicitly to attack the leading or most obvious
        /// answer rather than to build it. Descriptive only: coverage is judged from the
        /// mechanisms, and a portfolio need not manufacture a dedicated challenger.
        public var challengesLeadingAnswer: Bool
        public var costClass: CostClass
        /// Model override, stored as raw strings so ManifieldCore stays provider-agnostic;
        /// nil falls back to the researcher task's configured model.
        public var providerKind: String?
        public var model: String?
        /// Attack order chosen by whichever agent authored this generation — the pass-1
        /// planner for generation 1, the director afterwards. Lower runs first. Nil only in
        /// manifests written before priorities existed; the scheduler then keeps manifest
        /// order, which is what those programs were built under.
        public var priority: Int?

        public var id: String { planID }

        public init(planID: String, title: String,
                    challengesLeadingAnswer: Bool = false,
                    costClass: CostClass = .standard,
                    providerKind: String? = nil, model: String? = nil,
                    priority: Int? = nil) {
            self.planID = planID
            self.title = title
            self.challengesLeadingAnswer = challengesLeadingAnswer
            self.costClass = costClass
            self.providerKind = providerKind
            self.model = model
            self.priority = priority
        }

        /// Lenient decode: manifests written under the stance vocabulary still load. A branch
        /// whose stance was one of the three breaker roles keeps its job description.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            planID = try c.decode(String.self, forKey: .planID)
            title = try c.decode(String.self, forKey: .title)
            costClass = try c.decodeIfPresent(CostClass.self, forKey: .costClass) ?? .standard
            providerKind = try c.decodeIfPresent(String.self, forKey: .providerKind)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            priority = try c.decodeIfPresent(Int.self, forKey: .priority)
            if let flag = try c.decodeIfPresent(Bool.self, forKey: .challengesLeadingAnswer) {
                challengesLeadingAnswer = flag
            } else {
                let legacyStance = try? decoder.container(keyedBy: LegacyKeys.self)
                    .decodeIfPresent(String.self, forKey: .stance)
                challengesLeadingAnswer =
                    ["refute", "adversary", "impossible"].contains(legacyStance ?? "")
            }
        }

        private enum LegacyKeys: String, CodingKey { case stance }
    }

    /// An approach the planner considered and deliberately did not propose. Recording
    /// the misses is what makes the portfolio's coverage legible.
    public struct SkippedCell: Codable, Equatable, Sendable {
        public var cell: String
        public var why: String

        public init(cell: String, why: String) {
            self.cell = cell
            self.why = why
        }
    }

    /// A per-role model override for one program, stored as raw strings so ManifieldCore
    /// stays provider-agnostic — same shape as `Branch.providerKind`/`.model`.
    public struct ModelOverride: Codable, Equatable, Sendable {
        public var providerKind: String
        public var model: String

        public init(providerKind: String, model: String) {
            self.providerKind = providerKind
            self.model = model
        }
    }

    /// Reserved id prefix for in-memory wrappers around standalone plans.
    public static let virtualPrefix = "virtual-"

    public var id: String
    /// Short name for the program — the *problem* being attacked, not any one route to
    /// it. The goal statement is a directive sentence ("Determine the exact supremum…"),
    /// which reads like a single branch's task when used as a list label. Nil in
    /// manifests written before titles existed; read through `displayName`.
    public var title: String?
    /// The user prompt exactly as submitted. It is retained for history and diagnostics but
    /// is not handed to research agents as the mathematical target after formalization.
    public var goal: String
    /// Append-only target history. The active revision, rather than the mutable live library,
    /// is what every branch, finding, claim and review is answering.
    public var targetRevisions: [ResearchTargetRevision]
    public var activeTargetRevisionID: String
    public var status: Status
    /// How far this program may run unattended. Nil means the manual behaviour every existing
    /// program has: each pause waits for a person.
    public var continuation: ContinuationPolicy?
    /// Whether the planning front half included independent pilot attempts. Stored as
    /// provenance: pilots run only during creation, but an intentionally pilot-free program
    /// should not look like one whose old or incomplete transcript merely lacks pilot records.
    public var pilotsEnabled: Bool
    /// How many branches may hold an execution slot at once. Ships at 1.
    public var maxConcurrentBranches: Int
    /// Ceiling across all branches; admission stops when the sum of branch usage hits it.
    public var programTokenBudget: Int
    /// Usage spent before branch execution: audit, target drafting, recognition, pilots,
    /// portfolio design and branch planning. Zero for manifests written before it was counted.
    public var planningTokensUsed: Int
    public var branches: [Branch]
    /// Lines of attack, tracked across generations and outliving the branches that work them.
    /// Nil in manifests written before the registry existed.
    public var routes: [ResearchRoute]?
    /// Freeform work the director dispatched directly, outside a route. Read the same way as
    /// `routes`: what the director sees before it decides whether a given objective is already
    /// covered by something running or already tried.
    public var workerAssignments: [WorkerAssignment]
    public var findings: [ProgramFinding]
    /// Who was told about each finding, and why. A finding with no entry here has not been
    /// routed yet and reaches nobody — the default is silence, not broadcast.
    public var routings: [FindingRouting]
    /// Claims that specific durable results answer the user's question, with their rulings.
    public var solutions: [SolutionCandidate]
    /// Claims that the fixed goal statement itself is defective. Accepted challenges can coexist
    /// with unresolved research; only director governance changes the active target or routes.
    public var challenges: [ProblemChallenge]
    public var execution: ResearchExecution?
    /// Per-run model override by role, keyed by `AgentTask.rawValue` (ManifieldCore cannot
    /// import `ManifieldAgents`, so the key stays a raw string). Beats the global default for
    /// that role for the life of this program; empty means every role uses the global default.
    public var roleModelOverrides: [String: ModelOverride]
    public var skippedCells: [SkippedCell]
    /// Project-relative path of the synthesis report, once written.
    public var reportPath: String?
    /// What the last run of this program did to the theory library.
    public var lastRunChanges: [LibraryChange]?
    public var created: Date
    public var updated: Date

    public init(id: String, goal: String, title: String? = nil,
                targetRevisions: [ResearchTargetRevision] = [],
                activeTargetRevisionID: String? = nil,
                status: Status = .active,
                contract: SuccessContract? = nil, continuation: ContinuationPolicy? = nil,
                pilotsEnabled: Bool = true,
                maxConcurrentBranches: Int = 1, programTokenBudget: Int = 4_000_000,
                planningTokensUsed: Int = 0,
                branches: [Branch] = [], routes: [ResearchRoute]? = nil,
                workerAssignments: [WorkerAssignment] = [],
                findings: [ProgramFinding] = [],
                routings: [FindingRouting] = [],
                solutions: [SolutionCandidate] = [],
                challenges: [ProblemChallenge] = [], execution: ResearchExecution? = nil,
                roleModelOverrides: [String: ModelOverride] = [:],
                skippedCells: [SkippedCell] = [], reportPath: String? = nil,
                lastRunChanges: [LibraryChange]? = nil,
                created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.title = title
        self.goal = goal
        let revisions = targetRevisions.isEmpty
            ? [ResearchTargetRevision.legacy(requestText: goal)] : targetRevisions
        self.targetRevisions = revisions
        self.activeTargetRevisionID = activeTargetRevisionID
            .flatMap { id in revisions.contains(where: { $0.id == id }) ? id : nil }
            ?? revisions.last!.id
        self.status = status
        self.continuation = continuation
        self.pilotsEnabled = pilotsEnabled
        self.maxConcurrentBranches = max(1, maxConcurrentBranches)
        self.programTokenBudget = programTokenBudget
        self.planningTokensUsed = max(0, planningTokensUsed)
        self.branches = branches
        self.routes = routes
        self.workerAssignments = workerAssignments
        self.findings = findings
        self.routings = routings
        self.solutions = solutions
        self.challenges = challenges
        self.execution = execution
        self.roleModelOverrides = roleModelOverrides
        self.skippedCells = skippedCells
        self.reportPath = reportPath
        self.lastRunChanges = lastRunChanges
        self.created = created
        self.updated = updated
        // Last: the computed `contract` property's setter writes onto `targetRevisions`,
        // which needs every stored property — `self` — fully initialized first.
        self.contract = contract
    }

    /// Lenient decode: manifests written before routings and solution candidates existed load
    /// with both empty, which is exactly what they mean — nothing was routed, nothing claimed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        goal = try c.decode(String.self, forKey: .goal)
        let decodedRevisions = try c.decodeIfPresent(
            [ResearchTargetRevision].self, forKey: .targetRevisions) ?? []
        let revisions = decodedRevisions.isEmpty
            ? [ResearchTargetRevision.legacy(requestText: goal)] : decodedRevisions
        targetRevisions = revisions
        let decodedActive = try c.decodeIfPresent(String.self, forKey: .activeTargetRevisionID)
        activeTargetRevisionID = decodedActive
            .flatMap { id in revisions.contains(where: { $0.id == id }) ? id : nil }
            ?? revisions.last!.id
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
        continuation = try c.decodeIfPresent(ContinuationPolicy.self, forKey: .continuation)
        pilotsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pilotsEnabled) ?? true
        maxConcurrentBranches =
            max(1, try c.decodeIfPresent(Int.self, forKey: .maxConcurrentBranches) ?? 1)
        programTokenBudget =
            try c.decodeIfPresent(Int.self, forKey: .programTokenBudget) ?? 4_000_000
        planningTokensUsed =
            max(0, try c.decodeIfPresent(Int.self, forKey: .planningTokensUsed) ?? 0)
        branches = try c.decodeIfPresent([Branch].self, forKey: .branches) ?? []
        routes = try c.decodeIfPresent([ResearchRoute].self, forKey: .routes)
        workerAssignments =
            try c.decodeIfPresent([WorkerAssignment].self, forKey: .workerAssignments) ?? []
        findings = try c.decodeIfPresent([ProgramFinding].self, forKey: .findings) ?? []
        routings = try c.decodeIfPresent([FindingRouting].self, forKey: .routings) ?? []
        solutions = try c.decodeIfPresent([SolutionCandidate].self, forKey: .solutions) ?? []
        challenges = try c.decodeIfPresent([ProblemChallenge].self, forKey: .challenges) ?? []
        execution = try c.decodeIfPresent(ResearchExecution.self, forKey: .execution)
        roleModelOverrides =
            try c.decodeIfPresent([String: ModelOverride].self, forKey: .roleModelOverrides) ?? [:]
        skippedCells = try c.decodeIfPresent([SkippedCell].self, forKey: .skippedCells) ?? []
        reportPath = try c.decodeIfPresent(String.self, forKey: .reportPath)
        lastRunChanges = try c.decodeIfPresent([LibraryChange].self, forKey: .lastRunChanges)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()

        // `contract` was a stored, top-level field before the audited reading moved onto the
        // revision it describes. Not a `CodingKeys` case any more — nothing here is stored
        // under that key going forward — so it is read through its own tiny keyed container.
        // Merged only when the active revision has no statement of its own: a manifest written
        // after this change already carries one there, and the legacy field is stale beside it.
        let legacy = try decoder.container(keyedBy: LegacyContractKey.self)
        if let contract = try legacy.decodeIfPresent(SuccessContract.self, forKey: .contract),
           let index = targetRevisions.firstIndex(where: { $0.id == activeTargetRevisionID }),
           targetRevisions[index].statement.isEmpty {
            targetRevisions[index].statement = contract.statement
            targetRevisions[index].completeAnswers = contract.completeAnswers
            targetRevisions[index].completenessRationale = contract.completenessRationale
            targetRevisions[index].notCounted = contract.notCounted
            targetRevisions[index].recommendedReading = contract.recommendedReading
            targetRevisions[index].ambiguities = contract.ambiguities
            targetRevisions[index].reviewedAt = contract.reviewedAt
        }
    }

    private enum LegacyContractKey: String, CodingKey { case contract }

    /// Wraps a standalone plan as a one-branch program so the app has a single execution
    /// path. Never persisted — plan ids are date-prefixed by the approval flow, so the
    /// reserved prefix cannot collide with a real program id.
    public static func virtual(plan: PlanDocument) -> ResearchProgram {
        ResearchProgram(
            id: virtualPrefix + plan.id,
            goal: plan.goal,
            status: .active,
            maxConcurrentBranches: 1,
            programTokenBudget: plan.tokenBudget,
            branches: [Branch(planID: plan.id, title: plan.goal)],
            created: plan.created,
            updated: plan.updated)
    }

    public var isVirtual: Bool { id.hasPrefix(Self.virtualPrefix) }

    /// What to show wherever the program is named. Falls back to the goal statement for
    /// manifests written before titles existed, and to the id for an empty one.
    public var displayName: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return goal.isEmpty ? id : goal
    }

    /// Explicit name for new code; `goal` stays the encoded key for manifest compatibility.
    public var originalRequest: String { goal }

    public func branch(planID: String) -> Branch? {
        branches.first { $0.planID == planID }
    }

    public var activeTargetRevision: ResearchTargetRevision {
        targetRevisions.first { $0.id == activeTargetRevisionID }
            ?? targetRevisions.last
            ?? ResearchTargetRevision.legacy(requestText: goal)
    }

    /// The current authoritative formal statement. `goal` remains the original user text for
    /// history; accepted, governed corrections advance this value by a revision.
    public var researchRequest: String { activeTargetRevision.requestText }

    /// What counts as solving this question — the active target revision's audited reading,
    /// viewed as a `SuccessContract`. Not a second store: reading and writing this goes
    /// through the revision it describes, so a revision and its contract can never drift
    /// apart the way two independently-persisted values could. Nil while a program is running
    /// without one (enforcement is opt-in per program) or before a drafter has read the
    /// revision — an empty statement is exactly what `SuccessContract.validationProblems`
    /// already treats as absent.
    public var contract: SuccessContract? {
        get {
            let revision = activeTargetRevision
            guard !revision.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return SuccessContract(
                statement: revision.statement,
                completeAnswers: revision.completeAnswers,
                completenessRationale: revision.completenessRationale,
                notCounted: revision.notCounted,
                recommendedReading: revision.recommendedReading,
                ambiguities: revision.ambiguities,
                reviewedAt: revision.reviewedAt)
        }
        set {
            guard let index = targetRevisions.firstIndex(where: { $0.id == activeTargetRevisionID })
            else { return }
            targetRevisions[index].statement = newValue?.statement ?? ""
            targetRevisions[index].completeAnswers = newValue?.completeAnswers ?? []
            targetRevisions[index].completenessRationale = newValue?.completenessRationale ?? ""
            targetRevisions[index].notCounted = newValue?.notCounted ?? []
            targetRevisions[index].recommendedReading = newValue?.recommendedReading ?? ""
            targetRevisions[index].ambiguities = newValue?.ambiguities ?? []
            targetRevisions[index].reviewedAt = newValue?.reviewedAt
        }
    }

    /// Findings that have been ruled on and are wrong are withheld entirely, from everyone.
    public var circulatingFindings: [ProgramFinding] {
        findings.filter { !$0.isRejected }
    }

    /// Findings submitted but not yet routed. These reach nobody until the director rules,
    /// which is what makes routing a decision rather than a delay before a broadcast.
    public var unroutedFindings: [ProgramFinding] {
        let routed = Set(routings.map(\.findingID))
        return findings.filter { !routed.contains($0.id) && !$0.isRejected }
    }

    public func routing(forFinding findingID: String) -> FindingRouting? {
        routings.first { $0.findingID == findingID }
    }

    /// What `planID` should actually see: findings routed to it, never its own, never a
    /// rejected one. A finding with no routing yet reaches nobody.
    public func findings(routedTo planID: String) -> [ProgramFinding] {
        circulatingFindings.filter { finding in
            guard finding.branchPlanID != planID else { return false }
            return routing(forFinding: finding.id)?.reaches(planID) == true
        }
    }

    /// The claim that settled this program, if one did. Only the director may act on it.
    public var acceptedSolution: SolutionCandidate? {
        solutions.first { $0.status == .accepted }
    }

    /// Applies the user's ruling to a finding, in place.
    public mutating func setVerdict(_ verdict: ProgramFinding.Verdict?, note: String?,
                                    forFinding findingID: String) {
        guard let index = findings.firstIndex(where: { $0.id == findingID }) else { return }
        findings[index].verdict = verdict
        findings[index].verdictNote = note?.isEmpty == true ? nil : note
    }

    /// Records a routing decision, replacing any earlier one for the same finding — the
    /// director may revisit a `hold` once the program has moved on.
    public mutating func setRouting(_ routing: FindingRouting) {
        routings.removeAll { $0.findingID == routing.findingID }
        routings.append(routing)
    }

    public mutating func upsertSolution(_ candidate: SolutionCandidate) {
        if let index = solutions.firstIndex(where: { $0.id == candidate.id }) {
            solutions[index] = candidate
        } else {
            solutions.append(candidate)
        }
    }

    public mutating func upsertChallenge(_ challenge: ProblemChallenge) {
        if let index = challenges.firstIndex(where: { $0.id == challenge.id }) {
            challenges[index] = challenge
        } else {
            challenges.append(challenge)
        }
    }

    public mutating func appendTargetRevision(_ revision: ResearchTargetRevision) {
        guard !targetRevisions.contains(where: { $0.id == revision.id }) else {
            activeTargetRevisionID = revision.id
            return
        }
        targetRevisions.append(revision)
        activeTargetRevisionID = revision.id
    }
}

// MARK: - ProjectStore programs & branch memory

extension ProjectStore {

    /// Suffix marking a branch's research memory inside `plans/`. Reserved: a plan file
    /// ending in it would be invisible to `loadPlans()`.
    public static let branchMemorySuffix = ".memory.md"

    public var programsURL: URL { rootURL.appendingPathComponent("programs", isDirectory: true) }

    private static func programCoder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// All parseable programs, newest first; unparseable files are reported, not fatal.
    public func loadPrograms() -> (programs: [ResearchProgram], warnings: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: programsURL, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let (_, decoder) = Self.programCoder()
        var programs: [ResearchProgram] = []
        var warnings: [String] = []
        for file in files where file.pathExtension == "json" {
            do {
                programs.append(try decoder.decode(ResearchProgram.self, from: try Data(contentsOf: file)))
            } catch {
                warnings.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        programs.sort { $0.created > $1.created }
        return (programs, warnings)
    }

    public func program(id: String) -> ResearchProgram? {
        let url = programsURL.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let (_, decoder) = Self.programCoder()
        return try? decoder.decode(ResearchProgram.self, from: data)
    }

    public func saveProgram(_ program: ResearchProgram) throws {
        guard !program.isVirtual else {
            throw CoreError.io("virtual programs wrap standalone plans and are never persisted")
        }
        var program = program
        program.updated = Date()
        let (encoder, _) = Self.programCoder()
        try FileManager.default.createDirectory(at: programsURL, withIntermediateDirectories: true)
        try encoder.encode(program).write(
            to: programsURL.appendingPathComponent("\(program.id).json"), options: .atomic)
    }

    /// Deletes a program: its manifest, every branch plan it owns, those branches'
    /// memories, and the synthesis report. Only plans the manifest actually lists are
    /// touched, so a plan that was moved to another program is never collateral.
    public func deleteProgram(_ program: ResearchProgram) throws {
        let fm = FileManager.default
        let planIDs = Set(program.branches.map(\.planID) + (program.execution?.assignments.compactMap(\.planID) ?? []))
        for planID in planIDs {
            try deletePlan(id: planID)
        }
        if let reportPath = program.reportPath {
            let report = rootURL.appendingPathComponent(reportPath)
            if fm.fileExists(atPath: report.path) { try fm.removeItem(at: report) }
        }
        guard !program.isVirtual else { return }  // nothing on disk to remove
        let manifest = programsURL.appendingPathComponent("\(program.id).json")
        if fm.fileExists(atPath: manifest.path) { try fm.removeItem(at: manifest) }
    }

    /// `plans/<planID>.memory.md` — one isolated research memory per branch, in the same
    /// format as the project's `memory.md`.
    public func branchMemoryURL(planID: String) -> URL {
        plansURL.appendingPathComponent(planID + Self.branchMemorySuffix)
    }

    /// Pure disk read with no shared-state mutation, so it is safe to call from any
    /// thread — which is what lets agent contexts pull branch memory synchronously.
    public func loadBranchMemory(planID: String) -> String {
        (try? String(contentsOf: branchMemoryURL(planID: planID), encoding: .utf8)) ?? ""
    }

    public func saveBranchMemory(planID: String, text: String) throws {
        try FileManager.default.createDirectory(at: plansURL, withIntermediateDirectories: true)
        try text.write(to: branchMemoryURL(planID: planID), atomically: true, encoding: .utf8)
    }
}
