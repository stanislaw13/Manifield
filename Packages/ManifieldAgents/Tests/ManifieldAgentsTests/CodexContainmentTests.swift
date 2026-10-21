import Foundation
import XCTest
@testable import ManifieldAgents

final class CodexContainmentTests: XCTestCase {
    func testAppServerLaunchDisablesEveryNativeCapabilityClass() {
        let arguments = CodexSecurityPolicy.appServerArguments
        let disabled = stride(from: 0, to: arguments.count - 1, by: 1).compactMap { index -> String? in
            arguments[index] == "--disable" ? arguments[index + 1] : nil
        }
        for required in [
            "shell_tool", "unified_exec", "shell_snapshot", "view_image", "image_generation",
            "browser_use", "in_app_browser", "computer_use", "apps", "enable_mcp_apps",
            "plugins", "remote_plugin", "multi_agent", "multi_agent_v2", "code_mode"
        ] {
            XCTAssertTrue(disabled.contains(required), "missing containment switch: \(required)")
        }
        XCTAssertTrue(arguments.contains("tools.web_search=false"))
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
        XCTAssertFalse(disabled.contains("code_mode_host"),
                       "dynamic Manifield tools need Codex's restricted dispatch host")
        XCTAssertEqual(arguments.last, "app-server")
    }

    func testThreadPolicyIsReadOnlyNeverApproveAndEphemeral() {
        let params = CodexProtocol.threadStartParams(
            model: "m", cwd: "/private/tmp/manifield-scratch",
            developerInstructions: "Use the provided tools.", tools: [])
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
    }

#if os(macOS)
    /// This test intentionally proves the unsafe baseline that motivates disabling native tools:
    /// Codex's read-only Seatbelt profile prevents mutation, not reads outside cwd. It uses only
    /// an empty temporary sentinel and never opens a user file.
    func testBundledReadOnlySandboxCanReadOutsideCwdAndNestedSubprocessCannotImproveBoundary() throws {
        guard let binary = CodexBinaryLocator().locate() else {
            throw XCTSkip("codex binary is not installed")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-read-boundary-\(UUID().uuidString)", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = outside.appendingPathComponent("empty-sentinel")
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinel.path, contents: Data()))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "sandbox", "-c", "sandbox_mode=\"read-only\"", "--",
            "/bin/sh", "-c", "/bin/sh -c 'test -r \"$MANIFIELD_SENTINEL\"'"
        ]
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["MANIFIELD_SENTINEL"] = sentinel.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "read-only is not a readable-root allowlist")
    }

    func testBundledReadOnlySandboxBlocksNativeWrites() throws {
        guard let binary = CodexBinaryLocator().locate() else {
            throw XCTSkip("codex binary is not installed")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-write-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("write-attempt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "sandbox", "-c", "sandbox_mode=\"read-only\"", "--",
            "/usr/bin/touch", target.path
        ]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
#endif
}
