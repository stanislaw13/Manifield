import SwiftUI
import UniformTypeIdentifiers
import ManifieldCore
import ManifieldAgents

/// One file kept with the project: the document itself on the right (PDF in the built-in
/// viewer, LaTeX/text as plain text), with what the project knows about it — and what
/// agents may do with it — on top.
struct DocumentDetailView: View {
    @EnvironmentObject private var appState: AppState
    let slug: String

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmRemove = false
    @State private var textPreview: String?

    /// Read from the store on every redraw: the title, the extraction state and the file
    /// itself all change under this view.
    private var document: ProjectDocument? { appState.document(slug: slug) }

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    header(document)
                    Divider()
                    // Notices are prefixed with the file they concern, so one raised while
                    // adding a different file does not surface here.
                    if let notice = appState.documentNotice,
                       notice.hasPrefix("\(document.meta.title):") {
                        noticeBar(notice)
                        Divider()
                    }
                    viewer(document)
                }
            } else {
                ContentUnavailableView(
                    "File not found",
                    systemImage: "doc.questionmark",
                    description: Text("“\(slug)” is no longer in this project's documents folder."))
            }
        }
        .alert("Rename file", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { appState.renameDocument(slug: slug, title: renameText) }
        } message: {
            Text("Only the name shown here changes — agents keep addressing the file as “\(slug)”.")
        }
        .confirmationDialog(
            "Remove “\(document?.meta.title ?? slug)” from the project?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove File", role: .destructive) { appState.removeDocument(slug: slug) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file and its extracted text are deleted from the project folder. Theory items imported from it stay.")
        }
    }

    // MARK: - Header

    private func header(_ document: ProjectDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: document.isPDF ? "doc.richtext" : "doc.plaintext")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.meta.title).font(.headline).lineLimit(1)
                Text(subtitle(document))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if appState.documentsInFlight.contains(document.meta.title) {
                ProgressView().controlSize(.small)
            }
            actionsMenu(document)
        }
        .padding(10)
    }

    /// Everything the user needs to judge what agents can do with this file, in one line.
    private func subtitle(_ document: ProjectDocument) -> String {
        var parts: [String] = []
        let format = document.formatLabel
        if !format.isEmpty { parts.append(format) }
        parts.append(document.isSearchable
                     ? "searchable by agents"
                     : "no extractable text — agents cannot read it")
        if appState.chat.fulltextAccess.allowAll {
            parts.append("reading auto-allowed")
        } else if appState.chat.isDocumentGranted(slug: slug) {
            parts.append("allowed in the current chat")
        }
        if document.meta.originalFileName != document.meta.title {
            parts.append(document.meta.originalFileName)
        }
        return parts.joined(separator: " · ")
    }

    private func actionsMenu(_ document: ProjectDocument) -> some View {
        Menu {
            if document.isSearchable, !appState.chat.isDocumentGranted(slug: slug) {
                Button("Let Prismo Read It (this chat)") {
                    appState.chat.addDocument(slug: slug, title: document.meta.title)
                }
                .help("Same as approving the request banner — Prismo may search and read this file for the current conversation.")
            } else if document.isSearchable, !appState.chat.fulltextAccess.allowAll {
                Button("Revoke Prismo's Access") {
                    appState.chat.revokeGrant(key: ChatController.documentGrantKey(slug))
                }
            }
            Button("Import Items from This File…") {
                appState.importItems(fromDocument: slug)
            }
            .help("Runs the Organizer over this file and proposes definitions, theorems and lemmas for the library.")
            Divider()
            Button(document.isSearchable ? "Re-extract Text" : "Extract Text") {
                Task { await appState.extractDocumentText(slug: slug) }
            }
            .help("Re-reads the file into the agent-searchable text. Use it after OCRing a scanned PDF in place.")
            Button("Open in Default App") {
                if let url = document.fileURL { NSWorkspace.shared.open(url) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [document.fileURL ?? document.folderURL])
            }
            Button("Rename…") {
                renameText = document.meta.title
                isRenaming = true
            }
            Divider()
            Button("Remove from Project", role: .destructive) { confirmRemove = true }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.orange)
            Text(notice).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                appState.documentNotice = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.10))
    }

    // MARK: - Viewer

    @ViewBuilder
    private func viewer(_ document: ProjectDocument) -> some View {
        if let url = document.fileURL, document.isPDF {
            PDFViewer(url: url)
        } else if let url = document.fileURL {
            ScrollView {
                Text(textPreview ?? "")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .task(id: url) { textPreview = Self.loadTextPreview(url) }
        } else {
            ContentUnavailableView(
                "The stored file is missing",
                systemImage: "exclamationmark.triangle",
                description: Text("Its folder is still in the project, but the document itself is gone."))
        }
    }

    /// Text files are read for display only, so a giant `.tex` is truncated rather than
    /// paged — the agent-facing copy in fulltext.md is the complete one.
    private static func loadTextPreview(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(this file is not UTF-8 text — open it in its own app)"
        }
        let cap = 400_000
        return text.count <= cap
            ? text
            : String(text.prefix(cap)) + "\n\n… (truncated for display — open the file to read the rest)"
    }
}

// MARK: - Adding files

/// The one place files enter a project, shared by the sidebar's Add row and the Import
/// tab: pick documents, copy them in, extract their text, then show the last one added.
@MainActor
enum DocumentPicker {

    static var allowedTypes: [UTType] {
        [.pdf, UTType(filenameExtension: "tex") ?? .plainText, .plainText]
    }

    static func pick(into appState: AppState, select: Bool = true) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        panel.message = "Choose PDFs (or LaTeX files) to keep with this project."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        add(urls: panel.urls, into: appState, select: select)
    }

    static func add(urls: [URL], into appState: AppState, select: Bool = true) {
        Task {
            let added = await appState.addDocuments(at: urls)
            if select, let last = added.last {
                appState.selection = .document(slug: last.slug)
            }
        }
    }
}
