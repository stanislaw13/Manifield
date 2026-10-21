import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class GoalEditorProvider: LLMProvider, @unchecked Sendable {
    var description: String { "goal-editor-test" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]
    init(_ scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        let events = scripts.isEmpty ? [.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

final class ResearchGoalEditorTests: XCTestCase {
    private func makeStore() throws -> (ProjectStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-editor-tests-\(UUID().uuidString)")
        return (try ProjectStore.create(at: dir, name: "Goals"), dir)
    }

    func testSelectsAnExistingNaturalGoalItemAndDerivesContractFromItsStatement() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(TheoryItem(
            id: "conj-collatz", type: .conjecture, name: "Collatz conjecture",
            body: "## Statement\nFor every $n\\in\\mathbb N_{>0}$, some iterate of $f$ equals $1$."))
        let input = #"{"existing_item_id":"conj-collatz","recommended_reading":"The standard Collatz conjecture.","conventions":["Positive integers only"]}"#
        let provider = GoalEditorProvider([
            [.toolUseFinished(id: "g", name: "finalize_research_goal", inputJSON: input),
             .finished(.toolUse)],
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let result = try await ResearchGoalEditor.run(
            runner: AgentLoop(provider: provider), request: "Solve 3k+1 problem",
            store: store, tools: TheoryTools.readOnlyTools(store: store),
            outline: ContextAssembly.outline(items: store.items),
            applyCreate: { _ in XCTFail("existing selection must not write"); return "" })

        XCTAssertEqual(result?.item.id, "conj-collatz")
        XCTAssertEqual(result?.draft.contract.statement, result?.item.statement)
        XCTAssertEqual(result?.draft.contract.recommendedReading,
                       "The standard Collatz conjecture.")
        XCTAssertFalse(result?.createdItem ?? true)
        XCTAssertFalse(result?.interpretationConfirmed ?? true)
    }

    func testCreatesMissingGoalItemWithCompleteStatement() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = """
        ---
        id: conj-collatz
        type: conjecture
        name: Collatz conjecture
        status: conjecture
        depends_on: []
        resolves: []
        tags: [dynamics]
        ---
        ## Statement
        Define $f(n)=n/2$ for even $n$ and $f(n)=3n+1$ for odd $n$. For every positive
        integer $n$, there exists $i\\ge 0$ such that $f^i(n)=1$.
        """
        let json = try JSONSerialization.data(withJSONObject: [
            "new_item_markdown": markdown,
            "recommended_reading": "The standard Collatz conjecture.",
            "interpretation_note": "The shorthand was resolved automatically."
        ])
        let input = try XCTUnwrap(String(data: json, encoding: .utf8))
        let provider = GoalEditorProvider([
            [.toolUseFinished(id: "g", name: "finalize_research_goal", inputJSON: input),
             .finished(.toolUse)],
            [.textDelta("Done."), .finished(.endTurn)]
        ])

        let result = try await ResearchGoalEditor.run(
            runner: AgentLoop(provider: provider), request: "Solve 3k+1 problem",
            store: store, outline: "(empty)",
            applyCreate: { proposal in
                try store.save(proposal.item)
                return "created"
            })

        XCTAssertTrue(result?.createdItem == true)
        XCTAssertEqual(store.item(id: "conj-collatz")?.statement,
                       result?.draft.contract.statement)
        XCTAssertEqual(result?.draft.contract.recommendedReading,
                       "The standard Collatz conjecture.")
        XCTAssertEqual(result?.draft.ambiguityNote,
                       "The shorthand was resolved automatically.")
    }
}

// MARK: - Prompt assembly

/// The goal editor's rules used to live in `statement_auditor.md` and `contract_drafter.md`.
/// Merging the two turns into one agent silently orphaned both files, and nothing failed —
/// which is how the fidelity rules were lost. These guard the replacement against the same
/// silence: the manifest must resolve, and the assembled prompt must actually carry both
/// the rule and the user's own words.
extension ResearchGoalEditorTests {

    func testPromptManifestResolves() {
        XCTAssertEqual(PromptLibrary.validateAll(), [],
                       "every manifest template must exist with exactly its declared placeholders")
    }

    func testSystemPromptCarriesTheRequestAndTheFidelityRule() {
        let request = "Find $\\lfloor 100L\\rfloor$ — the average number of components."
        let prompt = ResearchGoalEditor.systemPrompt(
            request: request, notation: "", macros: "", outline: "(the library is empty)")

        XCTAssertFalse(prompt.contains("[PROMPT TEMPLATE ERROR"),
                       "research_goal_editor.md must load from the bundle")
        // The request is repeated into the system prompt on purpose: the library search runs
        // first and can bury the opening message under unrelated theory.
        XCTAssertTrue(prompt.contains(request))
        XCTAssertTrue(prompt.contains("A standard reading is what you fall back on where the "
                                      + "request is silent."))
        XCTAssertTrue(prompt.contains("Inventing doubt is as costly as missing it"))
        XCTAssertTrue(prompt.contains("Set `status: conjecture`"))
        XCTAssertTrue(prompt.contains("`open` is not a valid status value"))
        // honesty_rules is deliberately absent here — see systemPrompt's doc comment.
        XCTAssertFalse(prompt.contains("Epistemic contract"))
    }

    func testOpeningMessageDoesNotDisownTheRequest() {
        let message = ResearchGoalEditor.openingMessage(request: "Solve 3k+1 problem")
        // The old framing told the model not to use the request's own wording as the goal;
        // that single sentence is what licensed overriding the user's stated reading.
        XCTAssertFalse(message.contains("do not use its shorthand"))
        XCTAssertTrue(message.contains("exactly as they wrote it"))
        XCTAssertTrue(message.contains("Solve 3k+1 problem"))
    }
}
