import Foundation

/// Whether a `codex` binary actually speaks the protocol Manifield needs. Not a version check —
/// the only binary tested against was an alpha build with its own numbering, users may have
/// npm/brew builds numbered differently, and OpenAI can move any of these fields without a major
/// bump. Two independent, positive signals instead:
///
/// 1. **Methods** — `codex app-server`'s error for an unrecognized method lists every method it
///    knows, so one bogus request is a free, exact inventory.
/// 2. **Fields** — `codex app-server generate-json-schema` is that exact binary's own protocol
///    truth, so checking `ThreadStartParams` for `dynamicTools` and `TurnStartParams` for
///    `effort` can't drift from what the running process actually accepts.
///
/// Both matter because JSON-RPC param validation on this protocol is lenient — an unknown field
/// is silently ignored, not rejected. A binary too old for `dynamicTools` would accept a
/// `thread/start` carrying it, register zero Manifield tools, and the model would answer from
/// nothing, with no protocol-level error anywhere. The version-string shortcut this replaces
/// would have missed exactly that failure.
public struct CodexCapabilities: Sendable, Equatable {
    public var supportsDynamicTools: Bool
    public var supportsEffort: Bool
    public var supportsHistoryInjection: Bool
    public var missingMethods: Set<String>

    public var isSufficient: Bool {
        supportsDynamicTools && supportsEffort && missingMethods.isEmpty
    }

    public var incompatibilityDescription: String? {
        var issues: [String] = []
        if !supportsDynamicTools { issues.append("thread/start is missing the dynamicTools field") }
        if !supportsEffort { issues.append("turn/start is missing the effort field") }
        if !missingMethods.isEmpty {
            issues.append("missing methods: \(missingMethods.sorted().joined(separator: ", "))")
        }
        return issues.isEmpty ? nil : issues.joined(separator: "; ")
    }

    public init(
        supportsDynamicTools: Bool, supportsEffort: Bool,
        supportsHistoryInjection: Bool = true, missingMethods: Set<String>
    ) {
        self.supportsDynamicTools = supportsDynamicTools
        self.supportsEffort = supportsEffort
        self.supportsHistoryInjection = supportsHistoryInjection
        self.missingMethods = missingMethods
    }

    public static let requiredMethods: Set<String> = [
        "thread/start", "turn/start", "turn/interrupt",
        "model/list", "account/read", "account/rateLimits/read",
        "account/login/start", "account/login/cancel", "account/logout"
    ]

    /// Parses `"Invalid request: unknown variant \`x\`, expected one of \`a\`, \`b\`, …"` into
    /// the set of backtick-quoted method names — the exact shape this build's app-server returns
    /// for an unrecognized JSON-RPC method. Pure: fed a captured string in tests, fed a live
    /// error message in `probe(binaryPath:codexHome:)`.
    public static func parseSupportedMethods(fromUnknownMethodError message: String) -> Set<String> {
        guard let range = message.range(of: "expected one of") else { return [] }
        var methods: Set<String> = []
        var current = ""
        var inBacktick = false
        for char in message[range.upperBound...] {
            if char == "`" {
                if inBacktick, !current.isEmpty { methods.insert(current) }
                current = ""
                inBacktick.toggle()
            } else if inBacktick {
                current.append(char)
            }
        }
        return methods
    }

    public static func missingMethods(in supported: Set<String>) -> Set<String> {
        requiredMethods.subtracting(supported)
    }

    public static func hasDynamicToolsField(inThreadStartParamsSchema data: Data) -> Bool {
        hasProperty("dynamicTools", in: data)
    }

    public static func hasEffortField(inTurnStartParamsSchema data: Data) -> Bool {
        hasProperty("effort", in: data)
    }

    private static func hasProperty(_ name: String, in data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = obj["properties"] as? [String: Any]
        else { return false }
        return properties[name] != nil
    }
}

extension CodexCapabilities {

    /// Runs both live probes against one binary. Spends real process-launch time (a couple of
    /// seconds); callers should cache the result per `(binaryPath, codexHome)` rather than
    /// re-probing on every provider-availability check.
    public static func probe(binaryPath: String, codexHome: String) async throws -> CodexCapabilities {
        async let supported = probeMethods(binaryPath: binaryPath, codexHome: codexHome)
        async let schemas = probeSchemas(binaryPath: binaryPath, codexHome: codexHome)
        let (methods, (threadStart, turnStart)) = try await (supported, schemas)
        return CodexCapabilities(
            supportsDynamicTools: hasDynamicToolsField(inThreadStartParamsSchema: threadStart),
            supportsEffort: hasEffortField(inTurnStartParamsSchema: turnStart),
            supportsHistoryInjection: methods.contains("thread/inject_items"),
            missingMethods: missingMethods(in: methods))
    }

    private static func probeMethods(binaryPath: String, codexHome: String) async throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "CODEX_HOME": codexHome]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try process.run()
        defer { if process.isRunning { process.terminate() } }

        func writeLine(_ obj: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try writeLine(["method": "initialize", "id": 0, "params": CodexProtocol.initializeParams(
            clientName: "manifield-capability-probe", clientTitle: "Manifield",
            clientVersion: CodexServer.appVersion)])
        try writeLine(["method": "initialized", "params": [String: Any]()])
        // The method name only has to be unrecognized; the error it produces lists every one
        // that *is* — that response is the whole point of sending it.
        try writeLine(["method": "__manifield_unknown_probe_method__", "id": 1, "params": [String: Any]()])

        return try await withThrowingTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["id"] as? Int) == 1,
                          let error = obj["error"] as? [String: Any],
                          let message = error["message"] as? String
                    else { continue }
                    return parseSupportedMethods(fromUnknownMethodError: message)
                }
                throw CodexTransportError.unavailable("app-server closed before answering the capability probe")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw CodexTransportError.unavailable("capability probe timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func probeSchemas(
        binaryPath: String, codexHome: String
    ) async throws -> (threadStart: Data, turnStart: Data) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-schema-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "generate-json-schema", "--out", tempDir.path, "--experimental"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "CODEX_HOME": codexHome]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in continuation.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                if process.isRunning { process.terminate() }
                throw CodexTransportError.timedOut(operation: "generate-json-schema", seconds: 10)
            }
            _ = try await group.next()
            group.cancelAll()
        }
        guard process.terminationStatus == 0 else {
            throw CodexTransportError.unavailable(
                "generate-json-schema exited with status \(process.terminationStatus)")
        }
        let threadStart = try Data(contentsOf: tempDir.appendingPathComponent("v2/ThreadStartParams.json"))
        let turnStart = try Data(contentsOf: tempDir.appendingPathComponent("v2/TurnStartParams.json"))
        return (threadStart, turnStart)
    }
}
