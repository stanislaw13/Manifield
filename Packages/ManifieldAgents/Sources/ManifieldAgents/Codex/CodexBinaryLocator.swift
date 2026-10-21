import Foundation

/// Finds a `codex` binary on this machine. The bundled ChatGPT.app copy is the common case and
/// is never on `PATH` — a GUI-launched app inherits only `/usr/bin:/bin:/usr/sbin:/sbin` anyway,
/// so `PATH` is checked last, as a long shot rather than the primary route.
public struct CodexBinaryLocator: Sendable {

    private let isExecutable: @Sendable (String) -> Bool
    private let homeDirectory: String
    private let pathEnvironment: String?

    public init(
        isExecutable: @escaping @Sendable (String) -> Bool = CodexBinaryLocator.defaultIsExecutable,
        homeDirectory: String = NSHomeDirectory(),
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.isExecutable = isExecutable
        self.homeDirectory = homeDirectory
        self.pathEnvironment = pathEnvironment
    }

    /// First candidate that exists and is executable, `override` (a user-set path in Settings)
    /// checked first when non-empty.
    public func locate(override: String? = nil) -> String? {
        candidates(override: override).first(where: isExecutable)
    }

    func candidates(override: String?) -> [String] {
        var list: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            list.append(override)
        }
        // Newer ChatGPT.app builds moved the CLI into a `codex-cli` folder; older ones kept a
        // bare `codex` directly under Resources.
        list.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        list.append("\(homeDirectory)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        list.append("/Applications/ChatGPT.app/Contents/Resources/codex")
        list.append("\(homeDirectory)/Applications/ChatGPT.app/Contents/Resources/codex")
        list.append("\(homeDirectory)/.codex/bin/codex")
        list.append("/opt/homebrew/bin/codex")
        list.append("/usr/local/bin/codex")
        list.append("\(homeDirectory)/.npm-global/bin/codex")
        list.append("\(homeDirectory)/.volta/bin/codex")
        list.append("/usr/local/lib/node_modules/@openai/codex/bin/codex")
        if let pathEnvironment {
            for dir in pathEnvironment.split(separator: ":") where !dir.isEmpty {
                list.append("\(dir)/codex")
            }
        }
        return list
    }

    public static let defaultIsExecutable: @Sendable (String) -> Bool = { path in
        FileManager.default.isExecutableFile(atPath: path)
    }
}
