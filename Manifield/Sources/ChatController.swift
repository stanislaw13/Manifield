import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Composer mode: how much agency Prismo gets this conversation.
/// Ask is read-and-discuss, Plan drafts a target for the persistent research director,
/// Propose is the full agent with every library write behind the confirmation gate, and
/// Auto lets it write to the library directly.
/// Tool subsets are assembled per mode in AppState.makeChatConfig.
///
/// Declared (and displayed) in the order Auto, Plan, Propose, Ask.
///
/// `propose` is the default and carries the raw value `"propose"`; chats saved before the
/// mode split stored `"auto"` and therefore open in Auto.
enum ChatMode: String, Codable, CaseIterable, Identifiable {
    case auto, plan, propose, ask

    var id: String { rawValue }

    /// Modes in which Prismo may change the library at all.
    var canWriteTheory: Bool { self == .propose || self == .auto }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .plan: return "Plan"
        case .propose: return "Propose"
        case .ask: return "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "bolt"
        case .plan: return "map"
        case .propose: return "tray.full"
        case .ask: return "bubble.left.and.text.bubble.right"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Full agent — edits the library directly, no approval"
        case .plan: return "Draft a research target, then start it with your approval"
        case .propose: return "Full agent — every edit waits for your approval"
        case .ask: return "Read-only discussion, no execution"
        }
    }
}

/// Drives the chat: keeps the LLM transcript, streams agent activity into the chat
/// web view, and persists every conversation in the project folder so the sidebar can
/// offer a per-project chat history.
@MainActor
final class ChatController: ObservableObject {

    @Published var isRunning = false
    @Published var draft = ""
    /// Composer mode for this conversation (persisted per chat via setMode).
    @Published private(set) var mode: ChatMode = .propose
    /// Theory items the user pinned to this chat. Their full text is fed to Prismo's
    /// system prompt (see AppState.makeChatConfig) so the model knows what's loaded.
    @Published private(set) var attachedItems: [LinkedItem] = []
    /// The research branch this conversation is working on; its plan, guidance, journal
    /// and findings enter the system prompt so chat and the run share one context.
    @Published var branchPlanID: String?
    /// Files/photos staged in the composer; they become content blocks of the next
    /// user message when it is sent.
    @Published var pendingAttachments: [ComposerAttachment] = []
    /// Which source full texts Prismo may read. `allowAll` is the user's standing choice
    /// for this project; `granted` collects per-request grants and lasts one chat.
    @Published private(set) var fulltextAccess = FulltextAccessState()
    /// Set while an agent's request_fulltext_access call awaits the user's decision;
    /// ChatView renders it as an Allow/Deny banner.
    @Published private(set) var pendingFulltextRequest: FulltextRequest?
    /// Set when the Revert button on a change summary is clicked; ChatView raises the
    /// confirmation, because reverting overwrites the files as they are now.
    @Published var pendingRevert: RevertRequest?
    /// Live token/timing readout for the floating counter above the composer.
    @Published private(set) var stats = TurnStats()
    @Published var attachmentError: String?
    /// The theory item the side inspector is showing, as Prismo referred to it: a project
    /// item id, or `slug:item-id` for one of an attached source's items. Set by clicking a
    /// mention in the transcript; nil closes the pane.
    @Published var inspectedItemRef: String? {
        didSet {
            guard inspectedItemRef != oldValue else { return }
            box.call("chatSetOpenItem", inspectedItemRef ?? "")
        }
    }

    /// Saved chats in the open project, newest-first — the sidebar's history list.
    @Published private(set) var chats: [ChatSummary] = []
    /// Which saved chat is currently open (drives the sidebar highlight).
    @Published private(set) var activeChatID = ""

    /// Lightweight descriptor of a pinned item, kept for the composer pill and persistence.
    struct LinkedItem: Equatable, Codable {
        let id: String
        let name: String
    }

    /// A file staged in the composer. Images carry base64 + media type (sent as native
    /// image blocks); text-bearing files carry their extracted text.
    struct ComposerAttachment: Identifiable, Equatable {
        enum Kind: Equatable {
            case image(mediaType: String, base64: String)
            case document(text: String)
        }
        let id = UUID()
        let name: String
        let kind: Kind

        var isImage: Bool { if case .image = kind { return true }; return false }
    }

    /// Token/latency numbers for the current (or last finished) request.
    struct TurnStats: Equatable {
        /// Input tokens consumed across every provider round-trip in this turn.
        var inputTokens = 0
        /// Tokens generated across the current turn (all round-trips).
        var outputTokens = 0
        var cachedInputTokens = 0
        var cacheWriteInputTokens = 0
        var reasoningOutputTokens = 0
        var contextWindowTokens: Int?
        var turnStartedAt: Date?
        /// Ticks while running; freezes at the total once the turn ends.
        var elapsed: TimeInterval = 0
        /// True once any request ran in this chat (controls counter visibility).
        var hasEverRun = false
    }

    struct FulltextAccessState: Equatable, Codable {
        var allowAll = false
        var granted: Set<String> = []
    }

    /// Where a turn's change summary sits in this conversation. Only the pointer is
    /// persisted — the writes themselves live in the project's `WriteJournal`, so a
    /// reverted turn simply stops having a card to draw.
    struct WriteTurnMark: Codable, Equatable {
        let turnID: String
        /// Index in `transcript` the card follows on replay.
        let afterMessageIndex: Int
    }

    /// A revert waiting on the user. Reverting rewrites item files from the journal, so
    /// any edit made to those items since the turn goes with it — worth one confirmation.
    struct RevertRequest: Identifiable, Equatable {
        let id = UUID()
        let turnID: UUID
        let summary: String
        let hint: String
    }

    /// An agent asking to read a whole document — either an attached source's full text or
    /// one of the project's own kept files. Both suspend the turn on the same banner.
    struct FulltextRequest: Identifiable, Equatable {
        enum Subject: Equatable {
            case source(slug: String)
            case document(slug: String, title: String)
        }
        let id = UUID()
        let subject: Subject
        let reason: String

        /// The key inserted into `granted` on approval.
        var grantKey: String {
            switch subject {
            case .source(let slug): return slug
            case .document(let slug, _): return ChatController.documentGrantKey(slug)
            }
        }

        /// What the banner (and the transcript note) calls it.
        var displayName: String {
            switch subject {
            case .source(let slug): return "“\(slug)”"
            case .document(_, let title): return "“\(title)”"
            }
        }

        var isDocument: Bool {
            if case .document = subject { return true }
            return false
        }
    }

    /// One saved conversation, persisted to `sessions/chats/<id>.json`.
    struct ChatSession: Codable, Identifiable {
        let id: String
        var title: String
        /// True once the user manually renames — stops a late-arriving auto-generated
        /// title from overwriting their choice.
        var titleLocked: Bool?
        var createdAt: Date
        var updatedAt: Date
        var transcript: [LLMMessage]
        /// Legacy single pinned item (pre-multi-attach files); migrated on load.
        var linkedItem: LinkedItem?
        var attachedItems: [LinkedItem]?
        var mode: ChatMode?
        var fulltextGranted: Set<String>
        /// Plan id of the research branch this conversation is about, if any.
        var branchPlanID: String?
        /// Journal turns this chat opened that wrote to the library, and where their
        /// change summaries belong in the transcript.
        var writeTurns: [WriteTurnMark]?
    }

    /// A row in the sidebar history list, derived from a `ChatSession` without holding its
    /// full transcript in memory.
    struct ChatSummary: Identifiable, Equatable {
        let id: String
        var title: String
        var updatedAt: Date
        var messageCount: Int
        var linkedItemName: String?

        init(from session: ChatSession) {
            id = session.id
            title = session.title.isEmpty ? "New chat" : session.title
            updatedAt = session.updatedAt
            messageCount = session.transcript.filter { $0.role == .user }.count
            let items = session.attachedItems ?? session.linkedItem.map { [$0] } ?? []
            linkedItemName = items.first.map { first in
                items.count > 1 ? "\(first.name) +\(items.count - 1)" : first.name
            }
        }
    }

    let box = WebViewBox(page: "chat")

    private(set) var transcript: [LLMMessage] = []
    private var activeCreatedAt = Date()
    /// Empty until the chat is named — either auto-derived from the first prompt or renamed.
    private var activeTitle = ""
    private weak var appState: AppState?
    /// Change-summary cards this conversation shows, oldest first.
    private var writeTurns: [WriteTurnMark] = []
    /// The journal turn this chat opened last. Only this one can still gain writes — in
    /// Propose mode they land when the user accepts, which is after the reply finished.
    private var openTurnID: UUID?
    private var runTask: Task<Void, Never>?
    private var fulltextRequestContinuation: CheckedContinuation<Bool, Never>?
    private var turnTimer: Timer?

    private static let activeChatSession = "active-chat"
    private static let allowAllSession = "fulltext-allow-all"
    // Legacy single-chat files, migrated into the history on first open.
    private static let legacyTranscript = "current"
    private static let legacyLinkedItem = "current-linked-item"
    private static let legacyFulltextAccess = "current-fulltext-access"

    func attach(appState: AppState) {
        self.appState = appState
        cancel()
        transcript = []
        attachedItems = []
        pendingAttachments = []
        mode = .propose
        stats = TurnStats()
        fulltextAccess = FulltextAccessState()
        inspectedItemRef = nil
        pendingRevert = nil
        writeTurns = []
        openTurnID = nil
        activeTitle = ""
        box.call("chatReset")
        box.onMessage = { [weak self] body in self?.handleBridgeMessage(body) }
        appState.syncMacros(box)
        syncTheoryIndex()
        loadChats()          // migrates the legacy chat on first open
        restoreAllowAll()    // project-wide standing full-text choice
        restoreActiveChat()  // reopen the last chat, or start a fresh one
    }

    /// Starts a fresh conversation focused on `item`: opens a new chat, pins the item
    /// so its full text is injected into Prismo's context, and marks the load in the chat.
    func startLinkedChat(with item: TheoryItem) {
        cancel()
        startEmptyActive(id: UUID().uuidString)
        attachedItems = [LinkedItem(id: item.id, name: item.name)]
        box.call("chatContextNote", "Loaded \(item.id) — \(item.name)")
        persistActiveChatID()
    }

    /// Pins another item to the running conversation (composer + picker).
    func attachItem(_ item: TheoryItem) {
        guard !attachedItems.contains(where: { $0.id == item.id }) else { return }
        attachedItems.append(LinkedItem(id: item.id, name: item.name))
        box.call("chatContextNote", "Loaded \(item.id) — \(item.name)")
        saveSession()
    }

    /// Unpins one item without clearing the conversation.
    func removeAttachedItem(id: String) {
        attachedItems.removeAll { $0.id == id }
        saveSession()
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// User-driven mode switch (mode picker); persists with the conversation.
    func setMode(_ newMode: ChatMode) {
        guard newMode != mode else { return }
        mode = newMode
        saveSession()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isRunning, let appState else { return }
        let choice = AppSettings.effectiveChoice(for: .chat)
        if choice.kind == .codex, attachments.contains(where: \.isImage),
           let option = ModelListCache.shared.advertisedOption(for: choice.model, kind: .codex),
           !option.inputModalities.contains(.image) {
            attachmentError = "\(option.displayName) does not advertise image input. Remove the image or choose an image-capable Codex model."
            return
        }
        draft = ""
        pendingAttachments = []

        // Images precede text (providers prefer it); documents in between.
        var blocks: [ContentBlock] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image(let mediaType, let base64):
                blocks.append(.image(mediaType: mediaType, base64: base64))
            case .document(let docText):
                blocks.append(.document(name: attachment.name, text: docText))
            }
        }
        if !text.isEmpty { blocks.append(.text(text)) }

        renderUserMessage(blocks: blocks)
        box.call("chatBeginAssistant")
        // Show life immediately; the first text delta clears it.
        box.call("chatStatus", "Thinking", "thinking")
        beginTurn()

        let history = transcript + [LLMMessage(role: .user, blocks: blocks)]
        // Persist the user turn immediately so the chat lands in the sidebar (named from
        // this first prompt) right away, before Prismo's reply arrives.
        transcript = history
        saveSession()

        if history.count == 1, !text.isEmpty {
            let chatID = activeChatID
            let firstMessage = String(text.prefix(600))   // titling doesn't need the whole message
            Task<Void, Never> { [weak self] in
                guard let self, let appState = self.appState,
                      let (runner, config) = try? appState.makeChatNamingConfig() else { return }
                guard let result = try? await runner
                    .run(config: config, history: [.user(firstMessage)]) else { return }
                let title = ChatNaming.sanitize(result.finalText)
                guard !title.isEmpty else { return }
                self.applyGeneratedTitle(chatID: chatID, title: title)
            }
        }

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Opens the journal turn every library write this message makes is filed
                // under, so the change summary and the revert act on one unit.
                self.openTurnID = appState.beginWriteTurn()
                let (runner, config) = try appState.makeChatConfig(mode: self.mode)
                let result = try await runner.run(config: config, history: history) { activity in
                    DispatchQueue.main.async { self.handle(activity) }
                }
                self.transcript = result.transcript
                self.closeThinkingIfOpen()
                self.box.call("chatStatusClear")
                self.box.call("chatFinalize")
                self.saveSession()
            } catch is CancellationError {
                self.closeThinkingIfOpen()
                self.box.call("chatStatusClear")
                self.box.call("chatFinalize")
                self.box.call("chatToolNote", "✕ cancelled", true)
                self.transcript = history
            } catch {
                self.closeThinkingIfOpen()
                self.box.call("chatStatusClear")
                self.box.call("chatFinalize")
                self.box.call("chatError", Self.describeNetworkError(error))
                // Keep the user's message so they can retry after e.g. adding an API key.
                self.transcript = history
            }
            // A cancelled or failed turn can still have written before it stopped, so the
            // summary is drawn on every path out.
            self.syncWriteSummary()
            self.endTurn()
        }
    }

    func cancel() {
        // A pending access request would leave the agent loop awaiting forever —
        // resolve it as denied before tearing the run down.
        resolveFulltextRequest(false)
        runTask?.cancel()
        runTask = nil
        if isRunning { endTurn() }
    }

    // MARK: - Turn stats (token counter + timer)

    private func beginTurn() {
        isRunning = true
        stats.turnStartedAt = Date()
        stats.elapsed = 0
        stats.outputTokens = 0
        stats.cachedInputTokens = 0
        stats.cacheWriteInputTokens = 0
        stats.reasoningOutputTokens = 0
        stats.contextWindowTokens = nil
        stats.hasEverRun = true
        turnTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let start = self.stats.turnStartedAt, self.isRunning else { return }
                self.stats.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        turnTimer = timer
    }

    private func endTurn() {
        if let start = stats.turnStartedAt {
            stats.elapsed = Date().timeIntervalSince(start)
        }
        turnTimer?.invalidate()
        turnTimer = nil
        isRunning = false
    }

    // MARK: - Chat history

    /// True while the open conversation is an untouched blank one — nothing sent, nothing
    /// pinned. The sidebar's *New chat* row uses this to avoid re-rolling a chat that is
    /// already new: a fresh id would throw away a pinned item or a staged attachment for
    /// no visible gain.
    var isPristine: Bool {
        transcript.isEmpty && attachedItems.isEmpty && pendingAttachments.isEmpty
    }

    /// Archives the current chat (already on disk once it has content) and starts a new one.
    func newChat() {
        cancel()
        startEmptyActive(id: UUID().uuidString)
        persistActiveChatID()
    }

    /// Opens a previously saved chat, replaying its transcript into the web view.
    func switchTo(chatID: String) {
        guard chatID != activeChatID else { return }
        cancel()
        guard let session = loadChatSession(id: chatID) else {
            loadChats()  // the file vanished (e.g. deleted elsewhere) — refresh the list
            return
        }
        setActive(from: session)
        persistActiveChatID()
    }

    /// Deletes a saved chat; if it was open, falls back to the newest remaining one.
    func deleteChat(id: String) {
        appState?.store?.deleteChat(id: id)
        chats.removeAll { $0.id == id }
        guard id == activeChatID else { return }
        if let newest = chats.first, let session = loadChatSession(id: newest.id) {
            setActive(from: session)
        } else {
            startEmptyActive(id: UUID().uuidString)
        }
        persistActiveChatID()
    }

    /// Renames a chat; a manual title sticks (locks out the async auto-generated title).
    func renameChat(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if id == activeChatID { activeTitle = trimmed }
        if var session = loadChatSession(id: id) {
            session.title = trimmed
            session.titleLocked = true
            if let data = try? JSONEncoder().encode(session) {
                try? appState?.store?.saveChat(id: id, json: data)
            }
        }
        if let idx = chats.firstIndex(where: { $0.id == id }) {
            chats[idx].title = trimmed
        }
    }

    /// Applies an LLM-generated title once it arrives (see send()), unless the chat was
    /// deleted or its title was locked (manually renamed) in the meantime.
    private func applyGeneratedTitle(chatID: String, title: String) {
        guard var session = loadChatSession(id: chatID), session.titleLocked != true else { return }
        session.title = title
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? appState?.store?.saveChat(id: chatID, json: data)
        if chatID == activeChatID { activeTitle = title }
        if let idx = chats.firstIndex(where: { $0.id == chatID }) {
            chats[idx].title = title
        }
    }

    // MARK: - Full-text access

    /// Grant keys for the project's own files are namespaced, so a kept file can never be
    /// unlocked by a same-named source having been granted (or the reverse).
    nonisolated static func documentGrantKey(_ slug: String) -> String { "file:\(slug)" }

    /// The kept-file slug a grant key refers to, or nil for a source's key.
    nonisolated static func documentSlug(forGrantKey key: String) -> String? {
        key.hasPrefix("file:") ? String(key.dropFirst(5)) : nil
    }

    func isFulltextGranted(slug: String) -> Bool {
        fulltextAccess.allowAll || fulltextAccess.granted.contains(slug)
    }

    func isDocumentGranted(slug: String) -> Bool {
        fulltextAccess.allowAll || fulltextAccess.granted.contains(Self.documentGrantKey(slug))
    }

    func setFulltextAllowAll(_ allow: Bool) {
        fulltextAccess.allowAll = allow
        persistAllowAll(allow)
    }

    func revokeFulltextGrant(slug: String) {
        revokeGrant(key: slug)
    }

    /// Revokes one grant by its stored key (a source slug, or a kept file's namespaced key).
    func revokeGrant(key: String) {
        fulltextAccess.granted.remove(key)
        saveSession()
    }

    /// Grants a kept file for this chat without waiting to be asked (the composer's file
    /// picker) — the same effect as approving a request_document_access banner.
    func addDocument(slug: String, title: String) {
        let key = Self.documentGrantKey(slug)
        guard !fulltextAccess.granted.contains(key) else { return }
        fulltextAccess.granted.insert(key)
        saveSession()
        box.call("chatContextNote", "Loaded \(title) — readable this chat")
    }

    /// Proactively grants a source's full text for this chat (composer "Add Source…"
    /// picker) — the same effect as approving an on-demand request_fulltext_access
    /// banner, just started by the user instead of the model asking first. Item-level
    /// search/read is already always available, so this only unlocks the raw full text.
    func addSource(slug: String, name: String) {
        guard !fulltextAccess.granted.contains(slug) else { return }
        fulltextAccess.granted.insert(slug)
        saveSession()
        box.call("chatContextNote", "Loaded \(slug) — \(name)")
    }

    /// Called by the request_fulltext_access tool (off the main actor): shows the
    /// Allow/Deny banner and suspends until the user decides. Tool calls in a turn run
    /// sequentially, so at most one request is ever pending.
    func requestFulltextAccess(slug: String, reason: String) async -> Bool {
        await requestAccess(subject: .source(slug: slug), reason: reason)
    }

    /// The same flow for one of the project's own files (request_document_access).
    func requestDocumentAccess(slug: String, title: String, reason: String) async -> Bool {
        await requestAccess(subject: .document(slug: slug, title: title), reason: reason)
    }

    private func requestAccess(subject: FulltextRequest.Subject, reason: String) async -> Bool {
        resolveFulltextRequest(false)  // stale guard; should never fire
        return await withCheckedContinuation { continuation in
            fulltextRequestContinuation = continuation
            pendingFulltextRequest = FulltextRequest(subject: subject, reason: reason)
        }
    }

    func resolveFulltextRequest(_ granted: Bool) {
        guard let continuation = fulltextRequestContinuation else { return }
        fulltextRequestContinuation = nil
        if granted, let request = pendingFulltextRequest {
            fulltextAccess.granted.insert(request.grantKey)
            saveSession()
            box.call("chatContextNote", "Granted reading access to \(request.displayName) for this chat")
        }
        pendingFulltextRequest = nil
        continuation.resume(returning: granted)
    }

    // MARK: - Change summary + revert

    /// Draws (or refreshes) the change-summary card for the turn this chat opened last.
    ///
    /// Called when the turn ends and again whenever the journal moves, because the two
    /// write paths finish at different times: Auto writes during the turn, while Propose
    /// writes when the user accepts the proposal — which is after the reply has landed,
    /// and can be after they have wandered off to another tab and come back.
    func syncWriteSummary() {
        guard let appState, let turnID = openTurnID,
              appState.currentWriteTurn == turnID else { return }
        let writes = appState.writeJournal.writes(inTurn: turnID)
        guard !writes.isEmpty else { return }
        if !writeTurns.contains(where: { $0.turnID == turnID.uuidString }) {
            writeTurns.append(WriteTurnMark(
                turnID: turnID.uuidString,
                afterMessageIndex: max(0, transcript.count - 1)))
            saveSession()
        }
        box.call("chatWriteSummary", ChangeSummary.payload(turnID: turnID, writes: writes))
    }

    /// Replays the cards that belong after `index` when a saved chat is reopened. A turn
    /// whose writes are gone — reverted, or aged out of the capped journal — has nothing
    /// left to show or to undo, so it draws nothing.
    private func replayWriteSummaries(afterMessageIndex index: Int) {
        guard let appState else { return }
        for mark in writeTurns where mark.afterMessageIndex == index {
            guard let turnID = UUID(uuidString: mark.turnID) else { continue }
            let writes = appState.writeJournal.writes(inTurn: turnID)
            guard !writes.isEmpty else { continue }
            box.call("chatWriteSummary", ChangeSummary.payload(turnID: turnID, writes: writes))
        }
    }

    /// Carries out the revert the user confirmed: newest write first, so an item written
    /// twice in the turn lands back on the state it had before the turn began.
    func confirmRevert() {
        guard let request = pendingRevert, let appState else { return }
        pendingRevert = nil
        let writes = appState.writeJournal.writes(inTurn: request.turnID)
        guard !writes.isEmpty else { return }
        let label = WriteJournal.revertedLabel(for: writes)
        appState.revertWriteTurn(request.turnID)
        writeTurns.removeAll { $0.turnID == request.turnID.uuidString }
        saveSession()
        box.call("chatWriteTurnReverted", request.turnID.uuidString, label)
    }

    // MARK: - Theory item mentions

    /// Tells the transcript which item references exist, so mentions of them render as
    /// click targets. Only ids in this set become clickable, so an id-shaped English word
    /// stays plain text and a hallucinated id stays visibly unlinked. Call whenever the
    /// library or the set of attached sources changes.
    func syncTheoryIndex() {
        guard let appState else { return }
        var refs = (appState.store?.items ?? []).map(\.id)
        for entry in appState.attachedSources {
            refs.append(contentsOf: entry.store.items.map { "\(entry.ref.slug):\($0.id)" })
        }
        box.call("chatSetTheoryIndex", refs)
    }

    // MARK: - Agent activity → status strip + transcript

    /// True while a thinking note is streaming in the web view (closed lazily on the
    /// next non-thinking activity so we don't spam JS calls per token).
    private var thinkingOpen = false

    private func handle(_ activity: AgentActivity) {
        switch activity {
        case .thinkingDelta(let delta):
            if !thinkingOpen {
                thinkingOpen = true
                box.call("chatStatus", "Thinking", "thinking")
            }
            box.call("chatThinkingDelta", delta)
        case .textDelta(let delta):
            closeThinkingIfOpen()
            box.call("chatStatusClear")
            box.call("chatAppendDelta", delta)
        case .toolStarted(let name, let summary):
            closeThinkingIfOpen()
            box.call("chatFinalize")
            box.call("chatStatus", Self.statusLabel(forTool: name), "tool")
            box.call("chatToolNote", "→ \(name) \(summary)", false)
        case .toolFinished(let name, let preview, let isError):
            if isError {
                box.call("chatToolNote", "✕ \(name) failed", true)
            } else if name == "run_python" {
                // First line of the result is "exit code: N in X.Xs [flags]" — show it
                // up to the flags so the user sees the actual runtime next to the estimate.
                if let firstLine = preview.split(separator: "\n").first,
                   let gist = firstLine.split(separator: "[").first {
                    box.call("chatToolNote", "✓ run_python — \(gist.trimmingCharacters(in: .whitespaces))", false)
                }
            }
            // Waiting for the model's next round-trip.
            box.call("chatStatus", "Thinking", "thinking")
            box.call("chatBeginAssistant")
        case .usage(let input, let output):
            stats.inputTokens += input
            stats.outputTokens += output
        case .usageDetails(let details):
            stats.cachedInputTokens += details.cachedInputTokens
            stats.cacheWriteInputTokens += details.cacheWriteInputTokens
            stats.reasoningOutputTokens += details.reasoningOutputTokens
            if let window = details.contextWindowTokens { stats.contextWindowTokens = window }
        case .iterationLimitReached:
            box.call("chatToolNote", "⚠︎ tool iteration limit reached", true)
        }
    }

    /// 1–4 word user-facing label for what the agent is doing right now.
    static func statusLabel(forTool name: String) -> String {
        switch name {
        case "run_python": return "Running Python"
        case "create_visualization": return "Drawing visualization"
        case "oeis_lookup": return "Searching OEIS"
        case "search_theory": return "Searching the library"
        case "read_theory_item", "list_theory": return "Reading the library"
        case "propose_theory_edit": return "Drafting an edit"
        case "search_sources", "read_source_item": return "Searching sources"
        case "search_fulltext", "read_fulltext": return "Reading source text"
        case "request_fulltext_access": return "Requesting access"
        case "update_memory": return "Updating memory"
        case "start_research": return "Starting research"
        case "propose_branch_plan": return "Planning a branch"
        case "publish_finding": return "Publishing a finding"
        case "close_branch": return "Closing out the branch"
        case "review_proof": return "Reviewing proof"
        case "record_test_evidence": return "Recording evidence"
        default:
            return "Using " + name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func closeThinkingIfOpen() {
        guard thinkingOpen else { return }
        thinkingOpen = false
        box.call("chatThinkingDone")
    }

    /// NSURLError descriptions are terse ("A TLS error caused the secure connection to
    /// fail.") and omit the host — add it, plus a hint, so failures are diagnosable
    /// straight from the chat banner.
    static func describeNetworkError(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        let host = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.host
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? "the provider"
        switch ns.code {
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected:
            return "\(ns.localizedDescription) — while connecting to \(host). "
                + "If it recurs: a VPN, ad-blocker or antivirus doing TLS filtering is the usual culprit; "
                + "try another network or pause the filter and retry."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorTimedOut,
             NSURLErrorDNSLookupFailed:
            return "\(ns.localizedDescription) — while connecting to \(host). Check the connection and retry."
        default:
            return "\(ns.localizedDescription) (\(host))"
        }
    }

    // MARK: - Visualizations

    /// Hands a rendered PNG to the web view as a data URL (the web view has no file
    /// access outside its bundle) plus the project-relative path for save/reveal.
    func showVisualization(pngURL: URL, title: String, caption: String?) {
        guard let data = try? Data(contentsOf: pngURL) else { return }
        let relative = projectRelativePath(of: pngURL) ?? pngURL.lastPathComponent
        box.call("chatShowViz",
                 "data:image/png;base64,\(data.base64EncodedString())",
                 title, caption ?? "", relative)
    }

    private func projectRelativePath(of url: URL) -> String? {
        guard let root = appState?.store?.rootURL.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// Requests coming back from the web view: viz toolbar buttons, and clicks on the
    /// theory items Prismo mentioned.
    private func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "openItem":
            guard let ref = body["id"] as? String else { return }
            inspectedItemRef = ref
        case "revertWriteTurn":
            guard let raw = body["turnID"] as? String, let turnID = UUID(uuidString: raw),
                  let appState else { return }
            let writes = appState.writeJournal.writes(inTurn: turnID)
            guard !writes.isEmpty else { return }
            pendingRevert = RevertRequest(
                turnID: turnID,
                summary: WriteJournal.summary(for: writes),
                hint: WriteJournal.revertPhrase(for: writes))
        case "saveViz":
            guard let relative = body["path"] as? String,
                  let root = appState?.store?.rootURL else { return }
            let source = root.appendingPathComponent(relative)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            let title = (body["title"] as? String ?? "visualization")
            panel.nameFieldStringValue = PythonSandboxNameHelper.sanitize(title) + ".png"
            if panel.runModal() == .OK, let destination = panel.url {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        case "revealViz":
            guard let relative = body["path"] as? String,
                  let root = appState?.store?.rootURL else { return }
            let url = root.appendingPathComponent(relative)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    // MARK: - Persistence

    /// Writes the active chat to disk and refreshes its sidebar row. Empty chats aren't
    /// persisted, so a brand-new conversation stays out of the history until its first turn.
    private func saveSession() {
        guard let store = appState?.store, !transcript.isEmpty else { return }
        if activeTitle.isEmpty { activeTitle = Self.deriveTitle(from: transcript) }
        let session = ChatSession(
            id: activeChatID,
            title: activeTitle,
            createdAt: activeCreatedAt,
            updatedAt: Date(),
            transcript: transcript,
            linkedItem: nil,
            attachedItems: attachedItems,
            mode: mode,
            fulltextGranted: fulltextAccess.granted,
            branchPlanID: branchPlanID,
            writeTurns: writeTurns
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? store.saveChat(id: activeChatID, json: data)
        upsertSummary(for: session)
    }

    /// Loads the history list, migrating the legacy single-chat files on first open.
    private func loadChats() {
        guard let store = appState?.store else { chats = []; return }
        var ids = store.chatIDs()
        if ids.isEmpty {
            migrateLegacyChat(store: store)
            ids = store.chatIDs()
        }
        var summaries: [ChatSummary] = []
        for id in ids {
            if let session = loadChatSession(id: id) {
                summaries.append(ChatSummary(from: session))
            }
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
        chats = summaries
    }

    /// Reopens the chat that was active last time, else the newest saved chat, else a
    /// fresh empty one.
    private func restoreActiveChat() {
        let pointer = loadActiveChatID()
        if let id = pointer, let session = loadChatSession(id: id) {
            setActive(from: session)
        } else if let id = pointer {
            // The pointer names a still-empty chat from last session — keep its id.
            startEmptyActive(id: id)
        } else if let newest = chats.first, let session = loadChatSession(id: newest.id) {
            setActive(from: session)
            persistActiveChatID()
        } else {
            startEmptyActive(id: UUID().uuidString)
            persistActiveChatID()
        }
    }

    /// Adopts a saved chat as the active one and renders it into the web view.
    private func setActive(from session: ChatSession) {
        activeChatID = session.id
        activeCreatedAt = session.createdAt
        activeTitle = session.title
        transcript = session.transcript
        // Pinned items may have been deleted since; drop those (mirrors old restore).
        let restored = session.attachedItems ?? session.linkedItem.map { [$0] } ?? []
        attachedItems = restored.filter { appState?.store?.item(id: $0.id) != nil }
        mode = session.mode ?? .propose
        branchPlanID = session.branchPlanID.flatMap { id in
            appState?.store?.plan(id: id) != nil ? id : nil
        }
        pendingAttachments = []
        stats = TurnStats()
        inspectedItemRef = nil  // it belongs to the conversation being left, not this one
        pendingRevert = nil
        fulltextAccess.granted = session.fulltextGranted  // allowAll stays project-wide
        writeTurns = session.writeTurns ?? []
        // The last turn this chat opened may still be the project's current one (nothing
        // has been sent since), in which case a proposal accepted now belongs to its card.
        openTurnID = writeTurns.last.flatMap { UUID(uuidString: $0.turnID) }
        render(transcript: transcript)
    }

    /// Resets in-memory state to a new, unsaved chat. The project-wide `allowAll` choice
    /// is untouched; per-chat grants reset. The composer mode carries over — it's a
    /// composer control, not conversation content.
    private func startEmptyActive(id: String) {
        activeChatID = id
        activeCreatedAt = Date()
        activeTitle = ""
        transcript = []
        attachedItems = []
        branchPlanID = nil
        pendingAttachments = []
        stats = TurnStats()
        inspectedItemRef = nil
        pendingRevert = nil
        fulltextAccess.granted = []
        writeTurns = []
        openTurnID = nil
        box.call("chatReset")
    }

    /// Streams one user message into the web view: attachment pills first, then text.
    private func renderUserMessage(blocks: [ContentBlock]) {
        var attachmentNotes: [[String: String]] = []
        var text = ""
        for block in blocks {
            switch block {
            case .image(let mediaType, let base64):
                attachmentNotes.append([
                    "kind": "image", "name": "",
                    "preview": "data:\(mediaType);base64,\(base64)"
                ])
            case .document(let name, _):
                attachmentNotes.append(["kind": "document", "name": name, "preview": ""])
            case .text(let t):
                text = t
            default:
                break
            }
        }
        if !attachmentNotes.isEmpty {
            box.call("chatUserAttachments", attachmentNotes)
        }
        if !text.isEmpty {
            box.call("chatAppendUser", text)
        }
    }

    /// Replays a transcript into the chat web view (reset + re-append each block).
    private func render(transcript: [LLMMessage]) {
        box.call("chatReset")
        var pendingViz: (title: String, caption: String)?
        for (index, message) in transcript.enumerated() {
            var userBlocks: [ContentBlock] = []
            for block in message.blocks {
                switch (message.role, block) {
                case (.user, .text), (.user, .image), (.user, .document):
                    userBlocks.append(block)
                case (.user, .toolResult(_, let content, let isError)):
                    // A finished visualization leaves its PNG path in the tool result.
                    if let viz = pendingViz, !isError,
                       let path = Self.vizPath(fromToolResult: content) {
                        replayVisualization(path: path, title: viz.title, caption: viz.caption)
                    }
                    pendingViz = nil
                case (.assistant, .text(let text)):
                    box.call("chatAppendAssistant", text)
                case (.assistant, .toolUse(_, let name, let input)):
                    box.call("chatToolNote", "→ \(name) \(AgentLoop.summarize(inputJSON: input))", false)
                    if name == "create_visualization" {
                        let obj = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]
                        pendingViz = (obj?["title"] as? String ?? "Visualization",
                                      obj?["caption"] as? String ?? "")
                    }
                case (.assistant, .thinking(let text, _)):
                    box.call("chatThinkingReplay", text)
                default:
                    break
                }
            }
            if !userBlocks.isEmpty { renderUserMessage(blocks: userBlocks) }
            replayWriteSummaries(afterMessageIndex: index)
        }
    }

    /// Extracts "artifacts/…/viz.png" from a create_visualization tool result
    /// ("png: <path>" first line).
    static func vizPath(fromToolResult content: String) -> String? {
        guard let firstLine = content.split(separator: "\n").first,
              firstLine.hasPrefix("png: ") else { return nil }
        let path = String(firstLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        // Stored project-relative; refuse anything that escapes the project folder.
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return nil }
        return path
    }

    private func replayVisualization(path: String, title: String, caption: String) {
        guard let root = appState?.store?.rootURL else { return }
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return }
        box.call("chatShowViz",
                 "data:image/png;base64,\(data.base64EncodedString())",
                 title, caption, path)
    }

    private func loadChatSession(id: String) -> ChatSession? {
        guard let data = appState?.store?.loadChat(id: id) else { return nil }
        return try? JSONDecoder().decode(ChatSession.self, from: data)
    }

    /// Auto-name a chat from its first user prompt (first line, capped) — "New chat" if none.
    private static func deriveTitle(from transcript: [LLMMessage]) -> String {
        for message in transcript where message.role == .user {
            for block in message.blocks {
                if case .text(let text) = block {
                    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                    let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
                }
            }
        }
        return "New chat"
    }

    private func upsertSummary(for session: ChatSession) {
        let summary = ChatSummary(from: session)
        chats.removeAll { $0.id == session.id }
        chats.append(summary)
        chats.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Migration

    private func migrateLegacyChat(store: ProjectStore) {
        guard let data = store.loadSession(named: Self.legacyTranscript),
              let transcript = try? JSONDecoder().decode([LLMMessage].self, from: data),
              !transcript.isEmpty else { return }
        var linkedItem: LinkedItem?
        if let liData = store.loadSession(named: Self.legacyLinkedItem),
           let saved = try? JSONDecoder().decode(LinkedItem.self, from: liData) {
            linkedItem = saved
        }
        var granted: Set<String> = []
        if let faData = store.loadSession(named: Self.legacyFulltextAccess),
           let saved = try? JSONDecoder().decode(FulltextAccessState.self, from: faData) {
            granted = saved.granted
            if saved.allowAll { persistAllowAll(true) }  // carry over the standing choice
        }
        let now = Date()
        let id = UUID().uuidString
        let session = ChatSession(
            id: id, title: Self.deriveTitle(from: transcript),
            createdAt: now, updatedAt: now,
            transcript: transcript, linkedItem: linkedItem,
            attachedItems: nil, mode: nil, fulltextGranted: granted,
            branchPlanID: nil, writeTurns: nil)
        if let encoded = try? JSONEncoder().encode(session) {
            try? store.saveChat(id: id, json: encoded)
            saveActiveChatID(id, store: store)  // land the user on their existing chat
        }
    }

    // MARK: Small pointers (active chat id, project-wide allow-all)

    private func persistActiveChatID() {
        guard let store = appState?.store else { return }
        saveActiveChatID(activeChatID, store: store)
    }

    private func saveActiveChatID(_ id: String, store: ProjectStore) {
        if let data = try? JSONEncoder().encode(ActiveChatRef(id: id)) {
            try? store.saveSession(named: Self.activeChatSession, json: data)
        }
    }

    private func loadActiveChatID() -> String? {
        guard let store = appState?.store,
              let data = store.loadSession(named: Self.activeChatSession),
              let ref = try? JSONDecoder().decode(ActiveChatRef.self, from: data) else { return nil }
        return ref.id
    }

    private func persistAllowAll(_ allow: Bool) {
        guard let store = appState?.store else { return }
        if let data = try? JSONEncoder().encode(AllowAllFlag(allowAll: allow)) {
            try? store.saveSession(named: Self.allowAllSession, json: data)
        }
    }

    private func restoreAllowAll() {
        guard let store = appState?.store,
              let data = store.loadSession(named: Self.allowAllSession),
              let flag = try? JSONDecoder().decode(AllowAllFlag.self, from: data) else { return }
        fulltextAccess.allowAll = flag.allowAll
    }

    private struct ActiveChatRef: Codable { let id: String }
    private struct AllowAllFlag: Codable { let allowAll: Bool }
}

/// Filename-safe labels for the viz save panel (mirrors the sandbox's artifact naming).
enum PythonSandboxNameHelper {
    static func sanitize(_ label: String) -> String {
        let lowered = label.lowercased()
        var out = ""
        var lastDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "visualization" : String(out.prefix(48))
    }
}
