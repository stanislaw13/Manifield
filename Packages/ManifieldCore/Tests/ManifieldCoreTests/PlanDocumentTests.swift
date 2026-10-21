import XCTest
@testable import ManifieldCore

final class PlanTaskLineTests: XCTestCase {

    func testLineRoundTrip() {
        let tasks = [
            PlanTask(index: 1, title: "Survey extremal candidates on ≤8 vertices"),
            PlanTask(index: 2, title: "Strengthen the lower bound", status: .inProgress,
                     kind: .prove(targetID: "lem-gamma2-lower"), dependsOn: [1]),
            PlanTask(index: 3, title: "Formalize discharging rules", kind: .research,
                     dependsOn: [1, 2], reviewGate: true),
            PlanTask(index: 4, title: "Close the δ=2 case", status: .blocked,
                     needs: "user decision on whether C5 counts")
        ]
        for task in tasks {
            XCTAssertEqual(PlanTask.parse(line: task.line), task, "round-trip failed for: \(task.line)")
        }
    }

    func testParseToleratesWhitespace() {
        let task = PlanTask.parse(line: "  2.  [completed]  (prove: thm-x)  Do the thing — depends: 1 — review  ")
        XCTAssertEqual(task?.index, 2)
        XCTAssertEqual(task?.status, .completed)
        XCTAssertEqual(task?.kind, .prove(targetID: "thm-x"))
        XCTAssertEqual(task?.dependsOn, [1])
        XCTAssertEqual(task?.reviewGate, true)
    }

    func testRejectsMalformedLines() {
        XCTAssertNil(PlanTask.parse(line: "not a task"))
        XCTAssertNil(PlanTask.parse(line: "1. [bogus-status] (research) X"))
        XCTAssertNil(PlanTask.parse(line: "1. [pending] (fly-to-moon) X"))
        XCTAssertNil(PlanTask.parse(line: "1. [pending] (prove:) missing id"))
    }
}

final class PlanDocumentTests: XCTestCase {

    private func samplePlan() -> PlanDocument {
        PlanDocument(
            id: "2026-07-10-discharging",
            goal: "Prove conj-gamma2-doubling",
            status: .active,
            runMode: .auto,
            tokenBudget: 3_000_000,
            goalText: "Prove conj-gamma2-doubling for connected graphs with δ ≥ 2.",
            approach: "Discharging: assign charges by degree, discharge along near-spider paths.",
            tasks: [
                PlanTask(index: 1, title: "Enumerate extremal graphs", status: .completed),
                PlanTask(index: 2, title: "Prove the lower bound",
                         kind: .prove(targetID: "lem-lower"), dependsOn: [1], reviewGate: true)
            ],
            log: ["2026-07-10T12:00:00Z plan approved by user",
                  "2026-07-10T13:05:00Z task 1 completed: 853 graphs enumerated"]
        )
    }

    func testSerializeParseRoundTrip() throws {
        let plan = samplePlan()
        let parsed = try PlanDocument.parse(markdown: plan.serialized())
        XCTAssertEqual(parsed.id, plan.id)
        XCTAssertEqual(parsed.goal, plan.goal)
        XCTAssertEqual(parsed.status, .active)
        XCTAssertEqual(parsed.runMode, .auto)
        XCTAssertEqual(parsed.tokenBudget, 3_000_000)
        XCTAssertEqual(parsed.goalText, plan.goalText)
        XCTAssertEqual(parsed.approach, plan.approach)
        XCTAssertEqual(parsed.tasks, plan.tasks)
        XCTAssertEqual(parsed.log, plan.log)
    }

    func testHandEditedPlanParsesLeniently() throws {
        let markdown = """
        ---
        id: my-plan
        goal: "Do the thing: carefully"
        status: approved
        ---

        ## Goal
        Full prose goal.

        ## Approach
        The chosen way.

        ## Tasks

        1. [pending] (research) First step

        2. [pending] (prove: thm-a) Second step — depends: 1

        ## Log
        """
        let plan = try PlanDocument.parse(markdown: markdown)
        XCTAssertEqual(plan.goal, "Do the thing: carefully")
        XCTAssertEqual(plan.runMode, .checkpoint, "missing run_mode defaults safely")
        XCTAssertEqual(plan.tasks.count, 2)
        XCTAssertEqual(plan.tasks[1].dependsOn, [1])
        XCTAssertTrue(plan.log.isEmpty)
    }

    func testUnparseableTaskLineIsAnError() {
        let markdown = """
        ---
        id: p
        ---
        ## Tasks
        1. [pending] (research) Fine
        2. utterly broken line
        """
        XCTAssertThrowsError(try PlanDocument.parse(markdown: markdown)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unparseable task line"))
        }
    }

    func testRunnableTasksRespectDependencies() {
        var plan = samplePlan()
        XCTAssertEqual(plan.runnableTasks().map(\.index), [2],
                       "task 2's dependency (1) is completed, so it is runnable")
        plan.tasks[0].status = .pending
        XCTAssertEqual(plan.runnableTasks().map(\.index), [1],
                       "task 2 must wait for task 1 again")
        XCTAssertFalse(plan.isFinished)
    }

    func testStoreSaveAndLoadPlans() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "P")

        try store.savePlan(samplePlan())
        let (plans, warnings) = store.loadPlans()
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(plans[0].id, "2026-07-10-discharging")
        XCTAssertNotNil(store.plan(id: "2026-07-10-discharging"))

        // A broken file is a warning, not a failure.
        try "not a plan".write(
            to: store.plansURL.appendingPathComponent("broken.md"),
            atomically: true, encoding: .utf8)
        let reloaded = store.loadPlans()
        XCTAssertEqual(reloaded.plans.count, 1)
        XCTAssertEqual(reloaded.warnings.count, 1)
    }

    // MARK: - Research program branch fields

    func testProgramFieldsRoundTrip() throws {
        var plan = samplePlan()
        plan.program = "2026-07-24-gamma2-portfolio"
        plan.challengesLeadingAnswer = true
        plan.kill = "No counterexample below 12 vertices after an exhaustive scan"
        plan.lens = "Assume the conjecture is false and the obstruction is local:\nhunt small dense counterexamples first."

        let text = plan.serialized()
        XCTAssertTrue(text.contains("## Lens"))
        let parsed = try PlanDocument.parse(markdown: text)
        XCTAssertEqual(parsed.program, plan.program)
        XCTAssertTrue(parsed.challengesLeadingAnswer)
        XCTAssertEqual(parsed.kill, plan.kill)
        XCTAssertEqual(parsed.lens, plan.lens)
        XCTAssertEqual(parsed.tasks, plan.tasks, "program fields must not disturb task parsing")
    }

    func testLegacyPlanRoundTripsWithoutProgramFields() throws {
        let plan = samplePlan()
        let text = plan.serialized()
        XCTAssertFalse(text.contains("program:"))
        XCTAssertFalse(text.contains("challenges_leading_answer:"))
        XCTAssertFalse(text.contains("kill:"))
        XCTAssertFalse(text.contains("## Lens"))

        let parsed = try PlanDocument.parse(markdown: text)
        XCTAssertNil(parsed.program)
        XCTAssertFalse(parsed.challengesLeadingAnswer)
        XCTAssertNil(parsed.kill)
        XCTAssertEqual(parsed.lens, "")
        XCTAssertEqual(parsed.serialized(), text, "re-serializing a legacy plan is byte-stable")
    }

    func testEmptyKillIsNeverEmitted() throws {
        var plan = samplePlan()
        plan.kill = ""
        XCTAssertFalse(plan.serialized().contains("kill:"))
        XCTAssertNil(try PlanDocument.parse(markdown: plan.serialized()).kill)
    }

    func testPromptDigestIncludesTheRoleAndKillButNotLens() {
        var plan = samplePlan()
        plan.challengesLeadingAnswer = true
        plan.kill = "the bound stays above 3n/8"
        plan.lens = "LENS-SENTINEL"
        let digest = plan.promptDigest
        XCTAssertTrue(digest.contains("attacks the leading answer"))
        XCTAssertTrue(digest.contains("Kill criterion: the bound stays above 3n/8"))
        XCTAssertFalse(digest.contains("LENS-SENTINEL"),
                       "the lens gets its own system section — digesting it would double it")
    }

    func testGuidanceRoundTrips() throws {
        var plan = samplePlan()
        plan.guidance = "Stop chasing the δ=2 case; the wheel family is where the bound bites."
        let parsed = try PlanDocument.parse(markdown: plan.serialized())
        XCTAssertEqual(parsed.guidance, plan.guidance)
        XCTAssertFalse(samplePlan().serialized().contains("## Guidance"),
                       "no guidance means no section")
    }

    // MARK: - Editing an approved plan

    func testRemovePendingTaskRenumbersAndRemapsDependencies() {
        var plan = PlanDocument(id: "p", goal: "g", tasks: [
            PlanTask(index: 1, title: "One", status: .completed),
            PlanTask(index: 2, title: "Two"),
            PlanTask(index: 3, title: "Three", dependsOn: [1, 2]),
            PlanTask(index: 4, title: "Four", dependsOn: [3])
        ])
        XCTAssertTrue(plan.removeTask(index: 2))
        XCTAssertEqual(plan.tasks.map(\.index), [1, 2, 3])
        XCTAssertEqual(plan.tasks.map(\.title), ["One", "Three", "Four"])
        XCTAssertEqual(plan.tasks[1].dependsOn, [1], "the dependency on the removed task is dropped")
        XCTAssertEqual(plan.tasks[2].dependsOn, [2], "later references shift down")
    }

    func testRemoveRefusesStartedTasks() {
        var plan = PlanDocument(id: "p", goal: "g", tasks: [
            PlanTask(index: 1, title: "Done", status: .completed),
            PlanTask(index: 2, title: "Running", status: .inProgress),
            PlanTask(index: 3, title: "Pending")
        ])
        XCTAssertFalse(plan.removeTask(index: 1), "the journal already refers to it")
        XCTAssertFalse(plan.removeTask(index: 2))
        XCTAssertEqual(plan.tasks.count, 3)
    }

    func testRemovedTaskNeverLeavesAForwardDependency() {
        var plan = PlanDocument(id: "p", goal: "g", tasks: [
            PlanTask(index: 1, title: "One"),
            PlanTask(index: 2, title: "Two", dependsOn: [1]),
            PlanTask(index: 3, title: "Three", dependsOn: [2])
        ])
        XCTAssertTrue(plan.removeTask(index: 1))
        for task in plan.tasks {
            XCTAssertTrue(task.dependsOn.allSatisfy { $0 < task.index },
                          "task \(task.index) depends on \(task.dependsOn)")
        }
        // Still parseable after an edit — the task grammar rejects forward references.
        XCTAssertNoThrow(try PlanDocument.parse(markdown: plan.serialized()))
    }

    func testAppendTaskContinuesNumbering() {
        var plan = PlanDocument(id: "p", goal: "g", tasks: [
            PlanTask(index: 1, title: "One", status: .completed)
        ])
        XCTAssertEqual(plan.appendTask(title: "Two", kind: .prove(targetID: "lem-x")), 2)
        XCTAssertEqual(plan.tasks.last?.kind, .prove(targetID: "lem-x"))
    }

    func testLoadPlansSkipsBranchMemoryFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-store-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "P")

        try store.savePlan(samplePlan())
        try store.saveBranchMemory(planID: "2026-07-10-discharging",
                                   text: "## Goal\nBranch notes.\n")

        let (plans, warnings) = store.loadPlans()
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(warnings.isEmpty, "branch memories must not be parsed as plans: \(warnings)")
    }

    // MARK: - Stranding behind a failed task

    /// 1 fails; 2 depends on 1; 3 depends on 2; 4 is independent.
    private func chainPlan() -> PlanDocument {
        PlanDocument(id: "chain", goal: "g", tasks: [
            PlanTask(index: 1, title: "one", status: .failed),
            PlanTask(index: 2, title: "two", dependsOn: [1]),
            PlanTask(index: 3, title: "three", dependsOn: [2]),
            PlanTask(index: 4, title: "four")
        ])
    }

    func testStrandedTasksFollowsTheDependencyChain() {
        let stranded = chainPlan().strandedTasks(after: 1).map(\.index)
        XCTAssertEqual(stranded, [2, 3], "the whole transitive closure is unreachable, not just direct dependents")
    }

    func testStrandedTasksLeavesIndependentWorkAlone() {
        XCTAssertFalse(chainPlan().strandedTasks(after: 1).contains { $0.index == 4 })
    }

    func testStrandedTasksIgnoresTasksThatAlreadyRan() {
        var plan = chainPlan()
        plan.tasks[1].status = .completed        // task 2 completed before task 1 failed
        // 2 already ran, so it is not stranded — and 3's dependency is satisfied.
        XCTAssertEqual(plan.strandedTasks(after: 1).map(\.index), [])
    }

    func testUnreachableTasksReportsBlockedDescendantsOfAFailure() {
        var plan = chainPlan()
        plan.tasks[1].status = .blocked
        plan.tasks[2].status = .blocked
        XCTAssertEqual(plan.unreachableTasks().map(\.index), [2, 3])
    }

    /// The distinction the run loop depends on: a task blocked while waiting on the user is a
    /// real question, one blocked behind a failure is not — no answer completes a failed task.
    func testUnreachableTasksExcludesATaskBlockedOnTheUser() {
        var plan = PlanDocument(id: "p", goal: "g", tasks: [
            PlanTask(index: 1, title: "one"),
            PlanTask(index: 2, title: "two")
        ])
        plan.tasks[1].status = .blocked
        plan.tasks[1].needs = "which convention should I use?"
        XCTAssertTrue(plan.unreachableTasks().isEmpty)
    }
}
