import Foundation

/// Everything that can go wrong reaching Codex, distinct from `AgentError` because none of it is
/// an HTTP status or a provider API error — it is either "the binary/account isn't set up" or
/// "the subprocess we were talking to is gone."
public enum CodexTransportError: LocalizedError, Sendable {
    case unavailable(String)
    case processExited(String)
    case timedOut(operation: String, seconds: Double)
    case notSignedIn

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Codex is not available: \(detail)"
        case .processExited(let detail):
            return "The Codex session ended unexpectedly: \(detail)"
        case .timedOut(let operation, let seconds):
            return "Codex did not respond to \(operation) within \(Self.formatted(seconds)) seconds. The local app-server may be unresponsive; try again."
        case .notSignedIn:
            return "Not signed in to Codex. Sign in with your ChatGPT account in Settings."
        }
    }

    private static func formatted(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}

/// Operation-specific JSON-RPC deadlines. The shorter control-plane operations should fail fast;
/// starting a model turn gets longer because Codex can do meaningful setup before acknowledging it.
public struct CodexRequestTimeouts: Sendable {
    public var initialization: TimeInterval
    public var threadStart: TimeInterval
    public var turnStart: TimeInterval
    public var account: TimeInterval
    public var modelList: TimeInterval
    public var interrupt: TimeInterval
    public var login: TimeInterval
    public var other: TimeInterval

    public init(
        initialization: TimeInterval = 15, threadStart: TimeInterval = 20,
        turnStart: TimeInterval = 30, account: TimeInterval = 10,
        modelList: TimeInterval = 15, interrupt: TimeInterval = 5,
        login: TimeInterval = 15, other: TimeInterval = 15
    ) {
        self.initialization = initialization
        self.threadStart = threadStart
        self.turnStart = turnStart
        self.account = account
        self.modelList = modelList
        self.interrupt = interrupt
        self.login = login
        self.other = other
    }

    func value(for method: String) -> TimeInterval {
        switch method {
        case "initialize": return initialization
        case "thread/start", "thread/inject_items": return threadStart
        case "turn/start": return turnStart
        case "account/read", "account/rateLimits/read": return account
        case "model/list": return modelList
        case "turn/interrupt": return interrupt
        case "account/login/start", "account/login/cancel", "account/logout": return login
        default: return other
        }
    }
}

/// Process-wide account notifications from the generated app-server protocol. These are
/// broadcast because Settings can be waiting for login completion while its standing observer
/// also keeps the rolling plan-usage display current.
public enum CodexAccountEvent: Sendable, Equatable {
    case loginCompleted(loginID: String?, success: Bool, error: String?)
    case accountUpdated
    case rateLimitsUpdated([String: JSONValue])
}

/// One shared `codex app-server` subprocess for the whole app. Threads are the protocol's own
/// multiplexing unit, so one process serves every concurrent Codex-backed agent turn — spawning
/// per run would pay the handshake/auth/model-catalog cost on every one of the many turns a
/// research program runs, not once per app launch.
///
/// All mutable state is actor-isolated. The one thing that is *not* is the stdout
/// `readabilityHandler`, which Foundation invokes on its own GCD queue — every path from it into
/// actor state goes through a `Task { await ... }` hop (`consume`, `handleStdoutEOF`).
public actor CodexServer {

    public struct StartedThread: Sendable {
        public let threadID: String
        public let events: AsyncThrowingStream<CodexEvent, Error>
    }

    private enum State {
        case idle
        case launching
        case running(Process, stdin: FileHandle, generation: Int)
        case dead(Error)
        case stopped(Error)
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: JSONValue], Error>
        let timeoutTask: Task<Void, Never>
    }

    private let binaryPath: String
    private let codexHome: String
    private let cwd: String
    private let clientName: String
    private let clientVersion: String
    private let timeouts: CodexRequestTimeouts

    private var state: State = .idle
    private var processGeneration = 0
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var threadParsers: [String: CodexEventParser] = [:]
    private var retainedThreads: Set<String> = []
    private var threadContinuations: [String: AsyncThrowingStream<CodexEvent, Error>.Continuation] = [:]
    private var lineBuffer = Data()
    private var stderrTail = ""
    private var accountEventContinuations: [UUID: AsyncStream<CodexAccountEvent>.Continuation] = [:]

    /// Requests answered directly, with no `threadId` to route by — see `handleProcessScopedRequest`.
    private static let processScopedMethods: Set<String> = [
        "currentTime/read", "attestation/generate", "account/chatgptAuthTokens/refresh"
    ]

    /// The version reported in the `initialize` handshake's `clientInfo`, which is what a
    /// compliance-log entry on OpenAI's side has to identify this build by. It has to be the
    /// app's real marketing version, so it is read from the bundle rather than written down
    /// twice: this package sits below the app and cannot see `ManifieldDiagnostics`, and giving
    /// it that dependency to fetch one string would be the wrong trade. Unbundled hosts — the
    /// test runner, a command-line tool — have no version to report and say so rather than
    /// inventing one.
    public static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

    public init(
        binaryPath: String, codexHome: String, cwd: String,
        clientName: String = "manifield", clientVersion: String = CodexServer.appVersion,
        timeouts: CodexRequestTimeouts = CodexRequestTimeouts()
    ) {
        self.binaryPath = binaryPath
        self.codexHome = codexHome
        self.cwd = cwd
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.timeouts = timeouts
    }

    // MARK: - Lifecycle

    /// Spawns the process and completes the `initialize` handshake if it isn't already running.
    /// A request already in flight when the process dies fails, but a later request relaunches
    /// the same actor. Actor isolation plus `.launching` keeps concurrent callers from spawning
    /// more than one replacement process.
    private func ensureRunning() async throws {
        switch state {
        case .running: return
        case .launching:
            // Concurrent callers race to spawn; only the first should. A second caller arriving
            // mid-launch waits by polling briefly rather than double-spawning the process.
            while case .launching = state { try await Task.sleep(nanoseconds: 20_000_000) }
            try await ensureRunning()
            return
        case .dead:
            state = .idle
            try await ensureRunning()
            return
        case .stopped(let error):
            throw error
        case .idle:
            state = .launching
        }

        do {
            try spawn()
        } catch {
            fail(error)
            throw error
        }
        do {
            _ = try await request(method: "initialize", params: CodexProtocol.initializeParams(
                clientName: clientName, clientTitle: "Manifield", clientVersion: clientVersion))
            try send(CodexProtocol.encode(id: nil, method: "initialized", params: [:]))
        } catch {
            fail(error)
            throw error
        }
    }

    private func spawn() throws {
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)

        let process = Process()
        processGeneration += 1
        let generation = processGeneration
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = CodexSecurityPolicy.appServerArguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // HOME stays the real user home (some path resolution wants it); CODEX_HOME is what
        // actually redirects config/auth/MCP-servers/plugins to Manifield's private directory —
        // verified empirically to load zero of the user's MCP servers or plugins.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "CODEX_HOME": codexHome
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task { await self.handleTermination(status: proc.terminationStatus, generation: generation) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                Task { await self.handleStdoutEOF(generation: generation) }
            } else {
                Task { await self.consume(data, generation: generation) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            Task { await self.appendStderr(text) }
        }

        try process.run()
        lineBuffer.removeAll(keepingCapacity: true)
        stderrTail = ""
        state = .running(process, stdin: stdinPipe.fileHandleForWriting, generation: generation)
    }

    private func handleTermination(status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        fail(CodexTransportError.processExited("exit code \(status)\n\(stderrTail.suffix(2000))"))
    }

    private func handleStdoutEOF(generation: Int) {
        guard generation == processGeneration else { return }
        fail(CodexTransportError.processExited("stdout closed\n\(stderrTail.suffix(2000))"))
    }

    private func appendStderr(_ text: String) {
        stderrTail += text
        if stderrTail.count > 8192 { stderrTail = String(stderrTail.suffix(8192)) }
    }

    /// The single teardown funnel. Every death signal (termination, stdout EOF, a failed stdin
    /// write) routes here. Idempotent — a second call while already `.dead` is a no-op, which
    /// matters because termination and EOF can both fire for the same exit.
    private func fail(_ error: Error) {
        if case .dead = state { return }
        if case .stopped = state { return }
        if case .running(let process, _, _) = state {
            detachHandlersAndTerminate(process)
        }
        state = .dead(error)

        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: error)
        }

        for (_, continuation) in threadContinuations { continuation.finish(throwing: error) }
        threadContinuations.removeAll()
        threadParsers.removeAll()
        retainedThreads.removeAll()
    }

    /// Explicit shutdown, e.g. on app termination. Not part of the `fail` funnel — this is a
    /// clean stop, not an error, so waiters are resolved with `CancellationError` rather than a
    /// transport error. Unlike a crash (`.dead`), a deliberately stopped instance cannot restart.
    public func shutdown() {
        if case .stopped = state { return }
        if case .running(let process, _, _) = state { detachHandlersAndTerminate(process) }
        for (_, waiter) in pending {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
        for (_, continuation) in threadContinuations { continuation.finish(throwing: CancellationError()) }
        threadContinuations.removeAll()
        threadParsers.removeAll()
        retainedThreads.removeAll()
        for (_, continuation) in accountEventContinuations { continuation.finish() }
        accountEventContinuations.removeAll()
        state = .stopped(CancellationError())
    }

    private func detachHandlersAndTerminate(_ process: Process) {
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    // MARK: - Outbound requests

    /// A request that races process death throws rather than parking. A later public operation
    /// goes through `ensureRunning()` and can launch a replacement process.
    private func request(
        method: String, params: [String: Any], cancelWhenCallerCancels: Bool = true
    ) async throws -> [String: JSONValue] {
        guard case .running(_, let stdin, _) = state else {
            if case .dead(let error) = state { throw error }
            if case .stopped(let error) = state { throw error }
            throw CodexTransportError.unavailable("app-server is not running")
        }
        let id = nextID
        nextID += 1
        let data = try CodexProtocol.encode(id: .number(id), method: method, params: params)
        let seconds = timeouts.value(for: method)
        let operation = { [self] in
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    guard seconds > 0 else { return }
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    await self.timeoutRequest(id: id, method: method, seconds: seconds)
                }
                self.pending[id] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)
                do {
                    try stdin.write(contentsOf: data)
                } catch {
                    let waiter = self.pending.removeValue(forKey: id)
                    waiter?.timeoutTask.cancel()
                    waiter?.continuation.resume(throwing: error)
                    self.fail(error)
                }
            }
        }
        guard cancelWhenCallerCancels else { return try await operation() }
        return try await withTaskCancellationHandler(operation: operation) {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func cancelRequest(id: Int) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func timeoutRequest(id: Int, method: String, seconds: TimeInterval) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        let error = CodexTransportError.timedOut(operation: method, seconds: seconds)
        waiter.continuation.resume(throwing: error)
        // If turn/start was accepted but its response was lost, killing the process is the only
        // way to guarantee that an unobserved model turn cannot continue in the background.
        if method == "turn/start" { fail(error) }
    }

    private func send(_ data: Data) throws {
        guard case .running(_, let stdin, _) = state else {
            throw CodexTransportError.unavailable("app-server is not running")
        }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            fail(error)
            throw error
        }
    }

    // MARK: - Public surface

    public func startThread(
        model: String, developerInstructions: String, tools: [ToolSpec]
    ) async throws -> StartedThread {
        try await ensureRunning()
        let params = CodexProtocol.threadStartParams(
            model: model, cwd: cwd, developerInstructions: developerInstructions, tools: tools)
        let result = try await request(method: "thread/start", params: params)
        guard let threadID = result["thread"]?["id"]?.stringValue else {
            throw CodexTransportError.unavailable("thread/start returned no thread id")
        }
        let parser = CodexEventParser(threadID: threadID)
        threadParsers[threadID] = parser
        let (stream, continuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        threadContinuations[threadID] = continuation
        return StartedThread(threadID: threadID, events: stream)
    }

    public func injectItems(threadID: String, items: [[String: Any]]) async throws {
        guard !items.isEmpty else { return }
        _ = try await request(
            method: "thread/inject_items",
            params: CodexProtocol.threadInjectItemsParams(threadID: threadID, items: items))
    }

    public func retainThread(_ threadID: String) { retainedThreads.insert(threadID) }

    public func continueThread(_ threadID: String) throws -> StartedThread {
        guard case .running = state, retainedThreads.contains(threadID),
              threadParsers[threadID] != nil, threadContinuations[threadID] == nil else {
            throw CodexTransportError.unavailable("The previous native session is no longer idle and available.")
        }
        // Reuse the same parser: native tokenUsage totals accumulate across turns.
        let (stream, continuation) = AsyncThrowingStream<CodexEvent, Error>.makeStream()
        threadContinuations[threadID] = continuation
        return StartedThread(threadID: threadID, events: stream)
    }

    public func startTurn(threadID: String, input: [[String: Any]], effort: String) async throws -> String {
        let params = CodexProtocol.turnStartParams(threadID: threadID, input: input, effort: effort)
        // Do not abandon this response merely because the caller was cancelled: the returned id
        // is required to interrupt a turn the server may already have started.
        let result = try await request(method: "turn/start", params: params, cancelWhenCallerCancels: false)
        guard let turnID = result["turn"]?["id"]?.stringValue, !turnID.isEmpty else {
            throw CodexTransportError.unavailable("turn/start returned no turn id")
        }
        return turnID
    }

    public func startTurn(threadID: String, inputText: String, effort: String) async throws -> String {
        try await startTurn(
            threadID: threadID, input: [["type": "text", "text": inputText]], effort: effort)
    }

    /// Cancellation cleanup never throws a second error to its caller. If the interrupt cannot
    /// be acknowledged, however, the server is torn down: process death is the only remaining
    /// guarantee that an otherwise unobserved turn is no longer running.
    public func interruptTurn(threadID: String, turnID: String) async {
        guard !turnID.isEmpty else { return }
        do {
            _ = try await request(
                method: "turn/interrupt",
                params: CodexProtocol.turnInterruptParams(threadID: threadID, turnID: turnID),
                cancelWhenCallerCancels: false)
        } catch {
            fail(error)
        }
    }

    /// Replies to a pending `item/tool/call`. Fire-and-forget: Codex sends no response to a
    /// tool-call reply, and if the process has already died there is nothing left to tell.
    public func respond(requestID: CodexProtocol.RequestID, success: Bool, text: String) {
        guard case .running(_, let stdin, _) = state else { return }
        let result = CodexProtocol.toolCallResult(success: success, text: text)
        guard let data = try? CodexProtocol.encodeReply(id: requestID, result: result) else { return }
        try? stdin.write(contentsOf: data)
    }

    /// Releases a finished thread's parser and stream. Codex's own thread is `ephemeral` and
    /// needs no explicit archive/delete call; this only drops *our* bookkeeping for it.
    public func closeThread(_ threadID: String) {
        retainedThreads.remove(threadID)
        threadContinuations.removeValue(forKey: threadID)?.finish()
        threadParsers.removeValue(forKey: threadID)
    }

    public func accountInfo(refreshToken: Bool = true) async throws -> [String: JSONValue] {
        try await ensureRunning()
        // The generated schema specifies that managed ChatGPT authentication refreshes through
        // account/read(refreshToken: true). The inverse server callback is for external-token
        // embedders and is intentionally not used by Manifield.
        return try await request(
            method: "account/read", params: CodexProtocol.accountReadParams(refreshToken: refreshToken))
    }

    public func rateLimits() async throws -> [String: JSONValue] {
        try await ensureRunning()
        return try await request(method: "account/rateLimits/read", params: [:])
    }

    public func listModels() async throws -> [JSONValue] {
        try await ensureRunning()
        var models: [JSONValue] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "model/list", params: params)
            models.append(contentsOf: result["data"]?.arrayValue ?? [])
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw CodexTransportError.unavailable("model/list returned a repeated pagination cursor")
            }
        } while cursor != nil
        return models
    }

    public func startLogin() async throws -> (authURL: String, loginID: String) {
        try await ensureRunning()
        let result = try await request(method: "account/login/start", params: ["type": "chatgpt"])
        guard let url = result["authUrl"]?.stringValue, let loginID = result["loginId"]?.stringValue else {
            throw CodexTransportError.unavailable("account/login/start returned no auth URL")
        }
        return (url, loginID)
    }

    public func cancelLogin(loginID: String) async {
        _ = try? await request(method: "account/login/cancel", params: ["loginId": loginID])
    }

    public func logout() async {
        _ = try? await request(method: "account/logout", params: [:])
    }

    public func accountEvents() -> AsyncStream<CodexAccountEvent> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<CodexAccountEvent>.makeStream()
        accountEventContinuations[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAccountEventContinuation(identifier) }
        }
        return stream
    }

    private func removeAccountEventContinuation(_ identifier: UUID) {
        accountEventContinuations.removeValue(forKey: identifier)
    }

    // MARK: - Inbound dispatch

    private func consume(_ data: Data, generation: Int) {
        guard generation == processGeneration, case .running = state else { return }
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatch(line: line)
        }
    }

    private func dispatch(line: String) {
        guard let message = CodexProtocol.classify(line: line) else { return }
        switch message {
        case .response(let id, let result, let error):
            resolvePending(id: id, result: result, error: error)
        case .notification(let method, let params):
            // Explicit diagnostic opt-in: only usage counters and terminal status, never prompts,
            // tool arguments, account notifications, or authentication material.
            if ProcessInfo.processInfo.environment["MANIFIELD_CODEX_USAGE_TRACE"] == "1",
               method == "thread/tokenUsage/updated" || method == "turn/completed" {
                let detail = method == "thread/tokenUsage/updated" ? params["tokenUsage"]?.jsonString()
                    : params["turn"]?["status"]?.stringValue
                print("Codex accounting \(method) thread=\(params["threadId"]?.stringValue ?? "unknown") \(detail ?? "missing")")
            }
            routeAccountNotification(method: method, params: params)
            routeToThread(line: line, threadID: params["threadId"]?.stringValue)
        case .serverRequest(let id, let method, let params):
            routeServerRequest(id: id, method: method, params: params, line: line)
        }
    }

    private func resolvePending(id: CodexProtocol.RequestID, result: [String: JSONValue]?, error: [String: JSONValue]?) {
        guard case .number(let n) = id, let waiter = pending.removeValue(forKey: n) else { return }
        waiter.timeoutTask.cancel()
        if let error {
            let message = error["message"]?.stringValue ?? "codex request failed"
            waiter.continuation.resume(throwing: AgentError.api(message))
        } else {
            waiter.continuation.resume(returning: result ?? [:])
        }
    }

    /// A parser throwing (a failed or interrupted turn) ends that thread's stream with the same
    /// error, which is what lets `CodexRunner` consume it as a plain `for try await` loop rather
    /// than checking every yielded event for a failure case.
    private func routeToThread(line: String, threadID: String?) {
        guard let threadID, let parser = threadParsers[threadID] else { return }
        do {
            let events = try parser.handle(line: line)
            for event in events {
                threadContinuations[threadID]?.yield(event)
            }
            if events.contains(.turnCompleted) { finishThread(threadID) }
        } catch {
            finishThread(threadID, throwing: error)
        }
    }

    private func finishThread(_ threadID: String, throwing error: Error? = nil) {
        guard let continuation = threadContinuations.removeValue(forKey: threadID) else { return }
        if !retainedThreads.contains(threadID) { threadParsers.removeValue(forKey: threadID) }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private func routeAccountNotification(method: String, params: [String: JSONValue]) {
        let event: CodexAccountEvent
        switch method {
        case "account/login/completed":
            guard let success = params["success"]?.boolValue else { return }
            event = .loginCompleted(
                loginID: params["loginId"]?.stringValue,
                success: success,
                error: params["error"]?.stringValue)
        case "account/updated":
            event = .accountUpdated
        case "account/rateLimits/updated":
            guard let limits = params["rateLimits"]?.objectValue else { return }
            event = .rateLimitsUpdated(limits)
        default:
            return
        }
        for (_, continuation) in accountEventContinuations { continuation.yield(event) }
    }

    /// The hard rule: every server request gets an immediate reply, one way or another. Process-
    /// scoped requests are answered directly; `item/tool/call` for a live thread is forwarded so
    /// `CodexRunner` can execute the matching `AgentTool` and answer for real; anything else —
    /// an unknown method, or `item/tool/call` naming a thread we no longer track — is denied on
    /// the spot rather than left to time out. A leaked approval/elicitation request lands in that
    /// last branch, which is exactly where it belongs: its arrival means a containment layer
    /// upstream (sandbox, approval policy) didn't hold, and denying it is the safe default.
    private func routeServerRequest(id: CodexProtocol.RequestID, method: String, params: [String: JSONValue], line: String) {
        if Self.processScopedMethods.contains(method) {
            handleProcessScopedRequest(id: id, method: method, params: params)
            return
        }
        let threadID = params["threadId"]?.stringValue
        if method == "item/tool/call", let threadID, threadParsers[threadID] != nil {
            routeToThread(line: line, threadID: threadID)
            return
        }
        try? send(CodexProtocol.encodeErrorReply(id: id, code: -32601, message: "unsupported by this client"))
    }

    /// `currentTime/read` is answered for real. `attestation/generate` has no value this client
    /// can legitimately produce, so it is declined rather than faked. The generated schema says
    /// `account/chatgptAuthTokens/refresh` is the inverse callback for *external* auth clients,
    /// returning a fresh access token/account id after a 401. Manifield uses managed ChatGPT auth
    /// in private CODEX_HOME instead, so receiving that request indicates an auth-mode mismatch;
    /// answer immediately and actionably rather than returning fabricated or stale credentials.
    private func handleProcessScopedRequest(
        id: CodexProtocol.RequestID, method: String, params: [String: JSONValue]
    ) {
        switch method {
        case "currentTime/read":
            let now = Int(Date().timeIntervalSince1970)
            guard let data = try? CodexProtocol.encodeReply(id: id, result: ["currentTimeAt": now]) else { return }
            try? send(data)
        case "account/chatgptAuthTokens/refresh":
            let reason = params["reason"]?.stringValue ?? "unknown reason"
            try? send(CodexProtocol.encodeErrorReply(
                id: id, code: -32001,
                message: "Manifield uses Codex-managed ChatGPT authentication and cannot supply external auth tokens (\(reason)). Sign in again in Settings."))
        default:
            try? send(CodexProtocol.encodeErrorReply(id: id, code: -32601, message: "unsupported by this client"))
        }
    }
}
