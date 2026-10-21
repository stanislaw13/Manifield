import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class PilotProvider: LLMProvider, @unchecked Sendable {
    var description: String { "pilot" }
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

private final class ThrowingPilotProvider: LLMProvider, @unchecked Sendable {
    var description: String { "throwing" }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.http(503, "down")) }
    }
}

final class PilotTests: XCTestCase {

    func testEachDefaultPilotGetsItsOwnAngle() {
        let directives = Pilots.defaultBriefs.map {
            Pilots.systemPrompt(brief: $0, contract: nil, notation: "", outline: "", memory: "")
        }
        XCTAssertEqual(Set(directives).count, Pilots.defaultBriefs.count,
                       "pilots that share a directive are one pilot")
    }

    /// Defaults remain broad, but they are a fallback rather than a required topology.
    func testTheDefaultBriefsRemainBroadWithoutDefiningRequiredRoles() {
        XCTAssertEqual(Pilots.coverageProblems(Pilots.defaultBriefs), [])
        XCTAssertTrue(Pilots.requiredRoles.isEmpty)
        XCTAssertEqual(Set(Pilots.defaultBriefs.map(\.role)).count, 3)
    }

    func testPilotRolesAreNotQuotas() {
        let onlyBuilders = Pilots.defaultBriefs.filter { $0.role == .directAnswer }
        XCTAssertEqual(Pilots.coverageProblems(onlyBuilders), [])
    }

    func testAnEmptyPilotSetIsAValidDecision() {
        XCTAssertEqual(Pilots.coverageProblems([]), [])
    }

    /// The negative-resolution pilot must not assume the answer is a counterexample.
    func testTheChallengePilotIsNotHardwiredToCounterexamples() {
        let brief = try! XCTUnwrap(Pilots.defaultBriefs.first { $0.id == "negative" })
        XCTAssertTrue(brief.directive.contains("would answer the request"))
    }

    func testAPilotReportsItsText() async throws {
        let provider = PilotProvider(scripts: [
            [.textDelta("Found a construction at k=9."), .finished(.endTurn)]
        ])
        let result = try await Pilots.run(runner: AgentLoop(provider: provider),
                                      brief: Pilots.defaultBriefs[0], goal: "g", tools: [])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.text, "Found a construction at k=9.")
    }

    /// A pilot that knows what would settle the problem spends its budget differently.
    func testThePilotSeesTheContractWhenThereIsOne() {
        let contract = SuccessContract(
            statement: "FORMAL-TARGET-SENTINEL")
        let withContract = Pilots.systemPrompt(
            brief: Pilots.defaultBriefs[0], contract: contract,
            notation: "", outline: "", memory: "", goal: "RAW-REQUEST-SENTINEL")
        XCTAssertFalse(withContract.contains("RAW-REQUEST-SENTINEL"))
        XCTAssertTrue(withContract.contains("FORMAL-TARGET-SENTINEL"))
    }

    /// One angle failing must not cost the others — they are independent by construction.
    func testAFailingPilotIsCapturedNotThrown() async throws {
        let result = try await Pilots.run(runner: AgentLoop(provider: ThrowingPilotProvider()),
                                      brief: Pilots.defaultBriefs[1], goal: "g", tools: [])
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.failure)
    }

    func testRunAllKeepsGoingAfterAFailure() async throws {
        let results = try await Pilots.runAll(
            runner: AgentLoop(provider: ThrowingPilotProvider()), goal: "g", tools: [])
        XCTAssertEqual(results.count, Pilots.defaultBriefs.count)
        XCTAssertTrue(results.allSatisfy { !$0.succeeded })
    }

    /// "This angle produced nothing" is information about the problem; dropping it would
    /// overstate how much ground the pilots actually covered.
    func testTheDigestNamesPilotsThatProducedNothing() {
        let digest = Pilots.digest([
            .init(brief: Pilots.defaultBriefs[0], text: "something"),
            .init(brief: Pilots.defaultBriefs[1], text: "", failure: "timed out")
        ])
        XCTAssertTrue(digest.contains("something"))
        XCTAssertTrue(digest.contains("produced nothing"))
        XCTAssertTrue(digest.contains("timed out"))
    }

    func testTheDigestWarnsThatAgreementIsWeakEvidence() {
        let digest = Pilots.digest([.init(brief: Pilots.defaultBriefs[0], text: "x")])
        XCTAssertTrue(digest.contains("agreement between them is weak evidence"),
                      "pilots share a model and a prompt family; consensus proves little")
    }
}

final class PilotSelectorTests: XCTestCase {

    private func selectorProvider(_ json: String) -> PilotProvider {
        PilotProvider(scripts: [
            [.toolUseFinished(id: "1", name: "select_pilots", inputJSON: json),
             .finished(.toolUse)],
            [.textDelta("Selected."), .finished(.endTurn)]
        ])
    }

    private static let good = #"""
    {"pilots":[
      {"role":"direct_answer","title":"Direct","directive":"attack it head on"},
      {"role":"challenge","title":"Adversary","directive":"assume the obvious answer is wrong"},
      {"role":"reformulation","title":"Reduce","directive":"find an equivalent formulation"},
      {"role":"open","title":"Enumerate","directive":"exhaustively enumerate n <= 12"}]}
    """#

    func testASelectionBecomesBriefs() async throws {
        let briefs = try await PilotSelector.select(
            runner: AgentLoop(provider: selectorProvider(Self.good)), goal: "g", contract: nil)
        XCTAssertEqual(briefs.count, 4)
        XCTAssertEqual(briefs.map(\.role),
                       [.directAnswer, .challenge, .reformulation, .open])
        XCTAssertTrue(briefs[3].directive.contains("enumerate"))
    }

    func testASelectionMissingTheChallengeRoleIsAllowed() async throws {
        let signals = PilotSelectionSignals()
        let tool = SelectPilotsTool(signals: signals)
        _ = try await tool.execute(inputJSON: #"""
        {"pilots":[
          {"role":"direct_answer","title":"A","directive":"d"},
          {"role":"reformulation","title":"B","directive":"d"}]}
        """#)
        XCTAssertEqual(signals.briefs?.count, 2)
    }

    /// A failing selector must not cost the pilots: the defaults are a working set.
    func testAFailedSelectionFallsBackToTheDefaults() async throws {
        let briefs = try await PilotSelector.select(
            runner: AgentLoop(provider: ThrowingPilotProvider()), goal: "g", contract: nil)
        XCTAssertEqual(briefs.map(\.id), Pilots.defaultBriefs.map(\.id))
    }

    func testAnExplicitEmptySelectionDoesNotFallBackToDefaults() async throws {
        let briefs = try await PilotSelector.select(
            runner: AgentLoop(provider: selectorProvider(#"{"pilots":[]}"#)),
            goal: "g", contract: nil, recognitionDigest: "The decisive gap is already known.")
        XCTAssertTrue(briefs.isEmpty)
    }
}

final class StatementAuditorTests: XCTestCase {

    private func auditorProvider(_ json: String) -> PilotProvider {
        PilotProvider(scripts: [
            [.toolUseFinished(id: "1", name: "report_statement_reading", inputJSON: json),
             .finished(.toolUse)],
            [.textDelta("Audited."), .finished(.endTurn)]
        ])
    }

    func testAnAuditCarriesTheNormalizedReading() async throws {
        let audit = try await StatementAuditor.audit(
            runner: AgentLoop(provider: auditorProvider(#"""
            {"normalized_statement":"For all n >= 1, f(n) < 2^n.",
             "recommended_reading":"n ranges over positive integers.",
             "ambiguities":[{"reading":"n could include 0","consequence":"the base case changes"}],
             "conventions":["indices from 1"]}
            """#)),
            problem: "Is f(n) < 2^n?")
        let unwrapped = try XCTUnwrap(audit)
        XCTAssertEqual(unwrapped.normalizedStatement, "For all n >= 1, f(n) < 2^n.")
        XCTAssertEqual(unwrapped.ambiguities.count, 1)
        XCTAssertEqual(unwrapped.contractAmbiguities,
                       ["n could include 0 — the base case changes"])
    }

    /// A fork reported with no recommendation hands the drafter a choice it will make
    /// silently, which is the failure this whole stage exists to prevent.
    func testAnAmbiguityWithoutARecommendationIsRefused() async {
        let signals = StatementAuditSignals()
        do {
            _ = try await ReportStatementReadingTool(signals: signals).execute(inputJSON: #"""
            {"normalized_statement":"S",
             "ambiguities":[{"reading":"r","consequence":"c"}]}
            """#)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("which one to use"))
        }
    }

    func testAnUnambiguousStatementNeedsNoRecommendation() async throws {
        let signals = StatementAuditSignals()
        _ = try await ReportStatementReadingTool(signals: signals).execute(
            inputJSON: #"{"normalized_statement":"S"}"#)
        XCTAssertEqual(signals.audit?.normalizedStatement, "S")
    }

    /// The auditor reads the project, never the literature — a nearby paper here would pull
    /// the reading toward its terminology before the contract is even frozen.
    func testTheAuditorIsToldNotToSearchExternalLiterature() {
        let prompt = StatementAuditor.systemPrompt(notation: "", outline: "")
        XCTAssertTrue(prompt.contains("Do not search external literature"))
    }
}

final class ContractDrafterTests: XCTestCase {

    private func drafterProvider(_ json: String) -> PilotProvider {
        PilotProvider(scripts: [
            [.toolUseFinished(id: "1", name: "draft_success_contract", inputJSON: json),
             .finished(.toolUse)],
            [.textDelta("Drafted."), .finished(.endTurn)]
        ])
    }

    private static let goodDraft = #"""
    {"statement":"Does every k-set with distinct subset sums have max >= c*2^k, for an absolute c?",
     "ambiguity_note":"Read c as absolute, not depending on k."}
    """#

    func testADraftBecomesAContract() async throws {
        let draft = try await ContractDrafter.draft(
            runner: AgentLoop(provider: drafterProvider(Self.goodDraft)), goal: "g")
        let unwrapped = try XCTUnwrap(draft)
        XCTAssertTrue(unwrapped.contract.completeAnswers.isEmpty)
        XCTAssertTrue(unwrapped.contract.notCounted.isEmpty)
        XCTAssertEqual(unwrapped.contract.validationProblems, [])
        XCTAssertEqual(unwrapped.ambiguityNote, "Read c as absolute, not depending on k.")
    }

    /// A drafted contract is never binding on its own.
    func testADraftIsUnreviewedUntilAHumanApproves() async throws {
        let draft = try await ContractDrafter.draft(
            runner: AgentLoop(provider: drafterProvider(Self.goodDraft)), goal: "g")
        XCTAssertFalse(try XCTUnwrap(draft).contract.isReviewed)
    }

    func testAStatementOnlyDraftNeedsNoCompletenessTaxonomy() async throws {
        let draft = try await ContractDrafter.draft(
            runner: AgentLoop(provider: drafterProvider(#"""
            {"statement":"Classify all finite groups of order p squared."}
            """#)),
            goal: "g")
        XCTAssertEqual(draft?.contract.statement, "Classify all finite groups of order p squared.")
        XCTAssertEqual(draft?.contract.validationProblems, [])
    }

    func testTheDraftToolDoesNotAskForAnswerFormsOrExclusions() {
        let schema = DraftContractTool(signals: ContractSignals()).spec.inputSchemaJSON
        XCTAssertFalse(schema.contains("complete_answers"))
        XCTAssertFalse(schema.contains("not_counted"))
        XCTAssertFalse(schema.contains("completeness_rationale"))
    }

    /// Ambiguities the audit found survive a drafter that simply did not repeat them.
    func testAuditAmbiguitiesAreMergedIntoTheContract() async throws {
        let audit = StatementAuditor.Audit(
            normalizedStatement: "S",
            recommendedReading: "take n >= 1",
            ambiguities: [.init(reading: "n could include 0", consequence: "base case changes")])
        let draft = try await ContractDrafter.draft(
            runner: AgentLoop(provider: drafterProvider(Self.goodDraft)), goal: "g", audit: audit)
        XCTAssertEqual(try XCTUnwrap(draft).contract.recommendedReading, "take n >= 1")
        XCTAssertEqual(try XCTUnwrap(draft).contract.ambiguities,
                       ["n could include 0 — base case changes"])
    }

    /// The drafter must not see attempts at the problem: what turned out to be reachable
    /// must not shape what counts as an answer.
    func testTheDrafterSeesTheAuditAndNothingAboutAttempts() {
        let audit = StatementAuditor.Audit(normalizedStatement: "AUDIT-SENTINEL")
        let prompt = ContractDrafter.systemPrompt(audit: audit)
        XCTAssertTrue(prompt.contains("AUDIT-SENTINEL"))
        XCTAssertTrue(prompt.contains("do not see attempts"))
    }
}

final class ProgramStatusTests: XCTestCase {

    private func contract() -> SuccessContract {
        SuccessContract(
            statement: "S",
            completeAnswers: [
                .init(id: "A1", statement: "the theorem", evidence: "review"),
                .init(id: "A2", statement: "a counterexample", evidence: "a verified witness")
            ],
            completenessRationale: "The statement is either true or false.")
    }

    private func record(tokens: Int) -> RunRecord {
        var record = RunRecord(plan: PlanDocument(id: "b1", goal: "g"))
        record.tokensIn = tokens
        record.journal = [TaskJournalEntry(
            taskIndex: 1, outcome: "completed", summary: "s", tokensIn: tokens, tokensOut: 0,
            startedAt: Date(), endedAt: Date())]
        return record
    }

    /// The completions are alternatives, so nothing is "current" and nothing is partially
    /// reached — a form is claimed, accepted, or neither.
    func testCompletionsShowWhereAClaimStands() {
        var program = ResearchProgram(id: "p", goal: "g", contract: contract())
        program.solutions = [SolutionCandidate(
            branchPlanID: "b1", primaryItemID: "thm",
            argument: "a", contractRuling: .init(accepted: true, note: "n",
                                                 satisfiedCompletionIDs: ["A2"]),
            status: .underReview)]
        let status = ProgramStatus.make(
            program: program, records: ["b1": record(tokens: 100)], items: [])
        XCTAssertEqual(status.completions.map(\.claimed), [false, true])
        XCTAssertEqual(status.completions.map(\.accepted), [false, false])
    }

    /// The adjudicator's finding is what counts, not the claimant's guess.
    func testAnAcceptedCandidateMarksTheFormTheAdjudicatorNamed() {
        var program = ResearchProgram(id: "p", goal: "g", contract: contract())
        program.solutions = [SolutionCandidate(
            branchPlanID: "b1", primaryItemID: "thm",
            claimedCompletionIDs: ["A1"],
            argument: "a",
            contractRuling: .init(accepted: true, note: "n", satisfiedCompletionIDs: ["A2"]),
            reviewRuling: .init(accepted: true, note: "clean"),
            status: .accepted)]
        let status = ProgramStatus.make(program: program, records: [:], items: [])
        XCTAssertEqual(status.completions.map(\.accepted), [false, true])
    }

    func testCostPerFindingIsAttributedToTheRoute() {
        let program = ResearchProgram(
            id: "p", goal: "g",
            branches: [.init(planID: "b1", title: "B")],
            routes: [ResearchRoute(planID: "b1", mechanism: "m", status: .active)],
            findings: [.init(branchPlanID: "b1", kind: .evidence, statement: "x")])
        let status = ProgramStatus.make(
            program: program, records: ["b1": record(tokens: 500)], items: [])
        XCTAssertEqual(status.routes.first?.tokensSpent, 500)
        XCTAssertEqual(status.routes.first?.findings, 1)
    }

    func testPlanningSpendCountsAgainstTheProgramBudget() {
        let program = ResearchProgram(
            id: "p", goal: "g", programTokenBudget: 1_000,
            planningTokensUsed: 300)
        let status = ProgramStatus.make(
            program: program, records: ["b1": record(tokens: 250)], items: [])
        XCTAssertEqual(status.tokensSpent, 550)
        XCTAssertEqual(status.tokensRemaining, 450)
    }

    func testOpenObligationsAreSurfaced() {
        let items = [
            TheoryItem(id: "thm", type: .theorem, name: "T", status: .proofDrafted,
                       dependsOn: ["lem"], body: "## Statement\nx"),
            TheoryItem(id: "lem", type: .lemma, name: "L", status: .conjecture,
                       body: "## Statement\ny")
        ]
        let status = ProgramStatus.make(
            program: ResearchProgram(id: "p", goal: "g"), records: [:], items: items)
        XCTAssertEqual(status.openObligations.map(\.itemID), ["thm"])
    }

    func testAnUnreviewedContractIsFlagged() {
        let status = ProgramStatus.make(
            program: ResearchProgram(id: "p", goal: "g", contract: contract()),
            records: [:], items: [])
        XCTAssertTrue(status.contractUnreviewed,
                      "a verdict against an unchecked contract has to say so")
    }

    func testTheOneLinerIsTheThreeSecondRead() {
        var program = ResearchProgram(id: "p", goal: "g", contract: contract())
        program.routes = [
            ResearchRoute(planID: "b1", mechanism: "live one", status: .active),
            ResearchRoute(mechanism: "dead one", status: .falsified, obstruction: "capped")
        ]
        let status = ProgramStatus.make(
            program: program, records: ["b1": record(tokens: 10)], items: [])
        XCTAssertTrue(status.oneLiner.contains("No complete answer yet"))
        XCTAssertTrue(status.oneLiner.contains("1 route(s) live, 1 ruled out"))
    }
}
