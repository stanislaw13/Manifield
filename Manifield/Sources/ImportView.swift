import SwiftUI
import UniformTypeIdentifiers
import ManifieldCore
import ManifieldAgents

/// The two things "import" can mean, kept apart because they cost wildly different
/// things: parking a file in the project is a file copy, while organizing one into
/// library items is a model call per chunk.
private enum ImportMode: String, CaseIterable, Identifiable {
    case items
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .items: return "Import into the library"
        case .files: return "Add files to the project"
        }
    }

    var subtitle: String {
        switch self {
        case .items: return "Break a LaTeX or PDF document into definitions, theorems and lemmas you review before anything is saved."
        case .files: return "Keep PDFs as they are — read them in the app, and let agents search and read them on request. No model calls."
        }
    }

    var symbol: String {
        switch self {
        case .items: return "square.and.arrow.down.on.square"
        case .files: return "doc.on.doc"
        }
    }
}

/// Import flow: pick/drop a .tex or .pdf → chunked Organizer run (same parallel
/// pipeline as source import, with pause/resume and per-chunk retry) → either a
/// review list the user confirms, or direct saves when review is switched off.
/// The other mode just keeps files with the project (see `ImportMode`).
struct ImportView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Use the AppState-owned controller so the run survives view switches.
        ImportBody(importer: appState.theoryImport)
    }
}

private struct ImportBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var importer: TheoryImportController

    @State private var mode: ImportMode = .items
    @State private var sourceText = ""
    @State private var instructions = ""
    @State private var reviewBeforeSaving = true
    @State private var keepOriginal = true
    @State private var dontWarnAgain = false
    @State private var pendingRecord: SourceImportRecord?
    /// A file waiting for the user to start the run — either handed over from a kept
    /// document, or one they just chose. Nothing costs tokens until they confirm.
    @State private var stagedFile: StagedFile?
    /// File name while it is being read (extraction of a long PDF takes seconds).
    @State private var readingFile: String?

    /// A file staged for import. `keepFile` is false for documents already in the project.
    private struct StagedFile: Equatable {
        var url: URL
        var keepFile: Bool
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        Group {
            switch importer.phase {
            case .idle:
                idleView
            case .confirmLarge(let chunkCount, let totalChars):
                costWarning(chunkCount: chunkCount, totalChars: totalChars)
            case .running:
                runningView
            case .paused(let info):
                pausedView(info)
            case .review(let items, let warnings):
                reviewView(items: items, warnings: warnings)
            case .done(let info):
                doneView(info)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    Button("Try Again") { importer.reset() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            refreshPendingRecord()
            consumeSeed()
        }
        .onChange(of: importer.isRunning) { _, _ in refreshPendingRecord() }
        .onChange(of: appState.importSeed) { _, _ in consumeSeed() }
    }

    /// A file handed over from elsewhere ("Import items from this file" on a kept
    /// document): it is already in the project, so the run must not store it again. It is
    /// only staged — the user starts the run, since every chunk costs a model call.
    private func consumeSeed() {
        guard let url = appState.importSeed, case .idle = importer.phase else { return }
        appState.importSeed = nil
        mode = .items
        stagedFile = StagedFile(url: url, keepFile: false)
    }

    /// A record from a previous session (quit mid-import, or a review that was open).
    private func refreshPendingRecord() {
        guard case .idle = importer.phase, let store = appState.store else {
            pendingRecord = nil
            return
        }
        let record = TheoryImportController.pendingRecord(in: store)
        pendingRecord = (record?.isResumable == true || record?.hasRetryableFailures == true)
            ? record : nil
    }

    // MARK: - Idle (choose what kind of import, then pick a file)

    private var idleView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let record = pendingRecord {
                    resumeBanner(record)
                }
                modeChooser
                Divider().frame(maxWidth: 700)
                switch mode {
                case .items: itemsPanel
                case .files: filesPanel
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { drop(url: url) }
                }
            }
            return true
        }
    }

    /// The one decision that shapes everything below it: organize a document into items,
    /// or just keep the file.
    private var modeChooser: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(ImportMode.allCases) { candidate in
                modeCard(candidate)
            }
        }
        .frame(maxWidth: 700)
    }

    private func modeCard(_ candidate: ImportMode) -> some View {
        let isSelected = mode == candidate
        return Button {
            mode = candidate
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: candidate.symbol)
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                    : AnyShapeStyle(.secondary))
                    Text(candidate.title)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(candidate.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6)
                                             : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Add files

    private var filesPanel: some View {
        VStack(spacing: 14) {
            Button {
                DocumentPicker.pick(into: appState)
            } label: {
                Label("Choose PDFs…", systemImage: "folder")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Text("Files are copied into the project folder (`documents/`) and their text is extracted locally — no model calls, no network. You read them in the **Files** section of the sidebar; Prismo has to ask before reading one, unless you turn on “auto-allow reading full documents” in the chat composer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            if !appState.documentsInFlight.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Adding \(appState.documentsInFlight.joined(separator: ", "))…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = appState.documentNotice {
                Text(notice)
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            if appState.documents.isEmpty {
                Text("No files kept with this project yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In this project")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(appState.documents) { document in
                        Button {
                            appState.selection = .document(slug: document.slug)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: document.isPDF ? "doc.richtext" : "doc.plaintext")
                                    .foregroundStyle(.tint)
                                Text(document.meta.title).lineLimit(1)
                                Spacer()
                                Text(document.isSearchable ? document.formatLabel : "no text")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
            }
        }
    }

    // MARK: Import into the library

    private var itemsPanel: some View {
        VStack(spacing: 14) {
            Text("Drop a LaTeX (.tex) or PDF file here — or paste LaTeX below. Long documents are processed in parallel chunks; you can pause and resume at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            if let staged = stagedFile {
                stagedFileRow(staged)
            } else if let readingFile {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(readingFile)…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    pickFile()
                } label: {
                    Label("Choose File…", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep the original file in the project", isOn: $keepOriginal)
                    .disabled(stagedFile?.keepFile == false)
                    .help("The file is copied into the project and appears under Files, so you and the agents can go back to the real thing. Pasted LaTeX has no file to keep.")
                Toggle("Review before saving", isOn: $reviewBeforeSaving)
                    .help("On: proposed items wait in an editable review list — nothing is saved until you confirm. Off: items are saved to the project as each chunk finishes (like a source import).")
                HStack(spacing: 8) {
                    Text("Import model:")
                        .font(.callout).foregroundStyle(.secondary)
                    ModelTaskPicker(task: .importer, compact: true)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            .frame(maxWidth: 620, alignment: .leading)

            TextField("Import instructions (optional)", text: $instructions,
                      prompt: Text("e.g. “Import only the first 3 chapters” or “only linear-algebra theorems”"),
                      axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 620)
                .help("Free-text steering for the Organizer — it skips content outside the requested scope.")

            VStack(alignment: .leading, spacing: 4) {
                Text("Or paste LaTeX:").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $sourceText)
                    .font(.body.monospaced())
                    .frame(height: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("Analyze with Organizer") {
                        start(.latex(sourceText), name: "pasted LaTeX")
                        sourceText = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: 620)
        }
    }

    private func resumeBanner(_ record: SourceImportRecord) -> some View {
        let resumable = record.isResumable
        return HStack(spacing: 8) {
            Image(systemName: resumable ? "pause.circle" : "exclamationmark.triangle")
                .foregroundStyle(resumable ? Color.accentColor : .orange)
            Text(resumable
                 ? "Unfinished import: “\(record.request.name)” — \(record.doneCount)/\(record.chunks.count) chunks done."
                 : "“\(record.request.name)” finished with \(record.failedIndices.count) failed chunk(s).")
                .font(.callout)
            Button(resumable ? "Resume" : "Retry Failed") {
                appState.theoryImport.resume(appState: appState, onlyFailed: !resumable)
            }
            .controlSize(.small)
            Button("Discard") {
                if let store = appState.store {
                    SourceImportRecord.delete(atSourceFolder: store.rootURL,
                                              named: SourceImportRecord.theorySessionName)
                }
                refreshPendingRecord()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The staged file and the button that actually spends tokens.
    private func stagedFileRow(_ staged: StagedFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: staged.url.pathExtension.lowercased() == "pdf"
                  ? "doc.richtext" : "doc.plaintext")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(staged.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(staged.keepFile
                     ? "Ready to organize into library items."
                     : "Already kept in the project — this only extracts items from it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Another…") { pickFile(stageOnly: true) }
                .controlSize(.small)
            Button("Analyze with Organizer") { load(staged) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 620)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// `stageOnly` replaces a staged file without starting the run — the flow someone is
    /// in when they arrived from a kept document and are still deciding.
    private func pickFile(stageOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "tex") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let staged = StagedFile(url: url, keepFile: keepOriginal)
        if stageOnly {
            stagedFile = staged
        } else {
            load(staged)
        }
    }

    /// A dropped file does whatever the chosen mode does — dropping onto "Add files"
    /// must not silently start a model run.
    private func drop(url: URL) {
        switch mode {
        case .files: DocumentPicker.add(urls: [url], into: appState)
        case .items: load(StagedFile(url: url, keepFile: keepOriginal))
        }
    }

    /// Reads the file once: the same extraction feeds the Organizer's chunks and (when the
    /// original is kept) the stored document's searchable text. Reading a long PDF takes
    /// seconds, so it runs off the main thread.
    private func load(_ staged: StagedFile) {
        let url = staged.url
        let name = staged.name
        stagedFile = nil
        readingFile = name
        Task {
            defer { readingFile = nil }
            let extracted: PDFExtraction.Result
            do {
                extracted = try await Task.detached(priority: .userInitiated) {
                    try PDFExtraction.read(url: url)
                }.value
            } catch {
                importer.fail(error.localizedDescription)
                return
            }
            // The kept file keeps the extraction that was just made — storing it costs
            // nothing and makes the document searchable.
            let kept = staged.keepFile
                ? TheoryImportController.KeptFile(
                    url: url, fulltext: extracted.fulltext, pageCount: extracted.pageCount)
                : nil

            if url.pathExtension.lowercased() == "pdf" {
                guard extracted.hasText else {
                    importer.fail("Could not extract text from '\(name)'. If it is a scanned PDF, OCR it first — or add it under “Add files to the project” to keep it for reading.")
                    return
                }
                start(.pages(extracted.pages), name: name, keepFile: kept)
            } else {
                start(.latex(extracted.text ?? ""), name: name, keepFile: kept)
            }
        }
    }

    private func start(_ source: TheoryImportController.Source, name: String,
                       keepFile: TheoryImportController.KeptFile? = nil) {
        importer.start(source: source, sourceName: name,
                       instructions: instructions,
                       reviewBeforeSaving: reviewBeforeSaving,
                       keepFile: keepFile,
                       appState: appState)
    }

    // MARK: - Large-import confirmation

    private func costWarning(chunkCount: Int, totalChars: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 32)).foregroundStyle(.orange)
            Text("This is a large import").font(.headline)
            Text("“\(importer.sourceName)” splits into \(chunkCount) chunks — \(chunkCount) model calls sending ≈\(max(totalChars / 1_000, 1))k characters (≈\(max(totalChars / 4_000, 1))k tokens) in total. You can pause at any point; progress survives quitting the app.")
                .foregroundStyle(.secondary)
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

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: 10) {
            if let progress = importer.progress {
                ProgressView(value: progress.overallFraction)
                HStack {
                    Text("\(progress.completedChunks) of \(progress.totalChunks) chunks · \(progress.itemsTotal) items proposed so far")
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
                if progress.failedChunks > 0 {
                    Text("\(progress.failedChunks) chunk(s) failed — retry them from the review screen")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                Text("Organizer is analyzing \(importer.sourceName)…")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(importer.log)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
            .padding(6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            Text("You can switch to another tab — the import keeps running.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Pause") { importer.pause() }
                    .help("Stops after the chunks in flight. Resume any time — even after quitting the app.")
                Spacer()
                Button("Cancel", role: .destructive) { importer.cancel() }
            }
        }
        .padding()
    }

    private func pausedView(_ info: TheoryImportController.PausedInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.system(size: 36)).foregroundStyle(.tint)
            Text("Import paused — \(info.doneChunks) of \(info.totalChunks) chunks done")
                .font(.headline)
            Text("Progress is saved with the project; resume now or after restarting the app.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Resume") { importer.resume(appState: appState) }
                    .buttonStyle(.borderedProminent)
                Button("Discard", role: .destructive) {
                    if let store = appState.store {
                        SourceImportRecord.delete(atSourceFolder: store.rootURL,
                                                  named: SourceImportRecord.theorySessionName)
                    }
                    importer.reset()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review / Done

    @ViewBuilder
    private func reviewView(items: [TheoryImportController.ReviewedItem], warnings: [String]) -> some View {
        VStack(spacing: 0) {
            if importer.failedChunkCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("\(importer.failedChunkCount) chunk(s) failed to convert. Retry importing those chunks?")
                        .font(.callout)
                    Button("Retry Failed") { importer.retryFailed() }
                        .controlSize(.small)
                        .help("Re-runs only the failed chunks and returns here. Retry before editing — the list is rebuilt.")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.1))
                Divider()
            }
            ReviewList(
                items: items,
                warnings: warnings,
                onConfirm: confirmImport,
                onCancel: { importer.completeReview() },
                onUpdate: { importer.updateReview($0) }
            )
        }
    }

    private func doneView(_ info: TheoryImportController.DoneInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36)).foregroundStyle(.green)
            Text("Imported \(info.savedCount) item(s) into the project")
                .font(.headline)
            keptFileNote
            if !info.warnings.isEmpty {
                ScrollView {
                    Text(info.warnings.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                if info.failedChunkCount > 0 {
                    Button("Retry \(info.failedChunkCount) Failed Chunk(s)") {
                        importer.retryFailed()
                    }
                }
                Button("Open Library") {
                    importer.completeReview()
                    appState.selection = .library
                }
                .buttonStyle(.borderedProminent)
                Button("Done") { importer.completeReview() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where the original went, once a run kept it — the file is stored before the first
    /// model call, so this holds even for a run that failed.
    @ViewBuilder
    private var keptFileNote: some View {
        if let slug = importer.keptDocumentSlug, let document = appState.document(slug: slug) {
            Button {
                appState.selection = .document(slug: slug)
            } label: {
                Label("“\(document.meta.title)” is kept in the project — open it",
                      systemImage: document.isPDF ? "doc.richtext" : "doc.plaintext")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Confirm

    private func confirmImport(_ items: [TheoryImportController.ReviewedItem]) {
        for reviewed in items where reviewed.include {
            var item = reviewed.item
            item.source = item.source ?? importer.sourceName
            item.section = TheoryItem.sanitizeSection(item.section)
            appState.save(item)
        }
        importer.completeReview()
        appState.selection = .library
    }
}

/// Editable review list shown after the Organizer proposes a breakdown.
private struct ReviewList: View {
    @EnvironmentObject private var appState: AppState
    @State var items: [TheoryImportController.ReviewedItem]
    let warnings: [String]
    let onConfirm: ([TheoryImportController.ReviewedItem]) -> Void
    let onCancel: () -> Void
    /// Fired on every edit so the controller keeps the review current across tab switches.
    let onUpdate: ([TheoryImportController.ReviewedItem]) -> Void

    @StateObject private var previewBox = WebViewBox(page: "math")
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review proposed items").font(.title3.weight(.semibold))
                    Text("\(items.filter(\.include).count) of \(items.count) selected — nothing is saved until you confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Import Selected") { onConfirm(items) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!items.contains(where: \.include))
            }
            .padding()

            if !warnings.isEmpty {
                ScrollView {
                    Label(warnings.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 44)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Divider()

            HSplitView {
                List(selection: $selectedID) {
                    ForEach($items) { $reviewed in
                        HStack(alignment: .top) {
                            Toggle("", isOn: $reviewed.include)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                TextField("Name", text: $reviewed.item.name)
                                    .textFieldStyle(.plain)
                                    .font(.body.weight(.medium))
                                HStack(spacing: 6) {
                                    Text(reviewed.item.id).font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(reviewed.item.type.displayName).font(.caption2)
                                        .foregroundStyle(.secondary)
                                    StatusBadge(status: reviewed.item.status)
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "book.pages")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    TextField(
                                        "section (empty = unsorted)",
                                        text: Binding(
                                            get: { reviewed.item.section ?? "" },
                                            set: { $reviewed.item.section.wrappedValue = $0.isEmpty ? nil : $0 }
                                        )
                                    )
                                    .textFieldStyle(.plain)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .help("Section slug — use / for a subsection, e.g. weierstrass-theory/division")
                                }
                                if !reviewed.item.dependsOn.isEmpty {
                                    Text("depends: \(reviewed.item.dependsOn.joined(separator: ", "))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(reviewed.id)
                    }
                }
                .frame(minWidth: 320, idealWidth: 380)

                WebViewRepresentable(box: previewBox)
                    .frame(minWidth: 360)
            }
        }
        // The panes above demand 320 + 360, and NavigationSplitView sizes the detail column
        // from what its content demands — so without this floor the review pane outgrows
        // the window and gets centred, clipping the sidebar and the right edge.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: items) { _, updated in
            onUpdate(updated)
        }
        .onChange(of: selectedID) { _, id in
            if let reviewed = items.first(where: { $0.id == id }) {
                appState.syncMacros(previewBox)
                previewBox.call("setDocument", TheoryDocument.markdown(for: reviewed.item))
            }
        }
        .onAppear {
            selectedID = items.first?.id
            if let first = items.first {
                appState.syncMacros(previewBox)
                previewBox.call("setDocument", TheoryDocument.markdown(for: first.item))
            }
        }
    }
}
