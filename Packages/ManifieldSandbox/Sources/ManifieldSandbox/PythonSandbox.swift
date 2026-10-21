import Foundation

public struct SandboxRunResult: Sendable {
    public let exitCode: Int32
    public let timedOut: Bool
    /// False when the seatbelt profile could not be applied (e.g. running inside another
    /// sandbox) and the script ran unconfined — surfaced so the agent/user knows.
    public let sandboxed: Bool
    /// False when the shared venv is not set up and bare system Python was used.
    public let packagesAvailable: Bool
    public let duration: TimeInterval
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    /// Folder name under the project's artifacts/ directory holding script + outputs.
    public let artifactName: String
    public let artifactURL: URL
}

/// Runs agent-written Python scripts with: no network, writes confined to the run folder
/// and temp dirs (macOS seatbelt), a hard timeout, and output caps. Every run leaves a
/// complete artifact (script.py, stdout.txt, stderr.txt, meta.json) — the audit trail
/// behind every "I tested N graphs" claim.
public final class PythonSandbox {

    public static let stdoutLimit = 200_000
    public static let stderrLimit = 50_000

    /// How long a script may run. Two numbers rather than one because the agent picks its
    /// own timeout per script: `defaultTimeout` is what it gets when it doesn't ask, and
    /// `maxTimeout` is the ceiling on what it may ask for. The user sets both in Settings ›
    /// Limits, so a machine that can afford a ten-minute search and one that cannot are the
    /// same code with different numbers.
    public struct Limits: Sendable, Equatable {
        public var defaultTimeout: TimeInterval
        public var maxTimeout: TimeInterval

        public static let standard = Limits()

        public init(defaultTimeout: TimeInterval = 120, maxTimeout: TimeInterval = 600) {
            let floor = max(1, defaultTimeout)
            self.defaultTimeout = floor
            // A ceiling below the default would silently shorten every unasked-for run;
            // the default is the floor of the ceiling instead.
            self.maxTimeout = max(floor, maxTimeout)
        }
    }

    public let runtime: PythonRuntime
    public let artifactsURL: URL
    public let useSeatbelt: Bool
    /// Folded into every run-folder name so concurrent research branches sharing one
    /// project's `artifacts/` stay visibly separated. Nil for ordinary single runs.
    public let runNamespace: String?
    public let limits: Limits

    public init(runtime: PythonRuntime, artifactsURL: URL, useSeatbelt: Bool = true,
                runNamespace: String? = nil, limits: Limits = .standard) {
        self.runtime = runtime
        self.artifactsURL = artifactsURL
        self.useSeatbelt = useSeatbelt
        self.runNamespace = (runNamespace?.isEmpty == false) ? runNamespace : nil
        self.limits = limits
    }

    /// `timeout` nil takes `limits.defaultTimeout`; anything above `limits.maxTimeout` is
    /// clamped down to it — the ceiling is the user's, not the caller's, to raise.
    public func run(
        script: String,
        label: String,
        timeout requestedTimeout: TimeInterval? = nil
    ) async throws -> SandboxRunResult {
        let timeout = min(max(1, requestedTimeout ?? limits.defaultTimeout), limits.maxTimeout)
        guard let interpreter = runtime.runInterpreter() else {
            throw SandboxError.pythonNotFound
        }

        let runDir = try makeRunDirectory(label: label)
        let scriptURL = runDir.appendingPathComponent("script.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        var attempt = try await execute(
            interpreter: interpreter.path, runDir: runDir,
            timeout: timeout, seatbelt: useSeatbelt
        )
        // Nested-sandbox environments can refuse seatbelt application; retry unconfined
        // rather than failing, but report sandboxed=false honestly.
        if useSeatbelt, attempt.exitCode != 0, !attempt.timedOut,
           attempt.stderr.contains("sandbox_apply") || attempt.stderr.contains("sandbox-exec: ") {
            attempt = try await execute(
                interpreter: interpreter.path, runDir: runDir,
                timeout: timeout, seatbelt: false
            )
        }

        let result = SandboxRunResult(
            exitCode: attempt.exitCode,
            timedOut: attempt.timedOut,
            sandboxed: attempt.sandboxed,
            packagesAvailable: interpreter.hasPackages,
            duration: attempt.duration,
            stdout: attempt.stdout,
            stderr: attempt.stderr,
            stdoutTruncated: attempt.stdoutTruncated,
            artifactName: runDir.lastPathComponent,
            artifactURL: runDir
        )
        try persistArtifact(result, runDir: runDir)
        return result
    }

    // MARK: - Internals

    private struct Attempt {
        let exitCode: Int32
        let timedOut: Bool
        let sandboxed: Bool
        let duration: TimeInterval
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
    }

    private func execute(
        interpreter: String,
        runDir: URL,
        timeout: TimeInterval,
        seatbelt: Bool
    ) async throws -> Attempt {
        let process = Process()
        if seatbelt {
            let profileURL = runDir.appendingPathComponent(".sandbox.sb")
            try seatbeltProfile(runDir: runDir).write(to: profileURL, atomically: true, encoding: .utf8)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-f", profileURL.path, interpreter, "script.py"]
        } else {
            process.executableURL = URL(fileURLWithPath: interpreter)
            process.arguments = ["script.py"]
        }
        process.currentDirectoryURL = runDir
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": runDir.path,
            "TMPDIR": runDir.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONUNBUFFERED": "1"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outBuffer = LockedBuffer(limit: Self.stdoutLimit)
        let errBuffer = LockedBuffer(limit: Self.stderrLimit)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8) { outBuffer.append(text) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8) { errBuffer.append(text) }
        }

        let started = Date()
        do {
            try process.run()
        } catch {
            throw SandboxError.launchFailed(error.localizedDescription)
        }

        let timedOutFlag = LockedFlag()
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOutFlag.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        killer.cancel()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left in the pipes.
        if let rest = try? outPipe.fileHandleForReading.readToEnd(),
           let text = String(data: rest, encoding: .utf8) { outBuffer.append(text) }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(),
           let text = String(data: rest, encoding: .utf8) { errBuffer.append(text) }

        return Attempt(
            exitCode: process.terminationStatus,
            timedOut: timedOutFlag.value,
            sandboxed: seatbelt,
            duration: Date().timeIntervalSince(started),
            stdout: outBuffer.value,
            stderr: errBuffer.value,
            stdoutTruncated: outBuffer.truncated
        )
    }

    /// Allow everything except: any network access, and writes outside the run folder,
    /// the venv, temp locations and /dev.
    private func seatbeltProfile(runDir: URL) -> String {
        let venvPath = runtime.venvURL.resolvingSymlinksInPath().path
        let runPath = runDir.resolvingSymlinksInPath().path
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write* (require-not (require-any
            (subpath "\(runPath)")
            (subpath "\(venvPath)")
            (subpath "/private/var/folders")
            (subpath "/private/tmp")
            (subpath "/dev")
        )))
        """
    }

    /// Claims a fresh run folder. The timestamp only resolves to the second, so
    /// uniqueness comes from *creating* the directory rather than checking whether it
    /// exists first — two runs in the same second would otherwise both pass the check
    /// and write into one folder.
    func makeRunDirectory(label: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var base = formatter.string(from: Date())
        if let runNamespace { base += "-\(Self.sanitize(runNamespace))" }
        base += "-\(Self.sanitize(label))"

        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        var name = base
        var counter = 2
        while true {
            let dir = artifactsURL.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                name = "\(base)-\(counter)"
                counter += 1
            }
        }
    }

    private func persistArtifact(_ result: SandboxRunResult, runDir: URL) throws {
        try result.stdout.write(to: runDir.appendingPathComponent("stdout.txt"), atomically: true, encoding: .utf8)
        try result.stderr.write(to: runDir.appendingPathComponent("stderr.txt"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = [
            "exitCode": Int(result.exitCode),
            "timedOut": result.timedOut,
            "sandboxed": result.sandboxed,
            "packagesAvailable": result.packagesAvailable,
            "durationSeconds": (result.duration * 100).rounded() / 100,
            "stdoutTruncated": result.stdoutTruncated,
            "date": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: runDir.appendingPathComponent("meta.json"))
    }

    static func sanitize(_ label: String) -> String {
        let lowered = label.lowercased()
        var out = ""
        var lastDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "run" : String(out.prefix(48))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
