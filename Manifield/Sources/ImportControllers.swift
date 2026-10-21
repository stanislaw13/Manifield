import SwiftUI
import PDFKit
import ManifieldCore
import ManifieldAgents

// MARK: - Source import (literature → source library)

/// Owns a source import end to end so it runs in the background: the sheet only
/// *shows* this controller's state — closing it (or leaving the Sources tab, or even
/// switching projects; the source library is machine-local) never touches the run.
///
/// Durability: chunk progress is written through to `sessions/import-run.json` in the
/// source folder after every chunk, so a paused (or crashed) import resumes from the
/// record — including after an app restart — and failed chunks can be retried alone.
@MainActor
final class SourceImportController: ObservableObject {

    struct Request: Sendable {
        var fileURL: URL
        var name: String
        var authors: String
        var citation: String
        var license: String
        var convertToItems: Bool
        /// Free-text scope/steering, e.g. "import only the first 3 chapters".
        var instructions: String = ""
        /// For outline-less PDFs: let the model derive real section slugs from
        /// in-text headings instead of the synthetic part-N sections.
        var detectSections: Bool = false
        /// Run the deep-link pass after import (extra model calls) to reestablish
        /// cross-chunk depends_on edges.
        var linkPass: Bool = false
    }

    /// Local, model-free extraction results — computed off the main thread.
    struct Prepared: Sendable {
        let request: Request
        let chunks: [SourceImport.Chunk]
        let fulltext: FullTextDocument?
        let fullTex: String?
        let extractionWarnings: [String]
        /// Which chunking algorithm produced `chunks` — part of the resume fingerprint.
        let chunker: String
        /// The per-chunk character budget this run was split with, so the cost warning
        /// and the log can say what was used.
        let maxChunkSize: Int
        var totalChunkChars: Int { chunks.reduce(0) { $0 + $1.text.count } }
    }

    struct DoneInfo {
        let itemCount: Int
        let fulltextLabel: String?
        let warnings: [String]
        let sourceURL: URL
        let failedChunkCount: Int
        /// The user asked for citable items and the run produced none. Distinct from a
        /// deliberate document-only import, which the summary screen must not conflate
        /// with it — a pass that extracted nothing is a failure worth naming.
        var itemsRequestedButNoneMade = false
    }

    struct PausedInfo {
        let doneChunks: Int
        let totalChunks: Int
        let sourceURL: URL
    }

    enum Phase {
        case idle
        case preparing
        /// Extraction done, import is large — waiting for the user to accept the cost.
        case confirmLarge(chunkCount: Int, totalChars: Int)
        case running
        /// Chunk work stopped on request; the record on disk has the remaining chunks.
        case paused(PausedInfo)
        case done(DoneInfo)
        case failed(String)
    }

    /// A conversion at or above this many chunks (or characters) asks first. Both are the
    /// user's to move (Settings › Limits › Organizer & import), so they're read per import
    /// rather than frozen at launch.
    static var largeChunkThreshold: Int { AppSettings.Limit.importWarnChunks.value }
    static var largeCharsThreshold: Int { AppSettings.Limit.importWarnCharacters.value }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: ImportProgress?
    @Published private(set) var log = ""
    @Published private(set) var sourceName = ""

    private weak var appState: AppState?
    private var runTask: Task<Void, Never>?
    private var prepared: Prepared?
    private var activeStore: ProjectStore?
    private var record: SourceImportRecord?
    private var pauseRequested = false
    private var importedIDs: [String] = []
    private var chunkNotes: [(index: Int, title: String, note: String)] = []
    private var warnings: [String] = []

    /// The folder of the source currently being written, for the discovery scan to skip.
    var activeSourceURL: URL? { activeStore?.rootURL }

    /// Extraction, confirmation, or model calls underway.
    var isActive: Bool {
        switch phase {
        case .preparing, .confirmLarge, .running: return true
        case .idle, .paused, .done, .failed: return false
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// One-line status for indicators outside the sheet, e.g.
    /// "'Analytic Geometry' — 4/12 chunks · ~3 min left".
    var statusLine: String {
        guard let progress else { return "Reading '\(sourceName)'…" }
        var line = "'\(sourceName)' — \(progress.completedChunks)/\(progress.totalChunks) chunks"
        if let eta = progress.etaSeconds { line += " · ~\(ImportProgress.formatETA(eta)) left" }
        return line
    }

    // MARK: Lifecycle

    func begin(_ request: Request, appState: AppState) {
        guard !isActive else { return }
        self.appState = appState
        sourceName = request.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? request.fileURL.deletingPathExtension().lastPathComponent
            : request.name
        resetRunState()
        phase = .preparing

        runTask = Task {
            do {
                let prepared = try await Self.extract(request)
                self.prepared = prepared
                let needsWarning = request.convertToItems
                    && !AppSettings.suppressLargeImportWarning
                    && (prepared.chunks.count >= Self.largeChunkThreshold
                        || prepared.totalChunkChars >= Self.largeCharsThreshold)
                if needsWarning {
                    phase = .confirmLarge(
                        chunkCount: prepared.chunks.count,
                        totalChars: prepared.totalChunkChars)
                } else {
                    await run(prepared)
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func confirmLargeImport(dontShowAgain: Bool) {
        guard case .confirmLarge = phase, let prepared else { return }
        if dontShowAgain { AppSettings.suppressLargeImportWarning = true }
        runTask = Task { await run(prepared) }
    }

    /// Stops launching and aborts in-flight chunks (they re-run on resume; only
    /// terminal chunk states are ever recorded) and parks the run as paused —
    /// resumable any time, even after quitting the app.
    func pause() {
        guard isRunning else { return }
        pauseRequested = true
        runTask?.cancel()
        runTask = nil
    }

    /// Continues a paused/interrupted import from its on-disk record, or retries just
    /// the failed chunks of a finished one (`onlyFailed`). Chunks are re-derived from
    /// the stored original document; the fingerprint guards against drift.
    func resume(sourceURL: URL, appState: AppState, onlyFailed: Bool = false) {
        guard !isActive else { return }
        self.appState = appState
        resetRunState()
        phase = .preparing

        runTask = Task {
            do {
                let store = try ProjectStore(opening: sourceURL)
                guard var rec = SourceImportRecord.load(from: store) else {
                    throw CoreError.io("No import record found for this source.")
                }
                sourceName = rec.request.name
                guard let originalURL = store.originalDocumentURL else {
                    throw CoreError.io("The source's original document is missing — chunks cannot be re-derived.")
                }
                let request = Request(
                    fileURL: originalURL,
                    name: rec.request.name,
                    authors: rec.request.authors,
                    citation: rec.request.citation,
                    license: rec.request.license,
                    convertToItems: true,
                    instructions: rec.request.instructions ?? "",
                    detectSections: rec.request.detectSections ?? false)
                let prepared = try await Self.extract(
                    request, pinnedChunker: rec.fingerprint.chunker)
                guard Self.fingerprint(of: prepared) == rec.fingerprint else {
                    throw CoreError.io("The stored document no longer splits into the same chunks this import was started with — resuming would misalign items. Start a fresh import instead.")
                }
                let targets = (onlyFailed ? rec.failedIndices
                                          : rec.pendingIndices + rec.failedIndices).sorted()
                for i in rec.chunks.indices where targets.contains(rec.chunks[i].index) {
                    rec.chunks[i].status = .pending
                    rec.chunks[i].failureMessage = nil
                }
                rec.phase = .running
                rec.save(to: store)

                self.prepared = prepared
                self.activeStore = store
                self.record = rec
                self.importedIDs = rec.allItemIDs
                self.chunkNotes = rec.chunkNotes
                self.warnings = []
                phase = .running
                appendLog("→ Resuming '\(rec.request.name)' — \(targets.count) chunk(s) to go")

                if !targets.isEmpty {
                    try await runChunks(prepared: prepared, indices: targets, store: store)
                }
                await finish(store: store, fulltextLabel: prepared.fulltext?.info.unitLabel)
            } catch is CancellationError {
                handleCancellation()
            } catch {
                markFailed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        switch phase {
        case .preparing, .confirmLarge:
            phase = .idle
        case .running:
            // The task's CancellationError path handles the record + message, but the
            // task may already be gone (e.g. cancel raced completion) — pauseRequested
            // stays false so handleCancellation treats this as a real cancel.
            break
        case .idle, .paused, .done, .failed:
            break
        }
    }

    /// Drops a paused import's record (partial items stay in the library).
    func discard() {
        guard case .paused(let info) = phase else { return }
        SourceImportRecord.delete(atSourceFolder: info.sourceURL)
        acknowledge()
    }

    /// Clears a terminal state so the sheet returns to the form (and header chips vanish).
    func acknowledge() {
        guard !isActive else { return }
        phase = .idle
        progress = nil
        prepared = nil
        activeStore = nil
        record = nil
        pauseRequested = false
    }

    private func resetRunState() {
        progress = nil
        log = ""
        importedIDs = []
        chunkNotes = []
        warnings = []
        record = nil
        activeStore = nil
        pauseRequested = false
    }

    // MARK: Discovery (unfinished imports in the library)

    struct UnfinishedImport: Identifiable {
        let url: URL
        let record: SourceImportRecord
        var id: String { url.path }
    }

    /// Library sources whose records are resumable or retry-worthy. `running` records
    /// with no live run mean the app died mid-import — shown as resumable.
    static func scanLibrary(_ library: SourceLibrary, skipping activeURL: URL?) -> [UnfinishedImport] {
        library.list().compactMap { entry in
            guard entry.url.standardizedFileURL != activeURL?.standardizedFileURL,
                  let record = SourceImportRecord.load(atSourceFolder: entry.url),
                  record.isResumable || record.hasRetryableFailures else { return nil }
            return UnfinishedImport(url: entry.url, record: record)
        }
    }

    // MARK: Extraction (local, no model)

    /// PDFKit + cleanup can take seconds on a big book — keep it off the main thread.
    /// `pinnedChunker` pins the algorithm *and* the chunk budget on resume: a record
    /// created before the outline-aware splitter existed still re-chunks the way it
    /// started, and one started under a different import model keeps that model's
    /// chunk size instead of re-splitting under today's.
    private nonisolated static func extract(
        _ request: Request, pinnedChunker: String? = nil
    ) async throws -> Prepared {
        let budget = maxChunkSize(pinnedChunker: pinnedChunker, request: request)
        return try await Task.detached(priority: .userInitiated) {
            var chunks: [SourceImport.Chunk] = []
            var fullTex: String? = nil
            var fulltext: FullTextDocument? = nil
            var extractionWarnings: [String] = []
            var chunker = "none"
            let pinnedAlgorithm = pinnedChunker.map { $0.split(separator: "@").first.map(String.init) ?? $0 }

            let extracted = try PDFExtraction.read(url: request.fileURL)
            fulltext = extracted.fulltext
            extractionWarnings = extracted.warnings

            if request.fileURL.pathExtension.lowercased() == "pdf" {
                if extracted.hasText {
                    if request.convertToItems {
                        // Prefer the PDF's own structure: bookmarks become sections and
                        // chunk boundaries never straddle them. Degenerate outlines
                        // fall back to plain page batches.
                        if pinnedAlgorithm != "pdf-pages-v1",
                           let entries = extracted.outline,
                           let outlineChunks = SourceImport.splitPages(extracted.pages, outline: entries) {
                            chunks = outlineChunks
                            chunker = "pdf-outline-v1"
                        } else {
                            chunks = SourceImport.splitPages(extracted.pages.filter {
                                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            })
                            chunker = "pdf-pages-v1"
                        }
                    }
                } else if request.convertToItems {
                    throw CoreError.io("Could not extract text from '\(request.fileURL.lastPathComponent)'. If it is a scanned PDF, OCR it first.")
                }
            } else {
                fullTex = extracted.text
                if request.convertToItems {
                    // Decided from the file itself, before it is chunked or paid for.
                    if let reason = SourceImport.rejectionReason(
                        forLaTeX: extracted.text ?? "",
                        fileName: request.fileURL.lastPathComponent) {
                        throw CoreError.io(reason)
                    }
                    chunks = SourceImport.splitLaTeX(extracted.text ?? "", maxChunkSize: budget)
                    chunker = "latex-v2@\(budget)"
                }
            }
            // Screen before any model call: a file whose text is an encoded payload
            // costs nothing to reject here and a whole rate-limited import to discover.
            if request.convertToItems, !chunks.isEmpty {
                let screened = SourceImport.screen(chunks)
                chunks = screened.chunks
                extractionWarnings += screened.warnings
                if let reason = screened.emptyReason { throw CoreError.io(reason) }
            }
            guard !request.convertToItems || !chunks.isEmpty else {
                throw CoreError.io("No importable content found in '\(request.fileURL.lastPathComponent)'.")
            }
            return Prepared(
                request: request, chunks: chunks, fulltext: fulltext,
                fullTex: fullTex, extractionWarnings: extractionWarnings,
                chunker: chunker, maxChunkSize: budget)
        }.value
    }

    /// The per-chunk character budget: whatever the record pinned, else what the import
    /// model can take (see `ImportBudget`).
    private nonisolated static func maxChunkSize(pinnedChunker: String?, request: Request) -> Int {
        if let pinned = pinnedChunker?.split(separator: "@").last, let size = Int(pinned) {
            return size
        }
        return currentBudget(instructions: request.instructions).maxChunkCharacters
    }

    /// The import model's budget, with the organizer prompts that ride along measured
    /// rather than guessed — a chunk has to leave room for them.
    nonisolated static func currentBudget(instructions: String = "") -> ImportBudget {
        let choice = AppSettings.effectiveChoice(for: .importer)
        return ImportBudget.forModel(
            choice.model, kind: choice.kind,
            // The reply ceiling is what actually sizes a chunk — the Organizer restates most
            // of what it reads — so the user's setting has to reach the budget, not just the
            // request. Raising it makes chunks bigger, which is the point.
            maxOutputTokens: AppSettings.Limit.importResponseTokens.value,
            promptOverheadCharacters: Organizer.sourceSystemPromptOverheadCharacters(
                instructions: instructions.isEmpty ? nil : instructions))
    }

    private nonisolated static func fingerprint(of prepared: Prepared) -> SourceImportRecord.Fingerprint {
        SourceImportRecord.Fingerprint(
            chunker: prepared.chunker,
            chunkCount: prepared.chunks.count,
            chunkTextSHA256: SourceImportRecord.Fingerprint.hash(of: prepared.chunks))
    }

    // MARK: Run (store writes + parallel Organizer)

    /// Fills name/authors/citation the user left on "Auto" from the document's opening
    /// and closing text — one small model call, never the whole file. Extraction
    /// failures degrade to the file name; only cancellation propagates.
    private func resolveMetadata(_ prepared: Prepared) async throws -> Prepared {
        var request = prepared.request
        let needsName = request.name.trimmingCharacters(in: .whitespaces).isEmpty
        let needsAuthors = request.authors.trimmingCharacters(in: .whitespaces).isEmpty
        let needsCitation = request.citation.trimmingCharacters(in: .whitespaces).isEmpty
        let fallbackName = request.fileURL.deletingPathExtension().lastPathComponent
        guard needsName || needsAuthors || needsCitation else { return prepared }

        appendLog("→ Reading metadata from the document …")
        do {
            guard let appState else { throw CoreError.io("The app state went away.") }
            let runner = makeRunner(config: try appState.providerConfig(for: .importer))
            let sample = Self.metadataSample(of: prepared)
            let extracted = try await SourceMetadata.extract(
                runner: runner,
                head: sample.head,
                tail: sample.tail,
                fileName: request.fileURL.lastPathComponent,
                instructions: request.instructions)
            if needsName { request.name = extracted.name ?? fallbackName }
            if needsAuthors { request.authors = extracted.authors.joined(separator: ", ") }
            if needsCitation { request.citation = extracted.citation ?? "" }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if needsName { request.name = fallbackName }
            warnings.append("Metadata: extraction failed — \(error.localizedDescription). Using the file name.")
        }
        sourceName = request.name
        return Prepared(
            request: request, chunks: prepared.chunks, fulltext: prepared.fulltext,
            fullTex: prepared.fullTex, extractionWarnings: prepared.extractionWarnings,
            chunker: prepared.chunker, maxChunkSize: prepared.maxChunkSize)
    }

    /// Opening ~2 chunks + closing text — enough for title/authors/citation.
    private nonisolated static func metadataSample(of prepared: Prepared) -> (head: String, tail: String) {
        if !prepared.chunks.isEmpty {
            let head = prepared.chunks.prefix(2).map(\.text).joined(separator: "\n\n")
            let tail = prepared.chunks.last.map { String($0.text.suffix(2_000)) } ?? ""
            return (String(head.prefix(16_000)), tail)
        }
        if let fulltext = prepared.fulltext {
            let texts = fulltext.segments.map(\.text)
            let head = texts.prefix(4).joined(separator: "\n\n")
            let tail = String(texts.suffix(2).joined(separator: "\n\n").suffix(2_000))
            return (String(head.prefix(16_000)), tail)
        }
        return ("", "")
    }

    private func run(_ prepared: Prepared) async {
        guard let appState else {
            phase = .failed("The app state went away — reopen the importer and try again.")
            return
        }
        phase = .running
        warnings = prepared.extractionWarnings
        do {
            let prepared = try await resolveMetadata(prepared)
            self.prepared = prepared
            let request = prepared.request
            // Store the document and full text before any model call — cancelling a
            // long Organizer pass never loses them.
            let store = try appState.sourceLibrary.createSource(
                name: request.name.trimmingCharacters(in: .whitespaces),
                authors: request.authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                citation: request.citation.isEmpty ? nil : request.citation,
                license: request.license.isEmpty ? nil : request.license
            )
            activeStore = store
            if let fullTex = prepared.fullTex { store.importMacros(from: fullTex) }
            let originalURL = try store.storeOriginalDocument(from: request.fileURL)
            if let fulltext = prepared.fulltext { try store.saveFulltext(fulltext) }
            let fulltextLabel = prepared.fulltext?.info.unitLabel

            if !prepared.chunks.isEmpty {
                let rec = SourceImportRecord(
                    request: .init(
                        name: request.name,
                        authors: request.authors,
                        citation: request.citation,
                        license: request.license,
                        originalFileName: originalURL.lastPathComponent,
                        convertToItems: request.convertToItems,
                        instructions: request.instructions.isEmpty ? nil : request.instructions,
                        detectSections: request.detectSections ? true : nil,
                        linkPassRequested: request.linkPass ? true : nil),
                    fingerprint: Self.fingerprint(of: prepared),
                    chunks: prepared.chunks,
                    warnings: prepared.extractionWarnings)
                rec.save(to: store)
                record = rec
                try await runChunks(prepared: prepared, indices: nil, store: store)
            }
            await finish(store: store, fulltextLabel: fulltextLabel)
        } catch is CancellationError {
            handleCancellation()
        } catch {
            markFailed(error.localizedDescription)
        }
    }

    private func runChunks(prepared: Prepared, indices: [Int]?, store: ProjectStore) async throws {
        guard let appState else { throw CoreError.io("The app state went away.") }
        progress = ImportProgress(
            totalChunks: indices?.count ?? prepared.chunks.count,
            concurrency: AppSettings.importConcurrency)
        let agentRunner = makeRunner(config: try appState.providerConfig(for: .importer))
        let citation = prepared.request.citation.isEmpty ? nil : prepared.request.citation
        let largest = prepared.chunks.map(\.text.count).max() ?? 0
        appendLog("→ \(prepared.chunks.count) chunk(s), budget ~\(prepared.maxChunkSize / 1_000)k characters each (largest \(largest / 1_000)k)")

        // Events flow through a drained stream, not fire-and-forget hops:
        // every event (in particular the last chunk's items) is processed
        // before the run is declared finished.
        let (events, continuation) = AsyncStream<SourceImportEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await event in events { self?.handle(event) }
        }
        let runner = SourceImportRunner(
            chunks: prepared.chunks,
            indices: indices,
            citation: citation,
            instructions: prepared.request.instructions.isEmpty ? nil : prepared.request.instructions,
            // Text-derived sections only make sense when the chunker's own sections
            // are synthetic part-N batches.
            detectSections: prepared.request.detectSections && prepared.chunker == "pdf-pages-v1",
            concurrency: AppSettings.importConcurrency,
            maxTokens: AppSettings.Limit.importResponseTokens.value,
            runner: agentRunner,
            currentIDs: { @MainActor [weak self] in self?.importedIDs ?? [] },
            currentSections: { @MainActor [weak self] in
                Array(Set((self?.activeStore?.items ?? []).compactMap(\.section))).sorted()
            },
            onEvent: { continuation.yield($0) }
        )
        do {
            try await runner.run()
            continuation.finish()
            await consumer.value
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    /// Overview + optional link pass + terminal record state, shared by first runs
    /// and resumes.
    private func finish(store: ProjectStore, fulltextLabel: String?) async {
        if let appState, var rec = record, !rec.allItemIDs.isEmpty, !rec.overviewDone {
            appendLog("→ Writing source overview …")
            do {
                try await SourceOverviewGeneration.run(
                    appState: appState, store: store,
                    chunkNotes: rec.chunkNotes.map { (title: $0.title, note: $0.note) })
                rec.overviewDone = true
            } catch is CancellationError {
                handleCancellation()
                return
            } catch {
                warnings.append("Overview: generation failed — \(error.localizedDescription). You can retry from the source browser.")
            }
            record = rec
        }
        if let appState, var rec = record, rec.request.linkPassRequested == true,
           rec.linkPassDone != true, !rec.allItemIDs.isEmpty {
            appendLog("→ Deep link pass …")
            do {
                let result = try await LinkPassGeneration.run(
                    appState: appState, store: store,
                    onProgress: { [weak self] line in self?.appendLog(line) })
                appendLog("✓ Link pass — \(result.added) new connection(s)")
                warnings.append(contentsOf: result.warnings)
                rec.linkPassDone = true
            } catch is CancellationError {
                handleCancellation()
                return
            } catch {
                warnings.append("Link pass failed — \(error.localizedDescription). Run it later from the source page.")
            }
            record = rec
        }
        record?.phase = .finished
        record?.warnings = warnings
        if let record { record.save(to: store) }
        let failedCount = record?.failedIndices.count ?? 0
        let itemCount = record?.allItemIDs.count ?? importedIDs.count
        let wantedItems = prepared?.request.convertToItems ?? false
        var doneWarnings = warnings
        if failedCount > 0 {
            doneWarnings.append("\(failedCount) chunk(s) failed — you can retry just those.")
        }
        if wantedItems, itemCount == 0 {
            let chunkCount = record?.chunks.count ?? 0
            doneWarnings.append(
                failedCount == chunkCount && chunkCount > 0
                ? "No items were created: every chunk failed. The document and its full text are stored, so retrying costs only the failed chunks."
                : "No items were created. The Organizer returned nothing usable for \(chunkCount - failedCount) of \(chunkCount) chunk(s) — check the log above, and the import instructions if you set any.")
        }
        phase = .done(DoneInfo(
            itemCount: itemCount,
            fulltextLabel: fulltextLabel,
            warnings: doneWarnings,
            sourceURL: store.rootURL,
            failedChunkCount: failedCount,
            itemsRequestedButNoneMade: wantedItems && itemCount == 0))
    }

    private func handleCancellation() {
        if pauseRequested, let store = activeStore, var rec = record {
            pauseRequested = false
            rec.phase = .paused
            rec.save(to: store)
            record = rec
            appendLog("⏸ Paused — \(rec.doneCount)/\(rec.chunks.count) chunks done")
            phase = .paused(PausedInfo(
                doneChunks: rec.doneCount,
                totalChunks: rec.chunks.count,
                sourceURL: store.rootURL))
        } else if case .running = phase {
            record?.phase = .failed
            if let record, let store = activeStore { record.save(to: store) }
            phase = .failed("Import cancelled. Partially imported items remain in the library — the stored document and full text are already saved; browse and delete the source folder if unwanted.")
        } else if case .preparing = phase {
            phase = .idle
        }
    }

    private func markFailed(_ message: String) {
        record?.phase = .failed
        if let record, let store = activeStore { record.save(to: store) }
        phase = .failed(message)
    }

    private func handle(_ event: SourceImportEvent) {
        // No isRunning guard: after a cancel/pause the consumer still drains events
        // from chunks that had already finished — saving them matches the pause
        // semantics (finished work is never redone).
        guard let store = activeStore else { return }
        switch event {
        case .chunkStarted(let index, let title):
            progress?.chunkStarted(index: index)
            appendLog("→ \(title)")
        case .chunkProgress(let index, let streamedChars):
            progress?.chunkProgress(index: index, streamedChars: streamedChars)
        case .chunkFinished(let index, let title, let items, let note, let chunkWarnings, let duration, let responseChars):
            var saved: [TheoryItem] = []
            for var item in items {
                if store.item(id: item.id) != nil {
                    item.id = store.availableID(for: item.type, name: item.name)
                }
                do {
                    try store.save(item)
                    importedIDs.append(item.id)
                    saved.append(item)
                } catch {
                    warnings.append("\(title): could not save '\(item.id)' — \(error.localizedDescription)")
                }
            }
            progress?.chunkFinished(index: index, items: saved, duration: duration,
                                    responseChars: responseChars)
            if let note { chunkNotes.append((index: index, title: title, note: note)) }
            warnings.append(contentsOf: chunkWarnings.map { "\(title): \($0)" })
            appendLog("✓ \(title) — \(saved.count) item(s)")
            // Record write-through AFTER the item saves: a crash in between re-runs
            // this one chunk on resume (availableID renames the few duplicates).
            if var rec = record, let i = rec.chunks.firstIndex(where: { $0.index == index }) {
                rec.chunks[i].status = .done
                rec.chunks[i].itemIDs = saved.map(\.id)
                rec.chunks[i].note = note
                rec.chunks[i].warnings = chunkWarnings
                rec.save(to: store)
                record = rec
            }
        case .chunkFailed(let index, let title, let message, let duration):
            progress?.chunkFailed(index: index, duration: duration)
            warnings.append("\(title): chunk failed — \(message)")
            appendLog("✕ \(title) — \(message)")
            if var rec = record, let i = rec.chunks.firstIndex(where: { $0.index == index }) {
                rec.chunks[i].status = .failed
                rec.chunks[i].failureMessage = message
                rec.save(to: store)
                record = rec
            }
        case .chunkRetrying(_, let title, let attempt, let delay, let reason):
            appendLog(delay > 0
                      ? "↻ \(title) — \(reason), retrying in \(Int(delay))s (attempt \(attempt + 1))"
                      : "↻ \(title) — \(reason)")
        }
    }

    private func appendLog(_ line: String) {
        log = String((log + line + "\n").suffix(24_000))
    }
}

// MARK: - Theory import (file/paste → current project, chunked, optional review)

/// Owns the project-import run and its review list, so navigating away from the
/// Import tab (or waiting on a slow model) never loses either.
///
/// Same chunked pipeline as the source import (parallel chunks, pause/resume via a
/// record in the project's sessions folder, per-chunk retry) with one difference:
/// when "review before saving" is on, chunk results accumulate into the review list
/// (persisted in the record as proposed items) instead of hitting the store.
@MainActor
final class TheoryImportController: ObservableObject {

    enum Source: Sendable {
        case latex(String)
        case pages([String])
    }

    /// The file an import came from, to be kept in the project so the user and the agents
    /// can go back to the real thing afterwards. `fulltext` is the extraction the importer
    /// already did — storing it here costs nothing and makes the file searchable.
    struct KeptFile: Sendable {
        var url: URL
        var fulltext: FullTextDocument?
        var pageCount: Int?
    }

    struct ReviewedItem: Identifiable, Equatable {
        let id = UUID()
        var include = true
        var item: TheoryItem
    }

    struct PausedInfo {
        let doneChunks: Int
        let totalChunks: Int
    }

    struct DoneInfo {
        let savedCount: Int
        let warnings: [String]
        let failedChunkCount: Int
    }

    /// Slug of the file this run kept in the project, if any — the review and done
    /// screens link to it.
    private(set) var keptDocumentSlug: String?

    enum Phase {
        case idle
        case confirmLarge(chunkCount: Int, totalChars: Int)
        case running
        case paused(PausedInfo)
        case review([ReviewedItem], warnings: [String])
        /// Direct-save mode's terminal screen.
        case done(DoneInfo)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: ImportProgress?
    @Published private(set) var log = ""
    private(set) var sourceName = ""

    private weak var appState: AppState?
    private var runTask: Task<Void, Never>?
    private var chunks: [SourceImport.Chunk] = []
    private var chunker = "none"
    private var record: SourceImportRecord?
    private var reviewBeforeSaving = true
    private var instructions = ""
    private var pauseRequested = false
    /// New ids this run produced (proposals or saves) — feeds the taken-ids prompt.
    private var newIDs: [String] = []
    private var warnings: [String] = []

    /// The raw source text, stashed with the record: unlike a library source there is
    /// no stored original document to re-derive chunks from on resume.
    private struct SourceStash: Codable {
        var kind: String  // "latex" | "pages"
        var latex: String?
        var pages: [String]?
        var name: String
    }
    private static let stashName = "theory-import-source"

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isActive: Bool {
        switch phase {
        case .confirmLarge, .running: return true
        case .idle, .paused, .review, .done, .failed: return false
        }
    }

    // MARK: Lifecycle

    func start(source: Source, sourceName: String, instructions: String,
               reviewBeforeSaving: Bool, keepFile: KeptFile? = nil, appState: AppState) {
        guard !isActive, let store = appState.store else { return }
        self.appState = appState
        self.sourceName = sourceName
        self.instructions = instructions
        self.reviewBeforeSaving = reviewBeforeSaving
        resetRunState()
        keptDocumentSlug = nil

        // Keep the file before any model call: a cancelled or failed run still leaves the
        // user with the document they imported, readable in the Files section.
        if let keepFile {
            do {
                let document = try store.addDocument(
                    from: keepFile.url,
                    fulltext: keepFile.fulltext,
                    pageCount: keepFile.pageCount,
                    note: "imported into the library")
                keptDocumentSlug = document.slug
                appState.documentsVersion += 1
            } catch {
                warnings.append("Could not keep '\(keepFile.url.lastPathComponent)' in the project — \(error.localizedDescription)")
            }
        }

        // Harvest \newcommand/\def/… from the source so imported math renders correctly.
        if case .latex(let tex) = source {
            let added = store.importMacros(from: tex)
            if !added.isEmpty {
                warnings.append("Imported \(added.count) macro definition(s) into macros.tex: \(added.joined(separator: ", "))")
            }
        }

        let budget = SourceImportController.currentBudget(instructions: instructions).maxChunkCharacters
        switch source {
        case .latex(let tex):
            if let reason = SourceImport.rejectionReason(forLaTeX: tex, fileName: sourceName) {
                phase = .failed(reason)
                return
            }
            chunks = SourceImport.splitLaTeX(tex, maxChunkSize: budget)
            chunker = "latex-v2@\(budget)"
        case .pages(let pages):
            chunks = SourceImport.splitPages(pages.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            chunker = "pdf-pages-v1"
        }
        let screened = SourceImport.screen(chunks)
        chunks = screened.chunks
        warnings += screened.warnings
        if let reason = screened.emptyReason {
            phase = .failed(reason)
            return
        }
        guard !chunks.isEmpty else {
            phase = .failed("No importable content found in \(sourceName).")
            return
        }
        stashSource(source, to: store)

        let totalChars = chunks.reduce(0) { $0 + $1.text.count }
        if !AppSettings.suppressLargeImportWarning,
           chunks.count >= SourceImportController.largeChunkThreshold
            || totalChars >= SourceImportController.largeCharsThreshold {
            phase = .confirmLarge(chunkCount: chunks.count, totalChars: totalChars)
        } else {
            beginRun()
        }
    }

    func confirmLargeImport(dontShowAgain: Bool) {
        guard case .confirmLarge = phase else { return }
        if dontShowAgain { AppSettings.suppressLargeImportWarning = true }
        beginRun()
    }

    private func beginRun() {
        guard let store = appState?.store else { return }
        let rec = SourceImportRecord(
            request: .init(
                name: sourceName, authors: "", citation: "", license: "",
                originalFileName: "", convertToItems: true,
                instructions: instructions.isEmpty ? nil : instructions,
                reviewBeforeSaving: reviewBeforeSaving),
            fingerprint: .init(
                chunker: chunker, chunkCount: chunks.count,
                chunkTextSHA256: SourceImportRecord.Fingerprint.hash(of: chunks)),
            chunks: chunks)
        rec.save(to: store, named: SourceImportRecord.theorySessionName)
        record = rec
        phase = .running
        runTask = Task { await runChunks(indices: nil) }
    }

    func pause() {
        guard isRunning else { return }
        pauseRequested = true
        runTask?.cancel()
        runTask = nil
    }

    /// Continues from the project's record + source stash (also used for retrying
    /// failed chunks, and for reopening a review that survived an app restart).
    func resume(appState: AppState, onlyFailed: Bool = false) {
        guard !isActive, let store = appState.store,
              var rec = SourceImportRecord.load(from: store, named: SourceImportRecord.theorySessionName),
              let stashData = store.loadSession(named: Self.stashName),
              let stash = try? JSONDecoder().decode(SourceStash.self, from: stashData) else { return }
        self.appState = appState
        resetRunState()
        sourceName = stash.name
        instructions = rec.request.instructions ?? ""
        reviewBeforeSaving = rec.request.reviewBeforeSaving ?? true

        // The record pins the budget it was split with, so a model change between
        // sessions cannot silently re-chunk a half-finished import.
        if stash.kind == "latex" {
            let budget = rec.fingerprint.chunker.split(separator: "@").last.flatMap { Int($0) }
                ?? SourceImport.defaultMaxChunkSize
            chunks = SourceImport.splitLaTeX(stash.latex ?? "", maxChunkSize: budget)
            chunker = "latex-v2@\(budget)"
        } else {
            chunks = SourceImport.splitPages((stash.pages ?? []).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            chunker = "pdf-pages-v1"
        }
        let fingerprint = SourceImportRecord.Fingerprint(
            chunker: chunker, chunkCount: chunks.count,
            chunkTextSHA256: SourceImportRecord.Fingerprint.hash(of: chunks))
        guard fingerprint == rec.fingerprint else {
            phase = .failed("The stashed source no longer splits into the same chunks — resuming would misalign items. Start a fresh import.")
            return
        }

        newIDs = rec.allItemIDs
        let targets = (onlyFailed ? rec.failedIndices
                                  : rec.pendingIndices + rec.failedIndices).sorted()
        for i in rec.chunks.indices where targets.contains(rec.chunks[i].index) {
            rec.chunks[i].status = .pending
            rec.chunks[i].failureMessage = nil
            rec.chunks[i].proposedItems = nil
        }
        rec.phase = .running
        rec.save(to: store, named: SourceImportRecord.theorySessionName)
        record = rec
        phase = .running
        appendLog("→ Resuming '\(sourceName)' — \(targets.count) chunk(s) to go")
        runTask = Task {
            if targets.isEmpty {
                finishRun()
            } else {
                await runChunks(indices: targets)
            }
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if case .confirmLarge = phase {
            cleanupPersisted()
            phase = .idle
        }
        // .running resolves through the task's CancellationError path.
    }

    /// After the review's items were written (or the user abandoned it).
    func completeReview() {
        cleanupPersisted()
        reset()
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        phase = .idle
        resetRunState()
        keptDocumentSlug = nil
    }

    /// File-loading problems surface through the same failed screen as run errors.
    func fail(_ message: String) {
        guard !isRunning else { return }
        phase = .failed(message)
    }

    /// Review edits (names, sections, include flags) survive tab switches by being
    /// pushed back into the phase as the user makes them.
    func updateReview(_ items: [ReviewedItem]) {
        guard case .review(_, let warnings) = phase else { return }
        phase = .review(items, warnings: warnings)
    }

    /// The project's persisted import state, for the Import tab's resume banner.
    static func pendingRecord(in store: ProjectStore) -> SourceImportRecord? {
        SourceImportRecord.load(from: store, named: SourceImportRecord.theorySessionName)
    }

    /// Failed chunks visible from the review/done screens (retryable).
    var failedChunkCount: Int { record?.failedIndices.count ?? 0 }

    func retryFailed() {
        guard let appState else { return }
        resume(appState: appState, onlyFailed: true)
    }

    private func resetRunState() {
        progress = nil
        log = ""
        newIDs = []
        warnings = []
        record = nil
        pauseRequested = false
    }

    private func stashSource(_ source: Source, to store: ProjectStore) {
        let stash: SourceStash
        switch source {
        case .latex(let tex):
            stash = SourceStash(kind: "latex", latex: tex, pages: nil, name: sourceName)
        case .pages(let pages):
            stash = SourceStash(kind: "pages", latex: nil, pages: pages, name: sourceName)
        }
        if let data = try? JSONEncoder().encode(stash) {
            try? store.saveSession(named: Self.stashName, json: data)
        }
    }

    private func cleanupPersisted() {
        guard let store = appState?.store else { return }
        SourceImportRecord.delete(atSourceFolder: store.rootURL,
                                  named: SourceImportRecord.theorySessionName)
        try? FileManager.default.removeItem(
            at: store.sessionsURL.appendingPathComponent("\(Self.stashName).json"))
    }

    // MARK: Run

    private func runChunks(indices: [Int]?) async {
        guard let appState, let store = appState.store else {
            phase = .failed("No project open.")
            return
        }
        do {
            progress = ImportProgress(
                totalChunks: indices?.count ?? chunks.count,
                concurrency: AppSettings.importConcurrency)
            let agentRunner = makeRunner(config: try appState.providerConfig(for: .importer))
            let builder = Organizer.projectSystemPromptBuilder(
                existingItems: store.items,
                notation: store.notation,
                instructions: instructions.isEmpty ? nil : instructions)
            let existingIDs = store.items.map(\.id)

            let (events, continuation) = AsyncStream<SourceImportEvent>.makeStream()
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.handle(event) }
            }
            let runner = SourceImportRunner(
                chunks: chunks,
                indices: indices,
                citation: nil,
                itemPolicy: .project,
                makeSystemPrompt: builder,
                concurrency: AppSettings.importConcurrency,
                maxTokens: AppSettings.Limit.importResponseTokens.value,
                runner: agentRunner,
                currentIDs: { @MainActor [weak self] in existingIDs + (self?.newIDs ?? []) },
                onEvent: { continuation.yield($0) }
            )
            do {
                try await runner.run()
                continuation.finish()
                await consumer.value
            } catch {
                continuation.finish()
                await consumer.value
                throw error
            }
            finishRun()
        } catch is CancellationError {
            handleCancellation()
        } catch {
            markFailed(error.localizedDescription)
        }
    }

    private func handle(_ event: SourceImportEvent) {
        guard let appState, let store = appState.store else { return }
        switch event {
        case .chunkStarted(let index, let title):
            progress?.chunkStarted(index: index)
            appendLog("→ \(title)")
        case .chunkProgress(let index, let streamedChars):
            progress?.chunkProgress(index: index, streamedChars: streamedChars)
        case .chunkFinished(let index, let title, let items, _, let chunkWarnings, let duration, let responseChars):
            var kept: [TheoryItem] = []
            for var item in items {
                if reviewBeforeSaving {
                    if store.item(id: item.id) != nil || newIDs.contains(item.id) {
                        item.id = uniqueProposalID(for: item, store: store)
                    }
                    newIDs.append(item.id)
                    kept.append(item)
                } else {
                    if store.item(id: item.id) != nil {
                        item.id = store.availableID(for: item.type, name: item.name)
                    }
                    do {
                        try store.save(item)
                        newIDs.append(item.id)
                        kept.append(item)
                    } catch {
                        warnings.append("\(title): could not save '\(item.id)' — \(error.localizedDescription)")
                    }
                }
            }
            if !reviewBeforeSaving, !kept.isEmpty { appState.itemsVersion += 1 }
            progress?.chunkFinished(index: index, items: kept, duration: duration,
                                    responseChars: responseChars)
            warnings.append(contentsOf: chunkWarnings.map { "\(title): \($0)" })
            appendLog("✓ \(title) — \(kept.count) item(s)")
            if var rec = record, let i = rec.chunks.firstIndex(where: { $0.index == index }) {
                rec.chunks[i].status = .done
                rec.chunks[i].itemIDs = kept.map(\.id)
                rec.chunks[i].warnings = chunkWarnings
                rec.chunks[i].proposedItems = reviewBeforeSaving ? kept : nil
                rec.save(to: store, named: SourceImportRecord.theorySessionName)
                record = rec
            }
        case .chunkFailed(let index, let title, let message, let duration):
            progress?.chunkFailed(index: index, duration: duration)
            warnings.append("\(title): chunk failed — \(message)")
            appendLog("✕ \(title) — \(message)")
            if var rec = record, let i = rec.chunks.firstIndex(where: { $0.index == index }) {
                rec.chunks[i].status = .failed
                rec.chunks[i].failureMessage = message
                rec.save(to: store, named: SourceImportRecord.theorySessionName)
                record = rec
            }
        case .chunkRetrying(_, let title, let attempt, let delay, let reason):
            appendLog(delay > 0
                      ? "↻ \(title) — \(reason), retrying in \(Int(delay))s (attempt \(attempt + 1))"
                      : "↻ \(title) — \(reason)")
        }
    }

    /// Review mode saves nothing yet, so `store.availableID` can't dedupe — proposals
    /// dedupe against the project and each other textually.
    private func uniqueProposalID(for item: TheoryItem, store: ProjectStore) -> String {
        let base = "\(item.type.idPrefix)-\(TheoryItem.sanitizeID(item.name))"
        var candidate = base
        var counter = 2
        while store.item(id: candidate) != nil || newIDs.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func finishRun() {
        guard let store = appState?.store else { return }
        let failedCount = record?.failedIndices.count ?? 0
        var notes = warnings
        if failedCount > 0 {
            notes.append("\(failedCount) chunk(s) failed — you can retry just those.")
        }
        if reviewBeforeSaving {
            let reviewed = (record?.chunks ?? [])
                .sorted { $0.index < $1.index }
                .flatMap { $0.proposedItems ?? [] }
                .map { ReviewedItem(item: $0) }
            guard !reviewed.isEmpty else {
                markFailed("The Organizer found no theory items in \(sourceName). \(notes.joined(separator: " "))")
                return
            }
            // The record stays resumable on disk: quitting during review reopens it.
            record?.phase = .paused
            if let record { record.save(to: store, named: SourceImportRecord.theorySessionName) }
            phase = .review(reviewed, warnings: notes)
        } else {
            record?.phase = .finished
            if let record { record.save(to: store, named: SourceImportRecord.theorySessionName) }
            phase = .done(DoneInfo(
                savedCount: record?.allItemIDs.count ?? newIDs.count,
                warnings: notes,
                failedChunkCount: failedCount))
            if failedCount == 0 { cleanupPersisted() }
        }
    }

    private func handleCancellation() {
        guard let store = appState?.store else { return }
        if pauseRequested, var rec = record {
            pauseRequested = false
            rec.phase = .paused
            rec.save(to: store, named: SourceImportRecord.theorySessionName)
            record = rec
            appendLog("⏸ Paused — \(rec.doneCount)/\(rec.chunks.count) chunks done")
            phase = .paused(PausedInfo(doneChunks: rec.doneCount, totalChunks: rec.chunks.count))
        } else if case .running = phase {
            cleanupPersisted()
            phase = reviewBeforeSaving
                ? .idle  // nothing was saved; a plain cancel
                : .failed("Import cancelled. Items from finished chunks were already saved to the project.")
        }
    }

    private func markFailed(_ message: String) {
        if let store = appState?.store, var rec = record {
            rec.phase = .failed
            rec.save(to: store, named: SourceImportRecord.theorySessionName)
            record = rec
        }
        phase = .failed(message)
    }

    private func appendLog(_ line: String) {
        log = String((log + line + "\n").suffix(24_000))
    }
}
