import Foundation

/// The security boundary Manifield applies around `codex app-server`.
///
/// Codex's `readOnly` sandbox prevents writes and direct network access, but it deliberately has
/// no readable-root allowlist. On macOS it can read any path the unsandboxed host process can
/// read. Manifield therefore does not expose a native command/file tool at all: document access
/// is mediated exclusively by the dynamic `AgentTool`s registered on each ephemeral thread.
public enum CodexSecurityPolicy {
    /// Feature switches that could expose a native command, filesystem, network, browser,
    /// plugin, MCP-adjacent, or collaboration surface to the model. Keeping this list in one
    /// place makes the subprocess configuration testable rather than burying it in `spawn()`.
    static let disabledFeatures = [
        "shell_tool",
        "unified_exec",
        "shell_snapshot",
        "view_image",
        "image_generation",
        "browser_use",
        "browser_use_external",
        "in_app_browser",
        "computer_use",
        "apps",
        "enable_mcp_apps",
        "plugins",
        "remote_plugin",
        "plugin_sharing",
        "multi_agent",
        "multi_agent_v2",
        "code_mode",
        "workspace_dependencies"
    ]

    // Do not disable `code_mode_host`. Newer Codex models may expose dynamic tools through a
    // restricted `exec` wrapper (for example, `await tools.read_theory_item(...)`) even while
    // the user-facing `code_mode` feature and every native execution tool are disabled. The
    // host evaluates that wrapper and delegates only registered dynamic-tool calls back through
    // `item/tool/call`; without it, the call fails inside Codex with "code-mode host is disabled"
    // before Manifield has a chance to execute the AgentTool. Keeping `shell_tool`,
    // `unified_exec`, and `code_mode` disabled means this bridge does not grant shell or file
    // access of its own.

    static var appServerArguments: [String] {
        var arguments = [
            "-c", "tools.web_search=false",
            // A private CODEX_HOME is already empty of MCP definitions. This override is an
            // additional invariant against a future config file appearing there.
            "-c", "mcp_servers={}",
        ]
        for feature in disabledFeatures {
            arguments.append(contentsOf: ["--disable", feature])
        }
        arguments.append("app-server")
        return arguments
    }

    /// Shown in Settings. This intentionally distinguishes model-visible tools from the
    /// app-server process itself: the latter must read its private auth state and contact OpenAI.
    public static let settingsDescription =
        "Codex native shell, file, write, browser, network, MCP, plugin, and collaboration tools " +
        "are disabled. The model can read project or document text only through Manifield tools, " +
        "which enforce this chat’s access grants. The local app-server process itself can read " +
        "its private sign-in state and contact OpenAI; macOS read-only sandboxing alone is not a " +
        "filesystem confidentiality boundary."
}
