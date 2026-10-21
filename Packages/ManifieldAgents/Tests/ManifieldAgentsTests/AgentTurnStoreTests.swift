import XCTest
@testable import ManifieldAgents
@testable import ManifieldCore

/// The transcript store, and the guarantee it exists for: **nothing a run reasons through is
/// destroyed.** Compaction used to be the one irreversible act in the system.
final class AgentTurnStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-store-tests-\(UUID().uuidString)")
        store = try ProjectStore.create(at: tempDir, name: "T")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func turn(_ role: AgentTurnRecord.Role, title: String = "t",
                      messages: [LLMMessage] = [.user("hello")],
                      programID: String = "prog-1") -> AgentTurnRecord {
        AgentTurnRecord(programID: programID, role: role, title: title, messages: messages)
    }

    // MARK: - Round trip

    /// Timestamps are pinned to whole milliseconds because the files are written in ISO8601 so
    /// that a person can open one — that format is millisecond-resolution, and a `Date` built
    /// from `Date()` is finer. Millisecond ordering is ample here, and the sequence prefix is
    /// the authoritative order in any case.
    func testATurnSurvivesARoundTrip() throws {
        let original = AgentTurnRecord(
            programID: "prog-1", role: .directorVerdict, subjectID: nil,
            title: "Director", systemPrompt: "you rule on programs",
            messages: [.user("state"), LLMMessage(role: .assistant, blocks: [.text("continue")])],
            outcome: "continue", model: "claude-opus-5", tokensIn: 100, tokensOut: 20,
            startedAt: Date(timeIntervalSince1970: 1_770_000_000.25),
            endedAt: Date(timeIntervalSince1970: 1_770_000_042.5))
        let name = try store.saveTurn(original)
        let loaded = try XCTUnwrap(store.loadTurn(programID: "prog-1", fileName: name))
        XCTAssertEqual(loaded, original)
    }

    /// Two turns finishing inside the same second must not collapse to the same instant — a
    /// judging turn following the turn it rules on routinely does.
    func testSubSecondTimestampsAreNotTruncated() throws {
        let early = Date(timeIntervalSince1970: 1_770_000_000.125)
        let late = Date(timeIntervalSince1970: 1_770_000_000.875)
        let name = try store.saveTurn(AgentTurnRecord(
            programID: "prog-1", role: .routing, title: "routing",
            startedAt: early, endedAt: late))
        let loaded = try XCTUnwrap(store.loadTurn(programID: "prog-1", fileName: name))
        XCTAssertEqual(loaded.startedAt, early)
        XCTAssertEqual(loaded.endedAt, late)
    }

    func testSummariesAreChronologicalAndCarryNoMessages() throws {
        try store.saveTurn(turn(.statementAudit, title: "first"))
        try store.saveTurn(turn(.contractDraft, title: "second"))
        try store.saveTurn(turn(.pilot, title: "third"))

        let summaries = store.turnSummaries(programID: "prog-1")
        XCTAssertEqual(summaries.map(\.title), ["first", "second", "third"])
        XCTAssertTrue(summaries.allSatisfy { $0.byteSize > 0 })
    }

    /// The sequence prefix is read back off disk rather than kept in memory, so a relaunch
    /// mid-program does not restart numbering and silently interleave two runs' turns.
    func testSequenceNumberingSurvivesAFreshStore() throws {
        try store.saveTurn(turn(.pilot, title: "before"))
        let reopened = try ProjectStore(opening: tempDir)
        try reopened.saveTurn(turn(.pilot, title: "after"))
        XCTAssertEqual(store.turnSummaries(programID: "prog-1").map(\.title), ["before", "after"])
    }

    func testTurnsAreScopedToTheirProgram() throws {
        try store.saveTurn(turn(.pilot, title: "mine", programID: "prog-1"))
        try store.saveTurn(turn(.pilot, title: "theirs", programID: "prog-2"))
        XCTAssertEqual(store.turnSummaries(programID: "prog-1").map(\.title), ["mine"])
        XCTAssertEqual(store.turnSummaries(programID: "prog-2").map(\.title), ["theirs"])
    }

    /// A half-written file from a crash must not make the rest of the history unopenable —
    /// that is the exact failure this store exists to prevent.
    func testACorruptTurnFileIsSkippedRatherThanFatal() throws {
        try store.saveTurn(turn(.pilot, title: "good"))
        let directory = store.turnsURL(programID: "prog-1")
        try Data("{ not json".utf8)
            .write(to: directory.appendingPathComponent("0002-pilot-broken.json"))
        XCTAssertEqual(store.turnSummaries(programID: "prog-1").map(\.title), ["good"])
    }

    func testAnUnknownRoleFromANewerBuildDecodesAsOther() throws {
        let json = #"{"id":"x","programID":"prog-1","role":"telepathy","title":"t"}"#
        let decoded = try JSONDecoder().decode(AgentTurnRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.role, .other)
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    // MARK: - Size discipline

    /// A 12 MB sandbox stdout in a transcript buys nothing — it is already an artifact on disk —
    /// and makes the file unopenable. It is cut with the elided length named, so a reader can
    /// see that something was removed rather than silently reading a truncated result as whole.
    func testAnOversizedToolResultIsCutWithItsLengthNamed() throws {
        let huge = String(repeating: "x", count: 200_000)
        let record = AgentTurnRecord(
            programID: "prog-1", role: .branchLeg, title: "big",
            messages: [LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "t1", content: huge, isError: false)
            ])])
        guard case .toolResult(_, let content, _) = record.messages[0].blocks[0] else {
            return XCTFail("expected a tool result")
        }
        XCTAssertLessThan(content.count, 20_000)
        XCTAssertTrue(content.contains("characters elided"))
    }

    func testOrdinaryToolResultsAreUntouched() throws {
        let record = AgentTurnRecord(
            programID: "prog-1", role: .branchLeg, title: "small",
            messages: [LLMMessage(role: .user, blocks: [
                .toolResult(toolUseID: "t1", content: "42", isError: false)
            ])])
        guard case .toolResult(_, let content, _) = record.messages[0].blocks[0] else {
            return XCTFail("expected a tool result")
        }
        XCTAssertEqual(content, "42")
    }

    // MARK: - Housekeeping

    func testPurgeRemovesTranscriptsAndReportsZeroAfterwards() throws {
        try store.saveTurn(turn(.pilot))
        try store.saveTurn(turn(.portfolio))
        XCTAssertGreaterThan(store.turnsByteSize(programID: "prog-1"), 0)

        try store.purgeTurns(programID: "prog-1")
        XCTAssertEqual(store.turnSummaries(programID: "prog-1"), [])
        XCTAssertEqual(store.turnsByteSize(programID: "prog-1"), 0)
    }

    func testPurgingAProgramWithNoTranscriptsIsNotAnError() throws {
        XCTAssertNoThrow(try store.purgeTurns(programID: "never-ran"))
    }

    func testAProgramWithNoTurnsReportsEmptyRatherThanFailing() {
        XCTAssertEqual(store.turnSummaries(programID: "nothing-here"), [])
        XCTAssertEqual(store.turnsByteSize(programID: "nothing-here"), 0)
    }

    // MARK: - Adoption

    /// The front half runs before a program exists, so its turns are written under a session id
    /// and adopted at approval. Without this the pilots — the thing a reader most wants to see —
    /// would be filed under an id nothing ever looks up.
    func testApprovalAdoptsThePlanningSessionsTurns() throws {
        try store.saveTurn(turn(.statementAudit, title: "audit", programID: "planning-123"))
        try store.saveTurn(turn(.pilot, title: "direct", programID: "planning-123"))

        try store.adoptTurns(fromSession: "planning-123", toProgram: "2026-08-07-real")

        XCTAssertEqual(store.turnSummaries(programID: "2026-08-07-real").map(\.title),
                       ["audit", "direct"])
        XCTAssertEqual(store.turnSummaries(programID: "planning-123"), [])
    }

    func testAdoptingIntoAProgramThatAlreadyHasTurnsMergesRatherThanClobbers() throws {
        try store.saveTurn(turn(.branchLeg, title: "existing", programID: "prog-1"))
        try store.saveTurn(turn(.pilot, title: "adopted", programID: "planning-9"))

        try store.adoptTurns(fromSession: "planning-9", toProgram: "prog-1")

        XCTAssertEqual(Set(store.turnSummaries(programID: "prog-1").map(\.title)),
                       ["existing", "adopted"])
    }

    func testAdoptingASessionThatRecordedNothingIsNotAnError() {
        XCTAssertNoThrow(try store.adoptTurns(fromSession: "never-ran", toProgram: "prog-1"))
    }
}
