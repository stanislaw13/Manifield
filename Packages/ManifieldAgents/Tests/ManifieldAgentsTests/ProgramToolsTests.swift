import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class FindingCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _findings: [ProgramFinding] = []
    func add(_ f: ProgramFinding) { lock.lock(); _findings.append(f); lock.unlock() }
    var findings: [ProgramFinding] { lock.lock(); defer { lock.unlock() }; return _findings }
}

final class PublishFindingToolTests: XCTestCase {

    private func makeTool(_ capture: FindingCapture) -> AgentTool {
        ProgramTools.publishFindingTool(branchPlanID: "branch-a") { capture.add($0) }
    }

    func testPublishesTypedFindingWithEvidence() async throws {
        let capture = FindingCapture()
        let reply = try await makeTool(capture).execute(inputJSON: """
        {"kind": "obstruction", "statement": "Local charge arguments cannot reach δ=2.",
         "item_ids": ["lem-min-degree-two"], "artifact_path": "artifacts/run-1/stdout.txt"}
        """)

        XCTAssertTrue(reply.contains("sibling"))
        let finding = try XCTUnwrap(capture.findings.first)
        XCTAssertEqual(finding.kind, .obstruction)
        XCTAssertEqual(finding.branchPlanID, "branch-a")
        XCTAssertEqual(finding.itemIDs, ["lem-min-degree-two"])
        XCTAssertEqual(finding.artifactPath, "artifacts/run-1/stdout.txt")
    }

    /// Submitting is not broadcasting, and the reply has to say so — a branch told its
    /// finding "reached the siblings" would reason about what they now know, and be wrong.
    func testTheReplySaysTheFindingWasSubmittedNotBroadcast() async throws {
        let capture = FindingCapture()
        let reply = try await makeTool(capture).execute(inputJSON: """
        {"kind": "counterexample", "statement": "The wheel W6 has γ₂ = 3 < the claimed bound."}
        """)
        XCTAssertTrue(reply.contains("director decides"))
        XCTAssertTrue(reply.contains("do not see it automatically"))
        XCTAssertEqual(capture.findings.first?.kind, .counterexample)
    }

    /// A confirmed route-killing claim must not read as a settlement. The branch is told to
    /// close its task and, if it thinks the question is answered, to claim it explicitly —
    /// because a finding never settles anything on its own.
    func testAConfirmedClaimStillPointsAtFinishTaskAndClaimSolution() async throws {
        let capture = FindingCapture()
        let confirmed = try await ProgramTools.publishFindingTool(
            branchPlanID: "branch-a",
            adjudicate: { _ in .init(confirmed: true, note: "recomputed γ₂(W6)=3 independently") },
            publish: { capture.add($0) }
        ).execute(inputJSON: #"{"kind":"counterexample","statement":"W6 breaks it."}"#)
        XCTAssertTrue(confirmed.contains("finish_task"), "got: \(confirmed)")
        XCTAssertTrue(confirmed.contains("claim_solution"),
                      "a confirmed finding is not by itself a solution")
        XCTAssertEqual(capture.findings.first?.verdict, .confirmed)
    }

    /// A claim that fails independent verification never reaches the pool: the refusal is
    /// typed, carries the adjudicator's reason, and leaves the branch able to repair it.
    func testRejectedAdjudicationBlocksThePublish() async throws {
        let capture = FindingCapture()
        let tool = ProgramTools.publishFindingTool(
            branchPlanID: "branch-a",
            adjudicate: { _ in
                .init(confirmed: false, note: "the graph has a vertex of degree 1, which the hypothesis excludes")
            },
            publish: { capture.add($0) })

        do {
            _ = try await tool.execute(inputJSON: """
            {"kind": "counterexample", "statement": "G refutes the bound."}
            """)
            XCTFail("expected the rejected claim to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("degree 1"),
                          "the branch needs the actual reason to repair the claim")
        }
        XCTAssertTrue(capture.findings.isEmpty, "nothing may circulate")
    }

    /// A confirmed claim publishes carrying its verdict, so siblings and the director read
    /// it as verified rather than as one branch's assertion.
    func testConfirmedAdjudicationPublishesWithTheVerdict() async throws {
        let capture = FindingCapture()
        let reply = try await ProgramTools.publishFindingTool(
            branchPlanID: "branch-a",
            adjudicate: { _ in .init(confirmed: true, note: "recomputed the subset sums; the claim holds") },
            publish: { capture.add($0) }
        ).execute(inputJSON: #"{"kind":"counterexample","statement":"{3,5,6,7} breaks powers-of-two."}"#)

        XCTAssertTrue(reply.contains("CONFIRMED"))
        let finding = try XCTUnwrap(capture.findings.first)
        XCTAssertEqual(finding.verdict, .confirmed)
        XCTAssertTrue(finding.verdictNote?.contains("independent adjudication") ?? false)
    }

    /// Adjudication is only for the finding that can stop the program — an obstruction or a
    /// reduction publishes straight through, unverified, as it always did.
    func testAdjudicationOnlyGatesCounterexamples() async throws {
        let capture = FindingCapture()
        let calls = FindingCapture()
        let reply = try await ProgramTools.publishFindingTool(
            branchPlanID: "branch-a",
            adjudicate: { finding in
                calls.add(finding)
                return .init(confirmed: false, note: "should never be consulted")
            },
            publish: { capture.add($0) }
        ).execute(inputJSON: #"{"kind":"obstruction","statement":"Local charging caps at 2^k/sqrt(k)."}"#)

        XCTAssertTrue(reply.contains("Submitted"))
        XCTAssertTrue(calls.findings.isEmpty)
        XCTAssertEqual(capture.findings.first?.kind, .obstruction)
    }

    func testStatementIsClamped() async throws {
        let capture = FindingCapture()
        _ = try await makeTool(capture).execute(inputJSON: """
        {"kind": "evidence", "statement": "\(String(repeating: "x", count: 900))"}
        """)
        XCTAssertEqual(capture.findings.first?.statement.count, ProgramFinding.maxStatementLength)
    }

    func testUnknownKindListsTheValidOnes() async {
        do {
            _ = try await makeTool(FindingCapture()).execute(
                inputJSON: #"{"kind": "vibes", "statement": "s"}"#)
            XCTFail("expected rejection")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("counterexample"))
            XCTAssertTrue(message.contains("lens_abandoned"))
        }
    }

    func testMissingStatementIsRejected() async {
        do {
            _ = try await makeTool(FindingCapture()).execute(
                inputJSON: #"{"kind": "evidence", "statement": "   "}"#)
            XCTFail("expected rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("statement"))
        }
    }

    // MARK: - Goal-kind vocabulary






}

private final class CloseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(PlanStatus, String)] = []
    func add(_ status: PlanStatus, _ reason: String) {
        lock.lock(); calls.append((status, reason)); lock.unlock()
    }
    var value: [(PlanStatus, String)] { lock.lock(); defer { lock.unlock() }; return calls }
}

final class CloseBranchToolTests: XCTestCase {

    private func makeTool(_ capture: CloseCapture) -> AgentTool {
        ProgramTools.closeBranchTool(branchPlanID: "b1", branchTitle: "Discharging") { status, reason in
            capture.add(status, reason)
        }
    }

    func testMarksTheBranchFailedWithItsReason() async throws {
        let capture = CloseCapture()
        let reply = try await makeTool(capture).execute(inputJSON: """
        {"status": "failed", "reason": "Charge conservation fails on the δ=2 family."}
        """)
        XCTAssertEqual(capture.value.count, 1)
        XCTAssertEqual(capture.value.first?.0, .failed)
        XCTAssertTrue(try XCTUnwrap(capture.value.first?.1).contains("δ=2"))
        XCTAssertTrue(reply.contains("archive"))
    }

    /// A closed branch with no recorded reason is worse than an open one — the archive is
    /// read precisely to find out what was ruled out and why.
    func testReasonIsRequired() async {
        do {
            _ = try await makeTool(CloseCapture()).execute(
                inputJSON: #"{"status": "failed", "reason": "  "}"#)
            XCTFail("expected rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("reason"))
        }
    }

    /// Reopening and discarding stay with the user; the tool only closes out.
    func testRefusesStatusesOutsideItsRemit() async {
        for status in ["active", "abandoned", "approved", "draft"] {
            do {
                _ = try await makeTool(CloseCapture()).execute(
                    inputJSON: #"{"status": "\#(status)", "reason": "r"}"#)
                XCTFail("expected rejection for \(status)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("status"))
            }
        }
    }

    func testSchemaOffersOnlyTheClosableStatuses() {
        let schema = ProgramTools.closeBranchTool(
            branchPlanID: "b1", branchTitle: "T") { _, _ in }.spec.inputSchemaJSON
        XCTAssertTrue(schema.contains("\"failed\""))
        XCTAssertTrue(schema.contains("\"done\""))
        XCTAssertTrue(schema.contains("\"paused\""))
        XCTAssertFalse(schema.contains("\"abandoned\""))
        XCTAssertFalse(schema.contains("\"active\""))
    }
}

final class ProgramContextTests: XCTestCase {

    private let memory = """
    ## Goal
    GOAL-SENTINEL: settle conj-gamma2-doubling.

    ## Current Status
    STATUS-SENTINEL: three branches running.

    ## Active Strategies
    ACTIVE-SENTINEL: discharging looks best.

    ## Eliminated Strategies
    ELIMINATED-SENTINEL: naive induction — uncontrolled invariant.

    ## Key Insights
    INSIGHT-SENTINEL: the conjecture looks true for δ ≥ 3.

    ## Next Steps
    NEXT-SENTINEL: scan to n=12.
    """

    /// Facts cross; beliefs do not. Shared beliefs are exactly what would collapse a
    /// portfolio of contradictory approaches back into one line of thought.
    func testSharedFactsCarryGoalAndEliminatedButNoBeliefs() throws {
        let section = try XCTUnwrap(ProgramContext.sharedFactsSection(
            projectMemory: memory, routedFindings: []))

        XCTAssertTrue(section.contains("GOAL-SENTINEL"))
        XCTAssertTrue(section.contains("ELIMINATED-SENTINEL"))
        XCTAssertFalse(section.contains("INSIGHT-SENTINEL"))
        XCTAssertFalse(section.contains("STATUS-SENTINEL"))
        XCTAssertFalse(section.contains("ACTIVE-SENTINEL"))
        XCTAssertFalse(section.contains("NEXT-SENTINEL"))
    }

    func testRoutedFindingsRenderWithTheirItemsAndEvidence() throws {
        let findings = [
            ProgramFinding(branchPlanID: "branch-b", kind: .reduction, statement: "SIBLING-FINDING",
                           itemIDs: ["lem-x"], artifactPath: "artifacts/run-1/stdout.txt")
        ]
        let section = try XCTUnwrap(ProgramContext.sharedFactsSection(
            projectMemory: memory, routedFindings: findings))

        XCTAssertTrue(section.contains("SIBLING-FINDING"))
        XCTAssertTrue(section.contains("lem-x"))
        XCTAssertTrue(section.contains("artifacts/run-1/stdout.txt"))
        // Unreviewed by default (no verdict set above) — a sibling must be told this is the
        // publishing branch's own claim, not read it as indistinguishable from a checked fact.
        XCTAssertTrue(section.contains("UNVERIFIED"))
    }

    /// A finding the user ruled wrong must not reach a sibling — otherwise the error
    /// compounds through every branch that builds on it. Selection is the manifest's job now,
    /// so this is where it is pinned.
    func testRejectedAndUnroutedFindingsNeverReachABranch() {
        var program = ResearchProgram(id: "p", goal: "g", branches: [
            .init(planID: "branch-a", title: "A"), .init(planID: "branch-b", title: "B")
        ])
        program.findings = [
            ProgramFinding(id: "f1", branchPlanID: "branch-b", kind: .evidence,
                           statement: "REJECTED-CLAIM", verdict: .rejected),
            ProgramFinding(id: "f2", branchPlanID: "branch-b", kind: .obstruction,
                           statement: "ROUTED-CLAIM"),
            ProgramFinding(id: "f3", branchPlanID: "branch-b", kind: .reduction,
                           statement: "UNROUTED-CLAIM"),
            ProgramFinding(id: "f4", branchPlanID: "branch-a", kind: .evidence,
                           statement: "OWN-CLAIM")
        ]
        // Even a routed rejection stays out; an unrouted finding reaches nobody at all.
        program.setRouting(.init(findingID: "f1", decision: .global))
        program.setRouting(.init(findingID: "f2", decision: .sendNow,
                                 recipientPlanIDs: ["branch-a"]))
        program.setRouting(.init(findingID: "f4", decision: .global))

        let statements = program.findings(routedTo: "branch-a").map(\.statement)
        XCTAssertEqual(statements, ["ROUTED-CLAIM"])
    }

    /// The rule the whole routing mechanism exists for: a real, correct finding the director
    /// chose to hold must not appear in a sibling's context.
    func testAHeldFindingDoesNotReachASibling() {
        var program = ResearchProgram(id: "p", goal: "g", branches: [
            .init(planID: "branch-a", title: "A"), .init(planID: "branch-b", title: "B")
        ])
        program.findings = [
            ProgramFinding(id: "f1", branchPlanID: "branch-b", kind: .reduction,
                           statement: "ROUTE-SPECIFIC-PROGRESS")
        ]
        program.setRouting(.init(findingID: "f1", decision: .hold,
                                 rationale: "only meaningful inside b's approach"))

        XCTAssertTrue(program.findings(routedTo: "branch-a").isEmpty)
        // It is still on the program — held, not discarded.
        XCTAssertEqual(program.circulatingFindings.count, 1)
    }

    func testGlobalRoutingReachesEveryBranchButTheOriginator() {
        var program = ResearchProgram(id: "p", goal: "g", branches: [
            .init(planID: "branch-a", title: "A"), .init(planID: "branch-b", title: "B")
        ])
        program.findings = [
            ProgramFinding(id: "f1", branchPlanID: "branch-b", kind: .obstruction,
                           statement: "FATAL-TO-EVERYONE")
        ]
        program.setRouting(.init(findingID: "f1", decision: .global))

        XCTAssertEqual(program.findings(routedTo: "branch-a").count, 1)
        XCTAssertTrue(program.findings(routedTo: "branch-b").isEmpty,
                      "the originator already knows")
    }

    func testConfirmedFindingsAreMarkedAsChecked() throws {
        let findings = [
            ProgramFinding(branchPlanID: "branch-b", kind: .reduction, statement: "SOLID-CLAIM",
                           verdict: .confirmed, verdictNote: "verified by hand")
        ]
        let section = try XCTUnwrap(ProgramContext.sharedFactsSection(
            projectMemory: memory, routedFindings: findings))

        XCTAssertTrue(section.contains("SOLID-CLAIM"))
        XCTAssertTrue(section.contains("CONFIRMED"))
        XCTAssertTrue(section.contains("verified by hand"))
        XCTAssertFalse(section.contains("UNVERIFIED"), "a confirmed finding is not also provisional")
    }

    func testOnlyRejectedSiblingFindingsMeansNoFindingsToShare() throws {
        let section = try XCTUnwrap(ProgramContext.sharedFactsSection(
            projectMemory: memory,
            routedFindings: []))
        XCTAssertFalse(section.contains("NOPE"))
        XCTAssertTrue(section.contains("nothing has been routed to this branch"))
    }

    func testNothingToShareYieldsNoSection() {
        XCTAssertNil(ProgramContext.sharedFactsSection(
            projectMemory: "", routedFindings: []))
    }

    func testFindingsAloneStillRenderASection() throws {
        let section = try XCTUnwrap(ProgramContext.sharedFactsSection(
            projectMemory: "",
            routedFindings: [ProgramFinding(branchPlanID: "b", kind: .counterexample,
                                            statement: "W6 breaks it")]))
        XCTAssertTrue(section.contains("W6 breaks it"))
        XCTAssertFalse(section.contains("{{"))
    }

    /// Prove-task findings are derived from the outcome, never claimed by a model.
    func testProveOutcomeBecomesAFindingOnlyOnACleanReview() {
        let clean = ProofWorkbench.Outcome(
            finalStatus: .reviewedNoErrors, roundsUsed: 2, proposalCount: 1,
            externalsUsed: [], outstandingIssues: [])
        let finding = ProgramContext.finding(fromProveOutcome: clean, targetID: "lem-key",
                                             branchPlanID: "branch-a")
        XCTAssertEqual(finding?.kind, .proofOutcome)
        XCTAssertEqual(finding?.itemIDs, ["lem-key"])
        XCTAssertTrue(finding?.statement.contains("evidence, not certainty") ?? false)

        let drafted = ProofWorkbench.Outcome(
            finalStatus: .proofDrafted, roundsUsed: 3, proposalCount: 1,
            externalsUsed: [], outstandingIssues: [])
        XCTAssertNil(ProgramContext.finding(fromProveOutcome: drafted, targetID: "lem-key",
                                            branchPlanID: "branch-a"))

        let withIssues = ProofWorkbench.Outcome(
            finalStatus: .reviewedNoErrors, roundsUsed: 3, proposalCount: 1,
            externalsUsed: [],
            outstandingIssues: [ReviewIssue(location: "step 3", severity: "gap", description: "hole")])
        XCTAssertNil(ProgramContext.finding(fromProveOutcome: withIssues, targetID: "lem-key",
                                            branchPlanID: "branch-a"),
                     "outstanding issues mean there is nothing worth telling siblings")
    }
}
