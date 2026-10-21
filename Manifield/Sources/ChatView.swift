import SwiftUI
import ManifieldCore
import ManifieldAgents
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Use the AppState-owned controller so the transcript survives view switches.
        ChatBody(chat: appState.chat)
    }
}

private struct ChatBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController
    /// Measured height of the input text; the field grows with it up to a cap,
    /// then scrolls instead of pushing the chat off-screen.
    @State private var inputHeight: CGFloat = 24
    @State private var showItemPicker = false
    @State private var showSourcePicker = false
    @State private var attachmentError: String?
    private let maxInputHeight: CGFloat = 160

    var body: some View {
        // The inspector takes its width from the conversation, so opening it narrows the
        // transcript and the composer together; its divider is draggable.
        HSplitView {
            conversation
                .frame(minWidth: 380)

            if let reference = chat.inspectedItemRef {
                ChatItemInspector(reference: reference) { chat.inspectedItemRef = nil }
                    .frame(minWidth: 280, idealWidth: 380, maxWidth: 720)
            }
        }
        // Starting a new conversation lives in the sidebar's "New chat" row — one control,
        // in the same list as the chats it would push into history.
        .toolbar {
            ToolbarItem {
                Button {
                    if let url = appState.store?.artifactsURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Artifacts", systemImage: "folder.badge.gearshape")
                }
                .help("Open the artifacts folder — every run_python call saves its script and output there")
            }
        }
        .sheet(isPresented: $showItemPicker) {
            ItemPickerSheet(chat: chat)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSourcePicker) {
            SourcePickerSheet(chat: chat)
                .environmentObject(appState)
        }
        .alert("Couldn't attach file", isPresented: Binding(
            get: { attachmentError != nil || chat.attachmentError != nil },
            set: { if !$0 { attachmentError = nil; chat.attachmentError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(attachmentError ?? chat.attachmentError ?? "")
        }
        // Reverting rewrites files from the journal, so anything the user changed in those
        // items since the turn goes with it. Worth asking once.
        .alert(
            "Revert this turn's changes?",
            isPresented: Binding(
                get: { chat.pendingRevert != nil },
                set: { if !$0 { chat.pendingRevert = nil } }
            ),
            presenting: chat.pendingRevert
        ) { _ in
            Button("Cancel", role: .cancel) { chat.pendingRevert = nil }
            Button("Revert", role: .destructive) { chat.confirmRevert() }
        } message: { request in
            Text("""
            \(request.summary).

            This will \(request.hint) — including anything you have changed in them \
            since. It cannot be undone.
            """)
        }
        // Which ids are clickable in the transcript depends on both the library and the
        // attached sources, so re-push whenever either moves.
        .onAppear {
            chat.syncTheoryIndex()
            chat.syncWriteSummary()
        }
        .onChange(of: appState.itemsVersion) { _, _ in chat.syncTheoryIndex() }
        .onChange(of: appState.attachedSources.map(\.ref.slug)) { _, _ in chat.syncTheoryIndex() }
        // Accepting a proposal journals its write after the turn has already ended, so the
        // card has to be redrawn when the journal moves rather than only when a turn does.
        // Not while the turn is still running: the card is a summary and belongs at the
        // end of the turn, not stranded above the reply that is still streaming in.
        .onChange(of: appState.writeJournal.writes.count) { _, _ in
            guard !chat.isRunning else { return }
            chat.syncWriteSummary()
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            WebViewRepresentable(box: chat.box)

            if !appState.pendingProposals.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                    Text("\(appState.pendingProposals.count) proposed theory edit\(appState.pendingProposals.count == 1 ? "" : "s") awaiting your review")
                        .font(.callout)
                    Spacer()
                    Button("Review…") { appState.showProposalsSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.yellow.opacity(0.12))
                .overlay(alignment: .top) { Divider() }
            }

            if let request = chat.pendingFulltextRequest {
                fulltextRequestBanner(request)
            }

            composer
        }
    }

    // MARK: - Full-text access

    /// The agent is suspended on this decision — the turn continues once the user
    /// answers (or cancels the run, which counts as a denial).
    private func fulltextRequestBanner(_ request: ChatController.FulltextRequest) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: request.isDocument ? "doc.richtext" : "text.book.closed")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.isDocument
                     ? "Prismo asks to read the project file \(request.displayName)"
                     : "Prismo asks to read the full text of \(request.displayName)")
                    .font(.callout.weight(.medium))
                Text(request.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer()
            Button("Deny") { chat.resolveFulltextRequest(false) }
                .controlSize(.small)
            Button("Allow for This Chat") { chat.resolveFulltextRequest(true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !chat.attachedItems.isEmpty || !chat.pendingAttachments.isEmpty
                || !grantedSources.isEmpty || !grantedDocuments.isEmpty {
                attachmentPills
            }

            // The typing window: text on top, controls inside the same rounded card.
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if chat.draft.isEmpty {
                        Text("Ask Prismo about your theory…  (⏎ send · ⇧⏎ new line)")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $chat.draft,
                        onSubmit: { chat.send() },
                        onHeightChange: { inputHeight = $0 },
                        onAttachments: { attachments, errors in
                            chat.pendingAttachments.append(contentsOf: attachments)
                            if !errors.isEmpty { attachmentError = errors.joined(separator: "\n") }
                        }
                    )
                    .frame(height: min(max(inputHeight, 24), maxInputHeight))
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)

                HStack(spacing: 10) {
                    attachMenu
                    BranchContextPicker(chat: chat)
                    ModePicker(chat: chat, readableNames: readableNames, grantRows: grantRows)

                    Spacer()

                    ModelTaskPicker(task: .chat, compact: true)
                        .controlSize(.small)
                        .fixedSize()
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    sendButton
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .overlay(alignment: .topTrailing) {
            TurnStatsBadge(stats: chat.stats, isRunning: chat.isRunning)
                .padding(.trailing, 22)
                .offset(y: -14)
        }
    }

    private var sendButton: some View {
        Group {
            if chat.isRunning {
                Button {
                    chat.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop the current turn")
            } else {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⏎)")
            }
        }
    }

    private var canSend: Bool {
        !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chat.pendingAttachments.isEmpty
    }

    // MARK: Attachments

    private var attachMenu: some View {
        Menu {
            Button {
                showItemPicker = true
            } label: {
                Label("Add Theory Item…", systemImage: "books.vertical")
            }
            .help("Search the library and load an item into this chat's context")
            Button {
                showSourcePicker = true
            } label: {
                Label("Add Source…", systemImage: "text.book.closed")
            }
            .help("Grant Prismo full-text access to a literature source already attached to this project")
            Button {
                pickFiles()
            } label: {
                Label("Add Files or Photos…", systemImage: "doc.badge.plus")
            }
            .help("Attach a PDF, text/LaTeX/Python file, or an image to your next message")
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add context: a theory item, source, files, or photos")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AttachmentLoader.allowedTypes
        panel.message = "Attach files or photos to your next message"
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            do {
                chat.pendingAttachments.append(try AttachmentLoader.load(url: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            attachmentError = failures.joined(separator: "\n")
        }
    }

    private var attachmentPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.attachedItems, id: \.id) { item in
                    pill(icon: "books.vertical",
                         title: item.id,
                         subtitle: item.name,
                         help: "Loaded into Prismo's context for this whole chat") {
                        chat.removeAttachedItem(id: item.id)
                    }
                }
                ForEach(grantedSources, id: \.ref.slug) { entry in
                    pill(icon: "text.book.closed",
                         title: entry.ref.slug,
                         subtitle: entry.store.meta.name,
                         help: "Prismo can read this source's full text for this chat") {
                        chat.revokeFulltextGrant(slug: entry.ref.slug)
                    }
                }
                ForEach(grantedDocuments) { document in
                    pill(icon: document.isPDF ? "doc.richtext" : "doc.plaintext",
                         title: document.meta.title,
                         subtitle: document.formatLabel,
                         help: "Prismo can search and read this project file for this chat") {
                        chat.revokeGrant(key: ChatController.documentGrantKey(document.slug))
                    }
                }
                ForEach(chat.pendingAttachments) { attachment in
                    pill(icon: attachment.isImage ? "photo" : "doc.text",
                         title: attachment.name,
                         subtitle: nil,
                         help: "Will be attached to your next message") {
                        chat.removePendingAttachment(id: attachment.id)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func pill(icon: String, title: String, subtitle: String?, help: String,
                      onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10), in: Capsule())
        .help(help)
    }

    /// Sources in this project that carry a stored full text.
    private var fulltextSlugs: [String] {
        sourcesWithFulltext.map { $0.ref.slug }
    }

    private var sourcesWithFulltext: [(ref: SourceRef, store: ProjectStore)] {
        appState.attachedSources.filter { $0.store.hasFulltext }
    }

    /// Sources the user pinned to this chat via "Add Source…" (or an approved
    /// on-demand request) — shown as pills alongside pinned theory items.
    private var grantedSources: [(ref: SourceRef, store: ProjectStore)] {
        appState.attachedSources.filter { chat.fulltextAccess.granted.contains($0.ref.slug) }
    }

    /// Project files Prismo may read this chat (excluding the standing allow-all, which is
    /// shown in the mode picker rather than as one pill per file).
    private var grantedDocuments: [ProjectDocument] {
        appState.documents.filter {
            chat.fulltextAccess.granted.contains(ChatController.documentGrantKey($0.slug))
        }
    }

    /// Everything with a whole-document text Prismo could ask to read: attached sources and
    /// the project's own files.
    private var readableNames: [String] {
        fulltextSlugs + appState.documents.filter(\.isSearchable).map(\.meta.title)
    }

    /// The grants in force this chat, labelled for the mode picker's revoke list.
    private var grantRows: [GrantRow] {
        chat.fulltextAccess.granted.sorted().map { key in
            guard let slug = ChatController.documentSlug(forGrantKey: key) else {
                return GrantRow(id: key, label: key)
            }
            return GrantRow(id: key, label: appState.document(slug: slug)?.meta.title ?? slug)
        }
    }
}

/// One in-force reading grant (a source slug or a kept file), for the mode picker.
struct GrantRow: Identifiable {
    let id: String
    let label: String
}

// MARK: - Theory item inspector

/// The item a mention in the transcript opened, shown beside the conversation: the same
/// rendered document the Library detail pane shows, without leaving the chat.
///
/// `reference` is how Prismo wrote it — a project item id, or `slug:item-id` for an item
/// belonging to one of the project's attached sources.
private struct ChatItemInspector: View {
    @EnvironmentObject private var appState: AppState
    let reference: String
    let onClose: () -> Void

    @StateObject private var box = WebViewBox(page: "math")

    /// The item plus the store that owns it. A source's items carry their own macros and
    /// citation, so rendering needs the owning store rather than the open project.
    private var resolved: (item: TheoryItem, store: ProjectStore, sourceSlug: String?)? {
        if let colon = reference.firstIndex(of: ":") {
            let slug = String(reference[..<colon])
            let itemID = String(reference[reference.index(after: colon)...])
            guard let entry = appState.attachedSources.first(where: { $0.ref.slug == slug }),
                  let item = entry.store.item(id: itemID) else { return nil }
            return (item, entry.store, slug)
        }
        guard let store = appState.store, let item = store.item(id: reference) else { return nil }
        return (item, store, nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if resolved != nil {
                WebViewRepresentable(box: box)
            } else {
                ContentUnavailableView(
                    "Item not found",
                    systemImage: "questionmark.folder",
                    description: Text("Nothing in this project matches “\(reference)” — it may have been renamed or deleted, or belong to a source that is no longer attached.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { render() }
        .onChange(of: reference) { _, _ in render() }
        .onChange(of: appState.itemsVersion) { _, _ in render() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                if let resolved {
                    ItemNameText(name: resolved.item.name, macros: resolved.store.macroDictionary)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(reference)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(resolved.item.type.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        StatusBadge(status: resolved.item.status)
                    }
                    if resolved.sourceSlug != nil {
                        Label(resolved.store.meta.name, systemImage: "text.book.closed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Item not found").font(.headline)
                    Text(reference)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let resolved {
                Button(action: openInLibrary) {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(resolved.sourceSlug == nil
                      ? "Open this item in the Library tab"
                      : "Open this item in the Sources tab")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (the conversation gets the space back)")
        }
        .padding(10)
    }

    /// Jumps to the item's home tab, where it can be edited, proved or deleted.
    private func openInLibrary() {
        guard let resolved else { return }
        if let slug = resolved.sourceSlug {
            appState.selectedSourceSlug = slug
            appState.selectedSourceItemID = resolved.item.id
            appState.selection = .sources
        } else {
            appState.selectedItemID = resolved.item.id
            appState.libraryFilter = nil  // a type filter would hide the row we just selected
            appState.selection = .library
        }
    }

    private func render() {
        guard let resolved else { return }
        box.call("setMathMacros", resolved.store.macroDictionary)
        var document = TheoryDocument.markdown(for: resolved.item)
        if resolved.sourceSlug != nil, let citation = resolved.store.meta.citation {
            document += "\n\n---\n*Source: \(citation)*"
        }
        box.call("setDocument", document)
    }
}

// MARK: - Mode picker

/// Composer mode control: Auto / Plan / Propose / Ask, plus the standing "read full
/// documents" permission — everything that shapes how much agency Prismo gets lives in
/// one popover.
private struct ModePicker: View {
    @ObservedObject var chat: ChatController
    /// Names of everything with a whole-document text: attached sources' full texts and
    /// the project's own kept files.
    let readableNames: [String]
    /// Grants in force this chat, for the per-item revoke rows.
    let grantRows: [GrantRow]
    @State private var isOpen = false
    /// Set when Auto is chosen for the first time — the one-time explanation of what
    /// direct writes mean, shown before the mode actually changes.
    @State private var pendingAutoMode = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chat.mode.symbol)
                Text(chat.mode.displayName)
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .foregroundStyle(chat.mode == .propose ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help("How much agency Prismo gets this conversation")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ChatMode.allCases) { mode in
                    Button {
                        if mode == .auto, !AppSettings.hasSeenAutoModeNotice {
                            pendingAutoMode = true
                        } else {
                            chat.setMode(mode)
                        }
                        isOpen = false
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: mode.symbol)
                                .frame(width: 16)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(mode.displayName)
                                    .font(.callout.weight(.medium))
                                Text(mode.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if chat.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .background(chat.mode == mode ? Color.accentColor.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }

                if !readableNames.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                    Toggle(isOn: Binding(
                        get: { chat.fulltextAccess.allowAll },
                        set: { chat.setFulltextAllowAll($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto-allow reading full documents")
                                .font(.callout)
                            Text("Prismo may read the project's files and every attached source's full text without asking (\(readableNames.joined(separator: ", ")))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    if !grantRows.isEmpty && !chat.fulltextAccess.allowAll {
                        ForEach(grantRows) { row in
                            HStack {
                                Text("“\(row.label)” allowed this chat")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Revoke") { chat.revokeGrant(key: row.id) }
                                    .font(.caption)
                                    .controlSize(.mini)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 340)
        }
        // Attached to the button rather than inside the popover: the popover dismisses
        // as the alert opens, and an alert anchored to a disappearing view renders off
        // the bottom of the window instead of centred on it.
        .alert("Auto mode edits the library directly", isPresented: $pendingAutoMode) {
            Button("Cancel", role: .cancel) { }
            Button("Turn on Auto") {
                AppSettings.hasSeenAutoModeNotice = true
                chat.setMode(.auto)
            }
        } message: {
            Text("""
            In Auto, Prismo creates and edits theory items without asking first. \
            Project files are not version-controlled, so every write is recorded in the \
            project's change journal with the item's previous contents. Statements it is \
            not confident in still land as conjectures or drafts — it can never mark \
            anything approved.
            """)
        }
    }
}

// MARK: - Token counter + timer

/// Floating readout above the composer: request timer (live while running, frozen
/// total afterwards) and token counts (context in ↑, generated this turn ↓).
private struct TurnStatsBadge: View {
    let stats: ChatController.TurnStats
    let isRunning: Bool

    var body: some View {
        if isRunning || stats.hasEverRun {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: isRunning ? "timer" : "checkmark.circle")
                        .font(.system(size: 9))
                    Text(Self.duration(stats.elapsed))
                        .monospacedDigit()
                }
                .foregroundStyle(isRunning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

                if stats.inputTokens > 0 || stats.outputTokens > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .semibold))
                        Text(Self.tokens(stats.inputTokens))
                            .monospacedDigit()
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text(Self.tokens(stats.outputTokens))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
                if stats.cachedInputTokens > 0 {
                    Label(Self.tokens(stats.cachedInputTokens), systemImage: "bolt.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .help(helpText)
        }
    }

    private var helpText: String {
        var parts = ["Request timer", "↑ input tokens", "↓ output tokens"]
        if stats.cachedInputTokens > 0 { parts.append("⚡ \(stats.cachedInputTokens) cached-input tokens observed") }
        if stats.cacheWriteInputTokens > 0 { parts.append("\(stats.cacheWriteInputTokens) cache-write tokens") }
        if stats.reasoningOutputTokens > 0 { parts.append("\(stats.reasoningOutputTokens) reasoning tokens") }
        if let window = stats.contextWindowTokens { parts.append("context window \(window) tokens") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return String(format: "%dm %02ds", minutes, Int(seconds) % 60)
    }

    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<100_000: return String(format: "%.1fk", Double(count) / 1_000)
        default: return String(format: "%.0fk", Double(count) / 1_000)
        }
    }
}

// MARK: - Item picker

/// Searchable picker over the project's theory items; clicking toggles attachment so
/// several items can be loaded in one visit.
private struct ItemPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [TheoryItem] {
        let all = appState.store?.items ?? []
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.id.lowercased().contains(trimmed)
                || $0.name.lowercased().contains(trimmed)
                || $0.type.rawValue.contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search items by id, name or type…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4))

            Divider()

            if items.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List(items, id: \.id) { item in
                    let attached = chat.attachedItems.contains { $0.id == item.id }
                    Button {
                        if attached {
                            chat.removeAttachedItem(id: item.id)
                        } else {
                            chat.attachItem(item)
                        }
                    } label: {
                        HStack {
                            Image(systemName: attached ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(attached ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.id)
                                    .font(.callout.monospaced())
                                Text(item.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.type.displayName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Loaded items ride along in Prismo's context for the whole chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - Source picker

/// Grants full-text access to one of the project's already-attached literature sources
/// for this chat — the same effect as approving an on-demand request_fulltext_access
/// banner, just started by the user instead of the model having to ask first. Item-level
/// content (search_sources/read_source_item) is always available regardless; this only
/// unlocks the raw original document text for sources that stored one.
private struct SourcePickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var grantable: [(ref: SourceRef, store: ProjectStore)] {
        appState.attachedSources.filter { $0.store.hasFulltext }
    }

    private var filtered: [(ref: SourceRef, store: ProjectStore)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return grantable }
        return grantable.filter {
            $0.ref.slug.lowercased().contains(trimmed)
                || $0.store.meta.name.lowercased().contains(trimmed)
                || ($0.store.meta.citation ?? "").lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sources by name or citation…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4))

            Divider()

            if chat.fulltextAccess.allowAll {
                allowAllNotice
                Divider()
            }

            if grantable.isEmpty {
                ContentUnavailableView(
                    "No sources with stored full text",
                    systemImage: "text.book.closed",
                    description: Text("Attach a source with an original document from the Sources tab. Sources without one are still searchable — Prismo can already use their items without being asked to.")
                )
                .frame(maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxHeight: .infinity)
            } else {
                List(filtered, id: \.ref.slug) { entry in
                    let granted = chat.fulltextAccess.granted.contains(entry.ref.slug)
                    Button {
                        if granted {
                            chat.revokeFulltextGrant(slug: entry.ref.slug)
                        } else {
                            chat.addSource(slug: entry.ref.slug, name: entry.store.meta.name)
                        }
                    } label: {
                        HStack {
                            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(granted ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.store.meta.name)
                                    .font(.callout)
                                Text(entry.store.meta.citation ?? entry.ref.slug)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let info = entry.store.fulltextInfo {
                                Text(info.unitLabel)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Granted sources let Prismo read the full original text, not just its indexed items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 460, height: 420)
    }

    private var allowAllNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.accentColor)
            Text("“Auto-allow reading full documents” is on for this project — every attached source's full text is already available.")
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }
}

/// Picks which research branch this conversation is about. With one selected, the branch's
/// plan, lens, guidance, journal, memory and findings enter the system prompt on every
/// turn — so chat and the run are looking at the same thing, live.
struct BranchContextPicker: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chat: ChatController

    private var selectedPlan: PlanDocument? {
        chat.branchPlanID.flatMap { id in appState.plans.first { $0.id == id } }
    }

    var body: some View {
        Menu {
            Button {
                chat.branchPlanID = nil
            } label: {
                if chat.branchPlanID == nil { Image(systemName: "checkmark") }
                Text("No branch")
            }
            ForEach(appState.allPrograms) { program in
                let branchPlans = appState.branchPlans(of: program)
                if !branchPlans.isEmpty {
                    Section(program.displayName) {
                        ForEach(branchPlans, id: \.id) { plan in
                            Button {
                                chat.branchPlanID = plan.id
                            } label: {
                                if chat.branchPlanID == plan.id { Image(systemName: "checkmark") }
                                Text(program.branch(planID: plan.id)?.title ?? plan.id)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                if let plan = selectedPlan {
                    Text(appState.allPrograms
                        .compactMap { $0.branch(planID: plan.id)?.title }
                        .first ?? plan.id)
                        .lineLimit(1)
                } else {
                    Text("Branch")
                }
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(selectedPlan == nil
              ? "Work on a research branch in this conversation"
              : "This chat sees the branch's plan, guidance, journal and findings on every turn")
    }
}
