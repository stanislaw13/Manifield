import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class SolutionProvider: LLMProvider, @unchecked Sendable {
    var description: String { "solution" }
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

private func toolTurn(_ name: String, _ json: String) -> [[LLMEvent]] {
    [[.toolUseFinished(id: "1", name: name, inputJSON: json), .finished(.toolUse)],
     [.textDelta("done"), .finished(.endTurn)]]
}

private func contract() -> SuccessContract {
    SuccessContract(
        statement: "Is every k-set with distinct subset sums bounded below by c·2^k?",
        completeAnswers: [
            .init(id: "A1", statement: "a proof of the bound", evidence: "a reviewed proof"),
            .init(id: "A2", statement: "a family witnessing failure", evidence: "a verified witness")
        ],
        completenessRationale: "The bound either holds or a family witnesses that it does not.")
}

// MARK: - Contract adjudication

final class SolutionAdjudicatorTests: XCTestCase {

    private func candidate() -> SolutionCandidate {
        SolutionCandidate(branchPlanID: "b1", primaryItemID: "thm-bound",
                          claimedCompletionIDs: ["A1"],
                          argument: "The theorem gives the bound for every k.")
    }

    func testAnAcceptanceRecordsWhichFormsWereSatisfied() async throws {
        let provider = SolutionProvider(scripts: toolTurn("report_contract_adjudication", #"""
        {"verdict":"accepted","satisfied_completion_ids":["A1"],
         "note":"It establishes the inequality for every k under the stated hypotheses."}
        """#))
        let ruling = try await SolutionAdjudicator.adjudicate(
            runner: AgentLoop(provider: provider), goal: "g", contract: contract(),
            candidate: candidate(), items: [])
        let unwrapped = try XCTUnwrap(ruling)
        XCTAssertTrue(unwrapped.accepted)
        XCTAssertEqual(unwrapped.satisfiedCompletionIDs, ["A1"])
    }

    /// The claimant's guess is not binding. One result can satisfy a form the branch did not
    /// name, and a claimant naming the wrong one while being substantively right must pass.
    func testTheAdjudicatorMayNameADifferentFormThanTheClaimant() async throws {
        let provider = SolutionProvider(scripts: toolTurn("report_contract_adjudication", #"""
        {"verdict":"accepted","satisfied_completion_ids":["A2"],
         "note":"What was actually established is the failing family, not the bound."}
        """#))
        let ruling = try await SolutionAdjudicator.adjudicate(
            runner: AgentLoop(provider: provider), goal: "g", contract: contract(),
            candidate: candidate(), items: [])
        XCTAssertEqual(try XCTUnwrap(ruling).satisfiedCompletionIDs, ["A2"],
                       "the adjudicator's finding wins over the claim's")
    }

    func testARejectionCarriesTheGapSoTheBranchCanRepairIt() async throws {
        let provider = SolutionProvider(scripts: toolTurn("report_contract_adjudication", #"""
        {"verdict":"rejected",
         "note":"It proves the bound for even k only; the question quantifies over all k."}
        """#))
        let raw = try await SolutionAdjudicator.adjudicate(
            runner: AgentLoop(provider: provider), goal: "g", contract: contract(),
            candidate: candidate(), items: [])
        let ruling = try XCTUnwrap(raw)
        XCTAssertFalse(ruling.accepted)
        XCTAssertTrue(ruling.note.contains("even k only"))
    }

    /// Accepting without naming what was answered leaves the program unable to say what it
    /// settled — and is the shape an over-agreeable acceptance takes.
    func testAcceptingWithoutNamingAFormIsRefused() async {
        let signals = ContractAdjudicationSignals()
        let tool = ReportContractAdjudicationTool(signals: signals, contract: contract())
        do {
            _ = try await tool.execute(
                inputJSON: #"{"verdict":"accepted","note":"looks right to me"}"#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
        }
        XCTAssertNil(signals.ruling)
    }

    func testAVerdictWithoutAReasonIsRefused() async {
        let signals = ContractAdjudicationSignals()
        do {
            _ = try await ReportContractAdjudicationTool(signals: signals, contract: contract())
                .execute(inputJSON: #"{"verdict":"rejected","note":""}"#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("note"))
        }
    }

    /// It judges scope, not correctness. A turn that starts checking proofs stops checking
    /// whether the right question was answered, which is the one thing only it looks at.
    func testThePromptTellsItToAssumeTheMathematicsIsCorrect() {
        let prompt = SolutionAdjudicator.systemPrompt(
            goal: "g", contract: contract(), candidate: candidate(), items: [])
        XCTAssertTrue(prompt.contains("assuming the mathematics is correct"))
        XCTAssertTrue(prompt.contains("not checking the proofs"))
    }

    func testScopeReviewReceivesTheFrozenGoalItemRatherThanOnlyTheLivePrompt() {
        let goalItem = TheoryItem(
            id: "prob-fixed", type: .problem, name: "Fixed classification",
            body: "## Statement\nClassify every object satisfying the frozen hypothesis H.")
        let revision = ResearchTargetRevision(
            id: "goal-r1", requestText: try! XCTUnwrap(goalItem.statement),
            libraryItemID: goalItem.id, libraryItemType: goalItem.type,
            libraryItemName: goalItem.name,
            libraryItemData: Data(goalItem.serialized().utf8),
            dependencyItemData: [
                "def-h": Data("---\nid: def-h\ntype: definition\nname: H\n---\n## Statement\nH is fixed.\n".utf8)
            ],
            notationSnapshot: "Objects are denoted by X.",
            macrosSnapshot: "\\newcommand{\\Obj}{X}")

        let prompt = SolutionAdjudicator.systemPrompt(
            goal: "informal words retained only for history", contract: contract(),
            targetRevision: revision, candidate: candidate(), items: [])

        XCTAssertTrue(prompt.contains("Fixed research-goal item"))
        XCTAssertTrue(prompt.contains("prob-fixed"))
        XCTAssertTrue(prompt.contains("frozen hypothesis H"))
        XCTAssertTrue(prompt.contains("def-h"))
        XCTAssertTrue(prompt.contains("Objects are denoted by X."))
        XCTAssertTrue(prompt.contains("\\newcommand{\\Obj}{X}"))
    }
}

// MARK: - The review gate

final class SolutionReviewGateTests: XCTestCase {

    func testReviewDigestMatchesAProcessIndependentSHA256Vector() {
        let item = TheoryItem(id: "a", type: .lemma, name: "A", status: .reviewedNoErrors,
                              body: "A holds.")
        XCTAssertEqual(SolutionReviewGate.contentHash(item),
                       "sha256-v1:62447d7e4ddc71795954813161f6138959803320264f0f4af6a5ae837f8251ad")
    }

    private func items() -> [TheoryItem] {
        [
            TheoryItem(id: "lem-a", type: .lemma, name: "A", status: .reviewedNoErrors,
                       body: "## Statement\nA holds.\n\n## Proof\nBy induction."),
            TheoryItem(id: "thm-bound", type: .theorem, name: "T", status: .proofDrafted,
                       dependsOn: ["lem-a"],
                       body: "## Statement\nThe bound holds.\n\n## Proof\nApply lem-a.")
        ]
    }

    private func candidate() -> SolutionCandidate {
        SolutionCandidate(branchPlanID: "b1", primaryItemID: "thm-bound",
                          argument: "lem-a gives the step; the theorem follows.")
    }

    /// The rule this gate exists for. Item review certifies the parts and says nothing about
    /// whether they combine — every link can be individually correct while the chain applies
    /// one of them outside its hypotheses, skips a case, or simply does not close. So the
    /// assembly review runs even when every cited item is cached clean.
    func testTheAssemblyReviewRunsEvenWhenEveryItemIsCachedClean() async throws {
        let byID = Dictionary(items().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let warmCache = Dictionary(
            items().map { ($0.id, SolutionReviewGate.closureHash(itemID: $0.id, items: byID)) },
            uniquingKeysWith: { a, _ in a })
        let assemblyRan = LockedFlag()

        let (ruling, _) = try await SolutionReviewGate.review(
            candidate: candidate(), goal: "g", contract: contract(), items: items(),
            cache: warmCache,
            verifier: FailingVerifier(),   // must never be consulted: everything is cached
            reviewAssembly: { _, _ in
                assemblyRan.set()
                return (true, "the chain closes")
            })

        XCTAssertTrue(assemblyRan.value,
                      "'every dependency was reviewed' must never imply 'the solution was reviewed'")
        XCTAssertTrue(ruling.accepted)
        XCTAssertEqual(ruling.assemblyNote, "the chain closes")
    }

    /// The corollary: clean parts plus a broken join is a rejection.
    func testCleanItemsWithABrokenAssemblyIsRejected() async throws {
        let byID = Dictionary(items().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let warmCache = Dictionary(
            items().map { ($0.id, SolutionReviewGate.closureHash(itemID: $0.id, items: byID)) },
            uniquingKeysWith: { a, _ in a })

        let (ruling, _) = try await SolutionReviewGate.review(
            candidate: candidate(), goal: "g", contract: contract(), items: items(),
            cache: warmCache, verifier: FailingVerifier(),
            reviewAssembly: { _, _ in (false, "lem-a is applied to a case it does not cover") })

        XCTAssertFalse(ruling.accepted)
        XCTAssertTrue(ruling.note.contains("does not close"))
    }

    /// A cached review is only good for the exact snapshot it was performed on — content and
    /// the whole dependency closure. An item edited underneath invalidates it.
    func testEditingADependencyInvalidatesTheCachedReviewAbove() {
        var edited = items()
        let byID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let before = SolutionReviewGate.closureHash(itemID: "thm-bound", items: byID)

        edited[0].body = "## Statement\nA holds, but only for even n.\n\n## Proof\nBy induction."
        let afterByID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = SolutionReviewGate.closureHash(itemID: "thm-bound", items: afterByID)

        XCTAssertNotEqual(before, after,
                          "a lemma re-stated underneath a theorem changes the theorem's review")
    }

    /// A status downgrade is exactly the change a content-only hash would hide.
    func testADowngradedDependencyInvalidatesTheCache() {
        var edited = items()
        let byID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let before = SolutionReviewGate.closureHash(itemID: "thm-bound", items: byID)

        edited[0].status = .conjecture
        let afterByID = Dictionary(edited.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotEqual(before,
                          SolutionReviewGate.closureHash(itemID: "thm-bound", items: afterByID))
    }

    func testTheClosureIsWalkedInDependencyOrder() {
        let byID = Dictionary(items().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(SolutionReviewGate.closure(of: candidate(), items: byID).map(\.id),
                       ["lem-a", "thm-bound"])
    }

    /// An assembly review nobody managed to run is not an acceptance.
    func testNoAssemblyRulingIsNotAnAcceptance() async throws {
        let outcome = try await SolutionReviewGate.reviewAssembly(
            runner: AgentLoop(provider: SolutionProvider(scripts: [[.textDelta("hmm"), .finished(.endTurn)]])),
            goal: "g", contract: contract(), chain: items(), candidate: candidate())
        XCTAssertFalse(outcome.accepted)
    }

    func testAssemblyReviewReportsTheGapItFound() async throws {
        let provider = SolutionProvider(scripts: toolTurn("report_assembly_review", #"""
        {"verdict":"does_not_close",
         "note":"lem-a assumes n even; the theorem applies it at n=3."}
        """#))
        let outcome = try await SolutionReviewGate.reviewAssembly(
            runner: AgentLoop(provider: provider), goal: "g", contract: contract(),
            chain: items(), candidate: candidate())
        XCTAssertFalse(outcome.accepted)
        XCTAssertTrue(outcome.note.contains("n=3"))
    }
}

/// Fails loudly if consulted — used to prove the item-level cache was honoured.
private struct FailingVerifier: ProofVerifier {
    func review(target: TheoryItem, proofMarkdown: String,
                onActivity: @escaping @Sendable (AgentActivity) -> Void) async throws -> ReviewResult {
        XCTFail("a cached, unchanged item must not be re-reviewed")
        return ReviewResult(verdict: .noErrorsFound, issues: [])
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

// MARK: - The director's settle gate

final class SettleGateTests: XCTestCase {

    /// `settled` is not a verdict the model can reach and then justify: with no accepted
    /// candidate it is absent from the schema, the same move that removes `continue` at the
    /// generation ceiling.
    func testSettledIsAbsentFromTheSchemaWithoutAnAcceptedCandidate() {
        let signals = DirectorSignals()
        let locked = SetProgramVerdictTool(signals: signals, canSettle: false)
        XCTAssertFalse(locked.spec.inputSchemaJSON.contains("settled"))
        XCTAssertTrue(locked.spec.description.contains("NOT available"))

        let open = SetProgramVerdictTool(signals: signals, canSettle: true)
        XCTAssertTrue(open.spec.inputSchemaJSON.contains("settled"))
    }

    func testSettledIsRefusedWithoutAnAcceptedCandidate() async {
        let signals = DirectorSignals()
        do {
            _ = try await SetProgramVerdictTool(signals: signals,
                                                canSettle: false)
                .execute(inputJSON: #"{"verdict":"settled","rationale":"r","status":"s"}"#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("BOTH"))
        }
        XCTAssertNil(signals.decision)
    }

    func testSettledIsAllowedOnceACandidateIsAccepted() async throws {
        let signals = DirectorSignals()
        _ = try await SetProgramVerdictTool(signals: signals, canSettle: true)
            .execute(inputJSON: #"{"verdict":"settled","rationale":"r","status":"s"}"#)
        XCTAssertEqual(signals.decision?.verdict, .settled)
    }

    /// The program is the authority on whether anything was accepted, not the director.
    func testTheProgramReportsItsAcceptedCandidate() {
        var program = ResearchProgram(id: "p", goal: "g", contract: contract())
        program.solutions = [SolutionCandidate(branchPlanID: "b1", primaryItemID: "thm",
                                               argument: "a", status: .underReview)]
        XCTAssertNil(program.acceptedSolution)

        program.solutions[0].status = .accepted
        XCTAssertEqual(program.acceptedSolution?.primaryItemID, "thm")
    }
}

// MARK: - Routing decisions

final class RouteFindingsToolTests: XCTestCase {

    private func tool(_ signals: RoutingSignals) -> RouteFindingsTool {
        RouteFindingsTool(signals: signals, findingIDs: ["f1", "f2"],
                          branchIDs: ["b1", "b2"])
    }

    func testEachDecisionIsRecordedWithItsRecipients() async throws {
        let signals = RoutingSignals()
        _ = try await tool(signals).execute(inputJSON: #"""
        {"routings":[
          {"finding_id":"f1","decision":"send_now","recipients":["b2"],"rationale":"kills b2's assumption"},
          {"finding_id":"f2","decision":"hold","rationale":"route-specific, too early"}]}
        """#)
        XCTAssertEqual(signals.routings.count, 2)
        XCTAssertTrue(signals.routings[0].reaches("b2"))
        XCTAssertFalse(signals.routings[0].reaches("b1"))
        XCTAssertFalse(signals.routings[1].reaches("b1"), "a hold reaches nobody")
    }

    /// An unrouted finding reaches nobody, so leaving one out is a decision made by accident.
    func testLeavingAFindingUndecidedIsRefused() async {
        let signals = RoutingSignals()
        do {
            _ = try await tool(signals).execute(inputJSON: #"""
            {"routings":[{"finding_id":"f1","decision":"do_not_send","rationale":"branch-local"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("undecided"))
            XCTAssertTrue(error.localizedDescription.contains("f2"))
        }
    }

    /// `send_now` with nobody to send to is a hold that reads as a send.
    func testSendNowWithoutRecipientsIsRefused() async {
        let signals = RoutingSignals()
        do {
            _ = try await tool(signals).execute(inputJSON: #"""
            {"routings":[
              {"finding_id":"f1","decision":"send_now","recipients":[],"rationale":"r"},
              {"finding_id":"f2","decision":"hold","rationale":"r"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs at least one recipient"))
        }
    }

    /// Withholding needs a reason as much as sending does: the routing history is the record
    /// of what each branch knew and when.
    func testARoutingWithoutARationaleIsRefused() async {
        let signals = RoutingSignals()
        do {
            _ = try await tool(signals).execute(inputJSON: #"""
            {"routings":[{"finding_id":"f1","decision":"do_not_send","rationale":""},
                         {"finding_id":"f2","decision":"hold","rationale":"r"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rationale"))
        }
    }

    func testAnUnknownFindingIsRefused() async {
        let signals = RoutingSignals()
        do {
            _ = try await tool(signals).execute(inputJSON: #"""
            {"routings":[{"finding_id":"f9","decision":"hold","rationale":"r"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown finding id"))
        }
    }
}
