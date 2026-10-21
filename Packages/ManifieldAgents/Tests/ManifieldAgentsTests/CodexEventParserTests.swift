import XCTest
@testable import ManifieldAgents

final class CodexEventParserTests: XCTestCase {

    private func drain(_ lines: [String], threadID: String = "t1") throws -> [CodexEvent] {
        let parser = CodexEventParser(threadID: threadID)
        var events: [CodexEvent] = []
        for line in lines { events += try parser.handle(line: line) }
        return events
    }

    func testAgentMessageDeltaStreamsAsTextDelta() throws {
        let events = try drain([
            #"{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"tu1","itemId":"i1","delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"t1","turnId":"tu1","itemId":"i1","delta":"lo"}}"#
        ])
        XCTAssertEqual(events, [.textDelta("Hel"), .textDelta("lo")])
    }

    func testReasoningDeltasStreamAsThinkingDelta() throws {
        let events = try drain([
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"t1","turnId":"tu1","itemId":"i1","summaryIndex":0,"delta":"pondering"}}"#,
            #"{"method":"item/reasoning/textDelta","params":{"threadId":"t1","turnId":"tu1","itemId":"i1","contentIndex":0,"delta":"…more"}}"#
        ])
        XCTAssertEqual(events, [.thinkingDelta("pondering"), .thinkingDelta("…more")])
    }

    /// `phase` distinguishes mid-turn commentary from the turn's actual answer — only the
    /// latter should be treated as final by whoever assembles `finalText`.
    func testAgentMessageCompletedDistinguishesCommentaryFromFinalAnswer() throws {
        let events = try drain([
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","completedAtMs":1,"item":{"type":"agentMessage","id":"i1","text":"I'll search theory.","phase":"commentary"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","completedAtMs":2,"item":{"type":"agentMessage","id":"i2","text":"It returned X.","phase":"final_answer"}}}"#
        ])
        XCTAssertEqual(events, [
            .agentMessageCompleted(text: "I'll search theory.", isFinal: false),
            .agentMessageCompleted(text: "It returned X.", isFinal: true)
        ])
    }

    /// `phase` is nil on some models ("providers do not emit this consistently" per the
    /// schema) — that must not crash, and must not be mistaken for final.
    func testAgentMessageWithNoPhaseIsNotTreatedAsFinal() throws {
        let events = try drain([
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","completedAtMs":1,"item":{"type":"agentMessage","id":"i1","text":"Done."}}}"#
        ])
        XCTAssertEqual(events, [.agentMessageCompleted(text: "Done.", isFinal: false)])
    }

    func testReasoningItemCompletedJoinsSummaryLines() throws {
        let events = try drain([
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","completedAtMs":1,"item":{"type":"reasoning","id":"r1","summary":["Step one.","Step two."]}}}"#
        ])
        XCTAssertEqual(events, [.reasoningCompleted(text: "Step one.\nStep two.")])
    }

    /// `dynamicToolCall` items never enter the transcript — their id/tool/arguments already
    /// came through the `item/tool/call` request, which is the one source of truth for them.
    func testDynamicToolCallCompletedItemProducesNoEvent() throws {
        let events = try drain([
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","completedAtMs":1,"item":{"type":"dynamicToolCall","id":"exec-1","tool":"search_theory","arguments":{"query":"x"},"status":"completed"}}}"#
        ])
        XCTAssertEqual(events, [])
    }

    /// `item/tool/call` is a server *request* (has a top-level id), not a plain notification —
    /// the parser must classify and surface it the same as any other line.
    func testToolCallRequestIsExtractedWithItsReplyID() throws {
        let events = try drain([
            #"{"id":42,"method":"item/tool/call","params":{"threadId":"t1","turnId":"tu1","callId":"exec-1","tool":"search_theory","arguments":{"query":"compactness"}}}"#
        ])
        XCTAssertEqual(events, [.toolCallRequested(
            requestID: .number(42), callID: "exec-1", tool: "search_theory",
            argumentsJSON: #"{"query":"compactness"}"#)])
    }

    func testUnknownNotificationIsIgnoredNotFatal() throws {
        let events = try drain([
            #"{"method":"mcpServer/startupStatus/updated","params":{"threadId":"t1","name":"x","status":"ready"}}"#,
            #"{"method":"thread/status/changed","params":{"threadId":"t1","status":"active"}}"#
        ])
        XCTAssertEqual(events, [])
    }

    func testMalformedLineIsIgnored() throws {
        XCTAssertEqual(try drain(["not json", "{}", ""]), [])
    }

    // MARK: - Usage deltas

    func testUsageEmitsDeltaNotCumulativeTotal() throws {
        let events = try drain([
            usageLine(total: (input: 100, output: 10)),
            usageLine(total: (input: 150, output: 25))
        ])
        XCTAssertEqual(events, [.usage(input: 100, output: 10), .usage(input: 50, output: 15)])
    }

    /// A duplicate cumulative snapshot must not double-count — the delta against an unchanged
    /// baseline is zero, and a zero delta is dropped rather than forwarded as a no-op event.
    func testDuplicateUsageSnapshotEmitsNoDelta() throws {
        let events = try drain([
            usageLine(total: (input: 100, output: 10)),
            usageLine(total: (input: 100, output: 10))
        ])
        XCTAssertEqual(events, [.usage(input: 100, output: 10)])
    }

    /// A snapshot that goes backwards (reordering, or a counter reset) must never subtract from
    /// a budget — the delta clamps to zero rather than going negative.
    func testOutOfOrderUsageSnapshotClampsToZeroNeverNegative() throws {
        let events = try drain([
            usageLine(total: (input: 100, output: 10)),
            usageLine(total: (input: 60, output: 4))
        ])
        XCTAssertEqual(events, [.usage(input: 100, output: 10)],
                      "the second, smaller snapshot must not emit a negative delta")
    }

    func testUsageDeltasSumToTheFinalTotal() throws {
        let events = try drain([
            usageLine(total: (input: 10, output: 1)),
            usageLine(total: (input: 25, output: 3)),
            usageLine(total: (input: 40, output: 9))
        ])
        let (sumIn, sumOut) = events.reduce((0, 0)) { acc, event -> (Int, Int) in
            guard case .usage(let usage) = event else { return acc }
            return (acc.0 + usage.inputTokens, acc.1 + usage.outputTokens)
        }
        XCTAssertEqual(sumIn, 40)
        XCTAssertEqual(sumOut, 9)
    }

    func testUsageExposesCacheReasoningAndContextWindowTelemetry() throws {
        let line = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"tu1","modelContextWindow":200000,"tokenUsage":{"total":{"totalTokens":150,"inputTokens":100,"cachedInputTokens":40,"cacheWriteInputTokens":12,"outputTokens":50,"reasoningOutputTokens":30},"last":{"totalTokens":150,"inputTokens":100,"cachedInputTokens":40,"cacheWriteInputTokens":12,"outputTokens":50,"reasoningOutputTokens":30}}}}"#
        XCTAssertEqual(try drain([line]), [.usage(CodexUsage(
            inputTokens: 100, outputTokens: 50, cachedInputTokens: 40,
            cacheWriteInputTokens: 12, reasoningOutputTokens: 30,
            contextWindowTokens: 200_000))])
    }

    private func usageLine(total: (input: Int, output: Int)) -> String {
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"t1","turnId":"tu1","tokenUsage":{"total":{"totalTokens":\#(total.input + total.output),"inputTokens":\#(total.input),"outputTokens":\#(total.output)},"last":{"totalTokens":0,"inputTokens":0,"outputTokens":0}}}}"#
    }

    // MARK: - Turn completion

    func testTurnCompletedStatusCompletedEmitsTurnCompleted() throws {
        let events = try drain([
            #"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"tu1","status":"completed","items":[]}}}"#
        ])
        XCTAssertEqual(events, [.turnCompleted])
    }

    func testTurnCompletedStatusFailedThrows() {
        let parser = CodexEventParser(threadID: "t1")
        XCTAssertThrowsError(try parser.handle(
            line: #"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"tu1","status":"failed","items":[],"error":{"message":"boom"}}}}"#)
        ) {
            guard case AgentError.api(let message) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertEqual(message, "boom")
        }
    }

    func testTurnCompletedStatusInterruptedThrowsCancellation() {
        let parser = CodexEventParser(threadID: "t1")
        XCTAssertThrowsError(try parser.handle(
            line: #"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"tu1","status":"interrupted","items":[]}}}"#)
        ) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    /// The top-level `error` notification is distinct from `turn/completed.error` (it can arrive
    /// with no `turn/completed` following at all, e.g. an upfront model-rejection) and must be
    /// just as terminal.
    func testTopLevelErrorNotificationThrows() {
        let parser = CodexEventParser(threadID: "t1")
        XCTAssertThrowsError(try parser.handle(
            line: #"{"method":"error","params":{"threadId":"t1","turnId":"tu1","willRetry":false,"error":{"message":"model rejected"}}}"#)
        ) {
            guard case AgentError.api(let message) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertEqual(message, "model rejected")
        }
    }

    func testRetriableErrorNotificationDoesNotTerminateTheTurn() throws {
        let events = try drain([
            #"{"method":"error","params":{"threadId":"t1","turnId":"tu1","willRetry":true,"error":{"message":"temporary overload"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"t1","turnId":"tu1","item":{"type":"agentMessage","id":"i1","text":"Recovered.","phase":"final_answer"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"t1","turn":{"id":"tu1","status":"completed","items":[]}}}"#
        ])
        XCTAssertEqual(events, [
            .agentMessageCompleted(text: "Recovered.", isFinal: true),
            .turnCompleted
        ])
    }

    func testNonRetriableErrorNotificationTerminatesTheTurn() {
        let parser = CodexEventParser(threadID: "t1")
        XCTAssertThrowsError(try parser.handle(
            line: #"{"method":"error","params":{"threadId":"t1","turnId":"tu1","willRetry":false,"error":{"message":"permanent failure"}}}"#)
        ) {
            guard case AgentError.api(let message) = $0 else { return XCTFail("wrong error: \($0)") }
            XCTAssertEqual(message, "permanent failure")
        }
    }

    // MARK: - Thread isolation

    /// Two parsers bound to two different threads, fed the *same* interleaved lines, must each
    /// react only to their own thread — this is what keeps concurrent branches' token counts
    /// and transcripts from cross-contaminating.
    func testInterleavedNotificationsForTwoThreadsDoNotCrossStreams() throws {
        let parserA = CodexEventParser(threadID: "thread-A")
        let parserB = CodexEventParser(threadID: "thread-B")
        let lines = [
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-A","turnId":"tu1","itemId":"i1","delta":"A1"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-B","turnId":"tu2","itemId":"i2","delta":"B1"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-A","turnId":"tu1","itemId":"i1","delta":"A2"}}"#,
            usageLineForThread("thread-B", total: (input: 20, output: 2)),
            usageLineForThread("thread-A", total: (input: 5, output: 1)),
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-B","turnId":"tu2","itemId":"i2","delta":"B2"}}"#
        ]
        var eventsA: [CodexEvent] = []
        var eventsB: [CodexEvent] = []
        for line in lines {
            eventsA += try parserA.handle(line: line)
            eventsB += try parserB.handle(line: line)
        }
        XCTAssertEqual(eventsA, [.textDelta("A1"), .textDelta("A2"), .usage(input: 5, output: 1)])
        XCTAssertEqual(eventsB, [.textDelta("B1"), .usage(input: 20, output: 2), .textDelta("B2")])
    }

    /// Each thread's usage baseline is independent even when notifications interleave — thread
    /// A's cumulative total must never be diffed against thread B's baseline or vice versa.
    func testEachThreadKeepsItsOwnUsageBaselineUnderInterleaving() throws {
        let parserA = CodexEventParser(threadID: "thread-A")
        let parserB = CodexEventParser(threadID: "thread-B")
        let lines = [
            usageLineForThread("thread-A", total: (input: 100, output: 10)),
            usageLineForThread("thread-B", total: (input: 9, output: 1)),
            usageLineForThread("thread-A", total: (input: 120, output: 14)),
            usageLineForThread("thread-B", total: (input: 30, output: 5))
        ]
        var eventsA: [CodexEvent] = []
        var eventsB: [CodexEvent] = []
        for line in lines {
            eventsA += try parserA.handle(line: line)
            eventsB += try parserB.handle(line: line)
        }
        XCTAssertEqual(eventsA, [.usage(input: 100, output: 10), .usage(input: 20, output: 4)])
        XCTAssertEqual(eventsB, [.usage(input: 9, output: 1), .usage(input: 21, output: 4)])
    }

    private func usageLineForThread(_ threadID: String, total: (input: Int, output: Int)) -> String {
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(threadID)","turnId":"tu","tokenUsage":{"total":{"totalTokens":\#(total.input + total.output),"inputTokens":\#(total.input),"outputTokens":\#(total.output)},"last":{"totalTokens":0,"inputTokens":0,"outputTokens":0}}}}"#
    }
}
