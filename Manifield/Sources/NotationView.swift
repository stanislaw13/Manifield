import SwiftUI

/// Editors for the two per-project registries injected into rendering/agent context:
/// notation.md (definitions & conventions, always in agent context) and macros.tex
/// (LaTeX macro definitions applied to all math rendering).
struct NotationView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var previewBox = WebViewBox(page: "math")

    private enum Tab: String, CaseIterable, Identifiable {
        case notation = "Notation"
        case macros = "Math Macros"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .notation
    @State private var notationText = ""
    @State private var macrosText = ""
    @State private var dirty = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
            }
            .padding(10)
            Divider()

            HSplitView {
                TextEditor(text: tab == .notation ? $notationText : $macrosText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minWidth: 320)
                    .onChange(of: notationText) { _, _ in dirty = true; renderPreview() }
                    .onChange(of: macrosText) { _, _ in dirty = true; renderPreview() }

                WebViewRepresentable(box: previewBox)
                    .frame(minWidth: 320)
            }
        }
        // The two panes above demand 320 each, and NavigationSplitView sizes the detail
        // column from what its content demands — so without this floor the column reports
        // 640+, outgrows the window and gets centred, clipping the sidebar and the right
        // edge. The floor lets the column shrink; the HSplitView squeezes its panes instead.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            notationText = appState.store?.notation ?? ""
            macrosText = appState.store?.macros ?? ""
            dirty = false
            renderPreview()
        }
        .onChange(of: tab) { _, _ in renderPreview() }
    }

    private var caption: String {
        switch tab {
        case .notation:
            return "Injected into every agent's context — definitions, notation, standing assumptions."
        case .macros:
            return "One definition per line, e.g. \\newcommand{\\A}{\\mathcal{A}} — applied to all math rendering in the app."
        }
    }

    private func save() {
        try? appState.store?.saveNotation(notationText)
        try? appState.store?.saveMacros(macrosText)
        dirty = false
        appState.macrosChanged()
        renderPreview()
    }

    private func renderPreview() {
        appState.syncMacros(previewBox)
        switch tab {
        case .notation:
            previewBox.call("setDocument", notationText)
        case .macros:
            let macros = appState.store?.macroDictionary ?? [:]
            var doc = "## Defined macros (as last saved)\n\n"
            doc += macros.isEmpty
                ? "*No macros defined yet.*"
                : macros.sorted { $0.key < $1.key }
                    .map { "- `\($0.key)` → `\($0.value)`" }
                    .joined(separator: "\n")
            doc += "\n\n*Save to apply. Test them in any item preview — undefined macros show as red raw LaTeX.*"
            previewBox.call("setDocument", doc)
        }
    }
}
