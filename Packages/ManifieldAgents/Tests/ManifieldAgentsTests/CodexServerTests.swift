import XCTest
@testable import ManifieldAgents

/// Exercises `CodexServer`'s process-death teardown funnel — the highest-value coverage for this
/// type, and the one place a bug is worst: a hung continuation means an agent turn that never
/// returns. No real `codex` binary is needed for this: pointing `binaryPath` at `/bin/sh` with
/// codex's own spawn arguments (`-c "tools.web_search=false" ... app-server`) makes `/bin/sh`
/// execute `tools.web_search=false` as a harmless variable assignment, ignore the rest as unused
/// positional parameters, and exit almost immediately — without ever answering `initialize`.
/// That is exactly "the app-server crashed before responding," produced with real `Process`/
/// `Pipe`/termination-handler mechanics rather than a mock.
///
/// One invariant is not tested here because it can't be forced deterministically: a response
/// racing termination for the same request cannot double-resume its continuation, because
/// `resolvePending` removes it from `pending` (via `removeValue(forKey:)`) in the same
/// actor-isolated step that resumes it — there is no window for `fail()` to also see it. That is
/// provable by inspection of `CodexServer.resolvePending`/`fail`, not by a timing-dependent test.
final class CodexServerTeardownTests: XCTestCase {

    private var scratchDirs: [URL] = []

    override func tearDownWithError() throws {
        for url in scratchDirs { try? FileManager.default.removeItem(at: url) }
    }

    private func freshDir(_ label: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-server-tests-\(label)-\(UUID().uuidString)")
        scratchDirs.append(url)
        return url.path
    }

    private func fakeServer(
        crashFirstLaunch: Bool = false, respond: Bool = true,
        stoppedMarker: String? = nil, ignoredMethod: String? = nil,
        paginatedModels: Bool = false, emitAccountNotifications: Bool = false,
        serverRequestProbeMarker: String? = nil
    ) throws -> String {
        let directory = freshDir("binary")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: directory).appendingPathComponent("fake-codex")
        let stopped = stoppedMarker ?? ""
        let source = """
        #!/usr/bin/python3
        import json, os, signal, sys
        count_path = os.path.join(os.environ["CODEX_HOME"], "launch-count")
        os.makedirs(os.path.dirname(count_path), exist_ok=True)
        try:
            count = int(open(count_path).read()) + 1
        except Exception:
            count = 1
        open(count_path, "w").write(str(count))
        if \(crashFirstLaunch ? "True" : "False") and count == 1:
            sys.exit(17)
        stopped = \(String(reflecting: stopped))
        ignored_method = \(String(reflecting: ignoredMethod ?? ""))
        paginate_models = \(paginatedModels ? "True" : "False")
        emit_account_notifications = \(emitAccountNotifications ? "True" : "False")
        probe_marker = \(String(reflecting: serverRequestProbeMarker ?? ""))
        if stopped:
            def stop(sig, frame):
                open(stopped, "w").write("stopped")
                sys.exit(0)
            signal.signal(signal.SIGTERM, stop)
        thread_number = 0
        for line in sys.stdin:
            if not \(respond ? "True" : "False"):
                continue
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            request_id = request.get("id")
            if request_id is None:
                continue
            if method is None:
                if probe_marker:
                    with open(probe_marker, "a") as marker:
                        marker.write(json.dumps(request) + "\\n")
                continue
            if method == ignored_method:
                continue
            if method == "initialize":
                result = {}
            elif method == "thread/start":
                thread_number += 1
                result = {"thread": {"id": "thread-" + str(thread_number)}}
            elif method == "turn/start":
                thread_id = request["params"]["threadId"]
                result = {"turn": {"id": "turn-1"}}
                print(json.dumps({"id": request_id, "result": result}), flush=True)
                print(json.dumps({"method":"item/completed","params":{"threadId":thread_id,"turnId":"turn-1","item":{"type":"agentMessage","id":"item-1","text":"Done.","phase":"final_answer"}}}), flush=True)
                print(json.dumps({"method":"turn/completed","params":{"threadId":thread_id,"turn":{"id":"turn-1","status":"completed","items":[]}}}), flush=True)
                continue
            elif method == "account/read":
                result = {"account": None}
            elif method == "account/login/start":
                result = {"authUrl":"https://example.invalid/login", "loginId":"login-1"}
            elif method == "model/list":
                if paginate_models and request.get("params", {}).get("cursor") is None:
                    result = {"data": [{"id":"m-text","model":"m-text","displayName":"Text","inputModalities":["text"],"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Light"}],"defaultReasoningEffort":"low"}], "nextCursor":"page-2"}
                elif paginate_models:
                    result = {"data": [{"id":"m-vision","model":"m-vision","displayName":"Vision","inputModalities":["text","image"],"supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Normal"}],"defaultReasoningEffort":"medium"}]}
                else:
                    result = {"data": []}
            else:
                result = {}
            print(json.dumps({"id": request_id, "result": result}), flush=True)
            if emit_account_notifications and method == "account/read":
                print(json.dumps({"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":37,"resetsAt":1234}}}}), flush=True)
            if emit_account_notifications and method == "account/login/start":
                print(json.dumps({"method":"account/login/completed","params":{"loginId":"login-1","success":True,"error":None}}), flush=True)
            if probe_marker and method == "thread/start":
                print(json.dumps({"id":"native-approval","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","command":["/bin/sh"]}}), flush=True)
                print(json.dumps({"id":"external-refresh","method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized","previousAccountId":None}}), flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func launchCount(in codexHome: String) throws -> Int {
        Int(try String(contentsOfFile: URL(fileURLWithPath: codexHome).appendingPathComponent("launch-count").path,
                       encoding: .utf8)) ?? 0
    }

    private struct TimedOut: Error {}

    func testEveryUsedJSONRPCOperationHasAnOperationSpecificBoundedTimeout() {
        let timeouts = CodexRequestTimeouts()
        for method in [
            "initialize", "thread/start", "thread/inject_items", "turn/start", "turn/interrupt", "model/list",
            "account/read", "account/rateLimits/read", "account/login/start",
            "account/login/cancel", "account/logout"
        ] {
            XCTAssertGreaterThan(timeouts.value(for: method), 0, method)
            XCTAssertLessThanOrEqual(timeouts.value(for: method), 30, method)
        }
        XCTAssertEqual(timeouts.value(for: "turn/interrupt"), 5)
        XCTAssertEqual(timeouts.value(for: "turn/start"), 30)
    }

    /// Races `operation` against a wall-clock timeout so a hang fails the test fast and clearly,
    /// instead of via XCTest's own multi-minute default.
    private func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func testProcessExitingBeforeInitializeRespondsFailsThePendingRequestRatherThanHanging() async throws {
        let server = CodexServer(binaryPath: "/bin/sh", codexHome: freshDir("home"), cwd: freshDir("cwd"))
        do {
            _ = try await withTimeout(seconds: 8) {
                try await server.startThread(model: "m", developerInstructions: "i", tools: [])
            }
            XCTFail("expected the process exit to fail this request")
        } catch is TimedOut {
            XCTFail("a pending request must be failed on process death, not left hanging")
        } catch {
            // Any error is correct here — what matters is that it arrived instead of hanging.
        }
    }

    func testDeathIsFollowedByOneSuccessfulRecreationForConcurrentRequests() async throws {
        let home = freshDir("recover-home")
        let binary = try fakeServer(crashFirstLaunch: true)
        let server = CodexServer(binaryPath: binary, codexHome: home, cwd: freshDir("recover-cwd"))
        _ = try? await withTimeout(seconds: 2) { try await server.accountInfo() }

        let (a, b) = try await withTimeout(seconds: 2) {
            async let first = server.startThread(model: "m", developerInstructions: "i", tools: [])
            async let second = server.startThread(model: "m", developerInstructions: "i", tools: [])
            return try await (first, second)
        }
        XCTAssertNotEqual(a.threadID, b.threadID)
        XCTAssertEqual(try launchCount(in: home), 2, "the replacement must be spawned only once")
        await server.shutdown()
    }

    func testCompletedNotificationEndsServerStreamAndRunnerConsumePromptly() async throws {
        let server = CodexServer(
            binaryPath: try fakeServer(), codexHome: freshDir("complete-home"), cwd: freshDir("complete-cwd"))
        let started = try await server.startThread(model: "m", developerInstructions: "i", tools: [])
        _ = try await server.startTurn(threadID: started.threadID, inputText: "q", effort: "low")
        let result = try await withTimeout(seconds: 1) {
            try await CodexRunner.consume(
                started.events, server: server,
                config: AgentConfig(systemPrompt: "sys", tools: []),
                history: [.user("q")], onActivity: { _ in })
        }
        XCTAssertEqual(result.finalText, "Done.")
        await server.closeThread(started.threadID)
        await server.shutdown()
    }

    func testModelListingFollowsPaginationAndParsesAdvertisedMetadata() async throws {
        let server = CodexServer(
            binaryPath: try fakeServer(paginatedModels: true),
            codexHome: freshDir("models-home"), cwd: freshDir("models-cwd"))
        let options = codexModelOptions(from: try await server.listModels())
        XCTAssertEqual(options.map(\.id), ["m-text", "m-vision"])
        XCTAssertEqual(options[0].supportedReasoningEfforts, ["low"])
        XCTAssertEqual(options[1].inputModalities, [.text, .image])
        await server.shutdown()
    }

    func testInitializationTimeoutIsBoundedAndActionable() async throws {
        let server = CodexServer(
            binaryPath: try fakeServer(respond: false), codexHome: freshDir("timeout-home"),
            cwd: freshDir("timeout-cwd"),
            timeouts: CodexRequestTimeouts(initialization: 0.1, threadStart: 0.1, turnStart: 0.1,
                                           account: 0.1, modelList: 0.1, interrupt: 0.1,
                                           login: 0.1, other: 0.1))
        do {
            _ = try await withTimeout(seconds: 1) { try await server.accountInfo() }
            XCTFail("expected timeout")
        } catch is TimedOut {
            XCTFail("the server's request timeout did not fire")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("initialize"))
            XCTAssertTrue(error.localizedDescription.contains("did not respond"))
        }
    }

    func testUnacknowledgedInterruptKillsServerSoNoTurnCanBeLeftRunning() async throws {
        let home = freshDir("interrupt-timeout-home")
        let server = CodexServer(
            binaryPath: try fakeServer(ignoredMethod: "turn/interrupt"), codexHome: home,
            cwd: freshDir("interrupt-timeout-cwd"),
            timeouts: CodexRequestTimeouts(interrupt: 0.1))
        let started = try await server.startThread(model: "m", developerInstructions: "i", tools: [])
        let turnID = try await server.startTurn(threadID: started.threadID, inputText: "q", effort: "low")
        await server.interruptTurn(threadID: started.threadID, turnID: turnID)

        // A later request must use a replacement process, proving the unresponsive process was
        // killed instead of being allowed to keep an unobserved turn alive.
        _ = try await server.accountInfo()
        XCTAssertEqual(try launchCount(in: home), 2)
        await server.shutdown()
    }

    func testInterruptCleanupFromCancelledCallerDoesNotKillSharedServer() async throws {
        let home = freshDir("cancelled-interrupt-home")
        let server = CodexServer(binaryPath: try fakeServer(), codexHome: home, cwd: freshDir("cancelled-interrupt-cwd"))
        let first = try await server.startThread(model: "m", developerInstructions: "i", tools: [])
        let turnID = try await server.startTurn(threadID: first.threadID, inputText: "q", effort: "low")
        // Cancellation predates cleanup, as happens when an assignment meter stops its task.
        let cleanup = Task {
            while !Task.isCancelled { await Task.yield() }
            await server.interruptTurn(threadID: first.threadID, turnID: turnID)
        }
        cleanup.cancel()
        await cleanup.value
        _ = try await server.accountInfo()
        XCTAssertEqual(try launchCount(in: home), 1, "Stopping one assignment must leave the director's shared process alive.")
        await server.shutdown()
    }

    func testChangingSharedBinaryPathShutsDownTheOldProcess() async throws {
        let stopped = URL(fileURLWithPath: freshDir("stopped")).appendingPathComponent("old-stopped").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: stopped).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let firstBinary = try fakeServer(stoppedMarker: stopped)
        let secondBinary = try fakeServer()
        let first = CodexEnvironment.sharedServer(binaryPath: firstBinary)
        _ = try await first.accountInfo()

        let second = CodexEnvironment.sharedServer(binaryPath: secondBinary)
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: stopped), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped))
        await second.shutdown()
    }

    /// `respond` and `closeThread` are called from `CodexRunner` without knowing whether the
    /// server died in the meantime (a tool could be mid-execution when the process crashes) —
    /// both must be safe no-ops on a dead server rather than crashing the caller.
    func testRespondAndCloseThreadAreSafeNoOpsAfterDeath() async throws {
        let server = CodexServer(binaryPath: "/bin/sh", codexHome: freshDir("home"), cwd: freshDir("cwd"))
        _ = try? await withTimeout(seconds: 8) {
            try await server.startThread(model: "m", developerInstructions: "i", tools: [])
        }
        await server.respond(requestID: .number(1), success: true, text: "irrelevant")
        await server.closeThread("nonexistent-thread")
        // Reaching this line without throwing/crashing is the assertion.
    }

    func testAccountNotificationsAreBroadcastWithoutPolling() async throws {
        let server = CodexServer(
            binaryPath: try fakeServer(emitAccountNotifications: true),
            codexHome: freshDir("account-events-home"), cwd: freshDir("account-events-cwd"))
        let events = await server.accountEvents()
        var iterator = events.makeAsyncIterator()
        _ = try await server.accountInfo()
        let rateEvent = await iterator.next()
        guard case .rateLimitsUpdated(let snapshot) = rateEvent else {
            return XCTFail("expected rolling rate-limit event")
        }
        XCTAssertEqual(snapshot["primary"]?["usedPercent"]?.doubleValue, 37)

        _ = try await server.startLogin()
        let loginEvent = await iterator.next()
        XCTAssertEqual(loginEvent, .loginCompleted(loginID: "login-1", success: true, error: nil))
        await server.shutdown()
    }

    func testNativeApprovalIsDeniedAndExternalRefreshGetsActionableError() async throws {
        let markerDirectory = URL(fileURLWithPath: freshDir("server-request-probe"))
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        let marker = markerDirectory.appendingPathComponent("replies.jsonl").path
        let server = CodexServer(
            binaryPath: try fakeServer(serverRequestProbeMarker: marker),
            codexHome: freshDir("probe-home"), cwd: freshDir("probe-cwd"))
        _ = try await server.startThread(model: "m", developerInstructions: "i", tools: [])

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: marker, encoding: .utf8),
               text.split(separator: "\n").count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let lines = try String(contentsOfFile: marker, encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        let approval = try XCTUnwrap(lines.first { $0["id"] as? String == "native-approval" })
        XCTAssertEqual((approval["error"] as? [String: Any])?["code"] as? Int, -32601)
        let refresh = try XCTUnwrap(lines.first { $0["id"] as? String == "external-refresh" })
        let refreshError = try XCTUnwrap(refresh["error"] as? [String: Any])
        XCTAssertEqual(refreshError["code"] as? Int, -32001)
        XCTAssertTrue((refreshError["message"] as? String)?.contains("managed ChatGPT authentication") == true)
        await server.shutdown()
    }
}
