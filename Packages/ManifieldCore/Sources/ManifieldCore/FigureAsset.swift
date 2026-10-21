import Foundation

/// The image behind a figure item. Bytes live in the project's `figures/` folder, never
/// in the markdown:
///
///     MyProject/theory/fig-hat-tile.md    the item — frontmatter + ## Caption
///     MyProject/figures/fig-hat-tile.png  the image (`image:` in the frontmatter)
///     MyProject/figures/fig-hat-tile.py   the script that drew it (`generator:`)
///
/// Every path that reaches this type is untrusted. Item files are parsed from disk, and
/// `write_theory_item` hands the same parser frontmatter a model wrote — so `image:` is
/// attacker-controllable text, and the only paths that survive `sanitizedPath` are
/// `figures/<name>.<known extension>` with no separators or dot segments in the name.
public enum FigureAsset {

    public static let folderName = "figures"

    /// Formats a figure may be stored in. Raster only, deliberately: SVG is a scripting
    /// surface and PDF does not render in an `<img>`, so both wait for a phase that can
    /// rasterize on the way in.
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg"]

    public static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return nil
        }
    }

    /// Extensions accepted for a figure's generator script (kept beside the image as the
    /// audit trail; never executed by anything in this layer).
    public static let generatorExtensions: Set<String> = ["py"]

    /// The canonical relative path for a figure's image, e.g. `figures/fig-x.png`.
    public static func relativePath(id: String, extension ext: String) -> String {
        "\(folderName)/\(id).\(ext.lowercased())"
    }

    /// Accepts a project-relative path only when it names a file directly inside
    /// `figures/` with an extension we know. Returns nil for everything else: absolute
    /// paths, `..` anywhere, nested or missing directories, unknown formats, URLs.
    ///
    /// Normalization is deliberately *not* applied first — a path is either already in
    /// the one shape we write, or it is rejected. Resolving `figures/../figures/x.png`
    /// into something acceptable is exactly the cleverness that lets a traversal through.
    public static func sanitizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"),
              !trimmed.contains(".."), !trimmed.contains(":") else { return nil }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == folderName else { return nil }

        let file = String(parts[1])
        guard !file.isEmpty, file != ".", file != "..", !file.hasPrefix(".") else { return nil }

        let url = URL(fileURLWithPath: file)
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty,
              allowedExtensions.contains(ext) || generatorExtensions.contains(ext),
              !url.deletingPathExtension().lastPathComponent.isEmpty else { return nil }

        return "\(folderName)/\(file)"
    }

    /// Resolves a sanitized relative path against a project root, confirming the result
    /// really sits inside `<root>/figures/` after symlinks are resolved — belt and braces
    /// over `sanitizedPath`, because this is what hands bytes to a web view.
    public static func resolve(_ relativePath: String?, in rootURL: URL) -> URL? {
        guard let clean = sanitizedPath(relativePath) else { return nil }
        return resolve(clean, under: folderName, in: rootURL)
    }

    // MARK: - Promoting a sandbox render

    /// A rendered image in `artifacts/`, on its way to becoming a figure.
    public struct ArtifactRender: Equatable, Sendable {
        /// The run folder's name, e.g. `2026-08-01-101500-viz-spectral-gap`.
        public let run: String
        public let imageURL: URL
        /// The script the sandbox recorded for the run, when it is still there.
        public let generatorURL: URL?
    }

    static let artifactsFolderName = "artifacts"

    /// Locates the PNG a `create_visualization` run produced, given whatever the model
    /// passes back to `save_figure` — normally the `artifacts/<run>/viz.png` the tool
    /// reported, but a bare run name works too.
    ///
    /// Only the run name is taken from the input; the file names are ours. That is the
    /// point: an agent picks *which run* to promote and nothing else, so no string it
    /// writes can address a file outside one sandbox run folder.
    public static func resolveArtifactRender(_ raw: String?, in rootURL: URL) -> ArtifactRender? {
        guard let run = artifactRunName(raw) else { return nil }
        guard let image = resolve("\(artifactsFolderName)/\(run)/viz.png",
                                  under: artifactsFolderName, in: rootURL) else { return nil }
        let generator = resolve("\(artifactsFolderName)/\(run)/script.py",
                                under: artifactsFolderName, in: rootURL)
        return ArtifactRender(run: run, imageURL: image, generatorURL: generator)
    }

    /// The run folder from `artifacts/<run>/viz.png`, `<run>/viz.png` or `<run>`.
    /// Rejects anything with a dot segment or an empty component.
    static func artifactRunName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"),
              !trimmed.contains(".."), !trimmed.contains(":") else { return nil }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }

        var parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == artifactsFolderName { parts.removeFirst() }
        // A trailing file name is allowed but ignored — we name the files, not the agent.
        if parts.count == 2, parts[1].contains(".") { parts.removeLast() }
        guard parts.count == 1 else { return nil }

        let run = parts[0]
        guard !run.isEmpty, run != ".", run != "..", !run.hasPrefix(".") else { return nil }
        return run
    }

    /// Shared containment check: `relativePath` must land inside `<root>/<folder>/` once
    /// symlinks are resolved, and must exist.
    private static func resolve(_ relativePath: String, under folder: String, in rootURL: URL) -> URL? {
        let base = rootURL.appendingPathComponent(folder, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}
