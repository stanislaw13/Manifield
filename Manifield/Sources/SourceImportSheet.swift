import SwiftUI
import UniformTypeIdentifiers
import ManifieldCore
import ManifieldAgents

/// Chunked import of a book/article into the source library. The sheet is a window
/// onto SourceImportController — the import itself runs in the background, so closing
/// the sheet ("Continue in Background") or leaving the Sources tab never interrupts
/// it. The original file and its converted full text (fulltext.md) are always stored;
/// optionally the work is also processed into citable items, chunk by chunk, with
/// bounded parallelism. Bulk import is trusted-by-design — review afterwards by
/// browsing.
struct SourceImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var importer: SourceImportController
    @Environment(\.dismiss) private var dismiss

    @State private var fileURL: URL?
    @State private var name = ""
    @State private var authors = ""
    @State private var citation = ""
    @State private var license = ""
    @State private var instructions = ""
    @State private var detectSections = false
    @State private var linkPass = false
    /// Off = store only the document + its full text, no model calls at all.
    @State private var convertToItems = true
    @State private var concurrency = AppSettings.importConcurrency
    @State private var dontWarnAgain = false
    /// Expanded by default when the run produced nothing — that is when the log is the
    /// only way to see what happened.
    @State private var showDoneLog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Literature Source").font(.title3.weight(.semibold))
                Spacer()
                Button(importer.isActive ? "Continue in Background" : "Close") { dismiss() }
                    .help(importer.isActive
                          ? "The import keeps running; reopen it any time from the Sources header."
                          : "")
            }
            .padding()
            Divider()
            content.padding()
        }
        .frame(width: 640, height: 500)
    }

    @ViewBuilder
    private var content: some View {
        switch importer.phase {
        case .idle:
            form
        case .preparing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading \(importer.sourceName)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .confirmLarge(let chunkCount, let totalChars):
            costWarning(chunkCount: chunkCount, totalChars: totalChars)
        case .running:
            runningView
        case .paused(let info):
            pausedView(info)
        case .done(let info):
            doneView(info)
                .onAppear { showDoneLog = info.itemsRequestedButNoneMade }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32)).foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Back") { importer.acknowledge() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            LabeledContent("File") {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "none chosen")
                        .foregroundStyle(fileURL == nil ? .secondary : .primary)
                    Button("Choose…") { pickFile() }
                }
            }
            TextField("Name", text: $name, prompt: Text("Auto (from document)"))
            TextField("Authors (comma-separated)", text: $authors, prompt: Text("Auto (from document)"))
            TextField("Citation", text: $citation, prompt: Text("Auto (from document)"))
            TextField("License / legal note", text: $license, prompt: Text("personal research use"))
            TextField("Import instructions (optional)", text: $instructions,
                      prompt: Text("e.g. “Import only the first 3 chapters” or “only linear-algebra theorems”"),
                      axis: .vertical)
                .lineLimit(2...4)
                .help("Free-text steering for the import agent — it skips content outside the requested scope.")
            Toggle("Process into citable items", isOn: $convertToItems)
                .help("The Organizer extracts definitions/theorems as library items agents can search and cite. Untick to store just the document — no model calls.")
            if convertToItems {
                Toggle("Detect chapters from text", isOn: $detectSections)
                    .help("For PDFs without a bookmark outline: the import agent derives chapter/section names from headings in the text instead of generic “Part N” groups. PDFs with an outline (and LaTeX files) get real chapters automatically.")
                Toggle("Deep link pass (extra model calls)", isOn: $linkPass)
                    .help("After import, a second pass reads the finished item library and adds cross-chapter depends_on connections that per-chunk processing misses. Costs roughly one extra call per 25 items, each carrying the whole item catalog. Can also be run later from the source page.")
            }
            if convertToItems {
                LabeledContent("Import model") {
                    ModelTaskPicker(task: .importer, compact: true)
                }
                // The full range Settings › Limits allows, not a shortlist: a value chosen
                // there that this picker had no tag for would render as no selection at all.
                Picker("Parallel requests", selection: $concurrency) {
                    ForEach(Array(AppSettings.Limit.importConcurrency.range), id: \.self) { n in
                        Text(n == 1 ? "1 (sequential)" : "\(n)").tag(n)
                    }
                }
                .help("Chunks are independent model calls, so they can run in parallel — same prompts and model, just faster. Lower this if your provider rate-limits. Also in Settings › Limits.")
                .onChange(of: concurrency) { _, value in
                    AppSettings.importConcurrency = value
                }
            }
            Text(convertToItems
                 ? "The original file and its extracted text are stored with the source. The work is then split into chapters/sections and processed chunk by chunk — a long book takes many model calls. Items are saved with the “Cited literature” status; browse and prune afterwards. You can close this sheet while it runs."
                 : "No model calls: only the original file and its extracted text (fulltext.md) are stored. You can read the document in-app; agents see that it exists and can search/read the full text once you grant access in chat.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Start Import") {
                    guard let fileURL else { return }
                    importer.begin(SourceImportController.Request(
                        fileURL: fileURL,
                        name: name,
                        authors: authors,
                        citation: citation,
                        license: license,
                        convertToItems: convertToItems,
                        instructions: instructions,
                        detectSections: detectSections,
                        linkPass: linkPass
                    ), appState: appState)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileURL == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "tex") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        // Name is NOT pre-filled from the file name — an empty field means "Auto":
        // the metadata pass reads the real title from the document itself.
    }

    // MARK: Large-import confirmation

    private func costWarning(chunkCount: Int, totalChars: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 32)).foregroundStyle(.orange)
            Text("This is a large import").font(.headline)
            Text("“\(importer.sourceName)” splits into \(chunkCount) chunks — \(chunkCount) model calls sending ≈\(max(totalChars / 1_000, 1))k characters (≈\(max(totalChars / 4_000, 1))k tokens) in total. Depending on the model and parallel requests this can take a while and cost tokens. The document and its full text are stored either way.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(SourceImportController.currentBudget(instructions: instructions).summary)
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Toggle("Don't warn me about large imports again", isOn: $dontWarnAgain)
                .toggleStyle(.checkbox)
            HStack {
                Button("Cancel") { importer.cancel() }
                Button("Start Processing") {
                    importer.confirmLargeImport(dontShowAgain: dontWarnAgain)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Progress

    private var runningView: some View {
        VStack(spacing: 10) {
            if let progress = importer.progress {
                ProgressView(value: progress.overallFraction)
                HStack {
                    Text("\(progress.completedChunks) of \(progress.totalChunks) chunks · \(progress.itemsTotal) items imported so far")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let eta = progress.etaSeconds {
                        Text("≈ \(ImportProgress.formatETA(eta)) left")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                if progress.itemsTotal > 0 {
                    Text(progress.itemCountSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !progress.inFlight.isEmpty {
                    Text("In flight: " + progress.inFlight.keys.sorted().map { index in
                        "chunk \(index + 1) — \(Int(progress.fraction(ofInFlight: index) * 100))%"
                    }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if progress.failedChunks > 0 {
                    Text("\(progress.failedChunks) chunk(s) failed — details on the summary screen")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                Text("Storing document and full text…").foregroundStyle(.secondary)
            }
            ScrollView {
                Text(importer.log)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Continue in Background") { dismiss() }
                if importer.progress != nil {
                    Button("Pause") { importer.pause() }
                        .help("Stops after the chunks in flight; everything done so far is saved. Resume any time — even after quitting the app.")
                }
                Spacer()
                Button("Cancel Import", role: .destructive) { importer.cancel() }
            }
        }
    }

    // MARK: Paused

    private func pausedView(_ info: SourceImportController.PausedInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.system(size: 36)).foregroundStyle(.tint)
            Text("Import paused — \(info.doneChunks) of \(info.totalChunks) chunks done")
                .font(.headline)
            Text("Progress is saved with the source, so you can resume now, later, or after restarting the app — remaining chunks pick up where this left off.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack {
                Button("Resume") {
                    importer.resume(sourceURL: info.sourceURL, appState: appState)
                }
                .buttonStyle(.borderedProminent)
                Button("Discard Import", role: .destructive) { importer.discard() }
                    .help("Forgets the remaining chunks. Items already imported stay in the library.")
                Button("Close") { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Done

    /// An import that was asked for items and produced none did not succeed, whatever
    /// else it stored — say so instead of describing it as a document-only source.
    private func doneHeadline(_ info: SourceImportController.DoneInfo) -> String {
        if info.itemCount > 0 {
            return "Imported \(info.itemCount) items into '\(info.sourceURL.lastPathComponent)'"
        }
        if info.itemsRequestedButNoneMade {
            return "No items were created from '\(info.sourceURL.lastPathComponent)'"
        }
        return "Stored '\(info.sourceURL.lastPathComponent)' as a document-only source"
    }

    private func doneView(_ info: SourceImportController.DoneInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: info.itemsRequestedButNoneMade
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(info.itemsRequestedButNoneMade ? .orange : .green)
            Text(doneHeadline(info))
                .font(.headline)
                .multilineTextAlignment(.center)
            if let label = info.fulltextLabel {
                Text("Original document + full text stored (\(label)) — readable in the source browser; agents can ask for access in chat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !info.warnings.isEmpty {
                ScrollView {
                    Text(info.warnings.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            // The per-chunk log is the only record of what the run actually did; it used
            // to disappear the moment the run ended, which is exactly when it is wanted.
            if !importer.log.isEmpty {
                DisclosureGroup("Import log", isExpanded: $showDoneLog) {
                    ScrollView {
                        Text(importer.log)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                    .padding(6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)
                .frame(maxWidth: 480)
            }
            HStack {
                if info.failedChunkCount > 0 {
                    Button("Retry \(info.failedChunkCount) Failed Chunk(s)") {
                        importer.resume(sourceURL: info.sourceURL, appState: appState, onlyFailed: true)
                    }
                }
                Button("Attach to Current Project") {
                    appState.attachSource(at: info.sourceURL)
                    importer.acknowledge()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.store == nil)
                Button("New Import") { importer.acknowledge() }
                Button("Done") {
                    importer.acknowledge()
                    dismiss()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Live pill in the Sources header while an import runs in the background (and a
/// "finished" chip afterwards) — clicking reopens the import sheet.
struct ImportStatusChip: View {
    @ObservedObject var importer: SourceImportController
    let open: () -> Void

    var body: some View {
        if importer.isActive {
            Button(action: open) {
                HStack(spacing: 6) {
                    if let progress = importer.progress {
                        ProgressView(value: progress.overallFraction)
                            .frame(width: 56)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(importer.statusLine)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .help("An import is running in the background — click to see details")
        } else if case .paused(let info) = importer.phase {
            Button(action: open) {
                Label("Import paused — \(info.doneChunks)/\(info.totalChunks) chunks",
                      systemImage: "pause.circle")
                    .font(.caption)
            }
            .help("Click to resume or discard the paused import")
        } else if case .done(let info) = importer.phase {
            Button(action: open) {
                Label(info.itemCount > 0 ? "Import finished — \(info.itemCount) items"
                                         : "Import finished",
                      systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .help("Click to review the finished import and attach the source")
        }
    }
}

/// Drives the deep-link pass: bounded-parallel model calls over item batches, then a
/// single serialized apply on the main actor (ProjectStore is not thread-safe).
@MainActor
enum LinkPassGeneration {
    static func run(
        appState: AppState,
        store: ProjectStore,
        onProgress: @escaping @MainActor (String) -> Void
    ) async throws -> (added: Int, warnings: [String]) {
        let runner = makeRunner(config: try appState.providerConfig(for: .importer))
        let items = store.items
        let batches = LinkPass.batches(items: items)
        guard !batches.isEmpty else { return (0, []) }
        let system = LinkPass.systemPrompt(items: items)

        var edits: [LinkPass.Edit] = []
        var warnings: [String] = []
        let messages = batches.map { LinkPass.userMessage(batch: $0) }
        try await withThrowingTaskGroup(of: (Int, Result<[LinkPass.Edit], Error>).self) { group in
            var next = 0
            func launch() {
                let index = next
                next += 1
                let message = messages[index]
                group.addTask {
                    do {
                        let result = try await runner.run(
                            config: AgentConfig(systemPrompt: SystemPrompt(system), tools: [], maxTokens: 4096),
                            history: [.user(message)])
                        return (index, .success(try LinkPass.parse(result.finalText)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(2, messages.count) { launch() }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                onProgress("  link batch \(index + 1)/\(messages.count)")
                switch result {
                case .success(let batchEdits): edits += batchEdits
                case .failure(let error): warnings.append("Link batch \(index + 1): \(error.localizedDescription)")
                }
                if next < messages.count { launch() }
            }
        }
        let applied = LinkPass.apply(edits, store: store)
        appState.itemsVersion += 1
        return (applied.added, warnings + applied.warnings)
    }
}

/// Shared overview synthesis: one model call turning the import's chapter notes (when
/// available) and the item outline into overview.md. The regenerate path passes empty
/// notes — sources imported before overviews existed have none persisted, so the
/// synthesis works from the outline alone.
@MainActor
enum SourceOverviewGeneration {
    static func run(
        appState: AppState,
        store: ProjectStore,
        chunkNotes: [(title: String, note: String)]
    ) async throws {
        let runner = makeRunner(config: try appState.providerConfig(for: .importer))
        let config = AgentConfig(
            systemPrompt: SystemPrompt(SourceOverview.systemPrompt()),
            tools: [],
            maxTokens: 4096
        )
        // Document-only sources have no items to outline — brief the Librarian with
        // the stored full text's contents + opening pages instead.
        let preview: String? = store.items.isEmpty
            ? (try? store.loadFulltext()).map { SourceOverview.fulltextPreview($0) }
            : nil
        let message = SourceOverview.userMessage(
            name: store.meta.name,
            citation: store.meta.citation,
            chunkNotes: chunkNotes,
            outline: ContextAssembly.outline(items: store.items),
            fulltextPreview: preview
        )
        let result = try await runner.run(
            config: config,
            history: [.user(message)]
        )
        try store.saveOverview(SourceOverview.normalize(result.finalText))
    }
}
