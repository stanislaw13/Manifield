import Foundation

/// Fixed, app-owned locations for Manifield's private Codex session, and the one shared
/// `CodexServer` process for the app's lifetime. Neither is user-configurable — only the binary
/// path itself is (see `CodexBinaryLocator`).
///
/// Isolating `CODEX_HOME` here rather than sharing `~/.codex` is what keeps the user's own MCP
/// servers, plugins, and `config.toml` out of every Manifield agent turn — verified empirically
/// (a private `CODEX_HOME` produced zero `mcpServer/startupStatus/updated` events, where sharing
/// `~/.codex` loaded two MCP servers and seven plugins regardless of `-c mcp_servers={}`).
public enum CodexEnvironment {

    public static let codexHomeURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Manifield/codex-home", isDirectory: true)

    /// Codex reads `AGENTS.md` from `cwd` and its ancestors — this stays a Manifield-owned
    /// scratch directory, never the user's project, so nothing project-specific leaks into a
    /// Codex turn's instructions the way it would if `cwd` pointed at the project folder.
    public static let scratchCwdURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Manifield/codex-scratch", isDirectory: true)

    private static let lock = NSLock()
    private static var cached: (binaryPath: String, server: CodexServer)?
    private static var capabilityTasks: [String: Task<CodexCapabilities, Error>] = [:]

    /// One process for the app's lifetime per binary path — spawning per turn would pay the
    /// handshake/auth/model-catalog cost on every one of the many turns a research program runs,
    /// instead of once. Re-keys on `binaryPath` so pointing Settings at a different binary (rare)
    /// gets a fresh server rather than silently keeping the old one.
    public static func sharedServer(binaryPath: String) -> CodexServer {
        lock.lock()
        if let cached, cached.binaryPath == binaryPath {
            lock.unlock()
            return cached.server
        }
        let oldServer = cached?.server
        let server = CodexServer(binaryPath: binaryPath, codexHome: codexHomeURL.path, cwd: scratchCwdURL.path)
        cached = (binaryPath, server)
        lock.unlock()
        if let oldServer { Task { await oldServer.shutdown() } }
        return server
    }

    /// Probes once per executable fingerprint. Replacing a binary in place changes its size or
    /// modification date and therefore invalidates the cache without requiring an app restart.
    public static func capabilities(binaryPath: String) async throws -> CodexCapabilities {
        let key = executableFingerprint(binaryPath)
        let task = capabilityTask(for: key, binaryPath: binaryPath)
        do {
            return try await task.value
        } catch {
            removeCapabilityTask(for: key)
            throw error
        }
    }

    private static func capabilityTask(for key: String, binaryPath: String) -> Task<CodexCapabilities, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = capabilityTasks[key] { return existing }
        let task = Task {
            try await CodexCapabilities.probe(binaryPath: binaryPath, codexHome: codexHomeURL.path)
        }
        capabilityTasks[key] = task
        return task
    }

    private static func removeCapabilityTask(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        capabilityTasks.removeValue(forKey: key)
    }

    public static func requireCompatible(binaryPath: String) async throws {
        let result = try await capabilities(binaryPath: binaryPath)
        if let detail = result.incompatibilityDescription {
            throw CodexTransportError.unavailable("incompatible codex binary — \(detail)")
        }
    }

    static func executableFingerprint(_ binaryPath: String) -> String {
        let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else { return resolved }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(resolved)|\(inode)|\(size)|\(modified)"
    }
}
