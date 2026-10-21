import Foundation
import ManifieldCore
import ManifieldSandbox

/// The create_visualization tool: the model writes only the essence plotting code and
/// the harness wraps it in the Prismo house style (palette, grid, fonts), renders it to
/// PNG in the sandbox, saves it as an artifact, and hands the file to the UI for
/// inline display.
public enum VisualizationTools {

    /// Invoked after a successful render with the PNG already on disk, so the chat can
    /// show it inline. Called off the main actor.
    public typealias OnImage = @Sendable (_ pngURL: URL, _ title: String, _ caption: String?) -> Void

    public static func tool(sandbox: PythonSandbox, onImage: OnImage? = nil) -> AgentTool {
        CreateVisualizationTool(sandbox: sandbox, onImage: onImage)
    }

    /// The Prismo visualization theme: a colorblind-aware categorical cycle tuned for a
    /// white background, viridis for sequential data, subtle grid, Computer Modern
    /// mathtext. One place defines the style for every figure the agent produces.
    static let themePreamble = #"""
    import matplotlib
    matplotlib.use("Agg")
    import math
    import numpy as np
    import matplotlib.pyplot as plt
    from matplotlib import cycler
    try:
        import networkx as nx
    except ImportError:
        nx = None

    # ---- Prismo house style ----
    MANIFIELD_COLORS = ["#3A6FD8", "#D95D39", "#1F9E8E", "#8657C9",
                   "#C28E1E", "#3B99CC", "#C9527E", "#66707A"]
    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "savefig.facecolor": "white",
        "savefig.dpi": 200,
        "savefig.bbox": "tight",
        "savefig.pad_inches": 0.18,
        "figure.constrained_layout.use": True,
        "axes.prop_cycle": cycler(color=MANIFIELD_COLORS),
        "image.cmap": "viridis",
        "font.family": "sans-serif",
        "font.sans-serif": ["Helvetica Neue", "Helvetica", "Arial", "DejaVu Sans"],
        "mathtext.fontset": "cm",
        "font.size": 11.0,
        "axes.titlesize": 13.0,
        "axes.titleweight": "bold",
        "axes.titlepad": 10.0,
        "axes.labelsize": 11.0,
        "axes.labelcolor": "#3A3F47",
        "axes.edgecolor": "#8A919C",
        "axes.linewidth": 0.9,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.axisbelow": True,
        "grid.color": "#E3E6EB",
        "grid.linewidth": 0.6,
        "xtick.color": "#8A919C",
        "ytick.color": "#8A919C",
        "xtick.labelcolor": "#3A3F47",
        "ytick.labelcolor": "#3A3F47",
        "xtick.direction": "out",
        "ytick.direction": "out",
        "lines.linewidth": 2.0,
        "lines.markersize": 5.0,
        "legend.frameon": False,
        "legend.fontsize": 10.0,
        "scatter.edgecolors": "none",
    })
    # Graph drawings reuse the palette: nodes in Prismo blue, edges in quiet slate.
    MANIFIELD_GRAPH = dict(node_color="#3A6FD8", edge_color="#B4BAC4",
                      font_color="white", font_size=9, node_size=420, width=1.4)
    plt.show = lambda *args, **kwargs: None  # saving is automatic; never blocks
    fig, ax = plt.subplots(figsize=(7.2, 4.6))

    # ---- agent code ----
    """#

    static let themePostamble = #"""

    # ---- save (automatic) ----
    _fig = plt.gcf()
    _axes = _fig.get_axes()
    _has_content = any(a.has_data() or a.texts for a in _axes) or _fig.texts
    if not _axes or not _has_content:
        print("MANIFIELD_VIZ_EMPTY: the code drew nothing on any axes")
        raise SystemExit(3)
    _fig.savefig("viz.png")
    _w, _h = _fig.canvas.get_width_height()
    print(f"MANIFIELD_VIZ_SAVED viz.png {int(_w*2)}x{int(_h*2)}")
    """#

    /// Assembles the full script actually executed for a snippet.
    static func script(for code: String) -> String {
        themePreamble + "\n" + code + "\n" + themePostamble
    }
}

struct CreateVisualizationTool: AgentTool {
    let sandbox: PythonSandbox
    let onImage: VisualizationTools.OnImage?

    var spec: ToolSpec {
        ToolSpec(
            name: "create_visualization",
            description: """
            Render a publication-quality matplotlib visualization and show it to the user \
            inline in the chat (also saved as a project artifact they can download). Write \
            ONLY the essence plotting code — the harness wraps it in the Prismo house style \
            (color cycle, grid, fonts, viridis colormap, 200-dpi PNG) and saves automatically. \
            Preloaded names: plt, np, math, nx (networkx, if installed) and a ready figure \
            `fig, ax = plt.subplots(figsize=(7.2, 4.6))` — draw on `ax`, or create your own \
            figure for subplots/3D (the most recently used figure is saved; one figure per call). \
            Rules: do NOT import numpy/matplotlib/networkx (already done; import sympy or \
            stdlib modules yourself if needed); NEVER call plt.show() or savefig(); label the \
            axes; use mathtext like r'$\\gamma(G)$' in labels (full LaTeX is unavailable); \
            keep the preset style — override colors only when the data's meaning requires it \
            (the cycle is MANIFIELD_COLORS; graph drawing: nx.draw(G, ax=ax, **MANIFIELD_GRAPH)). \
            Compute the data inside the snippet (numpy available, no network, ~90s budget) — \
            never plot invented numbers. Use for: function/parametric plots, heatmaps of \
            matrices (ax.imshow/pcolormesh + fig.colorbar), graph drawings, histograms and \
            distributions, convergence/error plots (ax.set_yscale('log') where appropriate), \
            contour plots and vector fields, phase portraits, complex domain coloring.
            """,
            inputSchemaJSON: #"{"type":"object","properties":{"title":{"type":"string","description":"Short title shown above the image, e.g. 'Spectral gap vs. number of vertices'"},"code":{"type":"string","description":"The essence plotting code only (see tool description for the preloaded environment)"},"caption":{"type":"string","description":"Optional one-line caption shown under the image"}},"required":["title","code"]}"#
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let code = input["code"] as? String, !code.isEmpty else {
            throw AgentError.badResponse("missing 'code'")
        }
        guard let title = input["title"] as? String, !title.isEmpty else {
            throw AgentError.badResponse("missing 'title'")
        }
        let caption = input["caption"] as? String

        let result = try await sandbox.run(
            script: VisualizationTools.script(for: code),
            label: "viz-" + title,
            timeout: 90
        )

        if result.stderr.contains("No module named 'matplotlib'") {
            throw AgentError.api("""
            matplotlib is not installed in the Python environment. Tell the user to run \
            "Set Up Python Environment" in Settings again — the setup now includes matplotlib.
            """)
        }

        let pngURL = result.artifactURL.appendingPathComponent("viz.png")
        let saved = result.stdout.contains("MANIFIELD_VIZ_SAVED")
            && FileManager.default.fileExists(atPath: pngURL.path)

        guard result.exitCode == 0, saved else {
            var message = "Rendering failed (exit \(result.exitCode)"
            if result.timedOut { message += ", TIMED OUT" }
            message += ")."
            if result.stdout.contains("MANIFIELD_VIZ_EMPTY") {
                message += " The code ran but produced no plot — nothing was drawn on any axes."
            }
            let stderrTail = String(result.stderr.suffix(2_000))
            if !stderrTail.isEmpty { message += "\n--- stderr ---\n\(stderrTail)" }
            let stdoutTail = String(result.stdout.suffix(1_000))
            if !stdoutTail.isEmpty { message += "\n--- stdout ---\n\(stdoutTail)" }
            message += "\nFix the code and call create_visualization again."
            throw AgentError.api(message)
        }

        onImage?(pngURL, title, caption)

        // First line is machine-parseable — the chat replays saved conversations from it.
        var text = "png: artifacts/\(result.artifactName)/viz.png\n"
        text += "Rendered \"\(title)\" in \(String(format: "%.1f", result.duration))s — shown to the user inline."
        if let dims = result.stdout.split(separator: "\n")
            .first(where: { $0.hasPrefix("MANIFIELD_VIZ_SAVED") })?
            .split(separator: " ").last {
            text += " (\(dims) px)"
        }
        // The snippet may print computed values worth reporting back to the model.
        let extraOutput = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("MANIFIELD_VIZ_") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraOutput.isEmpty {
            text += "\n--- stdout ---\n" + String(extraOutput.suffix(4_000))
        }
        return text
    }
}
