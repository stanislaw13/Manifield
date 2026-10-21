import SwiftUI
import PDFKit
import ManifieldCore
import ManifieldAgents

/// Literature sources attached to the project. Routes between the all-sources list
/// page (attach/detach/import/open-as-project) and one source's detail page
/// (searchable item browser + PDF/overview reading pane).
struct SourcesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false

    var body: some View {
        Group {
            if let slug = appState.selectedSourceSlug,
               let source = appState.attachedSources.first(where: { $0.ref.slug == slug }) {
                SourceDetailPage(slug: slug, store: source.store)
                    .id(slug)  // fresh page state when switching sources
            } else {
                SourceListPage(showImporter: $showImporter)
            }
        }
        // The detail page's browser demands 280 + 380, and NavigationSplitView sizes the
        // detail column from what its content demands — so without this floor the column
        // outgrows the window and gets centred, clipping the sidebar and the right edge.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showImporter) {
            SourceImportSheet(importer: appState.sourceImport)
        }
    }
}

// MARK: - List page

/// Every source the project cites, one row each, with the attach/import entry points.
struct SourceListPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Binding var showImporter: Bool
    @State private var showAttachPicker = false
    @State private var unfinishedImports: [SourceImportController.UnfinishedImport] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(unfinishedImports) { unfinished in
                unfinishedBanner(unfinished)
                Divider()
            }
            if appState.attachedSources.isEmpty && appState.brokenSourceRefs.isEmpty {
                emptyState
            } else {
                sourceList
            }
        }
        .sheet(isPresented: $showAttachPicker) {
            AttachSourceSheet()
        }
        .onAppear { rescanUnfinished() }
        .onChange(of: appState.sourceImport.isRunning) { _, _ in rescanUnfinished() }
    }

    /// Library-wide scan for interrupted or failure-carrying imports (records with
    /// phase running found here mean the app died mid-import).
    private func rescanUnfinished() {
        unfinishedImports = SourceImportController.scanLibrary(
            appState.sourceLibrary, skipping: appState.sourceImport.activeSourceURL)
    }

    private func unfinishedBanner(_ unfinished: SourceImportController.UnfinishedImport) -> some View {
        let record = unfinished.record
        let resumable = record.isResumable
        return HStack(spacing: 8) {
            Image(systemName: resumable ? "pause.circle" : "exclamationmark.triangle")
                .foregroundStyle(resumable ? Color.accentColor : .orange)
            Text(resumable
                 ? "Unfinished import: “\(record.request.name)” — \(record.doneCount)/\(record.chunks.count) chunks done."
                 : "“\(record.request.name)” finished with \(record.failedIndices.count) failed chunk(s).")
                .font(.callout)
            Spacer()
            Button(resumable ? "Resume" : "Retry Failed") {
                appState.sourceImport.resume(
                    sourceURL: unfinished.url, appState: appState, onlyFailed: !resumable)
                showImporter = true
                rescanUnfinished()
            }
            .controlSize(.small)
            .disabled(appState.sourceImport.isActive)
            Button("Discard") {
                SourceImportRecord.delete(atSourceFolder: unfinished.url)
                rescanUnfinished()
            }
            .controlSize(.small)
            .help("Forgets the remaining chunks; already-imported items stay.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.08))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Literature Sources").font(.headline)
                Text("Established works this project cites. Agents search them and reference items as source:item-id.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ImportStatusChip(importer: appState.sourceImport) { showImporter = true }
            Button("Attach Existing…") { showAttachPicker = true }
            Button {
                showImporter = true
            } label: {
                Label("Import New Source…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40)).foregroundStyle(.tint)
            Text("No sources attached").font(.title3.weight(.semibold))
            Text("Import a book or article (processed chapter-by-chapter into citable items),\nor attach one already in your library — including shared .manifieldpack imports.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceList: some View {
        List {
            ForEach(appState.attachedSources, id: \.ref.slug) { source in
                row(for: source.ref, store: source.store)
            }
            if !appState.brokenSourceRefs.isEmpty {
                Section("Missing on disk") {
                    ForEach(appState.brokenSourceRefs, id: \.slug) { ref in
                        HStack {
                            Label(ref.slug, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(ref.path).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Detach") { appState.detachSource(slug: ref.slug) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func row(for ref: SourceRef, store: ProjectStore) -> some View {
        Button {
            appState.selectedSourceSlug = ref.slug
        } label: {
            HStack(spacing: 10) {
                Image(systemName: store.items.isEmpty ? "doc.richtext" : "books.vertical")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.meta.name).font(.body.weight(.medium))
                    HStack(spacing: 6) {
                        if let authors = store.meta.authors, !authors.isEmpty {
                            Text(authors.joined(separator: ", "))
                        }
                        if let citation = store.meta.citation {
                            Text(citation).lineLimit(1)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.items.isEmpty
                     ? (store.hasFulltext ? "document only" : "empty")
                     : "\(store.items.count) items")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { appState.selectedSourceSlug = ref.slug }
            Button("Open as Project") { openWindow(id: "project-window", value: store.rootURL) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [store.originalDocumentURL ?? store.rootURL])
            }
            Divider()
            Button("Detach from Project", role: .destructive) {
                appState.detachSource(slug: ref.slug)
            }
        }
    }
}

// MARK: - Attach picker

/// Attach picker fed by the machine-local source library, with a Browse… fallback
/// for source folders living elsewhere.
struct AttachSourceSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var entries: [SourceLibrary.Entry] {
        let attached = Set(appState.attachedSources.map { $0.store.rootURL.standardizedFileURL.path })
        return appState.sourceLibrary.list()
            .filter { !attached.contains($0.url.standardizedFileURL.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Attach a Source").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            let available = entries
            if available.isEmpty {
                VStack(spacing: 8) {
                    Text("Your source library has nothing new to attach.")
                        .foregroundStyle(.secondary)
                    Text(appState.sourceLibrary.rootURL.path)
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(available) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.meta.name).font(.body.weight(.medium))
                            if let citation = entry.meta.citation {
                                Text(citation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Attach") {
                            appState.attachSource(at: entry.url)
                            dismiss()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Text("Sources live in your machine-local library; one source can serve many projects.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Browse…") { browse() }
                    .help("Attach a source folder from anywhere on disk.")
            }
            .padding(10)
        }
        .frame(width: 520, height: 380)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = appState.sourceLibrary.rootURL
        panel.message = "Choose a source folder (a Manifield project, e.g. from your source library)."
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.attachSource(at: url)
        dismiss()
    }
}

// MARK: - Detail page

/// One source's browser: searchable, type-filterable item list on the left, the
/// reading pane (overview / original PDF / item markdown) on the right.
struct SourceDetailPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let slug: String
    let store: ProjectStore

    @StateObject private var detailBox = WebViewBox(page: "math")
    @State private var searchText = ""
    @State private var typeFilter: ItemType?
    @State private var isGeneratingOverview = false
    @State private var isLinking = false
    @State private var showLinkConfirm = false
    @State private var actionError: String?

    /// Pseudo item ids for the About rows (real ids are kebab-case, so no collision).
    private static let overviewRowID = "::overview::"
    private static let originalRowID = "::original::"

    private var hasOverview: Bool {
        !store.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The stored original, but only when the detail pane can actually render it.
    private var viewablePDF: URL? {
        guard let url = store.originalDocumentURL, url.pathExtension.lowercased() == "pdf" else {
            return nil
        }
        return url
    }

    /// The full text's unit label only describes the PDF when its segments *are* that
    /// PDF's pages — a LaTeX import counts sections of the .tex, so it is left off.
    private var originalRowLabel: String {
        guard let info = store.fulltextInfo, info.unit == .page else {
            return "Original document (PDF)"
        }
        return "Original document (PDF · \(info.unitLabel))"
    }

    private var isBrowsingFiltered: Bool {
        typeFilter != nil || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Items after the type filter and FTS query (rank-ordered while searching).
    private var visibleItems: [TheoryItem] {
        var items = store.items
        if let typeFilter {
            items = items.filter { $0.type == typeFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let hitIDs = (try? store.index.search(query, limit: 50).map(\.id)) ?? []
            let rank = Dictionary(uniqueKeysWithValues: hitIDs.enumerated().map { ($1, $0) })
            items = items
                .filter { rank[$0.id] != nil }
                .sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let record = importRecord, record.isResumable || record.hasRetryableFailures {
                importBanner(record)
                Divider()
            }
            browser
        }
        .onAppear {
            selectDefaultRow()
            reloadImportRecord()
        }
        .onChange(of: appState.sourceImport.isRunning) { _, _ in reloadImportRecord() }
        .confirmationDialog(linkEstimateText, isPresented: $showLinkConfirm, titleVisibility: .visible) {
            Button("Run Link Pass") { runLinkPass() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var linkEstimateText: String {
        let estimate = LinkPass.estimate(items: store.items)
        return "Reestablish cross-chapter connections? ≈\(estimate.calls) model call(s), ≈\(max(estimate.approxInputTokens / 1_000, 1))k input tokens."
    }

    private func runLinkPass() {
        isLinking = true
        actionError = nil
        Task {
            do {
                let result = try await LinkPassGeneration.run(
                    appState: appState, store: store, onProgress: { _ in })
                actionError = result.added > 0
                    ? "Link pass added \(result.added) connection(s)."
                    : "Link pass found no new connections."
                if !result.warnings.isEmpty {
                    actionError! += " \(result.warnings.count) warning(s) — see log."
                }
            } catch {
                actionError = "Link pass failed — \(error.localizedDescription)"
            }
            isLinking = false
        }
    }

    @State private var importRecord: SourceImportRecord?

    private func reloadImportRecord() {
        guard appState.sourceImport.activeSourceURL?.standardizedFileURL
                != store.rootURL.standardizedFileURL else {
            importRecord = nil  // its live progress shows in the chip, not a stale banner
            return
        }
        importRecord = SourceImportRecord.load(atSourceFolder: store.rootURL)
    }

    private func importBanner(_ record: SourceImportRecord) -> some View {
        let resumable = record.isResumable
        return HStack(spacing: 8) {
            Image(systemName: resumable ? "pause.circle" : "exclamationmark.triangle")
                .foregroundStyle(resumable ? Color.accentColor : .orange)
            Text(resumable
                 ? "This source's import is unfinished — \(record.doneCount)/\(record.chunks.count) chunks done."
                 : "Import finished with \(record.failedIndices.count) failed chunk(s) — retry importing those chunks?")
                .font(.callout)
            Spacer()
            Button(resumable ? "Resume" : "Retry Failed") {
                appState.sourceImport.resume(
                    sourceURL: store.rootURL, appState: appState, onlyFailed: !resumable)
                reloadImportRecord()
            }
            .controlSize(.small)
            .disabled(appState.sourceImport.isActive)
            Button("Dismiss") {
                SourceImportRecord.delete(atSourceFolder: store.rootURL)
                reloadImportRecord()
            }
            .controlSize(.small)
            .help("Forgets the remaining/failed chunks; imported items stay.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                appState.selectedSourceSlug = nil
            } label: {
                Label("Sources", systemImage: "chevron.left")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.meta.name).font(.headline)
                if let citation = store.meta.citation {
                    Text(citation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button("Show Graph") {
                    appState.graphScope = .source(slug)
                    appState.selection = .graph
                }
                Button("Open as Project") { openWindow(id: "project-window", value: store.rootURL) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [store.originalDocumentURL ?? store.rootURL])
                }
                if !hasOverview {
                    Button(isGeneratingOverview ? "Generating Overview…" : "Generate Overview") {
                        generateOverview()
                    }
                    .disabled(isGeneratingOverview || (store.items.isEmpty && !store.hasFulltext))
                }
                Button(isLinking ? "Linking Items…" : "Link Items…") {
                    showLinkConfirm = true
                }
                .disabled(isLinking || store.items.count < 2)
                .help("Second pass over the imported items that adds cross-chapter depends_on connections the per-chunk import misses.")
                Divider()
                Button("Detach from Project", role: .destructive) {
                    appState.detachSource(slug: slug)
                    appState.selectedSourceSlug = nil
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchBar
                List(selection: $appState.selectedSourceItemID) {
                    if !isBrowsingFiltered {
                        aboutSection
                    }
                    let macros = store.macroDictionary
                    ForEach(TheoryItem.groupedBySection(visibleItems), id: \.section) { group in
                        Section(TheoryItem.sectionDisplayName(group.section)) {
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 1) {
                                    ItemNameText(name: item.name, macros: macros)
                                    Text("\(slug):\(item.id)")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                .tag(item.id)
                            }
                        }
                    }
                }
                if let actionError {
                    Text(actionError)
                        .font(.caption2).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 460)

            Group {
                if appState.selectedSourceItemID == Self.originalRowID, let pdfURL = viewablePDF {
                    PDFViewer(url: pdfURL)
                } else {
                    WebViewRepresentable(box: detailBox)
                }
            }
            .frame(minWidth: 380)
        }
        .onChange(of: appState.selectedSourceItemID) { _, _ in renderDetail() }
        .onChange(of: appState.itemsVersion) { _, _ in renderDetail() }
        .onAppear { renderDetail() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search items…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: Capsule())

            typeFilterMenu
        }
        .padding(8)
    }

    private var typeFilterMenu: some View {
        let counts = Dictionary(grouping: store.items, by: \.type).mapValues(\.count)
        return Menu {
            Button("All types") { typeFilter = nil }
            Divider()
            ForEach(ItemType.allCases.filter { counts[$0] ?? 0 > 0 }) { type in
                Button {
                    typeFilter = type
                } label: {
                    if typeFilter == type { Image(systemName: "checkmark") }
                    Text("\(type.pluralName) (\(counts[type] ?? 0))")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(typeFilter.map(\.pluralName) ?? "Type")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(typeFilter != nil ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: Capsule())
            .foregroundStyle(typeFilter != nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            if hasOverview {
                Label("Source overview", systemImage: "text.book.closed")
                    .tag(Self.overviewRowID)
            }
            if viewablePDF != nil {
                Label(originalRowLabel, systemImage: "doc.richtext")
                    .tag(Self.originalRowID)
            } else {
                SourceActionRow(
                    title: "Add original PDF…",
                    systemImage: "doc.badge.plus",
                    help: "This source has no PDF to read — a LaTeX import stores the .tex it was built from. Add the typeset PDF to read it here; the imported original and its full text are left untouched."
                ) { addOriginalPDF() }
            }
        }
    }

    private func selectDefaultRow() {
        if let id = appState.selectedSourceItemID,
           id == Self.overviewRowID || id == Self.originalRowID || store.item(id: id) != nil {
            return  // keep an existing valid selection (e.g. set by the graph click-through)
        }
        if hasOverview {
            appState.selectedSourceItemID = Self.overviewRowID
        } else if store.items.isEmpty, viewablePDF != nil {
            appState.selectedSourceItemID = Self.originalRowID
        } else {
            appState.selectedSourceItemID = store.items.first?.id
        }
    }

    /// Supplies the readable document for a source imported from a format the viewer
    /// can't render (.tex). Nothing is re-extracted: the items and full text already
    /// come from the imported original, so this only adds the PDF to read.
    private func addOriginalPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose the PDF of “\(store.meta.name)” to read alongside this source."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        actionError = nil
        do {
            try store.addOriginalPDF(from: url)
            appState.selectedSourceItemID = Self.originalRowID  // also re-renders the row
        } catch {
            actionError = "Couldn't add the PDF — \(error.localizedDescription)"
        }
    }

    private func generateOverview() {
        isGeneratingOverview = true
        actionError = nil
        Task {
            do {
                try await SourceOverviewGeneration.run(
                    appState: appState, store: store, chunkNotes: [])
                appState.selectedSourceItemID = Self.overviewRowID
                renderDetail()
            } catch {
                actionError = "Overview generation failed — \(error.localizedDescription)"
            }
            isGeneratingOverview = false
        }
    }

    private func renderDetail() {
        if appState.selectedSourceItemID == Self.originalRowID {
            return  // the detail pane shows the PDF view, not the web view
        }
        // The source's own macros — its formulas may use commands the project lacks.
        detailBox.call("setMathMacros", store.macroDictionary)
        if appState.selectedSourceItemID == Self.overviewRowID {
            var doc = "# About: \(store.meta.name)\n\n\(store.overview)"
            if let citation = store.meta.citation {
                doc += "\n\n---\n*Source: \(citation)*"
            }
            detailBox.call("setDocument", doc)
            return
        }
        guard let id = appState.selectedSourceItemID, let item = store.item(id: id) else {
            detailBox.call("setDocument", "*Select an item to read it.*")
            return
        }
        var doc = TheoryDocument.markdown(for: item)
        if let citation = store.meta.citation {
            doc += "\n\n---\n*Source: \(citation)*"
        }
        detailBox.call("setDocument", doc)
    }
}

/// An action sitting among the About section's selectable rows — styled flush with them
/// rather than as a bordered button, so the section reads as one list.
private struct SourceActionRow: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Read-only PDF pane for a source's stored original document.
struct PDFViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
