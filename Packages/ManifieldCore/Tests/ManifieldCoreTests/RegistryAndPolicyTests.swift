import XCTest
@testable import ManifieldCore

final class ResearchRouteTests: XCTestCase {

    private func routes() -> [ResearchRoute] {
        [
            ResearchRoute(mechanism: "second-moment anti-concentration", status: .falsified,
                          obstruction: "capped at 2^k/sqrt(k)"),
            ResearchRoute(mechanism: "modular orbit constructions", status: .falsified,
                          obstruction: "no k=10 block below the benchmark"),
            ResearchRoute(mechanism: "exact certification by branch and bound", status: .active,
                          nextTest: "certify m(10)")
        ]
    }

    func testTheClosedRouteDigestCarriesEveryFalsifiedMechanismAndItsCause() {
        let digest = try? XCTUnwrap(routes().closedRouteDigest)
        let text = digest ?? ""
        XCTAssertTrue(text.contains("second-moment anti-concentration"))
        XCTAssertTrue(text.contains("capped at 2^k/sqrt(k)"), "why it died is the useful half")
        XCTAssertTrue(text.contains("modular orbit constructions"))
        XCTAssertFalse(text.contains("exact certification"), "live routes are not warnings")
    }

    func testNoDigestWhenNothingHasBeenRuledOut() {
        XCTAssertNil([ResearchRoute(mechanism: "m", status: .active)].closedRouteDigest)
    }

    func testLiveRoutesExcludeClosedOnes() {
        XCTAssertEqual(routes().liveRoutes.map(\.mechanism), ["exact certification by branch and bound"])
    }

    func testARouteLineShowsTheNextTestOnlyWhileItIsLive() {
        let live = ResearchRoute(mechanism: "m", status: .active, nextTest: "run it")
        XCTAssertTrue(live.line.contains("next: run it"))
        let dead = ResearchRoute(mechanism: "m", status: .falsified,
                                 obstruction: "it fails", nextTest: "run it")
        XCTAssertTrue(dead.line.contains("died on: it fails"))
        XCTAssertFalse(dead.line.contains("next:"))
    }

    func testRoutesSurviveAProgramRoundTrip() throws {
        let original = routes()          // ids are minted per call, so capture once
        let program = ResearchProgram(id: "p", goal: "g", routes: original)
        let decoded = try JSONDecoder().decode(
            ResearchProgram.self, from: try JSONEncoder().encode(program))
        XCTAssertEqual(decoded.routes, original)
    }
}

final class ProofObligationTests: XCTestCase {

    private func item(_ id: String, _ status: ItemStatus, dependsOn: [String] = []) -> TheoryItem {
        TheoryItem(id: id, type: .lemma, name: id, status: status,
                   dependsOn: dependsOn, body: "## Statement\nx")
    }

    func testAnEstablishedItemRestingOnAConjectureIsAnOpenObligation() {
        let obligations = ProofObligations.open(items: [
            item("thm-main", .proofDrafted, dependsOn: ["lem-a"]),
            item("lem-a", .conjecture)
        ])
        XCTAssertEqual(obligations.map(\.itemID), ["thm-main"])
        XCTAssertEqual(obligations.first?.unprovedDependencies, ["lem-a"])
    }

    /// The gap this catches: evidence on small cases presented as though it settled the claim.
    func testTestedIsNotEstablished() {
        let obligations = ProofObligations.open(items: [
            item("thm-main", .proofDrafted, dependsOn: ["lem-a"]),
            item("lem-a", .tested)
        ])
        XCTAssertEqual(obligations.first?.unprovedDependencies, ["lem-a"])
    }

    func testTheSearchIsTransitive() {
        let obligations = ProofObligations.open(items: [
            item("thm-main", .reviewedNoErrors, dependsOn: ["lem-a"]),
            item("lem-a", .proofDrafted, dependsOn: ["lem-b"]),
            item("lem-b", .conjecture)
        ])
        XCTAssertEqual(obligations.map(\.itemID), ["lem-a", "thm-main"])
        XCTAssertEqual(obligations.last?.unprovedDependencies, ["lem-b"])
    }

    func testAFullyEstablishedChainHasNoObligations() {
        XCTAssertTrue(ProofObligations.open(items: [
            item("thm-main", .proofDrafted, dependsOn: ["lem-a"]),
            item("lem-a", .humanApproved),
            item("conj-idle", .conjecture)
        ]).isEmpty, "a conjecture nobody leans on is not an obligation")
    }

    func testADanglingDependencyCounts() {
        let obligations = ProofObligations.open(items: [
            item("thm-main", .proofDrafted, dependsOn: ["lem-missing"])
        ])
        XCTAssertEqual(obligations.first?.unprovedDependencies, ["lem-missing"])
    }

    func testACycleDoesNotHang() {
        let obligations = ProofObligations.open(items: [
            item("a", .proofDrafted, dependsOn: ["b"]),
            item("b", .proofDrafted, dependsOn: ["a"])
        ])
        XCTAssertTrue(obligations.isEmpty, "mutually-supporting established items raise nothing here")
    }
}

final class ContinuationPolicyTests: XCTestCase {

    func testManualIsTheOldBehaviour() {
        let policy = ContinuationPolicy.manual
        XCTAssertFalse(policy.isUnattended)
        XCTAssertFalse(policy.autoContinueCheckpoints)
        XCTAssertEqual(policy.questionHandling, .alwaysPause)
    }

    /// Level 2 of the supervision dial: runs the night, still stops for the things that matter.
    func testOvernightRunsUnattendedButStillAsksAboutTheStatement() {
        let policy = ContinuationPolicy.overnight
        XCTAssertTrue(policy.isUnattended)
        XCTAssertTrue(policy.autoContinueCheckpoints)
        XCTAssertEqual(policy.questionHandling, .assumeTaskLevel)
        XCTAssertEqual(policy.budgetStepTokens, 0)
        XCTAssertEqual(policy.maxBudgetRaises, 0)
    }

    func testTheWallClockCeilingFires() {
        let policy = ContinuationPolicy.overnight
        let start = Date()
        XCTAssertFalse(policy.hasExceededWallClock(since: start, now: start.addingTimeInterval(60)))
        XCTAssertTrue(policy.hasExceededWallClock(
            since: start, now: start.addingTimeInterval(policy.maxWallClockSeconds + 1)))
    }

    func testNoWallClockLimitNeverFires() {
        XCTAssertFalse(ContinuationPolicy.manual.hasExceededWallClock(
            since: .distantPast, now: Date()))
    }

    func testAPolicySurvivesAProgramRoundTrip() throws {
        let program = ResearchProgram(id: "p", goal: "g", continuation: .overnight)
        let decoded = try JSONDecoder().decode(
            ResearchProgram.self, from: try JSONEncoder().encode(program))
        XCTAssertEqual(decoded.continuation, ContinuationPolicy.overnight)
    }

    /// Level 3: nothing stops it but its budgets. It still adjudicates a counterexample —
    /// "nobody is watching" is the reason to verify the claim, not to skip verifying it.
    func testFullAutoProceedsOnEveryQuestionButStillVerifies() {
        let policy = ContinuationPolicy.fullAuto
        XCTAssertTrue(policy.isUnattended)
        XCTAssertEqual(policy.questionHandling, .assumeAll)
        XCTAssertTrue(policy.autoAdjudicateCounterexamples)
        XCTAssertEqual(policy.budgetStepTokens, 0)
        XCTAssertEqual(policy.maxBudgetRaises, 0)
        XCTAssertTrue(ContinuationPolicy.overnight.autoAdjudicateCounterexamples)
        XCTAssertFalse(ContinuationPolicy.manual.autoAdjudicateCounterexamples,
                       "a supervised program keeps the human gate")
    }

    /// A manifest written before adjudication existed must keep loading, with the field at
    /// its safe default — the whole program file failing to decode would lose the run. The
    /// JSON here also carries "maxGenerations", from a manifest written before that was
    /// retired: a key the decoder has no case for is simply not read, not a decode failure.
    func testPolicyWrittenBeforeAdjudicationStillDecodes() throws {
        let json = """
        {"autoContinueCheckpoints":true,"budgetStepTokens":500000,"maxBudgetRaises":4,
         "questionHandling":"assume_task_level","maxWallClockSeconds":43200,"maxGenerations":3}
        """
        let decoded = try JSONDecoder().decode(
            ContinuationPolicy.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.autoAdjudicateCounterexamples)
        XCTAssertEqual(decoded.questionHandling, .assumeTaskLevel)
        XCTAssertEqual(decoded.maxWallClockSeconds, 43200)
    }
}
