import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Editor for the project's research memory (`memory.md`) and for each research branch's
/// isolated memory (`plans/<id>.memory.md`) — the persistent working state agents read
/// every turn and keep updated: goal, status, strategies (active and eliminated),
/// insights, next steps. Fully human-editable.
///
/// Branch memories live here rather than in the Research tab because they are documents,
/// not run state: the same editor, preview and macro handling applies to all of them, and
/// a branch's memory outlives the run that wrote it.
///
/// A literature source opened as its own project gets its `overview.md` here too, for the
/// same reason: it is standing prose about the work that rides in every agent context.
/// Otherwise it is only readable from the Sources browser of some *other* project that
/// happens to cite it — a source's own window couldn't show the one file describing it.
///
/// Reading is the common case, so a memory opens rendered; the raw markdown only appears
/// once you choose to edit. The expand button (or a row's context menu) hides the list and
/// gives one document the whole tab, which is the only way a long memory is comfortable to
/// read — that is an explicit control rather than a double-click, because a double-click
/// recognizer on a List row delays every ordinary click behind it.
struct MemoryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var previewBox = WebViewBox(page: "math")

    /// Unsaved text per scope, so switching documents never silently drops edits.
    @State private var drafts: [MemoryScope: String] = [:]
    /// What was last read from (or written to) disk — lets us tell edited from untouched
    /// without re-reading the file on every body evaluation.
    @State private var saved: [MemoryScope: String] = [:]
    @State private var editing = false
    /// Subpage mode: one document, no list.
    @State private var focused = false
    /// Tracks what the user *closed*, so the default is open and the choice survives the
    /// list being rebuilt — an "expanded" set had to be seeded on appear, which silently
    /// re-opened every plan each time you came back from a full-page memory.
    @State private var collapsedPrograms: Set<String> = []
    /// Which document is shown. Kept local rather than bound straight to AppState: every
    /// row click would otherwise republish AppState and re-render the sidebar, toolbar and
    /// every other observer, which is a lot of work to change a selection.
    @State private var scope: MemoryScope = .project
    private var text: String { drafts[scope] ?? "" }
    private var dirty: Bool { drafts[scope] != saved[scope] }

    var body: some View {
        Group {
            if focused {
                document
            } else {
                HSplitView {
                    documentList
                        .frame(minWidth: 200, idealWidth: 240)
                    document
                        .frame(minWidth: 420)
                }
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            scope = appState.selectedMemory
            // A scope the open project doesn't have (an overview on a plain workspace)
            // would leave the list with nothing selected and the pane blank.
            if scope == .sourceOverview, !appState.showsSourceOverview { scope = .project }
            load(scope)
        }
        // The Research tab jumps straight to a branch's memory; that is the one place the
        // selection arrives from outside.
        .onChange(of: appState.selectedMemory) { _, requested in
            guard requested != scope else { return }
            scope = requested
            focused = true
        }
        // Agents write memory mid-run; refresh anything the user has not edited.
        .onChange(of: appState.itemsVersion) { _, _ in
            for candidate in allScopes where drafts[candidate] == saved[candidate] {
                load(candidate, renderIfCurrent: true)
            }
        }
        .onChange(of: scope) { _, newScope in
            load(newScope, force: false)
            renderPreview()
        }
        // Entering or leaving the full page rebuilds the web view, which comes back empty;
        // nothing else re-renders it, so the document would silently blank out.
        .onChange(of: focused) { _, _ in renderPreview() }
        .onChange(of: editing) { _, _ in renderPreview() }
    }

    // MARK: Document list

    private var documentList: some View {
        List(selection: Binding(
            get: { scope },
            set: { scope = $0 ?? .project })) {
            // First when it exists: on a source, the overview is the document you came
            // for, and the research memory below it is usually empty.
            if appState.showsSourceOverview {
                Section("Source") {
                    row(.sourceOverview,
                        label: "Source overview",
                        subtitle: "Read by every project citing this")
                        .tag(MemoryScope.sourceOverview)
                }
            }
            Section("Project") {
                row(.project, label: "Project memory", subtitle: "Read by every agent")
                    .tag(MemoryScope.project)
            }
            if !programsWithBranches.isEmpty {
                Text("Research plans memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                // A collapsible `Section` rather than a `DisclosureGroup`: a disclosure
                // group inside a List keeps stale row metrics when it folds or when the
                // list is rebuilt, which is what painted an old plan title on top of the
                // next one. Sections are the List's own collapsing mechanism and don't.
                ForEach(programsWithBranches, id: \.id) { program in
                    Section(isExpanded: Binding(
                        get: { !collapsedPrograms.contains(program.id) },
                        set: { open in
                            if open { collapsedPrograms.remove(program.id) }
                            else { collapsedPrograms.insert(program.id) }
                        })) {
                        ForEach(appState.branchPlans(of: program), id: \.id) { plan in
                            let branchScope = MemoryScope.branch(planID: plan.id)
                            row(branchScope,
                                label: program.branch(planID: plan.id)?.title ?? plan.id,
                                subtitle: plan.challengesLeadingAnswer
                                    ? "challenges the leading answer" : plan.id)
                                .tag(branchScope)
                        }
                    } header: {
                        Text(program.displayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(program.displayName)
                    }
                }
            }
        }
    }

    private var programsWithBranches: [ResearchProgram] {
        appState.allPrograms.filter { !appState.branchPlans(of: $0).isEmpty }
    }

    private func row(_ rowScope: MemoryScope, label: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label).font(.callout).lineLimit(1)
                if let draft = drafts[rowScope], draft != saved[rowScope] {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                        .help("Unsaved changes")
                }
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        // No tap gesture here. A TapGesture(count: 2) on a List row makes *every* single
        // click wait out the double-click interval before selection resolves, which is
        // what made picking a memory need several clicks and feel dead in between.
        // Opening a full page is an explicit action instead: the header button, or here.
        .contextMenu {
            Button("Open on its own page") {
                scope = rowScope
                focused = true
            }
        }
    }

    // MARK: Document

    private var document: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing {
                HSplitView {
                    TextEditor(text: Binding(
                        get: { text },
                        set: { drafts[scope] = $0; renderPreview() }))
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minWidth: 260)

                    WebViewRepresentable(box: previewBox)
                        .frame(minWidth: 260)
                }
            } else {
                // A rendered memory is prose, so it gets a readable measure centred in the
                // pane rather than one long line across a full-width window. The inner
                // frame caps the column; the outer one centres it in whatever is left.
                WebViewRepresentable(box: previewBox)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top) {
            if focused {
                Button {
                    focused = false
                } label: {
                    Label("All memories", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.memoryTitle(for: scope)).font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if !focused {
                Button {
                    focused = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Give this memory the whole tab")
            }
            if editing {
                Button("Revert") { load(scope, force: true) }
                    .disabled(!dirty)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty)
                Button("Done") {
                    if dirty { save() }
                    editing = false
                }
                .help("Stops editing and shows the rendered memory")
            } else {
                Button {
                    editing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .help("Show the markdown source beside the rendered memory")
            }
        }
        .padding(10)
    }

    private var caption: String {
        switch scope {
        case .sourceOverview:
            // Not a MemoryDocument: no sections, and its own cap — which nothing enforces
            // on a hand-edit, so say what happens past it rather than only counting.
            return "Carried into every project that attaches this source, so agents can judge its "
                + "relevance before searching it. "
                + "\(text.count)/\(SourceOverview.maxLength) chars; more is truncated in context."
        case .project:
            return "Injected into every agent's context. Agents update it via update_memory. \(memoryUsage)"
        case .branch:
            return "This branch's own memory — sibling branches never see it, and that isolation is what keeps their reasoning apart. \(memoryUsage)"
        }
    }

    private var memoryUsage: String {
        let used = MemoryDocument.parse(markdown: text).serialized().count
        return "\(used)/\(MemoryDocument.maxLength) chars used."
    }

    // MARK: Loading & saving

    private var allScopes: [MemoryScope] {
        var scopes: [MemoryScope] = [.project]
        if appState.showsSourceOverview { scopes.append(.sourceOverview) }
        return scopes + appState.plans.map { MemoryScope.branch(planID: $0.id) }
    }

    /// Reads a scope from disk. `force` overwrites unsaved edits (what Revert does);
    /// otherwise an existing draft is left alone, so switching documents preserves work.
    private func load(_ target: MemoryScope, force: Bool = true, renderIfCurrent: Bool = false) {
        let onDisk = appState.memory(for: target)
        saved[target] = onDisk
        if force || drafts[target] == nil {
            drafts[target] = onDisk
        }
        if target == scope, force || renderIfCurrent { renderPreview() }
    }

    private func save() {
        do {
            try appState.saveMemory(text, for: scope)
            saved[scope] = text
        } catch {
            // Nothing to recover: the draft stays put and the row keeps its unsaved dot.
        }
    }

    private func renderPreview() {
        appState.syncMacros(previewBox)
        previewBox.call("setDocument", text.isEmpty ? emptyPlaceholder : text)
    }

    private var emptyPlaceholder: String {
        scope == .sourceOverview
            // Import writes it; the Sources browser of a project citing this source can
            // regenerate it. Say so, or an empty pane looks like a bug.
            ? "*This source has no overview yet — it is written at the end of an import, and "
              + "can be regenerated from the source's Actions menu in a project that attaches "
              + "it. You can also just write one here.*"
            : "*This memory is empty.*"
    }
}
