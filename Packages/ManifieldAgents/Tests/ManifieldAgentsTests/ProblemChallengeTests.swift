import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class ProblemChallengeProvider: LLMProvider, @unchecked Sendable {
    var description: String { "problem-challenge-scripted" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var _requests: [LLMRequest] = []

    init(_ scripts: [[LLMEvent]]) { self.scripts = scripts }

    var requests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

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

private func challengeReviewCall(
    accepted: Bool,
    note: String,
    targetDisposition: ProblemChallenge.ReviewRuling.TargetDisposition? = nil
) -> [LLMEvent] {
    let disposition = targetDisposition.map { ",\"target_disposition\":\"\($0.rawValue)\"" } ?? ""
    return [.toolUseFinished(
        id: UUID().uuidString,
        name: "report_problem_challenge_review",
        inputJSON: "{\"accepted\":\(accepted),\"note\":\"\(note)\"\(disposition)}"),
     .finished(.toolUse)]
}

private final class ChallengeProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [ProblemChallenge] = []
    func append(_ challenge: ProblemChallenge) {
        lock.lock(); _values.append(challenge); lock.unlock()
    }
    var values: [ProblemChallenge] {
        lock.lock(); defer { lock.unlock() }; return _values
    }
}

private final class FiledChallengeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (String, String?, String?, [String])?
    var value: (String, String?, String?, [String])? {
        lock.lock(); defer { lock.unlock() }; return _value
    }
    func set(_ description: String, _ replacement: String?, _ itemID: String?, _ evidence: [String]) {
        lock.lock(); _value = (description, replacement, itemID, evidence); lock.unlock()
    }
}

final class ProblemChallengeToolTests: XCTestCase {

    func testChallengeIsFreeformAndSupportsNonThesisRequests() async throws {
        let capture = FiledChallengeCapture()
        let signals = TaskSignals()
        let tool = ProgramTools.problemChallengeTool(
            branchPlanID: "classification-branch", signals: signals
        ) { description, replacement, itemID, evidence in
            capture.set(description, replacement, itemID, evidence)
            return "challenge-1"
        }

        let schema = tool.spec.inputSchemaJSON
        XCTAssertFalse(schema.contains("category"))
        XCTAssertFalse(schema.contains("outcome"))
        XCTAssertFalse(schema.contains("assertion_false"))

        let reply = try await tool.execute(inputJSON: #"""
        {"description":"The classification domain uses n without defining or quantifying it.",
         "proposed_replacement_request":"Classify the groups separately for each specified n.",
         "proposed_target_item_id":"qst-classification-corrected",
         "evidence_item_ids":["def-domain"]}
        """#)

        XCTAssertEqual(capture.value?.0,
                       "The classification domain uses n without defining or quantifying it.")
        XCTAssertEqual(capture.value?.1, "Classify the groups separately for each specified n.")
        XCTAssertEqual(capture.value?.2, "qst-classification-corrected")
        XCTAssertEqual(capture.value?.3, ["def-domain"])
        XCTAssertEqual(signals.problemChallenge, "challenge-1")
        XCTAssertEqual(signals.outcome?.kind, .completed)
        XCTAssertTrue(reply.contains("changes nothing yet"))
    }

    func testChallengeDescriptionRejectsConvenienceAndRequiresConcreteDefect() async {
        let signals = TaskSignals()
        let tool = ProgramTools.problemChallengeTool(
            branchPlanID: "b", signals: signals
        ) { _, _, _, _ in "never" }

        XCTAssertTrue(tool.spec.description.contains("not for a hard problem"))
        XCTAssertTrue(tool.spec.description.contains("correction forced by the defect"))
        do {
            _ = try await tool.execute(inputJSON: #"{"description":"   "}"#)
            XCTFail("an empty freeform challenge must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("actual defect"))
        }
        XCTAssertNil(signals.problemChallenge)
    }

    func testClaimSolutionExplainsTheChallengeBoundary() {
        let tool = ClaimSolutionTool(
            branchPlanID: "b", contract: nil, signals: TaskSignals(),
            claim: { _, _, _, _ in "candidate" })
        XCTAssertTrue(tool.spec.description.contains("goal Statement remains valid"))
        XCTAssertTrue(tool.spec.description.contains("submit_problem_challenge"))
        XCTAssertTrue(tool.spec.description.contains("impossible as written"))
    }
}

final class ProblemChallengeReviewerTests: XCTestCase {

    private let target = ResearchTargetRevision(
        id: "r1", requestText: "Classify all groups satisfying C.")

    func testReviewUsesSeparateMathematicalAndScopeGates() async throws {
        let provider = ProblemChallengeProvider([
            challengeReviewCall(accepted: true, note: "the domain parameter is unbound"),
            [.textDelta("Mathematical ruling filed."), .finished(.endTurn)],
            challengeReviewCall(accepted: true, note: "adding its quantifier is the minimal repair"),
            [.textDelta("Scope ruling filed."), .finished(.endTurn)]
        ])
        let challenge = ProblemChallenge(
            id: "c1", branchPlanID: "b", targetRevisionID: target.id,
            description: "The classification domain contains an unbound parameter.",
            proposedReplacementRequest: "For every n, classify the groups.",
            proposedTargetItemID: "qst-corrected", proposedTargetItemType: .question,
            proposedTargetItemData: Data("CORRECTED-TARGET-SENTINEL".utf8))

        let reviewed = try await ProblemChallengeReviewer.review(
            challenge: challenge, target: target, items: [], tools: [],
            runner: AgentLoop(provider: provider))

        XCTAssertEqual(reviewed.status, .accepted)
        XCTAssertEqual(reviewed.mathematicalRuling?.accepted, true)
        XCTAssertEqual(reviewed.scopeRuling?.accepted, true)
        XCTAssertEqual(provider.requests.count, 4)
        XCTAssertTrue(provider.requests[0].system.text.contains("mathematical reviewer"))
        XCTAssertTrue(provider.requests[0].system.text.contains("Classify all groups"))
        XCTAssertTrue(provider.requests[0].system.text.contains("not force it into a fixed taxonomy"))
        XCTAssertTrue(provider.requests[0].messages.first?.plainText
            .contains("CORRECTED-TARGET-SENTINEL") == true)
        XCTAssertTrue(provider.requests[2].system.text.contains("scope and necessity reviewer"))
        XCTAssertTrue(provider.requests[2].system.text.contains("smallest correction"))
    }

    func testMathematicalRejectionDoesNotRunScopeGate() async throws {
        let provider = ProblemChallengeProvider([
            challengeReviewCall(accepted: false, note: "the cited family does satisfy C"),
            [.textDelta("Rejected."), .finished(.endTurn)]
        ])
        let challenge = ProblemChallenge(
            id: "c1", branchPlanID: "b", targetRevisionID: target.id,
            description: "The requested objects do not exist.")

        let reviewed = try await ProblemChallengeReviewer.review(
            challenge: challenge, target: target, items: [], tools: [],
            runner: AgentLoop(provider: provider))

        XCTAssertEqual(reviewed.status, .mathematicalRejected)
        XCTAssertNil(reviewed.scopeRuling)
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testReviewReadsFiledEvidenceBytesNotLaterLiveEdits() async throws {
        let filed = Data("---\nid: lem-evidence\ntype: lemma\nname: Evidence\nstatus: tested\n---\n\nFILED-SENTINEL".utf8)
        let live = TheoryItem(
            id: "lem-evidence", type: .lemma, name: "Evidence",
            status: .tested, body: "LIVE-EDIT-SENTINEL")
        let provider = ProblemChallengeProvider([
            challengeReviewCall(accepted: false, note: "not enough"),
            [.textDelta("Rejected."), .finished(.endTurn)]
        ])
        let challenge = ProblemChallenge(
            id: "c1", branchPlanID: "b", targetRevisionID: target.id,
            description: "The domain is empty.", evidenceItemIDs: ["lem-evidence"],
            evidenceItemData: ["lem-evidence": filed],
            evidenceItemSnapshots: ["lem-evidence": ResearchTargetRevision.sha256(filed)])

        _ = try await ProblemChallengeReviewer.review(
            challenge: challenge, target: target, items: [live], tools: [],
            runner: AgentLoop(provider: provider))

        let message = try XCTUnwrap(provider.requests.first?.messages.first?.plainText)
        XCTAssertTrue(message.contains("FILED-SENTINEL"))
        XCTAssertFalse(message.contains("LIVE-EDIT-SENTINEL"))
        XCTAssertTrue(message.contains(ResearchTargetRevision.sha256(filed)))
    }

    func testInterruptedScopePersistsAcceptedMathematicalGateAndRetryDoesNotRepeatIt() async throws {
        let provider = ProblemChallengeProvider([
            challengeReviewCall(accepted: true, note: "the parameter is unbound"),
            [.textDelta("Mathematical ruling filed."), .finished(.endTurn)],
            [.textDelta("Scope review was interrupted."), .finished(.endTurn)],
            challengeReviewCall(accepted: true, note: "quantifying it is the minimal repair",
                                targetDisposition: .partialInvalidity),
            [.textDelta("Scope ruling filed."), .finished(.endTurn)]
        ])
        let challenge = ProblemChallenge(
            id: "c-resume", branchPlanID: "b", targetRevisionID: target.id,
            description: "The classification domain contains an unbound parameter.",
            evidenceItemIDs: ["def-domain"],
            evidenceItemData: ["def-domain": Data("FROZEN-EVIDENCE".utf8)])
        let progress = ChallengeProgressCapture()

        do {
            _ = try await ProblemChallengeReviewer.review(
                challenge: challenge, target: target, items: [], tools: [],
                runner: AgentLoop(provider: provider),
                onProgress: { progress.append($0) })
            XCTFail("scope review without a ruling must remain pending")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("without a ruling"))
        }

        let pending = try XCTUnwrap(progress.values.last)
        XCTAssertEqual(progress.values.map(\.status), [.mathematicalReview, .scopeReview])
        XCTAssertEqual(pending.status, .scopeReview)
        XCTAssertEqual(pending.mathematicalRuling?.accepted, true)
        XCTAssertNil(pending.scopeRuling)
        let mathematicalRequestsBeforeRetry = provider.requests.filter {
            $0.system.text.contains("mathematical reviewer")
        }.count

        let reviewed = try await ProblemChallengeReviewer.review(
            challenge: pending, target: target, items: [], tools: [],
            runner: AgentLoop(provider: provider),
            onProgress: { progress.append($0) })

        XCTAssertEqual(reviewed.status, .accepted)
        XCTAssertEqual(progress.values.last?.status, .accepted)
        XCTAssertEqual(reviewed.mathematicalRuling?.note, "the parameter is unbound")
        XCTAssertEqual(reviewed.scopeRuling?.targetDisposition, .partialInvalidity)
        XCTAssertEqual(provider.requests.filter {
            $0.system.text.contains("mathematical reviewer")
        }.count, mathematicalRequestsBeforeRetry)
    }

    func testScopeReviewRetainsEveryTargetDisposition() async throws {
        let dispositions: [ProblemChallenge.ReviewRuling.TargetDisposition] = [
            .fullInvalidity, .partialInvalidity, .needsClarification
        ]
        for disposition in dispositions {
            let provider = ProblemChallengeProvider([
                challengeReviewCall(accepted: true, note: "mathematical defect established"),
                [.textDelta("Mathematical ruling filed."), .finished(.endTurn)],
                challengeReviewCall(accepted: true, note: "scope decided",
                                    targetDisposition: disposition),
                [.textDelta("Scope ruling filed."), .finished(.endTurn)]
            ])
            let reviewed = try await ProblemChallengeReviewer.review(
                challenge: ProblemChallenge(
                    id: "c-\(disposition.rawValue)", branchPlanID: "b",
                    targetRevisionID: target.id, description: "A concrete defect."),
                target: target, items: [], tools: [], runner: AgentLoop(provider: provider))

            XCTAssertEqual(reviewed.scopeRuling?.targetDisposition, disposition)
        }
    }
}

final class ProblemChallengeGovernanceTests: XCTestCase {

    private func challenge() -> ProblemChallenge {
        ProblemChallenge(
            id: "c1", branchPlanID: "b1", targetRevisionID: "r1",
            description: "The target omits a required quantifier.",
            proposedReplacementRequest: "For each n, classify all groups.",
            proposedTargetItemID: "qst-classification-corrected",
            proposedTargetItemType: .question,
            proposedTargetItemData: Data("corrected target bytes".utf8))
    }

    func testGovernanceRequiresMinimalReplacementForRevision() async {
        let tool = GovernProblemChallengeTool(
            signals: DirectorSignals(), challenge: challenge(), branchIDs: ["b1"])
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"apply_revision":true,"stop_branch_plan_ids":[],"replan_branch_plan_ids":["b1"],
             "continue_branch_plan_ids":[],"open_new_portfolio":true,"rationale":"repair it"}
            """#)
            XCTFail("a revision without its governed request must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("minimal replacement_request"))
        }
    }

    func testGovernanceCannotReviseWithoutASeparatePinnedLibraryTarget() async {
        let incomplete = ProblemChallenge(
            id: "c-no-item", branchPlanID: "b1", targetRevisionID: "r1",
            description: "The target omits a required quantifier.",
            proposedReplacementRequest: "For each n, classify all groups.")
        let tool = GovernProblemChallengeTool(
            signals: DirectorSignals(), challenge: incomplete, branchIDs: ["b1"])
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"apply_revision":true,"replacement_request":"For each n, classify all groups.",
             "stop_branch_plan_ids":[],"replan_branch_plan_ids":["b1"],
             "continue_branch_plan_ids":[],"open_new_portfolio":true,
             "rationale":"Add the missing quantifier."}
            """#)
            XCTFail("a governed revision must keep the corrected request in the library")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("separate corrected library target"))
        }
    }

    func testGovernanceCannotGiveOneBranchConflictingDispositions() async {
        let tool = GovernProblemChallengeTool(
            signals: DirectorSignals(), challenge: challenge(), branchIDs: ["b1", "b2"])
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"apply_revision":false,"stop_branch_plan_ids":["b1"],
             "replan_branch_plan_ids":[],"continue_branch_plan_ids":["b1"],
             "open_new_portfolio":false,"rationale":"only one part failed"}
            """#)
            XCTFail("a branch must have one disposition")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("at once"))
        }
    }

    func testReplanningRequiresANewPortfolio() async {
        let tool = GovernProblemChallengeTool(
            signals: DirectorSignals(), challenge: challenge(), branchIDs: ["b1"])
        do {
            _ = try await tool.execute(inputJSON: #"""
            {"apply_revision":false,"stop_branch_plan_ids":[],
             "replan_branch_plan_ids":["b1"],"continue_branch_plan_ids":[],
             "open_new_portfolio":false,"rationale":"the objective changed"}
            """#)
            XCTFail("replanned work needs governed replacement routes")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("require open_new_portfolio"))
        }
    }

    func testGovernanceCanReplanAffectedWorkAndOpenUnresolvedPortfolio() async throws {
        let signals = DirectorSignals()
        signals.setVerdict(.continue, rationale: "classification remains", status: "Replanning.")
        let tool = GovernProblemChallengeTool(
            signals: signals, challenge: challenge(), branchIDs: ["b1", "b2"])

        _ = try await tool.execute(inputJSON: #"""
        {"apply_revision":true,"replacement_request":"Classify all groups for each n.",
         "stop_branch_plan_ids":["b2"],"replan_branch_plan_ids":["b1"],
         "continue_branch_plan_ids":[],"open_new_portfolio":true,
         "rationale":"Quantifying n repairs the defect; the classification remains unresolved."}
        """#)

        let governance = try XCTUnwrap(signals.decision?.challengeGovernance)
        XCTAssertTrue(governance.applyRevision)
        XCTAssertEqual(governance.replanBranchPlanIDs, ["b1"])
        XCTAssertEqual(governance.stopBranchPlanIDs, ["b2"])
        XCTAssertTrue(governance.openNewPortfolio)
    }

    func testPinnedContextCarriesVersionHashTypeAndRawSnapshot() {
        let raw = Data("---\ntype: algorithm\n---\n\n## Statement\nEnumerate the objects.\n".utf8)
        var target = ResearchTargetRevision(
            id: "revision-sentinel", requestText: "Enumerate the objects.",
            libraryItemID: "alg-enumerate", libraryItemType: .algorithm,
            libraryItemData: raw)
        target.recommendedReading = "Treat the size advice as operational guidance."
        target.ambiguities = ["The practical ceiling is not numerically specified."]

        let rendered = ContextAssembly.pinnedTargetSection(target)
        XCTAssertTrue(rendered.contains("revision-sentinel"))
        XCTAssertTrue(rendered.contains(ResearchTargetRevision.sha256(raw)))
        XCTAssertTrue(rendered.contains("[algorithm]"))
        XCTAssertTrue(rendered.contains("Enumerate the objects."))
        XCTAssertTrue(rendered.contains("Adopted reading: Treat the size advice as operational guidance."))
        XCTAssertTrue(rendered.contains("The practical ceiling is not numerically specified."))
        XCTAssertTrue(rendered.contains("never change its Statement"))
    }

    func testAcceptedChallengeForcesDirectorGovernanceBeforeContinuing() async throws {
        var accepted = challenge()
        accepted.status = .accepted
        accepted.mathematicalRuling = .init(accepted: true, note: "n is unbound")
        accepted.scopeRuling = .init(accepted: true, note: "a quantifier is necessary")
        let program = ResearchProgram(
            id: "p", goal: "Classify all groups for n.",
            branches: [.init(planID: "b1", title: "Classification")],
            challenges: [accepted])
        let provider = ProblemChallengeProvider([
            [.toolUseFinished(id: "g", name: "govern_problem_challenge", inputJSON: #"""
            {"apply_revision":true,"replacement_request":"For each n, classify all groups.",
             "stop_branch_plan_ids":[],"replan_branch_plan_ids":["b1"],
             "continue_branch_plan_ids":[],"open_new_portfolio":true,
             "rationale":"The quantifier is necessary and classification remains unresolved."}
            """#), .finished(.toolUse)],
            [.toolUseFinished(id: "v", name: "set_program_verdict", inputJSON: #"""
            {"verdict":"continue","rationale":"The corrected classification is open.",
             "status":"Replanning under the quantified request."}
            """#), .finished(.toolUse)],
            [.toolUseFinished(id: "r", name: "propose_routes", inputJSON: #"""
            {"routes":[{"mechanism":"classification by finite presentations",
                        "next_test":"enumerate the n=1 cases"}]}
            """#), .finished(.toolUse)],
            [.textDelta("Governed."), .finished(.endTurn)]
        ])
        let signal = Director.progressSignal(
            program: program, records: [:], generation: 1, findingsBefore: 0)

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program, records: [:],
            signal: signal, generation: 1,
            trigger: .problemChallengeAccepted(challengeID: accepted.id))

        XCTAssertEqual(decision?.verdict, .continue)
        XCTAssertEqual(decision?.routes.count, 1)
        XCTAssertEqual(decision?.challengeGovernance?.replanBranchPlanIDs, ["b1"])
        let firstRequest = try XCTUnwrap(provider.requests.first)
        XCTAssertNotNil(firstRequest.tools.first { $0.name == "govern_problem_challenge" })
        let verdictSchema = try XCTUnwrap(
            firstRequest.tools.first { $0.name == "set_program_verdict" }?.inputSchemaJSON)
        XCTAssertFalse(verdictSchema.contains("settled"),
                       "a challenge can revise or stop research, but cannot itself settle it")
    }

    func testDirectorMayResumeUnaffectedBranchesWithoutDuplicateRoutes() async throws {
        var accepted = challenge()
        accepted.status = .accepted
        accepted.mathematicalRuling = .init(accepted: true, note: "one subrequest is malformed")
        accepted.scopeRuling = .init(accepted: true, note: "the other subrequest is unchanged")
        let program = ResearchProgram(
            id: "p", goal: "Do A and B.",
            branches: [.init(planID: "b1", title: "Unaffected B")],
            challenges: [accepted])
        let provider = ProblemChallengeProvider([
            [.toolUseFinished(id: "g", name: "govern_problem_challenge", inputJSON: #"""
            {"apply_revision":false,"stop_branch_plan_ids":[],"replan_branch_plan_ids":[],
             "continue_branch_plan_ids":["b1"],"open_new_portfolio":false,
             "rationale":"The challenge affects A only; branch b1 still answers B."}
            """#), .finished(.toolUse)],
            [.toolUseFinished(id: "v", name: "set_program_verdict", inputJSON: #"""
            {"verdict":"continue","rationale":"B remains unresolved.",
             "status":"Resuming the unaffected B branch."}
            """#), .finished(.toolUse)],
            [.textDelta("Governed."), .finished(.endTurn)]
        ])
        let signal = Director.progressSignal(
            program: program, records: [:], generation: 1, findingsBefore: 0)

        let decision = try await Director.decide(
            runner: AgentLoop(provider: provider), program: program, records: [:],
            signal: signal, generation: 1,
            trigger: .problemChallengeAccepted(challengeID: accepted.id))

        XCTAssertEqual(decision?.verdict, .continue)
        XCTAssertTrue(decision?.routes.isEmpty == true)
        XCTAssertEqual(decision?.challengeGovernance?.continueBranchPlanIDs, ["b1"])
        let verdictSchema = try XCTUnwrap(provider.requests.first?.tools
            .first { $0.name == "set_program_verdict" }?.inputSchemaJSON)
        XCTAssertTrue(verdictSchema.contains("continue"),
                      "verified target governance gets one continuation decision at the ordinary ceiling")
    }
}
