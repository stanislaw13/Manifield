import XCTest
@testable import ManifieldAgents
@testable import ManifieldCore

/// The program map's layout. A pure projection, so it is tested without a view.
final class ProgramGraphTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func program(
        routes: [ResearchRoute],
        findings: [ProgramFinding] = [],
        routings: [FindingRouting] = [],
        solutions: [SolutionCandidate] = [],
        skipped: [ResearchProgram.SkippedCell] = []
    ) -> ResearchProgram {
        ResearchProgram(
            id: "p", goal: "g",
            branches: routes.compactMap { route in
                route.planID.map {
                    ResearchProgram.Branch(planID: $0, title: "Branch \($0)",
                                           challengesLeadingAnswer: $0 == "b2")
                }
            },
            routes: routes,
            findings: findings,
            routings: routings,
            solutions: solutions,
            skippedCells: skipped)
    }

    private func record(_ planID: String, tasks: Int, from: Double) -> RunRecord {
        var record = RunRecord(plan: PlanDocument(id: planID, goal: "g"))
        record.startedAt = at(from)
        record.journal = (1...tasks).map { index in
            TaskJournalEntry(taskIndex: index, outcome: "completed",
                             summary: "did \(index)", tokensIn: 100, tokensOut: 10,
                             startedAt: at(from + Double(index) * 5),
                             endedAt: at(from + Double(index) * 5 + 4))
        }
        record.tokensIn = 100 * tasks
        record.tokensOut = 10 * tasks
        return record
    }

    // MARK: - Lanes

    func testEachRouteBecomesALaneInGenerationOrder() {
        let graph = ProgramGraph.build(
            program: program(routes: [
                ResearchRoute(id: "r2", planID: "b2", mechanism: "second",
                              generation: 2, createdAt: at(60)),
                ResearchRoute(id: "r1", planID: "b1", mechanism: "first",
                              generation: 1, createdAt: at(0)),
            ]),
            records: [:])

        XCTAssertEqual(graph.lanes.map(\.routeID), ["r1", "r2"])
        XCTAssertEqual(graph.lanes.map(\.generation), [1, 2])
    }

    /// A lane's job is to outlive the branch working it, but a branch with no route entry still
    /// has to appear — otherwise a program whose registry was never written draws as nothing.
    func testABranchWithNoRouteStillGetsALane() {
        var p = program(routes: [])
        p.branches = [ResearchProgram.Branch(planID: "orphan", title: "Unregistered")]
        let graph = ProgramGraph.build(program: p, records: [:])
        XCTAssertEqual(graph.lanes.map(\.planID), ["orphan"])
        XCTAssertEqual(graph.lanes.first?.title, "Unregistered")
    }

    func testALaneCarriesItsTaskTicksAndSpend() {
        let graph = ProgramGraph.build(
            program: program(routes: [ResearchRoute(id: "r1", planID: "b1", mechanism: "m")]),
            records: ["b1": record("b1", tasks: 3, from: 0)])

        let lane = try? XCTUnwrap(graph.lanes.first)
        XCTAssertEqual(lane?.taskTicks.map(\.taskIndex), [1, 2, 3])
        XCTAssertTrue(lane?.taskTicks.allSatisfy(\.completed) == true)
        XCTAssertEqual(lane?.tokensSpent, 330)
    }

    /// Without lineage a later generation is a stack of unrelated columns.
    func testLineageLinksAGenerationToWhatProducedIt() {
        let graph = ProgramGraph.build(
            program: program(routes: [
                ResearchRoute(id: "r1", planID: "b1", mechanism: "first", generation: 1,
                              createdAt: at(0)),
                ResearchRoute(id: "r2", planID: "b2", mechanism: "second",
                              parentRouteIDs: ["r1"], generation: 2, createdAt: at(60)),
            ]),
            records: [:])

        XCTAssertEqual(graph.lanes[0].parentLaneIndices, [])
        XCTAssertEqual(graph.lanes[1].parentLaneIndices, [0])
    }

    // MARK: - Routing edges

    private func twoBranchFixture(
        decision: FindingRouting.Decision,
        recipients: [String] = []
    ) -> ProgramGraph {
        let finding = ProgramFinding(id: "f1", branchPlanID: "b1", kind: .evidence,
                                     statement: "exhaustive to k=22", createdAt: at(20))
        let routing = FindingRouting(findingID: "f1", decision: decision,
                                     recipientPlanIDs: recipients,
                                     rationale: "because", decidedAt: at(22))
        return ProgramGraph.build(
            program: program(
                routes: [
                    ResearchRoute(id: "r1", planID: "b1", mechanism: "one", createdAt: at(0)),
                    ResearchRoute(id: "r2", planID: "b2", mechanism: "two", createdAt: at(1)),
                    ResearchRoute(id: "r3", planID: "b3", mechanism: "three", createdAt: at(2)),
                ],
                findings: [finding], routings: [routing]),
            records: [:])
    }

    func testSendNowDrawsAnEdgeToTheNamedRecipientOnly() {
        let graph = twoBranchFixture(decision: .sendNow, recipients: ["b3"])
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges.first?.fromLane, 0)
        XCTAssertEqual(graph.edges.first?.toLane, 2)
    }

    func testGlobalReachesEveryLaneButTheOriginator() {
        let graph = twoBranchFixture(decision: .global)
        XCTAssertEqual(graph.edges.map(\.toLane).sorted(), [1, 2])
        XCTAssertFalse(graph.edges.contains { $0.toLane == 0 })
    }

    /// **The point of the whole view.** A held finding exists, and reaches nobody. Drawn as a
    /// node with no edge leaving it, "the director decided not to tell anyone" is legible at a
    /// glance — and it is the one thing the routing model does that no list can show.
    func testAHeldFindingProducesANodeAndNoEdge() {
        let graph = twoBranchFixture(decision: .hold)
        XCTAssertEqual(graph.nodes.filter { if case .finding = $0.kind { return true }; return false }.count, 1)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    func testDoNotSendProducesNoEdge() {
        XCTAssertTrue(twoBranchFixture(decision: .doNotSend).edges.isEmpty)
    }

    /// An unrouted finding is not the same as a withheld one — it has not been decided yet —
    /// and the node has to say so rather than looking like a `do_not_send`.
    func testAnUnroutedFindingCarriesNoDecision() {
        let graph = ProgramGraph.build(
            program: program(
                routes: [ResearchRoute(id: "r1", planID: "b1", mechanism: "one")],
                findings: [ProgramFinding(id: "f1", branchPlanID: "b1", kind: .evidence,
                                          statement: "s", createdAt: at(10))]),
            records: [:])
        guard case .finding(_, let decision) = graph.nodes.first?.kind else {
            return XCTFail("expected a finding node")
        }
        XCTAssertNil(decision)
        XCTAssertTrue(graph.edges.isEmpty)
    }

    // MARK: - Nodes

    func testAttributedLibraryChangesBecomeNodesAndUnattributedOnesDoNot() {
        var record = record("b1", tasks: 1, from: 0)
        record.libraryChanges = [
            LibraryChange(itemID: "lem-a", name: "A", kind: .created,
                          branchPlanID: "b1", taskIndex: 1, at: at(5)),
            // No branch and no moment: nowhere to put it on a graph whose axes are those two.
            LibraryChange(itemID: "lem-b", name: "B", kind: .statusChanged),
        ]
        let graph = ProgramGraph.build(
            program: program(routes: [ResearchRoute(id: "r1", planID: "b1", mechanism: "m")]),
            records: ["b1": record])

        let changes = graph.nodes.filter {
            if case .libraryChange = $0.kind { return true }; return false
        }
        XCTAssertEqual(changes.map(\.subjectID), ["lem-a"])
    }

    func testAClaimBecomesANodeOnItsBranchesLane() {
        let candidate = SolutionCandidate(id: "c1", branchPlanID: "b2",
                                          primaryItemID: "thm-x", argument: "because",
                                          status: .underReview, createdAt: at(40))
        let graph = ProgramGraph.build(
            program: program(routes: [
                ResearchRoute(id: "r1", planID: "b1", mechanism: "one", createdAt: at(0)),
                ResearchRoute(id: "r2", planID: "b2", mechanism: "two", createdAt: at(1)),
            ], solutions: [candidate]),
            records: [:])

        let claim = try? XCTUnwrap(graph.nodes.first {
            if case .claim = $0.kind { return true }; return false
        })
        XCTAssertEqual(claim?.laneIndex, 1)
        XCTAssertEqual(claim?.subjectID, "c1")
    }

    func testAClosedRouteGetsATerminator() {
        let graph = ProgramGraph.build(
            program: program(routes: [
                ResearchRoute(id: "r1", planID: "b1", mechanism: "one", status: .falsified,
                              obstruction: "died on the log factor", updatedAt: at(30)),
            ]),
            records: [:])

        guard case .routeClosed(let status) = graph.nodes.first(where: {
            if case .routeClosed = $0.kind { return true }; return false
        })?.kind else { return XCTFail("expected a terminator") }
        XCTAssertEqual(status, .falsified)
    }

    // MARK: - Boundaries, ghosts, time

    func testAGenerationBoundaryIsDrawnForEveryWaveAfterTheFirst() {
        let graph = ProgramGraph.build(
            program: program(routes: [
                ResearchRoute(id: "r1", planID: "b1", mechanism: "one", generation: 1,
                              createdAt: at(0)),
                ResearchRoute(id: "r2", planID: "b2", mechanism: "two", generation: 2,
                              createdAt: at(60)),
                ResearchRoute(id: "r3", planID: "b3", mechanism: "three", generation: 2,
                              createdAt: at(65)),
            ]),
            records: [:])

        XCTAssertEqual(graph.boundaries.map(\.generation), [2])
        XCTAssertEqual(graph.boundaries.first?.at, at(60), "placed at the earliest of its wave")
        XCTAssertTrue(graph.boundaries.first?.label.contains("2 route(s)") == true)
    }

    func testSkippedCellsBecomeGhosts() {
        let graph = ProgramGraph.build(
            program: program(routes: [], skipped: [
                .init(cell: "Probabilistic existence", why: "no concentration available here"),
            ]),
            records: [:])
        XCTAssertEqual(graph.ghosts.map(\.cell), ["Probabilistic existence"])
        XCTAssertEqual(graph.ghosts.first?.why, "no concentration available here")
    }

    func testTheTimeWindowSpansEveryRecordedMoment() {
        let graph = ProgramGraph.build(
            program: program(
                routes: [ResearchRoute(id: "r1", planID: "b1", mechanism: "m")],
                findings: [ProgramFinding(id: "f1", branchPlanID: "b1", kind: .evidence,
                                          statement: "s", createdAt: at(90))]),
            records: ["b1": record("b1", tasks: 2, from: 0)])

        XCTAssertEqual(graph.start, at(0))
        XCTAssertEqual(graph.end, at(90))
        XCTAssertEqual(graph.fraction(of: at(45)), 0.5, accuracy: 0.001)
    }

    /// A record whose clock is off must not push a node off the canvas.
    func testFractionsAreClamped() {
        let graph = ProgramGraph.build(
            program: program(routes: [ResearchRoute(id: "r1", planID: "b1", mechanism: "m")]),
            records: ["b1": record("b1", tasks: 2, from: 0)])
        XCTAssertEqual(graph.fraction(of: at(-500)), 0)
        XCTAssertEqual(graph.fraction(of: at(9999)), 1)
    }

    /// A program that has not run yet: every moment collapses to one instant. The window must
    /// stay well-formed rather than dividing by zero.
    func testAProgramWithNoTimedEventsHasAWellFormedWindow() {
        let graph = ProgramGraph.build(
            program: program(routes: []), records: [:])
        XCTAssertTrue(graph.isEmpty)
        XCTAssertLessThanOrEqual(graph.start, graph.end)
        XCTAssertEqual(graph.fraction(of: Date()), 0)
    }
}
