import Foundation
import ManifieldCore

/// Agent access to figures.
///
/// Two asymmetries shape this surface, and both are deliberate:
///
/// *Agents cannot see a figure.* A tool result carries a `String`
/// (`ContentBlock.toolResult`), so there is no path for image bytes to reach the model,
/// and the providers disagree about images in tool results anyway. `read_figure`
/// therefore reports what is *written* about a figure — caption, what it illustrates, the
/// code that drew it — and says plainly that the picture itself was not seen, because a
/// model told only "here is a figure" will happily invent what is in it.
///
/// *Agents cannot draw straight into the library.* A figure needs bytes, and the only
/// bytes an agent can produce are a `create_visualization` render sitting in `artifacts/`.
/// `save_figure` promotes one of those runs; it cannot introduce an image from anywhere
/// else, and it goes through the same proposal gate as any other write.
public enum FigureTools {

    /// Read-only figure access. Safe in every mode — captions are already in the library
    /// outline and the search index.
    public static func readTools(store: ProjectStore) -> [AgentTool] {
        [ReadFigureTool(store: store)]
    }

    /// Adds promotion of a rendered visualization into a permanent figure. `apply` is the
    /// host's write path — enqueuing a proposal in Propose mode, writing directly in Auto.
    public static func writeTools(
        store: ProjectStore,
        apply: @escaping @Sendable (TheoryProposal) async throws -> String
    ) -> [AgentTool] {
        [SaveFigureTool(store: store, apply: apply)]
    }
}

struct ReadFigureTool: AgentTool {
    let store: ProjectStore

    var spec: ToolSpec {
        ToolSpec(
            name: "read_figure",
            description: """
            Read what is recorded about a figure: its caption, the items it illustrates, \
            and the script that drew it if it was generated. IMPORTANT: this does NOT show \
            you the image — you cannot see figures at all. Describe a figure only from its \
            caption and generator code, never from what you imagine is in it, and say so \
            if the user asks about visual detail the caption does not cover.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string","description":"Figure id, e.g. fig-2-dominating-set"}},"required":["id"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let id = jsonObject(inputJSON)["id"] as? String ?? ""
        guard let item = store.item(id: id) else { throw CoreError.itemNotFound(id) }
        guard item.isFigure else {
            throw AgentError.badResponse(
                "'\(id)' is a \(item.type.rawValue), not a figure — use read_theory_item.")
        }

        var lines = ["\(item.id) — \(item.name)"]
        if !item.dependsOn.isEmpty {
            lines.append("illustrates: \(item.dependsOn.joined(separator: ", "))")
        }
        if let section = item.section {
            lines.append("section: \(TheoryItem.sectionDisplayName(section))")
        }

        if let imageURL = store.figureImageURL(for: item) {
            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: imageURL.path)[.size] as? Int) ?? nil
            var line = "image: \(imageURL.pathExtension.uppercased()) on file"
            if let bytes { line += ", \(bytes / 1024) KB" }
            lines.append(line)
        } else {
            lines.append("image: MISSING — this figure's file is not in the project.")
        }
        lines.append("(The image is not shown to you. Everything below is text.)")

        lines.append("\n## Caption\n" + (item.caption ?? "(no caption written)"))

        if let generatorURL = store.figureGeneratorURL(for: item),
           let source = try? String(contentsOf: generatorURL, encoding: .utf8) {
            let clipped = source.count > 4_000
                ? String(source.prefix(4_000)) + "\n… (truncated)"
                : source
            lines.append("\n## Generator (\(item.generator ?? generatorURL.lastPathComponent))\n"
                + "```python\n\(clipped)\n```")
        }
        return lines.joined(separator: "\n")
    }
}

struct SaveFigureTool: AgentTool {
    let store: ProjectStore
    let apply: @Sendable (TheoryProposal) async throws -> String

    var spec: ToolSpec {
        ToolSpec(
            name: "save_figure",
            description: """
            Keep a visualization you rendered with create_visualization as a permanent \
            figure in the library, with its own id, caption and place in the dependency \
            graph. Renders left in artifacts/ are per-run scratch: they are not part of the \
            project, not searchable, and are stripped when the project is shared — so use \
            this whenever a picture is worth referring to later. The run's script is stored \
            alongside the image, so the figure stays reproducible. Pass the artifacts path \
            create_visualization reported. Write a caption that says what the picture shows \
            and how to read it; it is the only description anyone (including you, later) \
            gets without opening the image. List the items the figure illustrates in \
            'illustrates' — the figure depends on them, not the other way round.
            """,
            inputSchemaJSON: #"""
            {"type":"object","properties":{"artifact":{"type":"string","description":"The path create_visualization returned, e.g. artifacts/2026-08-01-101500-viz-spectral-gap/viz.png"},"name":{"type":"string","description":"Short descriptive title, e.g. 'A minimum 2-dominating set'"},"caption":{"type":"string","description":"What the figure shows and how to read it (markdown + LaTeX allowed)"},"illustrates":{"type":"array","items":{"type":"string"},"description":"Ids of the theory items this figure depicts"},"section":{"type":"string","description":"Optional section slug to file it under, e.g. preliminaries"}},"required":["artifact","name","caption"]}
            """#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AgentError.badResponse("missing 'name'")
        }
        guard let caption = (input["caption"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else {
            throw AgentError.badResponse(
                "missing 'caption' — a figure nobody can see needs one to be worth keeping")
        }
        guard let artifact = input["artifact"] as? String else {
            throw AgentError.badResponse("missing 'artifact'")
        }
        guard let render = FigureAsset.resolveArtifactRender(artifact, in: store.rootURL) else {
            throw AgentError.badResponse("""
            No rendered image at '\(artifact)'. Pass the path create_visualization reported \
            (the 'png: artifacts/…/viz.png' line of its result). Render the figure first if \
            you have not already.
            """)
        }

        let illustrates = (input["illustrates"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A dangling id would draw a stub node in the graph, so refuse rather than
        // quietly create one; external `slug:item-id` citations are legitimate.
        let unknown = illustrates.filter { store.item(id: $0) == nil && !$0.contains(":") }
        guard unknown.isEmpty else {
            throw AgentError.badResponse(
                "unknown item id(s) in 'illustrates': \(unknown.joined(separator: ", "))")
        }

        let id = store.availableID(for: .figure, name: name)
        let item = TheoryItem(
            id: id,
            type: .figure,
            name: name,
            status: .illustration,
            dependsOn: illustrates,
            section: TheoryItem.sanitizeSection(input["section"] as? String),
            // The paths the item will carry once the host copies the files in. Nothing is
            // written here: proposing must not touch the project.
            image: FigureAsset.relativePath(id: id, extension: "png"),
            generator: render.generatorURL == nil
                ? nil
                : FigureAsset.relativePath(id: id, extension: "py"),
            body: "## Caption\n\(caption)")

        return try await apply(
            TheoryProposal(action: .create, item: item, figureSource: render.run))
    }
}
