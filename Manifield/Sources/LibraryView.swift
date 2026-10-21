import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ManifieldCore

/// Asks for an image file in one of the formats a figure may be stored in.
enum FigureImagePicker {
    @MainActor
    static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FigureAsset.allowedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the figure's image"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var showNewItem = false
    @State private var showExplorer = false

    private var visibleItems: [TheoryItem] {
        guard let store = appState.store else { return [] }
        var items = store.items
        if let filter = appState.libraryFilter {
            items = items.filter { $0.type == filter }
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

    /// Items grouped by section for display; single flat group when no sections exist.
    private var groupedItems: [(section: String?, items: [TheoryItem])] {
        TheoryItem.groupedBySection(visibleItems)
    }

    var body: some View {
        let macros = appState.store?.macroDictionary ?? [:]
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $appState.selectedItemID) {
                    ForEach(groupedItems, id: \.section) { group in
                        Section {
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    ItemNameText(name: item.name, macros: macros)
                                    HStack(spacing: 6) {
                                        Text(item.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        StatusBadge(status: item.status)
                                    }
                                }
                                .padding(.vertical, 2)
                                .tag(item.id)
                            }
                        } header: {
                            if groupedItems.count > 1 || group.section != nil {
                                Text(TheoryItem.sectionDisplayName(group.section))
                            }
                        }
                    }
                }
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search theory")
            }
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 420)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showExplorer = true
                    } label: {
                        Label("Explore", systemImage: "sparkles")
                    }
                    .help("Ask Prismo to propose new candidate conjectures extending this theory")
                    Button {
                        showNewItem = true
                    } label: {
                        Label("New Item", systemImage: "plus")
                    }
                    .help("Add a theory item by hand")
                }
            }

            TheoryDetailView()
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        // The list and detail demand 240 + 400, and NavigationSplitView sizes the detail
        // column from what its content demands — so without this floor the column reports
        // 640+, outgrows the window and gets centred, clipping the sidebar and the right
        // edge. The floor lets the column shrink; the HSplitView squeezes its panes instead.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showNewItem) {
            NewItemSheet()
        }
        .sheet(isPresented: $showExplorer) {
            ExplorerSheet()
        }
    }
}

struct NewItemSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var type: ItemType = .lemma
    @State private var name = ""
    @State private var section = ""
    @State private var illustrates = ""
    @State private var imageURL: URL?
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// A figure with no image is an empty frame — there is nothing to create yet.
    private var canCreate: Bool {
        !trimmedName.isEmpty && (type != .figure || imageURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(type == .figure ? "New figure" : "New theory item")
                .font(.title3.weight(.semibold))
            Picker("Type", selection: $type) {
                ForEach(ItemType.ShapeFamily.allCases) { family in
                    Section(family.displayName) {
                        ForEach(ItemType.allCases.filter { $0.shapeFamily == family }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            if type == .figure {
                imageRow
                TextField("Illustrates (comma-separated item ids)", text: $illustrates)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .help("The items this figure depicts — they become its dependencies, so the figure appears next to them in the graph")
            }
            TextField("Section (optional, e.g. preliminaries or main/division)", text: $section)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var imageRow: some View {
        HStack(spacing: 8) {
            Button(imageURL == nil ? "Choose Image…" : "Change…") {
                if let picked = FigureImagePicker.run() { imageURL = picked }
            }
            Text(imageURL?.lastPathComponent ?? "No image chosen")
                .font(.caption)
                .foregroundStyle(imageURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func create() {
        guard let store = appState.store else { return }
        let id = store.availableID(for: type, name: trimmedName)

        var image: String?
        if type == .figure {
            guard let source = imageURL else { return }
            do {
                image = try store.addFigureImage(from: source, for: id)
            } catch {
                self.error = error.localizedDescription
                return
            }
        }

        let item = TheoryItem(
            id: id, type: type, name: trimmedName,
            status: TheoryItem.defaultStatus(for: type),
            dependsOn: type == .figure ? splitIDs(illustrates) : [],
            section: TheoryItem.sanitizeSection(section),
            image: image,
            body: type == .figure
                ? "## Caption\n\n(what the figure shows)"
                : "## Statement\n\n(statement)\n\n## Proof\n\n(proof)"
        )
        appState.save(item)
        appState.selectedItemID = id
        dismiss()
    }

    private func splitIDs(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct TheoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var box = WebViewBox(page: "math")
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var showDependencies = false
    @State private var undefinedMacros: [String] = []

    private var item: TheoryItem? {
        appState.selectedItemID.flatMap { appState.store?.item(id: $0) }
    }

    var body: some View {
        Group {
            if let item {
                VStack(spacing: 0) {
                    header(for: item)
                    if !undefinedMacros.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Undefined LaTeX macro\(undefinedMacros.count == 1 ? "" : "s"): \(undefinedMacros.joined(separator: ", "))")
                                .font(.callout)
                            Spacer()
                            Button("Define in Math Macros…") {
                                appState.selection = .notation
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.12))
                    }
                    Divider()
                    WebViewRepresentable(box: box)
                        .padding(10)
                }
            } else {
                Text("Select a theory item")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            box.onMessage = { message in
                if message["type"] as? String == "undefinedMacros",
                   let names = message["names"] as? [String] {
                    undefinedMacros = names.sorted()
                }
            }
            render()
        }
        .onChange(of: appState.selectedItemID) { _, _ in
            // Following a dependency link swaps the item under the popover; leaving it open
            // would anchor it to a chip that may no longer exist on the new item.
            showDependencies = false
            render()
        }
        .onChange(of: appState.itemsVersion) { _, _ in render() }
        .sheet(isPresented: $showEditor) {
            if let item { ItemEditorSheet(item: item) }
        }
        .confirmationDialog(deleteWarning, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = item?.id { appState.deleteItem(id: id) }
            }
        }
    }

    private var deleteWarning: String {
        guard let item, let store = appState.store else { return "Delete item?" }
        let dependents = store.graph.transitiveDependents(of: item.id)
        return dependents.isEmpty
            ? "Delete '\(item.id)'?"
            : "Delete '\(item.id)'? ⚠️ \(dependents.count) item(s) depend on it: \(dependents.sorted().joined(separator: ", "))"
    }

    private func render() {
        guard let item else { return }
        undefinedMacros = []
        appState.syncMacros(box)
        box.call("setDocument", TheoryDocument.markdown(for: item))
    }

    /// Two text lines and a row of fixed-size controls — nothing here may wrap, because the
    /// header has to keep one height at every window width. Everything that can grow is
    /// capped: both text lines truncate, and the dependency list (which used to stack one
    /// link per row and could be twenty long) moved into `dependenciesPopover`.
    private func header(for item: TheoryItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ItemNameText(name: item.name,
                             macros: appState.store?.macroDictionary ?? [:],
                             fontSize: NSFont.systemFontSize + 2,
                             lineLimit: 1)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(item.type.displayName).font(.caption).foregroundStyle(.secondary)
                    if item.section != nil {
                        Label(TheoryItem.sectionDisplayName(item.section), systemImage: "book.pages")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.tags.isEmpty {
                        // .secondary, not .tertiary: tertiary is barely legible against
                        // either background, and the leading # already sets tags apart
                        // from the id and type beside them.
                        Text(item.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            // The title block is the only part that gives up width; the controls to its
            // right keep theirs, so squeezing the window truncates the title instead of
            // shredding every label into a one-character column.
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !item.dependsOn.isEmpty {
                dependenciesButton(for: item)
            }

            if item.isFigure {
                // No status control: the trust ladder is about proof, and a figure has
                // nothing on it to prove. Replacing the image is the equivalent action.
                Button {
                    if let picked = FigureImagePicker.run() {
                        appState.setFigureImage(from: picked, on: item)
                    }
                } label: {
                    Image(systemName: "photo")
                }
                .help("Replace this figure's image")
            } else {
                // The user can set trust status by hand; agents will move it automatically later.
                StatusMenu(status: item.status) { newStatus in
                    var updated = item
                    updated.status = newStatus
                    appState.save(updated)
                }
            }

            Button {
                appState.chat.startLinkedChat(with: item)
                appState.selection = .chat
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .help("Open a new chat with this item loaded — Prismo will have it as context")

            Button {
                showEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Edit this item")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this item")
        }
        .padding(10)
    }

    /// A count, not a list: one chip of constant width however many dependencies an item
    /// has. The list itself opens in a popover, which is also the first place there is room
    /// to resolve each id to its actual name.
    private func dependenciesButton(for item: TheoryItem) -> some View {
        Button {
            showDependencies = true
        } label: {
            HStack(spacing: 3) {
                // The sidebar's Dependency Graph glyph — same concept, same icon, and it
                // avoids a second arrow sitting next to the status pill's chevron.
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("\(item.dependsOn.count)")
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(item.dependsOn.count) item(s) this one depends on — click to list them")
        .popover(isPresented: $showDependencies, arrowEdge: .bottom) {
            dependenciesPopover(for: item)
        }
    }

    private func dependenciesPopover(for item: TheoryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Depends on")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.dependsOn, id: \.self) { dep in
                        Button {
                            appState.selectedItemID = dep
                            showDependencies = false
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                // A citation into a source reads `slug:item-id` and has no
                                // item in this project — then the id is all there is to show.
                                if let resolved = appState.store?.item(id: dep) {
                                    ItemNameText(name: resolved.name,
                                                 macros: appState.store?.macroDictionary ?? [:],
                                                 lineLimit: 1)
                                        .font(.callout)
                                }
                                Text(dep)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            // Caps the popover instead of the header: a long dependency list scrolls here.
            .frame(maxHeight: 260)
        }
        .frame(width: 300)
    }
}

struct ItemEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewBox = WebViewBox(page: "math")

    @State var item: TheoryItem
    @State private var dependsText: String
    @State private var resolvesText: String
    @State private var tagsText: String
    @State private var sectionText: String

    init(item: TheoryItem) {
        _item = State(initialValue: item)
        _dependsText = State(initialValue: item.dependsOn.joined(separator: ", "))
        _resolvesText = State(initialValue: item.resolves.joined(separator: ", "))
        _tagsText = State(initialValue: item.tags.joined(separator: ", "))
        _sectionText = State(initialValue: item.section ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit \(item.id)").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    item.dependsOn = splitList(dependsText)
                    item.resolves = splitList(resolvesText)
                    item.tags = splitList(tagsText)
                    item.section = TheoryItem.sanitizeSection(sectionText)
                    appState.save(item)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: $item.name)
                        .textFieldStyle(.roundedBorder)
                    TextField(item.isFigure ? "Illustrates (comma-separated ids)"
                                            : "Depends on (comma-separated ids)",
                              text: $dependsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Resolves goal items (comma-separated ids)", text: $resolvesText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Section (slug, / for subsection, empty = unsorted)", text: $sectionText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    TextField("Tags (comma-separated)", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                    if item.isFigure { imageRow }
                    Text(item.isFigure ? "Caption (markdown + LaTeX)" : "Body (markdown + LaTeX)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $item.body)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding()
                .frame(minWidth: 380)

                VStack(spacing: 0) {
                    HStack {
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { renderPreview() }
                            .controlSize(.small)
                    }
                    .padding(8)
                    WebViewRepresentable(box: previewBox)
                }
                .frame(minWidth: 340)
            }
        }
        .frame(width: 940, height: 600)
        .onAppear { renderPreview() }
        .onChange(of: item.body) { _, _ in renderPreview() }
    }

    /// Choosing an image commits it straight away rather than waiting for Save. The copy
    /// replaces whatever the id had on disk, so deferring the frontmatter would leave a
    /// cancelled edit pointing at a file that is already gone. Only the image is written
    /// — text edits in progress stay in the editor until Save.
    private var imageRow: some View {
        HStack(spacing: 8) {
            Button("Choose Image…") {
                guard let picked = FigureImagePicker.run(),
                      let store = appState.store,
                      var stored = store.item(id: item.id) else { return }
                do {
                    stored.image = try store.addFigureImage(from: picked, for: item.id)
                    appState.save(stored)
                    item.image = stored.image
                    renderPreview()
                } catch {
                    appState.openError = error.localizedDescription
                }
            }
            Text(item.image ?? "no image")
                .font(.caption.monospaced())
                .foregroundStyle(item.image == nil ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func renderPreview() {
        appState.syncMacros(previewBox)
        previewBox.call("setDocument", TheoryDocument.markdown(for: item))
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
