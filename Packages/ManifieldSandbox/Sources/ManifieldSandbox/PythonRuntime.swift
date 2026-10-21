import Foundation

public enum SandboxError: LocalizedError {
    case pythonNotFound
    case setupFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "No python3 interpreter found. Install the Xcode command line tools or Homebrew Python, or set a custom path in Settings."
        case .setupFailed(let message):
            return "Python environment setup failed: \(message)"
        case .launchFailed(let message):
            return "Could not launch Python: \(message)"
        }
    }
}

/// Locates a Python interpreter and manages the shared virtualenv (with the math stack)
/// that agent scripts run in. The venv lives in Application Support and is shared by all
/// projects; per-run artifacts stay in each project's folder.
public struct PythonRuntime: Sendable {

    public static let packages = ["networkx", "sympy", "numpy", "matplotlib"]

    public let venvURL: URL
    public var interpreterOverride: String?

    public init(venvURL: URL? = nil, interpreterOverride: String? = nil) {
        self.venvURL = venvURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Manifield/pyenv", isDirectory: true)
        self.interpreterOverride = (interpreterOverride?.isEmpty == false) ? interpreterOverride : nil
    }

    public var venvPython: URL { venvURL.appendingPathComponent("bin/python3") }
    private var setupMarker: URL { venvURL.appendingPathComponent(".manifield-setup-complete") }

    /// True when the venv exists and the package install completed.
    public var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path)
            && FileManager.default.fileExists(atPath: setupMarker.path)
    }

    public func findSystemPython() -> String? {
        let candidates = [
            interpreterOverride,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Interpreter used for runs: the venv when ready (math stack available), otherwise
    /// bare system python.
    public func runInterpreter() -> (path: String, hasPackages: Bool)? {
        if isReady { return (venvPython.path, true) }
        if let system = findSystemPython() { return (system, false) }
        return nil
    }

    /// Creates the venv and installs the math packages. Needs network (pip); run it from
    /// Settings, not from inside the sandbox. Progress lines stream to `progress`.
    public func setUp(progress: @escaping @Sendable (String) -> Void) async throws {
        guard let python = findSystemPython() else { throw SandboxError.pythonNotFound }
        try? FileManager.default.createDirectory(
            at: venvURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        progress("Creating virtualenv at \(venvURL.path) …")
        try await runStep(python, ["-m", "venv", "--clear", venvURL.path], progress: progress)
        progress("Upgrading pip …")
        try await runStep(venvPython.path, ["-m", "pip", "install", "--upgrade", "pip"], progress: progress)
        progress("Installing \(Self.packages.joined(separator: ", ")) …")
        try await runStep(venvPython.path, ["-m", "pip", "install"] + Self.packages, progress: progress)
        try Data("ok".utf8).write(to: setupMarker)
        progress("Environment ready.")
    }

    private func runStep(
        _ executable: String,
        _ arguments: [String],
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = LockedBuffer(limit: 64 * 1024)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collected.append(text)
            for line in text.split(separator: "\n") { progress(String(line)) }
        }

        do {
            try process.run()
        } catch {
            throw SandboxError.launchFailed(error.localizedDescription)
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            throw SandboxError.setupFailed(
                "\(([executable] + arguments).joined(separator: " ")) exited with \(process.terminationStatus)\n\(collected.value.suffix(2000))")
        }
    }
}

/// Tiny thread-safe string accumulator for pipe readability handlers.
final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let limit: Int
    private(set) var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count < limit {
            buffer += text
            if buffer.count > limit {
                buffer = String(buffer.prefix(limit))
                truncated = true
            }
        } else {
            truncated = true
        }
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
