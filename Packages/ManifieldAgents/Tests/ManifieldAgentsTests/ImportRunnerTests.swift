import XCTest
import ManifieldCore
@testable import ManifieldAgents

final class ImportProgressTests: XCTestCase {

    func testOverallFractionBlendsCompletedAndInFlight() {
        var progress = ImportProgress(totalChunks: 4, concurrency: 2)
        XCTAssertEqual(progress.overallFraction, 0)

        progress.chunkStarted(index: 0)
        progress.chunkStarted(index: 1)
        progress.chunkProgress(index: 0, streamedChars: 3_000)  // half of the 6k default
        XCTAssertEqual(progress.fraction(ofInFlight: 0), 0.5, accuracy: 0.01)
        XCTAssertEqual(progress.overallFraction, 0.5 / 4, accuracy: 0.01)

        progress.chunkFinished(
            index: 0, items: [TheoryItem(id: "def-a", type: .definition, name: "A")],
            duration: 10, responseChars: 4_000)
        // In-flight estimates now use the observed 4k average, not the default.
        progress.chunkProgress(index: 1, streamedChars: 2_000)
        XCTAssertEqual(progress.fraction(ofInFlight: 1), 0.5, accuracy: 0.01)
        XCTAssertEqual(progress.overallFraction, (1 + 0.5) / 4, accuracy: 0.01)
    }

    func testInFlightEstimateNeverClaimsCompletion() {
        var progress = ImportProgress(totalChunks: 2, concurrency: 1)
        progress.chunkStarted(index: 0)
        progress.chunkProgress(index: 0, streamedChars: 1_000_000)
        XCTAssertEqual(progress.fraction(ofInFlight: 0), ImportProgress.inFlightCap)
    }

    func testETAUsesAverageDurationAndConcurrency() {
        var progress = ImportProgress(totalChunks: 10, concurrency: 2)
        XCTAssertNil(progress.etaSeconds, "no estimate before the first chunk lands")

        progress.chunkStarted(index: 0)
        progress.chunkFinished(index: 0, items: [], duration: 30, responseChars: 5_000)
        progress.chunkStarted(index: 1)
        progress.chunkFinished(index: 1, items: [], duration: 60, responseChars: 5_000)
        // avg 45 s × 8 outstanding ÷ 2 workers = 180 s.
        XCTAssertEqual(try XCTUnwrap(progress.etaSeconds), 180, accuracy: 1)

        // Streaming progress on a running chunk shrinks the outstanding work.
        progress.chunkStarted(index: 2)
        progress.chunkProgress(index: 2, streamedChars: 2_500)  // half of the 5k average
        XCTAssertEqual(try XCTUnwrap(progress.etaSeconds), 45 * 7.5 / 2, accuracy: 1)
    }

    func testNoETAWhenDone() {
        var progress = ImportProgress(totalChunks: 1, concurrency: 3)
        progress.chunkStarted(index: 0)
        progress.chunkFinished(index: 0, items: [], duration: 5, responseChars: 100)
        XCTAssertNil(progress.etaSeconds)
        XCTAssertEqual(progress.overallFraction, 1)
    }

    func testItemCountsAndSummary() {
        var progress = ImportProgress(totalChunks: 2, concurrency: 1)
        progress.chunkFinished(index: 0, items: [
            TheoryItem(id: "def-a", type: .definition, name: "A"),
            TheoryItem(id: "def-b", type: .definition, name: "B"),
            TheoryItem(id: "thm-c", type: .theorem, name: "C")
        ], duration: 5, responseChars: 100)
        progress.chunkFailed(index: 1, duration: 2)

        XCTAssertEqual(progress.itemsTotal, 3)
        XCTAssertEqual(progress.itemCountSummary, "2 definitions · 1 theorem")
        XCTAssertEqual(progress.failedChunks, 1)
        XCTAssertEqual(progress.completedChunks, 2)
    }

    func testETAFormatting() {
        XCTAssertEqual(ImportProgress.formatETA(42), "42 s")
        XCTAssertEqual(ImportProgress.formatETA(200), "3 min")
    }
}

// MARK: - Runner

/// Thread-safe scripted provider: maps each request to a response by inspecting its
/// content (parallel chunk order is nondeterministic). A nil response parks the
/// stream without finishing — the consumer only leaves it via task cancellation.
private final class KeyedProvider: LLMProvider, @unchecked Sendable {
    var description: String { "keyed" }
    private let lock = NSLock()
    private(set) var systemPrompts: [String] = []
    private let respond: @Sendable (LLMRequest) -> [LLMEvent]?

    init(respond: @escaping @Sendable (LLMRequest) -> [LLMEvent]?) {
        self.respond = respond
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        systemPrompts.append(request.system.text)
        lock.unlock()
        let events = respond(request)
        return AsyncThrowingStream { continuation in
            guard let events else { return }  // parked
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Collects runner events across worker threads.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [SourceImportEvent] = []
    func append(_ event: SourceImportEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
}

final class SourceImportRunnerTests: XCTestCase {

    private func chunk(_ n: Int) -> SourceImport.Chunk {
        SourceImport.Chunk(title: "Chapter \(n)", section: "chapter-\(n)", text: "CHUNK\(n) body text")
    }

    private static func itemJSON(id: String) -> String {
        #"[{"id":"\#(id)","type":"definition","name":"\#(id)","statement":"S"},{"type":"summary","content":"note for \#(id)"}]"#
    }

    func testParallelRunEmitsAllEventsAndNormalizes() async throws {
        let provider = KeyedProvider { request in
            // Identify the chunk from the user message and answer for it.
            let text = request.messages.first?.plainText ?? ""
            let n = (1...3).first { text.contains("CHUNK\($0)") } ?? 0
            return [.textDelta(Self.itemJSON(id: "def-c\(n)")), .finished(.endTurn)]
        }
        let log = EventLog()
        let runner = SourceImportRunner(
            chunks: [chunk(1), chunk(2), chunk(3)],
            citation: "Author, 2001",
            concurrency: 3,
            runner: AgentLoop(provider: provider),
            currentIDs: { [] },
            onEvent: { log.append($0) })
        try await runner.run()

        var started = Set<Int>(), finished = Set<Int>()
        for event in log.events {
            switch event {
            case .chunkStarted(let index, _): started.insert(index)
            case .chunkFinished(let index, _, let items, let note, _, let duration, let chars):
                finished.insert(index)
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items[0].status, .source, "normalize must run in the runner")
                XCTAssertEqual(items[0].source, "Author, 2001")
                XCTAssertEqual(items[0].section, "chapter-\(index + 1)")
                XCTAssertEqual(note, "note for def-c\(index + 1)")
                XCTAssertGreaterThan(duration, 0)
                XCTAssertGreaterThan(chars, 0)
            case .chunkFailed(let index, _, let message, _):
                XCTFail("chunk \(index) failed: \(message)")
            case .chunkRetrying(let index, _, _, _, let reason):
                XCTFail("chunk \(index) retried: \(reason)")
            case .chunkProgress: break
            }
        }
        XCTAssertEqual(started, [0, 1, 2])
        XCTAssertEqual(finished, [0, 1, 2])
    }

    func testFailedChunkIsIsolated() async throws {
        let provider = KeyedProvider { request in
            let text = request.messages.first?.plainText ?? ""
            if text.contains("CHUNK2") {
                return [.textDelta("no json here at all"), .finished(.endTurn)]
            }
            let n = text.contains("CHUNK1") ? 1 : 3
            return [.textDelta(Self.itemJSON(id: "def-c\(n)")), .finished(.endTurn)]
        }
        let log = EventLog()
        let runner = SourceImportRunner(
            chunks: [chunk(1), chunk(2), chunk(3)],
            citation: nil, concurrency: 2, runner: AgentLoop(provider: provider),
            currentIDs: { [] }, onEvent: { log.append($0) })
        try await runner.run()  // must not throw

        var finished = Set<Int>(), failed = Set<Int>()
        for event in log.events {
            if case .chunkFinished(let index, _, _, _, _, _, _) = event { finished.insert(index) }
            if case .chunkFailed(let index, _, _, _) = event { failed.insert(index) }
        }
        XCTAssertEqual(failed, [1])
        XCTAssertEqual(finished, [0, 2])
    }

    func testTakenIDsReachLaterChunksWhenSequential() async throws {
        let provider = KeyedProvider { request in
            let text = request.messages.first?.plainText ?? ""
            let n = (1...2).first { text.contains("CHUNK\($0)") } ?? 0
            return [.textDelta(Self.itemJSON(id: "def-c\(n)")), .finished(.endTurn)]
        }
        // Simulate the app: saved ids accumulate as chunks finish.
        let saved = EventLog()
        let runner = SourceImportRunner(
            chunks: [chunk(1), chunk(2)],
            citation: nil, concurrency: 1, runner: AgentLoop(provider: provider),
            currentIDs: {
                saved.events.compactMap {
                    if case .chunkFinished(_, _, let items, _, _, _, _) = $0 { return items.first?.id }
                    return nil
                }
            },
            onEvent: { saved.append($0) })
        try await runner.run()

        XCTAssertEqual(provider.systemPrompts.count, 2)
        XCTAssertFalse(provider.systemPrompts[0].contains("def-c1"))
        XCTAssertTrue(provider.systemPrompts[1].contains("def-c1"),
                      "second chunk's prompt must list the first chunk's saved id")
    }

    func testSubsetRunKeepsOriginalIndices() async throws {
        // Resume/retry path: only chunks 0 and 2 run, and their events (and section /
        // order stamps) must carry the ORIGINAL indices.
        let provider = KeyedProvider { request in
            let text = request.messages.first?.plainText ?? ""
            let n = (1...3).first { text.contains("CHUNK\($0)") } ?? 0
            return [.textDelta(Self.itemJSON(id: "def-c\(n)")), .finished(.endTurn)]
        }
        let log = EventLog()
        let runner = SourceImportRunner(
            chunks: [chunk(1), chunk(2), chunk(3)],
            indices: [0, 2],
            citation: nil, concurrency: 2, runner: AgentLoop(provider: provider),
            currentIDs: { [] }, onEvent: { log.append($0) })
        try await runner.run()

        var finished: [Int: TheoryItem] = [:]
        for event in log.events {
            if case .chunkFinished(let index, _, let items, _, _, _, _) = event {
                finished[index] = items.first
            }
        }
        XCTAssertEqual(Set(finished.keys), [0, 2], "only the requested chunks run")
        XCTAssertEqual(finished[2]?.section, "chapter-3")
        XCTAssertEqual(finished[2]?.order, 2000, "order stamp uses the original chunk index")
    }

    func testCancellationStopsPendingChunks() async throws {
        // First chunk parks forever; cancelling the run must end it promptly.
        let provider = KeyedProvider { request in
            let text = request.messages.first?.plainText ?? ""
            if text.contains("CHUNK1") { return nil }  // parked stream
            return [.textDelta(Self.itemJSON(id: "def-x")), .finished(.endTurn)]
        }
        let log = EventLog()
        let runner = SourceImportRunner(
            chunks: [chunk(1), chunk(2), chunk(3)],
            citation: nil, concurrency: 1, runner: AgentLoop(provider: provider),
            currentIDs: { [] }, onEvent: { log.append($0) })

        let task = Task { try await runner.run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            try await task.value
        } catch is CancellationError {
            // expected
        }
        let finishedCount = log.events.filter {
            if case .chunkFinished = $0 { return true }
            return false
        }.count
        XCTAssertEqual(finishedCount, 0, "no chunk should complete after cancellation")
    }
}
