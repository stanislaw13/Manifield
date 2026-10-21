import XCTest
import ManifieldCore
@testable import ManifieldAgents

/// Thread-safe holder standing in for the app's main-actor memory store.
private final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String
    init(_ text: String) { self.text = text }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    func set(_ new: String) { lock.lock(); text = new; lock.unlock() }
}

final class MemoryToolsTests: XCTestCase {

    private func makeTool(_ box: MemoryBox) -> AgentTool {
        MemoryTools.updateTool(
            currentMemory: { box.get() },
            saveMemory: { box.set($0) }
        )
    }

    func testReplacesOneSectionAndKeepsOthers() async throws {
        let box = MemoryBox("## Goal\nOld goal\n\n## Key Insights\nInsight A\n")
        let reply = try await makeTool(box).execute(inputJSON: """
            {"section": "goal", "content": "Prove conj-x."}
            """)
        XCTAssertTrue(reply.contains("Goal"))
        let document = MemoryDocument.parse(markdown: box.get())
        XCTAssertEqual(document.sections[.goal], "Prove conj-x.")
        XCTAssertEqual(document.sections[.keyInsights], "Insight A")
    }

    func testRejectsOversizeWithCompressionInstruction() async throws {
        let box = MemoryBox("")
        let huge = String(repeating: "x", count: MemoryDocument.maxLength + 1)
        do {
            _ = try await makeTool(box).execute(inputJSON: """
                {"section": "key-insights", "content": "\(huge)"}
                """)
            XCTFail("expected rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("REJECTED"))
            XCTAssertTrue(error.localizedDescription.contains("Compress"))
        }
        XCTAssertEqual(box.get(), "", "nothing must be written on rejection")
    }

    func testRejectsUnknownSection() async {
        let box = MemoryBox("")
        await XCTAssertThrowsErrorAsync(
            try await self.makeTool(box).execute(inputJSON: #"{"section": "nope", "content": "x"}"#))
    }
}

final class MemoryPromptInjectionTests: XCTestCase {

    func testChatPromptCarriesMemoryAndRules() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "",
            memory: "## Goal\nProve the doubling conjecture.\n"
        ).text
        XCTAssertTrue(prompt.contains("Research memory"))
        XCTAssertTrue(prompt.contains("Prove the doubling conjecture."))
        XCTAssertTrue(prompt.contains("Memory discipline (update_memory):"))
    }

    func testChatPromptMarksEmptyMemory() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: "", memory: ""
        ).text
        XCTAssertTrue(prompt.contains("the research memory is empty"))
    }

    func testChatPromptWithoutMemoryParameterOmitsSection() {
        let prompt = ContextAssembly.chatSystemPrompt(
            projectName: "P", notation: "", items: [], userProfile: ""
        ).text
        XCTAssertFalse(prompt.contains("Research memory"))
    }

    func testProverPromptIncludesNonEmptyMemoryOnly() {
        let with = ProverPrompts.proverSystem(
            policy: .restricted, notation: "", outline: "(empty)", userProfile: "",
            memory: "## Eliminated Strategies\n- induction on n — fails.\n")
        XCTAssertTrue(with.contains("induction on n — fails."))
        XCTAssertFalse(with.contains("Memory discipline"),
                       "the prover has no update_memory tool, so no update rules")

        let without = ProverPrompts.proverSystem(
            policy: .restricted, notation: "", outline: "(empty)", userProfile: "", memory: "")
        XCTAssertFalse(without.contains("Research memory"))
    }
}
