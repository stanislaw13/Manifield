import XCTest
import ManifieldCore
@testable import ManifieldAgents

private final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    var description: String { "scripted" }
    private let lock = NSLock()
    private var scripts: [[LLMEvent]]

    init(scripts: [[LLMEvent]]) {
        self.scripts = scripts
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        let events = scripts.isEmpty ? [LLMEvent.finished(.endTurn)] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class ProposalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proposals: [TheoryProposal] = []
    func add(_ p: TheoryProposal) { lock.lock(); proposals.append(p); lock.unlock() }
    var all: [TheoryProposal] { lock.lock(); defer { lock.unlock() }; return proposals }
}

final class ProverHelperTests: XCTestCase {

    func testCleanProof() {
        XCTAssertEqual(ProofWorkbench.cleanProof("```markdown\nStep 1.\n```"), "Step 1.")
        XCTAssertEqual(ProofWorkbench.cleanProof("## Proof\nStep 1."), "Step 1.")
        XCTAssertEqual(ProofWorkbench.cleanProof("  Step 1.  "), "Step 1.")
    }

    func testReplacingProofSection() {
        let body = "## Statement\n$x=x$.\n\n## Proof\nOld proof.\n\n## Notes\nKeep me."
        let replaced = ProofWorkbench.replacingProofSection(in: body, with: "New proof.")
        XCTAssertTrue(replaced.contains("New proof."))
        XCTAssertFalse(replaced.contains("Old proof."))
        XCTAssertTrue(replaced.contains("## Notes\nKeep me."))

        let appended = ProofWorkbench.replacingProofSection(in: "## Statement\n$x=x$.", with: "Fresh.")
        XCTAssertTrue(appended.hasSuffix("## Proof\nFresh."))
    }

    func testParseVerdict() {
        let ok = LLMReviewer.parseVerdict(#"{"verdict": "no-errors-found"}"#)
        XCTAssertEqual(ok.verdict, .noErrorsFound)

        let bad = LLMReviewer.parseVerdict("""
        Some prose. {"verdict": "issues", "issues": [{"location": "step 2", "severity": "fatal", "description": "does not follow"}]}
        """)
        XCTAssertEqual(bad.verdict, .issues)
        XCTAssertEqual(bad.issues.first?.location, "step 2")

        let garbage = LLMReviewer.parseVerdict("I think it looks fine!")
        XCTAssertEqual(garbage.verdict, .issues, "unparseable output must never count as approval")
        XCTAssertTrue(garbage.issues.first?.description.contains("not parseable") ?? false)
    }

    func testExternalToolPolicies() async throws {
        let collector = ExternalCollector()
        let restricted = UseExternalResultTool(policy: .restricted, collector: collector)
        let denied = try await restricted.execute(
            inputJSON: #"{"name": "Hall's theorem", "statement": "S", "citation": "Hall (1935)"}"#)
        XCTAssertTrue(denied.contains("DENIED"))
        XCTAssertTrue(collector.all.isEmpty)

        let auto = UseExternalResultTool(policy: .autoExternal, collector: collector)
        let ok = try await auto.execute(
            inputJSON: #"{"name": "Hall's theorem", "statement": "S", "citation": "Hall (1935)"}"#)
        XCTAssertTrue(ok.contains("Recorded"))
        _ = try await auto.execute(
            inputJSON: #"{"name": "hall's THEOREM", "statement": "S2", "citation": "x"}"#)
        XCTAssertEqual(collector.all.count, 1, "declarations dedupe by name")
    }
}

final class ProofWorkbenchTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prover-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "T")
        try store.save(TheoryItem(
            id: "lem-a", type: .lemma, name: "Helper lemma", status: .humanApproved,
            body: "## Statement\n$a \\le b$."))
        try store.save(TheoryItem(
            id: "thm-t", type: .theorem, name: "Target", status: .conjecture,
            dependsOn: ["lem-a"],
            body: "## Statement\n$x = x$.\n\n## Proof\nOld sketchy proof."))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWorkbench(
        scripts: [[LLMEvent]],
        policy: KnowledgePolicy,
        maxRounds: Int,
        box: ProposalBox
    ) -> ProofWorkbench {
        ProofWorkbench(
            runner: AgentLoop(provider: ScriptedProvider(scripts: scripts)),
            store: store,
            attachedSources: [],
            extraTools: [],
            userProfile: "",
            configuration: .init(policy: policy, maxRounds: maxRounds),
            onProposal: { box.add($0) },
            onEvent: { _ in }
        )
    }

    func testProveReviseApproveWithExternal() async throws {
        let issuesJSON = #"{"verdict": "issues", "issues": [{"location": "step 1", "severity": "gap", "description": "justify the bound"}]}"#
        let scripts: [[LLMEvent]] = [
            // Round 1 prover: declares an external, then produces a draft.
            [.toolUseFinished(id: "t1", name: "use_external_result",
                              inputJSON: #"{"name": "Hall's marriage theorem", "statement": "A bipartite graph has a perfect matching iff ...", "citation": "Hall (1935)"}"#),
             .finished(.toolUse)],
            [.textDelta("Step 1. By (by lem-a) we bound the left side.\nStep 2. Apply (by external: Hall's marriage theorem)."),
             .finished(.endTurn)],
            // Reviewer round 1: issues.
            [.textDelta(issuesJSON), .finished(.endTurn)],
            // Round 2 prover: revised proof.
            [.textDelta("Step 1. By (by lem-a), since $a \\le b$, the bound holds.\nStep 2. Apply (by external: Hall's marriage theorem)."),
             .finished(.endTurn)],
            // Reviewer round 2: clean.
            [.textDelta(#"{"verdict": "no-errors-found"}"#), .finished(.endTurn)]
        ]
        let box = ProposalBox()
        let workbench = makeWorkbench(scripts: scripts, policy: .autoExternal, maxRounds: 3, box: box)
        let outcome = try await workbench.run(targetID: "thm-t")

        XCTAssertEqual(outcome.finalStatus, .reviewedNoErrors)
        XCTAssertEqual(outcome.roundsUsed, 2)
        XCTAssertEqual(outcome.externalsUsed.map(\.name), ["Hall's marriage theorem"])
        XCTAssertTrue(outcome.outstandingIssues.isEmpty)
        XCTAssertEqual(outcome.proposalCount, 2)

        let proposals = box.all
        XCTAssertEqual(proposals.count, 2)
        let update = proposals[0]
        XCTAssertEqual(update.action, .update)
        XCTAssertEqual(update.item.id, "thm-t")
        XCTAssertEqual(update.item.status, .reviewedNoErrors)
        XCTAssertTrue(update.item.body.contains("since $a \\le b$"))
        XCTAssertFalse(update.item.body.contains("Old sketchy proof"))
        XCTAssertTrue(update.item.body.contains("## Statement"), "statement section preserved")
        XCTAssertTrue(update.item.dependsOn.contains("lem-a"))
        XCTAssertTrue(update.item.dependsOn.contains("thm-hall-s-marriage-theorem"))

        let external = proposals[1]
        XCTAssertEqual(external.action, .create)
        XCTAssertEqual(external.item.id, "thm-hall-s-marriage-theorem")
        XCTAssertEqual(external.item.status, .source)
        XCTAssertEqual(external.item.section, "external-results")
        XCTAssertTrue(external.item.source?.contains("unverified") ?? false)
        // Nothing was written to the store itself.
        XCTAssertEqual(self.store.item(id: "thm-t")?.status, .conjecture)
        XCTAssertNil(self.store.item(id: "thm-hall-s-marriage-theorem"))
    }

    func testGivesUpAfterMaxRoundsWithOutstandingIssues() async throws {
        let issuesJSON = #"{"verdict": "issues", "issues": [{"location": "step 1", "severity": "fatal", "description": "wrong"}]}"#
        let scripts: [[LLMEvent]] = [
            [.textDelta("Step 1. Hand-wave."), .finished(.endTurn)],
            [.textDelta(issuesJSON), .finished(.endTurn)],
            [.textDelta("Step 1. Slightly better hand-wave."), .finished(.endTurn)],
            [.textDelta(issuesJSON), .finished(.endTurn)]
        ]
        let box = ProposalBox()
        let workbench = makeWorkbench(scripts: scripts, policy: .restricted, maxRounds: 2, box: box)
        let outcome = try await workbench.run(targetID: "thm-t")

        XCTAssertEqual(outcome.finalStatus, .proofDrafted)
        XCTAssertEqual(outcome.roundsUsed, 2)
        XCTAssertEqual(outcome.outstandingIssues.count, 1)
        XCTAssertTrue(outcome.externalsUsed.isEmpty)
        let update = box.all[0]
        XCTAssertEqual(update.item.status, .proofDrafted)
        XCTAssertTrue(update.item.body.contains("Outstanding review issues"))
        XCTAssertTrue(update.item.body.contains("[fatal] step 1"))
    }
}
