import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class DirectorProvider: LLMProvider, @unchecked Sendable {
    var description: String { "director-scripted" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var _requests: [LLMRequest] = []
    var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        _requests.append(request)
        let events = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private func directorCall(_ name: String, _ json: String) -> [LLMEvent] {
    [.toolUseFinished(id: UUID().uuidString, name: name, inputJSON: json), .finished(.toolUse)]
}

final class DirectorMechanismGuardTests: XCTestCase {

    func testTheSameMechanismInDifferentWordsIsRecognised() {
        XCTAssertTrue(ProposeRoutesTool.isSameMechanism(
            "anti-concentration via the second moment",
            "second-moment anti-concentration"))
    }

    func testDifferentMechanismsAreNotConflated() {
        XCTAssertFalse(ProposeRoutesTool.isSameMechanism(
            "anti-concentration via the second moment",
            "algebraic construction from modular orbits"))
    }

    func testAFalsifiedRouteCannotBeReproposed() async {
        let signals = DirectorSignals()
        let tool = ProposeRoutesTool(
            signals: signals,
            existingRoutes: [ResearchRoute(
                mechanism: "second-moment anti-concentration",
                status: .falsified,
                obstruction: "capped at 2^k/sqrt(k)")],
            generation: 2)
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"routes":[{"mechanism":"anti-concentration via the second moment","next_test":"x"},
                       {"mechanism":"modular orbit constructions","next_test":"y"}]}
            """#)
            XCTFail("expected the dead route to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("died on: capped at 2^k/sqrt(k)"),
                          "the refusal tells the director why it died: \(error.localizedDescription)")
        }
    }

    func testTwoProposedRoutesSharingAMechanismAreRefused() async {
        let tool = ProposeRoutesTool(signals: DirectorSignals(), existingRoutes: [], generation: 2)
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"routes":[{"mechanism":"greedy local repair search","next_test":"a"},
                       {"mechanism":"local repair greedy search","next_test":"b"}]}
            """#)
            XCTFail("routes that fail for the same reason are one route")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("one route"))
        }
    }

    func testARouteWithoutADecisiveTestIsRefused() async {
        let tool = ProposeRoutesTool(signals: DirectorSignals(), existingRoutes: [], generation: 2)
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"routes":[{"mechanism":"a"},{"mechanism":"b","next_test":"y"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not ready to be a route"))
        }
    }
}

final class DirectorProgressSignalTests: XCTestCase {

    private func program(findings: [ProgramFinding]) -> ResearchProgram {
        ResearchProgram(id: "p", goal: "g", findings: findings)
    }

    func testInitialPlanningIsNotReportedAsAStall() {
        let signal = Director.progressSignal(program: program(findings: []), records: [:],
                                             generation: 1, findingsBefore: 0)
        XCTAssertTrue(signal.isInitialPlanning)
        XCTAssertFalse(signal.isStalled)
        XCTAssertFalse(signal.promptLine.contains("NOTHING NEW WAS LEARNED"))
    }

    func testOnlyInformativeFindingsCountAsProgress() {
        // A branch restating its own position is not new information about the problem.
        let signal = Director.progressSignal(
            program: program(findings: [
                .init(branchPlanID: "b", kind: .lensAbandoned, statement: "gave up"),
                .init(branchPlanID: "b", kind: .candidateAnswer, statement: "maybe 84")
            ]),
            records: [:], generation: 1, findingsBefore: 0)
        XCTAssertEqual(signal.newFindings, 0)
        XCTAssertTrue(signal.isStalled)
    }

    func testEvidenceAndObstructionsCount() {
        let signal = Director.progressSignal(
            program: program(findings: [
                .init(branchPlanID: "b", kind: .evidence, statement: "m(8)=84"),
                .init(branchPlanID: "b", kind: .obstruction, statement: "capped")
            ]),
            records: [:], generation: 1, findingsBefore: 0)
        XCTAssertEqual(signal.newFindings, 2)
        XCTAssertFalse(signal.isStalled)
    }

    func testFindingsFromEarlierGenerationsAreNotCountedAgain() {
        let signal = Director.progressSignal(
            program: program(findings: [
                .init(branchPlanID: "b", kind: .evidence, statement: "old"),
                .init(branchPlanID: "b", kind: .evidence, statement: "new")
            ]),
            records: [:], generation: 2, findingsBefore: 1)
        XCTAssertEqual(signal.newFindings, 1)
    }

    func testARejectedFindingIsNotProgress() {
        var rejected = ProgramFinding(branchPlanID: "b", kind: .evidence, statement: "wrong")
        rejected.verdict = .rejected
        let signal = Director.progressSignal(
            program: program(findings: [rejected]), records: [:],
            generation: 1, findingsBefore: 0)
        XCTAssertEqual(signal.newFindings, 0)
    }

    func testTheStallIsStatedPlainlyInThePrompt() {
        let signal = Director.progressSignal(
            program: program(findings: []), records: [:], generation: 2, findingsBefore: 0)
        XCTAssertTrue(signal.promptLine.contains("NOTHING NEW WAS LEARNED"))
    }
}

final class DirectorDecisionTests: XCTestCase {

    private func program() -> ResearchProgram {
        ResearchProgram(
            id: "p", goal: "Settle conj-x",
            contract: SuccessContract(
                statement: "S",
                completeAnswers: [
                    .init(id: "A1", statement: "a proof of the theorem", evidence: "review"),
                    .init(id: "A2", statement: "a counterexample", evidence: "a verified witness")
                ],
                completenessRationale: "The statement is either true or false."),
            branches: [.init(planID: "b1", title: "First", challengesLeadingAnswer: true)],
            routes: [ResearchRoute(mechanism: "second-moment anti-concentration",
                                   status: .falsified, obstruction: "capped")])
    }

    private func signal() -> Director.ProgressSignal {
        Director.progressSignal(program: program(), records: [:],
                                generation: 1, findingsBefore: 0)
    }

    func testAContinueVerdictCarriesItsRoutes() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"continue","rationale":"the computational route is untouched",
             "status":"Anti-concentration is ruled out; trying exact certification next."}
            """#),
            directorCall("propose_routes", #"""
            {"routes":[{"mechanism":"exact certification by branch and bound","next_test":"certify k=10"},
                       {"mechanism":"modular orbit constructions","next_test":"sweep p<=300"}]}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)

        let unwrapped = try XCTUnwrap(decision)
        XCTAssertEqual(unwrapped.verdict, .continue)
        XCTAssertEqual(unwrapped.routes.count, 2)
        XCTAssertEqual(unwrapped.routes.first?.generation, 2)
        XCTAssertFalse(unwrapped.status.isEmpty, "the status line is the research page's copy")
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.system.text.contains("do not assume the conclusion or presupposition"))
        let routeTool = try XCTUnwrap(request.tools.first { $0.name == "propose_routes" })
        XCTAssertTrue(routeTool.description.contains("Do not list the conclusion or presupposition"))
    }

    /// dispatch_worker is the other half of `continue` — a decisive small dispatch, no route
    /// or portfolio needed. Each call adds one assignment, unlike propose_routes' single slate.
    func testAContinueVerdictCarriesItsWorkerAssignments() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"continue","rationale":"one decisive dispatch settles the gap",
             "status":"Dispatching a worker to close the residual case."}
            """#),
            directorCall("dispatch_worker", #"""
            {"objective":"close the residual case by direct computation",
             "stop_condition":"the case is closed or ruled out","token_budget":150000,
             "model_tier":"strong"}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)

        let unwrapped = try XCTUnwrap(decision)
        XCTAssertEqual(unwrapped.verdict, .continue)
        XCTAssertTrue(unwrapped.routes.isEmpty)
        XCTAssertEqual(unwrapped.workerAssignments.count, 1)
        let assignment = try XCTUnwrap(unwrapped.workerAssignments.first)
        XCTAssertEqual(assignment.objective, "close the residual case by direct computation")
        XCTAssertEqual(assignment.stopCondition, "the case is closed or ruled out")
        XCTAssertEqual(assignment.tokenBudget, 150_000)
        XCTAssertEqual(assignment.modelTier, "strong")
        XCTAssertEqual(assignment.targetRevisionID, program().activeTargetRevisionID)
        XCTAssertNil(assignment.planID, "not built into a branch until the runner admits it")
    }

    /// A dispatch alone, with no routes at all, is still a real continuation — the downgrade
    /// guard must not treat "no routes" as "nothing to do" once dispatch_worker exists.
    func testContinueWithOnlyWorkerAssignmentsIsNotDowngraded() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"continue","rationale":"a small dispatch is all this needs",
             "status":"Dispatching."}
            """#),
            directorCall("dispatch_worker", #"""
            {"objective":"check the n=7 case exactly","stop_condition":"the case is decided"}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)

        XCTAssertEqual(try XCTUnwrap(decision).verdict, .continue,
                       "a real dispatch must not be downgraded just because routes is empty")
    }

    /// A continuation with nothing in it is not a continuation.
    func testContinueWithNoRoutesIsDowngradedToFutile() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"continue","rationale":"more work exists","status":"Carrying on."}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)

        XCTAssertEqual(try XCTUnwrap(decision).verdict, .futile)
        XCTAssertTrue(try XCTUnwrap(decision).rationale.contains("downgraded"))
    }

    /// `maxGenerations` is retired: nothing about a high generation count narrows the verdict
    /// schema any more. Token, wall-clock, and concurrency budgets are the only ceilings left,
    /// and those stop admission before the director is ever convened — they never reach here
    /// as a reason `continue` isn't offered.
    func testContinueIsAlwaysOfferedRegardlessOfGeneration() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"futile","rationale":"nothing left","status":"Stopping."}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        _ = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 40)

        let schema = try XCTUnwrap(provider.requests.first?.tools
            .first { $0.name == "set_program_verdict" }?.inputSchemaJSON)
        XCTAssertTrue(schema.contains("continue"),
                      "no generation count narrows what the director may choose any more")
    }

    func testTheDirectorSeesTheRegistryAndTheProgressSignal() async throws {
        let provider = DirectorProvider(scripts: [
            directorCall("set_program_verdict", #"""
            {"verdict":"futile","rationale":"r","status":"s"}
            """#),
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        _ = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)

        let system = try XCTUnwrap(provider.requests.first?.system.text)
        XCTAssertTrue(system.contains("second-moment anti-concentration"),
                      "the registry is the director's memory of what died")
        XCTAssertTrue(system.contains("NOTHING NEW WAS LEARNED"),
                      "the futility signal is computed and injected, never asked for")
        XCTAssertTrue(system.contains("Research goal"))
    }

    func testNoVerdictMeansNoDecision() async throws {
        let provider = DirectorProvider(scripts: [
            [.textDelta("I am thinking about it."), .finished(.endTurn)]
        ])
        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program(), records: [:], signal: signal(),
            generation: 1)
        XCTAssertNil(decision, "the caller must not invent a verdict the director did not give")
    }
}

/// A finding's trust state was always representable (`verdict == nil` already meant
/// unreviewed), but nothing said so explicitly at the one point that matters — the message a
/// recipient actually reads. These pin that the routing turn's own view carries the same
/// label `ProgramContext.sharedFactsSection` puts in front of the receiving branch.
final class DirectorRoutingTrustLabelTests: XCTestCase {

    func testAnUnreviewedFindingIsLabeledProvisionalNotLeftSilent() {
        let finding = ProgramFinding(
            branchPlanID: "b1", kind: .evidence, statement: "the bound holds for n<50")
        let message = Director.routingUserMessage([finding])
        XCTAssertTrue(message.contains("PROVISIONAL"))
        XCTAssertTrue(message.contains("hypothesis"))
    }

    func testAConfirmedFindingIsNotAlsoLabeledProvisional() {
        var finding = ProgramFinding(
            branchPlanID: "b1", kind: .evidence, statement: "the bound holds for n<50")
        finding.verdict = .confirmed
        let message = Director.routingUserMessage([finding])
        XCTAssertTrue(message.contains("CONFIRMED"))
        XCTAssertFalse(message.contains("PROVISIONAL"))
    }
}
