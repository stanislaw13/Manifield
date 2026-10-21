import XCTest
@testable import ManifieldCore

final class WorkerAssignmentTests: XCTestCase {

    private func assignment(
        objective: String = "Find the exact constant in the residual case.",
        constraints: [String] = [],
        stopCondition: String? = nil
    ) -> WorkerAssignment {
        WorkerAssignment(objective: objective, constraints: constraints,
                         targetRevisionID: "rev-1", tokenBudget: 500_000,
                         stopCondition: stopCondition)
    }

    func testBriefCarriesTheObjective() {
        XCTAssertTrue(assignment().brief.contains("Find the exact constant"))
    }

    func testBriefStatesConstraintsAndStopConditionWhenPresent() {
        let brief = assignment(
            constraints: ["assume the graph is connected"],
            stopCondition: "a counterexample or a proof, whichever comes first"
        ).brief
        XCTAssertTrue(brief.contains("assume the graph is connected"))
        XCTAssertTrue(brief.contains("a counterexample or a proof"))
    }

    func testBriefOmitsEmptySectionsRatherThanPrintingThem() {
        let brief = assignment().brief
        XCTAssertFalse(brief.contains("Constraints:"))
        XCTAssertFalse(brief.contains("Stop condition:"))
    }

    /// The one property the bootstrap mechanism actually depends on: `taskMessage` in
    /// ResearchWorkbench builds the model's opening message from `task.title` alone, never
    /// from `needs` — so a self-planning instruction that only lived in `needs` would silently
    /// never reach the model. Pin the field it must be in.
    func testBootstrapInstructionLivesInTheTaskTitleNotNeeds() {
        let plan = assignment().bootstrapPlan(planID: "p1", goal: "g")
        XCTAssertEqual(plan.tasks.count, 1)
        let task = plan.tasks[0]
        XCTAssertTrue(task.title.contains("revise_plan") || task.title.contains("add_task"))
        XCTAssertNil(task.needs)
    }

    func testBootstrapPlanCarriesTheBriefAsItsLens() {
        let a = assignment(constraints: ["work over the reals only"])
        let plan = a.bootstrapPlan(planID: "p1", goal: "g")
        XCTAssertEqual(plan.lens, a.brief)
        XCTAssertTrue(plan.lens.contains("work over the reals only"))
    }

    func testBootstrapPlanIsImmediatelyRunnable() {
        let plan = assignment().bootstrapPlan(planID: "p1", goal: "g")
        XCTAssertEqual(plan.status, .approved)
        XCTAssertEqual(plan.runMode, .auto)
        XCTAssertEqual(plan.tasks.first?.status, .pending)
        XCTAssertFalse(plan.isFinished)
    }

    func testRoundTripsThroughJSON() throws {
        var a = assignment(constraints: ["c1"], stopCondition: "s1")
        a.planID = "p1"
        a.relevantItemIDs = ["item-a"]
        a.relevantFindingIDs = ["finding-1"]
        a.modelTier = "strong"
        a.priority = 2
        a.parentAssignmentIDs = ["parent-1"]
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(WorkerAssignment.self, from: data)
        XCTAssertEqual(decoded, a)
    }
}
