import Foundation

/// A freeform unit of work the director hands a branch, in place of a `ResearchRoute` built
/// from a role in a fixed portfolio.
///
/// Nothing here is a mathematical taxonomy — no pilot, prover, or challenger role. A "pilot" is
/// simply a small-budget assignment with a decisive stop condition; the director expresses that
/// through `tokenBudget` and `stopCondition`, not through a type the code enumerates.
public struct WorkerAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Set once the assignment becomes a branch. Nil only in the instant between the director
    /// proposing it and the runner building the branch — never persisted that way.
    public var planID: String?
    public var objective: String
    public var constraints: [String]
    public var targetRevisionID: String
    /// Theory items the director explicitly selected as relevant. Not a blanket grant — the
    /// worker still searches the library itself; this is what the director already knows.
    public var relevantItemIDs: [String]
    /// Findings routed in alongside this assignment, already labeled with trust state by
    /// whoever routed them. Provisional findings travel with an explicit warning; see
    /// `ProgramFinding.trust` and `route_findings`.
    public var relevantFindingIDs: [String]
    public var tokenBudget: Int
    /// "strong" to run on the strongest configured model; nil for the default.
    public var modelTier: String?
    /// Lower runs first, matching `ResearchProgram.Branch.priority`.
    public var priority: Int?
    /// The observable fact that ends this assignment — what makes a small, decisive dispatch
    /// (what used to be called a "pilot") different from an open-ended one is a stop condition
    /// with teeth, not a role label.
    public var stopCondition: String?
    /// Assignments this one was proposed in response to — the obstruction it works around, the
    /// partial result it builds on. Empty for a first dispatch.
    public var parentAssignmentIDs: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        planID: String? = nil,
        objective: String,
        constraints: [String] = [],
        targetRevisionID: String,
        relevantItemIDs: [String] = [],
        relevantFindingIDs: [String] = [],
        tokenBudget: Int,
        modelTier: String? = nil,
        priority: Int? = nil,
        stopCondition: String? = nil,
        parentAssignmentIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.planID = planID
        self.objective = objective
        self.constraints = constraints
        self.targetRevisionID = targetRevisionID
        self.relevantItemIDs = relevantItemIDs
        self.relevantFindingIDs = relevantFindingIDs
        self.tokenBudget = tokenBudget
        self.modelTier = modelTier
        self.priority = priority
        self.stopCondition = stopCondition
        self.parentAssignmentIDs = parentAssignmentIDs
        self.createdAt = createdAt
    }

    /// The standing brief injected as the branch's lens — what a route's `prior` was, for an
    /// assignment. Written in the second person, exactly like a route's, so the branch reads
    /// one voice regardless of which kind of dispatch produced it.
    public var brief: String {
        var lines = ["You were dispatched with this objective: \(objective)"]
        if !constraints.isEmpty {
            lines.append("Constraints: " + constraints.joined(separator: "; "))
        }
        if let stopCondition, !stopCondition.isEmpty {
            lines.append("Stop condition: \(stopCondition)")
        }
        if !relevantItemIDs.isEmpty {
            lines.append("Items the director already knows are relevant: "
                + relevantItemIDs.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// The one mechanical task every self-planning worker starts from. No separate planner
    /// context writes this branch's plan beforehand — the worker drafts it here, inside the
    /// same conversation it will then work in, using `revise_plan` and `add_task` exactly as
    /// it would to revise a plan at any later point.
    ///
    /// The task title carries the instruction because it is the one per-task field that
    /// reaches the model's opening message (`ResearchWorkbench.taskMessage`) — `needs` does
    /// not, it is read only for a blocked task's question. The objective and constraints
    /// themselves are not repeated here: `lens` already puts the full brief in the branch's
    /// system prompt, ahead of every task this branch will ever run.
    public func bootstrapPlan(planID: String, goal: String) -> PlanDocument {
        PlanDocument(
            id: planID, goal: goal, status: .approved, runMode: .auto,
            tokenBudget: tokenBudget,
            goalText: goal,
            approach: "Self-planned: \(objective.prefix(120))",
            tasks: [PlanTask(
                index: 1,
                title: "Using revise_plan or add_task, lay out the tasks your objective and "
                    + "constraints above actually need — as many or as few as that is. Continue "
                    + "directly into the first of them in this same turn if you can. Revise the "
                    + "plan again later the same way, whenever the evidence changes what is "
                    + "worth doing next.")],
            log: ["\(ISO8601DateFormatter().string(from: Date())) dispatched by the director "
                + "as a self-planning worker"],
            challengesLeadingAnswer: false,
            lens: brief)
    }
}
