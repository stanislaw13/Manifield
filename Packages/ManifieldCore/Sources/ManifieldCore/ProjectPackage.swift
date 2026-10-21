import Foundation

/// The Manifield interchange format: a `.manifieldpack` file is a zip of a project folder's
/// *content* — theory, notation, macros, metadata — with derived and personal state
/// (search index, chat sessions, run artifacts) stripped. Because it is the same plain
/// format projects use on disk, anyone can publish a processed theory or reference work
/// and anyone else can import it as a project or (once attached) as a cited source.
public enum ProjectPackage {

    public static let fileExtension = "manifieldpack"

    /// Entries that constitute the shareable content of a project. The source overview
    /// (overview.md) is content about the work itself, so it travels; memory.md is the
    /// owner's working state and stays behind. Stored documents (original.* +
    /// fulltext.md, and a workspace's `documents/` folder) are content too — whether
    /// sharing them is appropriate is a licensing question the `license` field exists
    /// to answer, and the same applies to `figures/`, whose images a figure item is
    /// useless without.
    static let includedEntries = ["project.json", "notation.md", "macros.tex", "overview.md", "fulltext.md", "theory", "figures", "documents", "graph.json"]

    /// Exports the project's content to a `.manifieldpack` at `destination` (overwrites).
    public static func export(projectAt rootURL: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard ProjectStore.isProject(rootURL) else { throw CoreError.notAProject(rootURL) }

        let staging = fm.temporaryDirectory.appendingPathComponent("manifieldpack-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let originals = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("original.") }
            .map(\.lastPathComponent) ?? []
        for entry in includedEntries + originals {
            let source = rootURL.appendingPathComponent(entry)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: staging.appendingPathComponent(entry))
            }
        }

        try? fm.removeItem(at: destination)
        try runDitto(["-c", "-k", staging.path, destination.path])
    }

    /// Imports a `.manifieldpack` into a fresh project folder at `destination` (must not
    /// exist yet). Returns the opened, validated store.
    @discardableResult
    public static func importPackage(at packageURL: URL, to destination: URL) throws -> ProjectStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw CoreError.io("'\(destination.lastPathComponent)' already exists — choose a new folder name.")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try runDitto(["-x", "-k", packageURL.path, destination.path])
            // Validate by opening; rebuilds index.sqlite and graph.json from theory/.
            return try ProjectStore(opening: destination)
        } catch {
            try? fm.removeItem(at: destination)  // don't leave a broken half-import behind
            throw error
        }
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CoreError.io("Packaging failed (ditto \(process.terminationStatus)): \(message.prefix(300))")
        }
    }
}
