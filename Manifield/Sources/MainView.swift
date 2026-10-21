import SwiftUI
import ManifieldCore
import ManifieldAgents

struct MainView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if appState.store?.meta.kind == .source {
                    sourceKindBanner
                }
                detail
            }
        }
        .navigationTitle(appState.store?.meta.name ?? "Manifield")
        .toolbar {
            ToolbarItemGroup {
                RunIndicator(
                    research: appState.research,
                    program: appState.research.activeProgramID.flatMap { appState.program(id: $0) },
                    plans: appState.plans
                ) {
                    appState.selection = .research
                }
                if !appState.pendingProposals.isEmpty {
                    Button {
                        appState.showProposalsSheet = true
                    } label: {
                        Label("\(appState.pendingProposals.count) proposal(s)", systemImage: "tray.full")
                    }
                    .badge(appState.pendingProposals.count)
                    .help("Agent-proposed theory edits awaiting your confirmation")
                }
                Button {
                    appState.reloadFromDisk()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Re-read the project folder from disk")
            }
        }
        .sheet(isPresented: $appState.showProposalsSheet) {
            ProposalReviewSheet()
        }
        .alert(
            "Dependent items affected",
            isPresented: Binding(
                get: { appState.pendingBreakage != nil },
                set: { if !$0 { appState.pendingBreakage = nil } }
            ),
            presenting: appState.pendingBreakage
        ) { breakage in
            Button("Downgrade \(breakage.affectedIDs.count) item(s)", role: .destructive) {
                appState.applyBreakage(breakage)
            }
            Button("Keep their statuses", role: .cancel) {
                appState.pendingBreakage = nil
            }
        } message: { breakage in
            Text("""
            '\(breakage.sourceID)' was downgraded, but these items rely on it (directly or \
            transitively) and currently claim review or approval:

            \(breakage.affectedIDs.joined(separator: ", "))

            Downgrading resets them to "Proof drafted" so their proofs get re-reviewed.
            """)
        }
        .onChange(of: appState.pendingProposals.count) { old, count in
            if count > old { appState.showProposalsSheet = true }
        }
    }

    /// Shown when a literature source is opened as its own project: edits here hit
    /// the one shared library copy every attaching project cites.
    ///
    /// Inset with its tint bounded to a rounded rect, rather than the edge-to-edge strip
    /// the app's other banners use. Those all sit *below* a view's own header; this one is
    /// the top of the detail column, flush against the window's titlebar band — and that
    /// band runs the full width of the window, sidebar included, so a full-bleed fill here
    /// washed across behind the sidebar instead of stopping at the page content.
    private var sourceKindBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical")
            Text("Literature source — edits affect every project citing it.")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .chat: ChatView()
        case .graph: GraphView()
        case .library: LibraryView()
        case .sources: SourcesView()
        case .importer: ImportView()
        case .notation: NotationView()
        case .memory: MemoryView()
        case .research: ResearchView()
        case .document(let slug): DocumentDetailView(slug: slug).id(slug)
        }
    }
}

/// Toolbar chip shown while a research run is active: live progress with each branch's
/// task checklist in its menu, so the program's state is visible from any tab.
struct RunIndicator: View {
    @ObservedObject var research: ResearchController
    let program: ResearchProgram?
    let plans: [PlanDocument]
    let onTap: () -> Void

    private var branchPlans: [PlanDocument] {
        guard let program else { return [] }
        return program.branches.compactMap { branch in plans.first { $0.id == branch.planID } }
    }

    var body: some View {
        if research.isRunning {
            Menu {
                if let program {
                    ForEach(program.branches, id: \.planID) { branch in
                        if let plan = plans.first(where: { $0.id == branch.planID }) {
                            Section(program.isVirtual
                                    ? (plan.goal.isEmpty ? plan.id : plan.goal)
                                    : (branch.challengesLeadingAnswer
                                       ? "\(branch.title) — challenger"
                                       : branch.title)) {
                                ForEach(plan.tasks, id: \.index) { task in
                                    // Disabled rows: this is a checklist, not a set of actions.
                                    Button {} label: {
                                        Label("\(task.index). \(task.title)",
                                              systemImage: task.status.iconName)
                                    }
                                    .disabled(true)
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("Open Research tab", action: onTap)
            } label: {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(progressLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(research.currentActivity.isEmpty ? "Research running" : research.currentActivity)
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                }
            }
            .help("A research run is active — the menu shows each branch's task list")
        }
    }

    /// Tasks for a single plan; branches once a real program is running.
    private var progressLabel: String {
        guard let program else { return "" }
        if program.isVirtual, let plan = branchPlans.first {
            return "\(plan.tasks.filter { $0.status == .completed }.count)/\(plan.tasks.count)"
        }
        let done = branchPlans.filter(\.isFinished).count
        return "\(done)/\(program.branches.count) branches"
    }
}

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(selection: Binding(
            get: { appState.selection },
            set: { appState.selection = $0 ?? .library }
        )) {
            Section("Workspace") {
                NewChatRow(chat: appState.chat)
                Label {
                    HStack {
                        Text("Research")
                        Spacer()
                        countBadge(appState.plans.count)
                    }
                } icon: {
                    Image(systemName: "map")
                }
                .tag(SidebarSelection.research)
                Label("Dependency Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarSelection.graph)
                Label {
                    HStack {
                        Text("Sources")
                        Spacer()
                        countBadge(appState.attachedSources.count)
                    }
                } icon: {
                    Image(systemName: "books.vertical.circle")
                }
                .tag(SidebarSelection.sources)
                Label("Import", systemImage: "square.and.arrow.down")
                    .tag(SidebarSelection.importer)
                Label("Notation", systemImage: "character.textbox")
                    .tag(SidebarSelection.notation)
                Label("Memory", systemImage: "brain")
                    .tag(SidebarSelection.memory)
            }

            if appState.store != nil {
                FilesSection()
            }

            Section("Library") {
                Label {
                    HStack {
                        Text("All Items")
                        Spacer()
                        countBadge(appState.store?.items.count ?? 0)
                    }
                } icon: {
                    Image(systemName: "books.vertical")
                }
                .tag(SidebarSelection.library)
            }

            if let store = appState.store {
                Section("By Type") {
                    // Only types that actually occur — 25 types would swamp the sidebar.
                    let counts = Dictionary(grouping: store.items, by: \.type).mapValues(\.count)
                    ForEach(ItemType.allCases.filter { counts[$0] ?? 0 > 0 }) { type in
                        let count = counts[type] ?? 0
                        Button {
                            appState.libraryFilter = type
                            appState.selection = .library
                        } label: {
                            HStack {
                                Text(type.pluralName)
                                Spacer()
                                countBadge(count)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(appState.libraryFilter == type && appState.selection == .library
                                         ? Color.accentColor : Color.primary)
                    }
                    if appState.libraryFilter != nil {
                        Button("Clear filter") { appState.libraryFilter = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ChatHistorySection(chat: appState.chat)
            }
        }
        .listStyle(.sidebar)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Opens the chat tab on a *fresh* conversation. This row used to be a plain selection tag
/// that reopened whatever chat was last active, which made the "Chats" list below the only
/// way to start a new one; now that list is purely for going back to an old conversation.
private struct NewChatRow: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController

    var body: some View {
        // The row reads as selected while the blank chat is the one on screen, matching how
        // a saved chat's row highlights when it is open.
        let isActive = appState.selection == .chat && chat.isPristine
        Button {
            if !chat.isPristine { chat.newChat() }
            appState.selection = .chat
        } label: {
            Label("New chat", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .disabled(chat.isRunning)
        .help("Start a new conversation with Prismo — the current one stays in your chat history")
    }
}

/// The files kept with the project (`documents/`): the PDFs an import came from, and any
/// the user parked here to read. Clicking a row opens it in the built-in viewer; agents
/// reach the same files through the gated document tools.
private struct FilesSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var renamingSlug: String?
    @State private var renameText = ""

    var body: some View {
        // Grouped like the chat history section: the alert hangs off the group, not off a
        // row that disappears the moment the rename lands.
        Group {
            Section("Files") {
                ForEach(appState.documents) { document in
                    Label {
                        HStack(spacing: 4) {
                            Text(document.meta.title).lineLimit(1)
                            Spacer(minLength: 0)
                            if !document.isSearchable {
                                Image(systemName: "eye.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } icon: {
                        Image(systemName: document.isPDF ? "doc.richtext" : "doc.plaintext")
                    }
                    .tag(SidebarSelection.document(slug: document.slug))
                    .help(document.isSearchable
                          ? "\(document.meta.originalFileName) — \(document.formatLabel)"
                          : "\(document.meta.originalFileName) — no extractable text, so agents cannot read it")
                    .contextMenu { menu(for: document) }
                }
                ForEach(appState.documentsInFlight, id: \.self) { name in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(name).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Button {
                    DocumentPicker.pick(into: appState)
                } label: {
                    Label("Add PDF…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Keep a PDF (or LaTeX file) with the project: readable here, and searchable by agents once you allow it.")
            }
        }
        .alert("Rename file", isPresented: Binding(
            get: { renamingSlug != nil },
            set: { if !$0 { renamingSlug = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSlug = nil }
            Button("Save") {
                if let slug = renamingSlug {
                    appState.renameDocument(slug: slug, title: renameText)
                }
                renamingSlug = nil
            }
        }
    }

    @ViewBuilder
    private func menu(for document: ProjectDocument) -> some View {
        Button("Open") { appState.selection = .document(slug: document.slug) }
        Button("Import Items from This File…") {
            appState.importItems(fromDocument: document.slug)
        }
        Button("Rename…") {
            renameText = document.meta.title
            renamingSlug = document.slug
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [document.fileURL ?? document.folderURL])
        }
        Divider()
        Button("Remove from Project", role: .destructive) {
            appState.removeDocument(slug: document.slug)
        }
    }
}

/// Per-project chat history: every saved conversation, newest first. Clicking a row reopens
/// it in the Chat tab; right-click renames or deletes. Observes the chat controller directly
/// so the list and active-chat highlight stay live (nested ObservableObjects don't propagate
/// through AppState on their own).
private struct ChatHistorySection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController
    @State private var renaming: ChatController.ChatSummary?
    @State private var renameText = ""

    var body: some View {
        Group {
            if !chat.chats.isEmpty {
                Section("Chats") {
                    ForEach(chat.chats) { summary in
                        row(summary)
                    }
                }
            }
        }
        .alert("Rename chat", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { chat.renameChat(id: renaming.id, title: renameText) }
                renaming = nil
            }
        }
    }

    private func row(_ summary: ChatController.ChatSummary) -> some View {
        let isActive = appState.selection == .chat && chat.activeChatID == summary.id
        // Switching to a *different* chat mid-run cancels the in-flight turn (switchTo
        // calls cancel()), so those rows stay disabled. But the row for the chat that's
        // already active just flips the tab back — switchTo no-ops on its own id — so
        // reopening the one that's running must stay clickable.
        let blockedByRun = chat.isRunning && summary.id != chat.activeChatID
        return Button {
            chat.switchTo(chatID: summary.id)
            appState.selection = .chat
        } label: {
            HStack(spacing: 6) {
                Image(systemName: summary.linkedItemName != nil ? "paperclip" : "bubble.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(summary.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .disabled(blockedByRun)
        .help(summary.linkedItemName.map { "Pinned: \($0)" } ?? summary.title)
        .contextMenu {
            Button("Rename…") {
                renameText = summary.title
                renaming = summary
            }
            Button("Delete", role: .destructive) {
                chat.deleteChat(id: summary.id)
            }
        }
    }
}

/// Trust-level badge used across list rows and detail headers.
struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(hex: status.colorHex).opacity(0.18), in: Capsule())
            .foregroundStyle(Color(hex: status.colorHex))
    }
}

/// The editable form of `StatusBadge`: the coloured pill *is* the picker. A 190pt picker
/// standing next to a read-only badge stated the same thing twice and ate the width the
/// title needed, which is what wrapped the header one character per line on a narrow
/// window. Same chip idiom as the graph's filter menus, so the colour carries the meaning
/// and the chevron carries the affordance.
struct StatusMenu: View {
    let status: ItemStatus
    let onChange: (ItemStatus) -> Void

    var body: some View {
        Menu {
            ForEach(ItemStatus.allCases) { candidate in
                Button {
                    guard candidate != status else { return }
                    onChange(candidate)
                } label: {
                    if candidate == status { Image(systemName: "checkmark") }
                    Text(candidate.displayName)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(status.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(hex: status.colorHex).opacity(0.18), in: Capsule())
            .foregroundStyle(Color(hex: status.colorHex))
        }
        .menuStyle(.borderlessButton)
        // The label draws its own chevron, so the style's built-in one is a second arrow.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Trust level of this statement — click to change")
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Sheet listing agent proposals; each can be inspected, accepted or rejected.
struct ProposalReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewBox = WebViewBox(page: "math")
    @State private var selectedProposal: TheoryProposal.ID?
    @State private var isExpanded = false

    private static let compactSize = CGSize(width: 860, height: 520)

    private var sheetSize: CGSize {
        guard isExpanded else { return Self.compactSize }
        return NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Proposed theory edits")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "Restore" : "Expand to full screen")
                Button("Done") { dismiss() }
            }
            .padding()

            if appState.pendingProposals.isEmpty {
                Text("No pending proposals.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(appState.pendingProposals, selection: $selectedProposal) { proposal in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(proposal.action == .create ? "CREATE" : "UPDATE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(proposal.action == .create ? .green : .orange)
                                Text(proposal.item.id).font(.caption.monospaced())
                            }
                            Text(proposal.item.name).font(.body)
                            HStack {
                                StatusBadge(status: proposal.item.status)
                                Text(proposal.item.type.displayName)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Accept") { appState.accept(proposal) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                Button("Reject") { appState.reject(proposal) }
                                    .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                        .tag(proposal.id)
                    }
                    .frame(minWidth: 280, idealWidth: 320)

                    WebViewRepresentable(box: previewBox)
                        .frame(minWidth: 360)
                }
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .onChange(of: selectedProposal) { _, id in
            renderPreview(id: id)
        }
        .onAppear {
            selectedProposal = appState.pendingProposals.first?.id
            renderPreview(id: selectedProposal)
        }
    }

    private func renderPreview(id: TheoryProposal.ID?) {
        appState.syncMacros(previewBox)
        guard let proposal = appState.pendingProposals.first(where: { $0.id == id }) else {
            previewBox.call("setDocument", "*Select a proposal to preview it.*")
            return
        }
        previewBox.call("setDocument", TheoryDocument.markdown(for: proposal.item))
    }
}

/// Composes the markdown shown in detail/preview web views for an item.
/// Main-actor bound because a figure's image is resolved against the open project.
@MainActor
enum TheoryDocument {
    static func markdown(for item: TheoryItem) -> String {
        var parts: [String] = ["# \(item.name)"]
        var meta = "`\(item.id)` · \(item.type.displayName)"
        // "Illustration" is not a trust level; saying it beside a picture only invites
        // the reader to look for a ladder that does not apply here.
        if !item.isFigure { meta += " · \(item.status.displayName)" }
        if item.section != nil {
            meta += " · § \(TheoryItem.sectionDisplayName(item.section))"
        }
        if !item.dependsOn.isEmpty {
            let label = item.isFigure ? "illustrates" : "depends on"
            meta += " · \(label): " + item.dependsOn.map { "`\($0)`" }.joined(separator: ", ")
        }
        parts.append(meta)
        if item.isFigure { parts.append(figureBlock(for: item)) }
        parts.append(item.body)
        return parts.joined(separator: "\n\n")
    }

    /// The image itself, resolved at render time. Item files never contain image markup:
    /// the `image:` frontmatter field names a file in `figures/`, and only this function
    /// turns it into something a page can load.
    private static func figureBlock(for item: TheoryItem) -> String {
        guard FigureResolver.shared.imageURL(forItemID: item.id) != nil,
              let url = FigureScheme.url(forItemID: item.id) else {
            return "> ⚠️ This figure's image is missing from `\(FigureAsset.folderName)/`."
        }
        return "![\(altText(for: item))](\(url.absoluteString))"
    }

    /// Alt text goes through the same markdown+LaTeX pipeline as everything else, so
    /// strip the three characters that would end the link early or open a math segment.
    private static func altText(for item: TheoryItem) -> String {
        String(item.name.filter { $0 != "[" && $0 != "]" && $0 != "$" })
    }
}
