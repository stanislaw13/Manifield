import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class DirectorWorkbenchTests: XCTestCase {
    func testDirectorPromptDelegatesNovelMathematicsAndDoesNotStopBecauseGoalIsOpen() {
        XCTAssertTrue(DirectorWorkbench.system.contains(
            "Do not develop, record, or rely on a new proof, obstruction, construction"))
        XCTAssertTrue(DirectorWorkbench.system.contains(
            "Do not pause or resolve as unresolved merely because the goal is open"))
        XCTAssertTrue(DirectorWorkbench.system.contains("Those are reasons to"))
        XCTAssertTrue(DirectorWorkbench.system.contains("dispatch research work."))
    }

    func testProgramStateMakesAcceptedChallengeGovernanceExplicit() throws {
        var program = ResearchProgram(id: "challenge-state", goal: "g", execution: .init(limits: .unlimited))
        var challenge = ProblemChallenge(id: "counterexample", branchPlanID: "worker",
            targetRevisionID: program.activeTargetRevisionID, description: "The entire target is false.")
        challenge.status = .accepted
        challenge.mathematicalRuling = .init(accepted: true, note: "Verified.")
        challenge.scopeRuling = .init(accepted: true, note: "Full invalidity.",
            targetDisposition: .fullInvalidity)
        program.challenges = [challenge]

        let state = try DirectorWorkbench.state(program)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
        let challenges = try XCTUnwrap(object["challenges"] as? [[String: Any]])
        let visible = try XCTUnwrap(challenges.first)
        XCTAssertEqual(visible["mathematicalReview"] as? String, "accepted")
        XCTAssertEqual(visible["scopeReview"] as? String, "accepted")
        XCTAssertEqual(visible["targetDisposition"] as? String, "fullInvalidity")
        XCTAssertTrue((visible["actionRequired"] as? String)?.contains("Both independent reviews are complete") == true)
        XCTAssertTrue((visible["actionRequired"] as? String)?.contains("resolve_program") == true)
    }

    func testDispatchInheritsUserLimitInsteadOfModelGuessedAllocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = ResearchProgram(id: "allocation", goal: "Inspect", execution: .init(limits: .init(assignmentTokens: .bounded(150_000))))
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in .init(summary: "No result") }
        try await scheduler.start()
        let session = try ResearchConversation(key: "allocation", directory: directory)
        let director = DirectorWorkbench(runner: AgentLoop(provider: DirectorScenarioProvider(scheduler: scheduler)),
            scheduler: scheduler, conversation: session, libraryTools: [])
        let dispatch = try XCTUnwrap(director.makeTools().first { $0.spec.name == "dispatch_work" })
        XCTAssertFalse(dispatch.spec.inputSchemaJSON.contains("token_budget"))
        _ = try await dispatch.execute(callID: "allocate", inputJSON: #"{"mode":"direct","objective":"Inspect","token_budget":5000}"#)
        await scheduler.drain()
        let final = await scheduler.snapshot()
        XCTAssertEqual(final.execution?.assignments.first?.tokenLimit, .bounded(150_000))
        try await scheduler.pause("Test complete")
    }
    func testDispatchRecordsShortTitleForTheInterface() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let p = ResearchProgram(id: "titled", goal: "Inspect", execution: .init(limits: .unlimited))
        let scheduler = try PersistentResearchScheduler(program: p, save: { _ in }) { _, _, _ in .init(summary: "No result") }
        try await scheduler.start()
        let session = try ResearchConversation(key: "titled", directory: directory)
        let director = DirectorWorkbench(runner: AgentLoop(provider: DirectorScenarioProvider(scheduler: scheduler)),
            scheduler: scheduler, conversation: session, libraryTools: [])
        let dispatch = try XCTUnwrap(director.makeTools().first { $0.spec.name == "dispatch_work" })
        XCTAssertTrue(dispatch.spec.inputSchemaJSON.contains("\"title\""))
        _ = try await dispatch.execute(callID: "titled",
            inputJSON: #"{"mode":"direct","title":"Midpoint identity","objective":"Establish the midpoint identity for the local isometry, then report the exact gap."}"#)
        await scheduler.drain()
        let final = await scheduler.snapshot()
        XCTAssertEqual(final.execution?.assignments.first?.title, "Midpoint identity")
        XCTAssertTrue(try DirectorWorkbench.state(final).contains("Midpoint identity"))
        try await scheduler.pause("Test complete")
    }

    func testOneConversationSearchesDelegatesWaitsReadsAndContinuesSpecificGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = ResearchProgram(id: "scenario", goal: "Prove the local extension", execution: .init(limits: .unlimited))
        let scheduler = try PersistentResearchScheduler(program: program, save: { _ in }) { assignment, _, scheduler in
            try await scheduler.acknowledgeGuidance(assignmentID: assignment.id, messageIDs: assignment.messages.map(\.id))
            return .init(outcome: assignment.revision == 1 ? .partial : .achieved,
                  summary: assignment.revision == 1 ? "The local step works; the midpoint identity remains." : "The focused midpoint step is established.",
                  unresolved: assignment.revision == 1 ? "midpoint identity" : "")
        }
        try await scheduler.start()
        let provider = DirectorScenarioProvider(scheduler: scheduler)
        let session = try ResearchConversation(key: "scenario", directory: directory)
        let search = FunctionAgentTool(name: "search_theory", description: "Search", schema: "{}") { _, _ in "lem-local — local isometry" }
        let director = DirectorWorkbench(runner: AgentLoop(provider: provider), scheduler: scheduler,
            conversation: session, libraryTools: [search])
        try await director.run()
        await scheduler.drain()
        let final = await scheduler.snapshot(), requests = await provider.requests
        XCTAssertEqual(final.execution?.assignments.count, 1)
        XCTAssertEqual(final.execution?.assignments[0].reports.count, 2)
        XCTAssertEqual(final.execution?.assignments[0].revision, 2)
        XCTAssertEqual(final.execution?.resolution?.kind, .unresolved)
        XCTAssertGreaterThan(requests.count, 5)
        XCTAssertTrue(requests.last!.messages.count > requests.first!.messages.count)
        XCTAssertTrue(requests.allSatisfy { request in
            !request.tools.contains { $0.name == "route_findings" || $0.name == "propose_portfolio" }
        })
        let saved = await session.snapshot()
        XCTAssertGreaterThan(saved.eventCursor, 0)
        XCTAssertTrue(saved.messages.flatMap(\.blocks).contains { block in
            if case .toolUse(_, let name, let json) = block { return name == "continue_work" && json.contains("midpoint") }; return false
        })
    }
}

private actor DirectorScenarioProvider: LLMProvider {
    nonisolated var description: String { "scripted director" }
    private let scheduler: PersistentResearchScheduler
    var requests: [LLMRequest] = []
    init(scheduler: PersistentResearchScheduler) { self.scheduler = scheduler }
    nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events = await self.next(request)
                events.forEach { continuation.yield($0) }; continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func next(_ request: LLMRequest) async -> [LLMEvent] {
        requests.append(request)
        let state = await scheduler.snapshot(), step = requests.count
        let assignment = state.execution?.assignments.first
        let name: String, input: String
        switch step {
        case 1: name = "search_theory"; input = "{}"
        case 2: name = "dispatch_work"; input = #"{"mode":"direct","objective":"Use lem-local to establish the local extension","item_ids":["lem-local"]}"#
        case 3, 6:
            name = "wait_for_work"
            input = "{\"after_sequence\":\(state.execution?.events.last?.sequence ?? 0)}"
        case 4:
            name = "read_research_record"; input = "{\"id\":\"\(assignment!.id)\"}"
        case 5:
            name = "continue_work"; input = "{\"assignment_id\":\"\(assignment!.id)\",\"message\":\"Work only on the unresolved midpoint identity.\"}"
        default:
            name = "resolve_program"; input = #"{"kind":"unresolved","evidence_ids":[],"explanation":"A local lemma is established, but the full extension is not yet proved."}"#
        }
        return [.toolUseFinished(id: "step-\(step)", name: name, inputJSON: input), .finished(.toolUse)]
    }
}
