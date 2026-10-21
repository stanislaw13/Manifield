import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class RecognitionProvider: LLMProvider, @unchecked Sendable {
    var description: String { "recognition-test" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    private var requests: [LLMRequest] = []
    init(_ scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        requests.append(request)
        let next = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in next { continuation.yield(event) }
            continuation.finish()
        }
    }

    var requestedToolNames: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return requests.map { $0.tools.map(\.name) }
    }
}

private struct RecognitionProbeTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(name: "probe", description: "bounded probe", inputSchemaJSON: #"{"type":"object"}"#)
    }
    func execute(inputJSON: String) async throws -> String { "probe evidence" }
}

final class AuthoritativeTargetTests: XCTestCase {
    func testRendererHandsWorkersTheFormalTargetWithoutCompetingRawShorthand() {
        let contract = SuccessContract(
            statement: "FORMAL-SENTINEL", completeAnswers: [
                .init(id: "A1", statement: "LEGACY-ANSWER", evidence: "LEGACY-METHOD")
            ], completenessRationale: "LEGACY-RATIONALE", notCounted: ["LEGACY-EXCLUSION"])
        let rendered = ContextAssembly.researchTargetSection(
            originalRequest: "RAW-SENTINEL", contract: contract)
        XCTAssertFalse(rendered.contains("RAW-SENTINEL"))
        XCTAssertTrue(rendered.contains("FORMAL-SENTINEL"))
        XCTAssertFalse(rendered.contains("LEGACY-ANSWER"))
        XCTAssertFalse(rendered.contains("LEGACY-METHOD"))
        XCTAssertFalse(rendered.contains("LEGACY-EXCLUSION"))
    }

    func testReviewerAcceptsCheckedCitationsAndExactWitnesses() {
        let reviewer = PromptLibrary.text("reviewer_system")
        let checker = PromptLibrary.text("checker_rules")
        XCTAssertTrue(reviewer.contains("checked citation is evidence"))
        XCTAssertTrue(reviewer.contains("exact arithmetic"))
        XCTAssertTrue(checker.contains("Certified computation can settle"))
    }
}

final class RecognitionTests: XCTestCase {
    private let omega = "73948492097301691765464030714938921180352979774791349212169829996615700482"

    /// Regression for the failed run: the exact 74-digit value must leave recognition as a
    /// filed candidate, not survive only in prose or a scratch artifact.
    func testExactOmegaIsFiledThroughClaimSolution() async throws {
        let claim = #"{"primary_item_id":"exact-omega","argument":"Exact verification gives Ω = PLACEHOLDER."}"#
            .replacingOccurrences(of: "PLACEHOLDER", with: omega)
        let report = #"{"summary":"Computed and independently checked Ω = PLACEHOLDER."}"#
            .replacingOccurrences(of: "PLACEHOLDER", with: omega)
        let provider = RecognitionProvider([
            [.toolUseFinished(id: "c", name: "claim_solution", inputJSON: claim),
             .finished(.toolUse)],
            [.toolUseFinished(id: "r", name: "report_recognition", inputJSON: report),
             .finished(.toolUse)],
            [.textDelta("Filed."), .finished(.endTurn)]
        ])
        let result = try await Recognition.run(
            runner: AgentLoop(provider: provider), goal: "Compute Ω exactly.",
            contract: SuccessContract(statement: "Determine the exact value of Ω."),
            targetItemID: "qst-omega", tools: [])
        XCTAssertEqual(result?.claim?.primaryItemID, "exact-omega")
        XCTAssertTrue(result?.claim?.argument.contains(omega) == true)
        XCTAssertTrue(result?.summary.contains(omega) == true)
        XCTAssertEqual(result?.targetItemID, "qst-omega")
    }

    func testRejectedClaimGapIsPrimaryPlanningInput() {
        let candidate = SolutionCandidate(
            branchPlanID: "planning-recognition", primaryItemID: "candidate",
            argument: "a", contractRuling: .init(
                accepted: false, note: "leastness is not established"),
            status: .contractRejected)
        let digest = Recognition.Result(
            summary: "Found a plausible pair.", candidate: candidate).digest
        XCTAssertTrue(digest.contains("portfolio must address this gap"))
        XCTAssertTrue(digest.contains("leastness is not established"))
    }

    func testRecognitionCannotEditExistingTheory() {
        let prompt = Recognition.systemPrompt(
            goal: "g", contract: nil, notation: "", outline: "(empty)")
        XCTAssertTrue(prompt.contains("cannot edit existing"))
        XCTAssertTrue(prompt.contains("claim_solution"))
    }

    func testRecognitionStopsAtTheResearchRouteBoundary() {
        let prompt = Recognition.systemPrompt(
            goal: "Compute an invariant with several arithmetic conditions.",
            contract: nil, notation: "", outline: "(empty)")

        XCTAssertTrue(prompt.contains("verification and triage pass"))
        XCTAssertTrue(prompt.contains("not a general solving phase"))
        XCTAssertTrue(prompt.contains("do not develop a multi-obligation solution"))
        XCTAssertTrue(prompt.contains("stopping boundary is operational"))
        XCTAssertTrue(prompt.contains("research branches exist to develop those routes"))
        XCTAssertTrue(prompt.contains("obligations that should guide the pilot selector"))
    }

    func testRecognitionReceivesTheAlreadySelectedQuestion() async throws {
        let provider = RecognitionProvider([
            [.toolUseFinished(id: "r", name: "report_recognition",
                              inputJSON: #"{"summary":"No existing classification was found."}"#),
             .finished(.toolUse)],
            [.textDelta("Reported."), .finished(.endTurn)]
        ])

        let result = try await Recognition.run(
            runner: AgentLoop(provider: provider),
            goal: "Classify all groups satisfying C.", contract: nil,
            targetItemID: "qst-classify-groups", tools: [])

        XCTAssertEqual(result?.targetItemID, "qst-classify-groups")
        let prompt = Recognition.systemPrompt(
            goal: "Classify all groups satisfying C.", contract: nil,
            notation: "", outline: "qst-classify-groups [question]")
        XCTAssertTrue(prompt.contains("research goal was already"))
        XCTAssertFalse(provider.requestedToolNames.flatMap { $0 }.contains("set_research_target"))
    }

    func testRecognitionReportCarriesTheFixedTarget() async throws {
        let provider = RecognitionProvider([
            [.toolUseFinished(id: "r", name: "report_recognition",
                              inputJSON: #"{"summary":"Looked everywhere."}"#),
             .finished(.toolUse)],
            [.textDelta("Could not finish."), .finished(.endTurn)]
        ])

        let result = try await Recognition.run(
            runner: AgentLoop(provider: provider), goal: "Classify all groups.",
            contract: nil, targetItemID: "qst-classify-groups", tools: [])

        XCTAssertEqual(result?.targetItemID, "qst-classify-groups")
    }

    func testAttemptLimitStillLeavesAReportOnlyFinalizationOpportunity() async throws {
        let probes: [[LLMEvent]] = (1...13).map { index in
            [.toolUseFinished(id: "p\(index)", name: "probe", inputJSON: "{}"),
             .finished(.toolUse)]
        }
        let finalReport: [LLMEvent] = [
            .toolUseFinished(
                id: "report", name: "report_recognition",
                inputJSON: #"{"summary":"The bounded probes found a route, but a proof remains."}"#),
            .finished(.toolUse)
        ]
        let provider = RecognitionProvider(probes + [finalReport])

        let result = try await Recognition.run(
            runner: AgentLoop(provider: provider), goal: "Prove the target.",
            contract: nil, targetItemID: "qst-target", tools: [RecognitionProbeTool()])

        XCTAssertEqual(result?.targetItemID, "qst-target")
        XCTAssertEqual(result?.summary, "The bounded probes found a route, but a proof remains.")
        XCTAssertEqual(provider.requestedToolNames.count, 14)
        XCTAssertEqual(provider.requestedToolNames.last, ["report_recognition"])
    }

    func testFinalizationPromptForbidsContinuingResearch() {
        let prompt = Recognition.finalizationPrompt(hasTarget: true)
        XCTAssertTrue(prompt.contains("Do not search, compute, solve further"))
        XCTAssertTrue(prompt.contains("only the evidence already present"))
        XCTAssertTrue(prompt.contains("Call `report_recognition` exactly once"))
    }
}
