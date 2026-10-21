import SwiftUI
import ManifieldCore

struct GraphView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var box = WebViewBox(page: "graph")

    /// What clicking a node traces through the derivation DAG. The control that sets
    /// it lives in the page's settings panel, so the labels are over there too.
    private enum TraceMode {
        case off
        case needs        // ancestors: everything this item depends on, transitively
        case buildsOn     // descendants: everything derived from it

        var jsMode: String {
            switch self {
            case .off: return "none"
            case .needs: return "ancestors"
            case .buildsOn: return "descendants"
            }
        }

        init(jsMode: String) {
            switch jsMode {
            case "ancestors": self = .needs
            case "descendants": self = .buildsOn
            default: self = .off
            }
        }
    }

    @State private var traceMode: TraceMode = .off
    @State private var typeFilter: Set<ItemType> = []
    @State private var statusFilter: Set<ItemStatus> = []
    @State private var sectionFilter: String?
    @State private var searchText = ""
    @State private var showExplorer = false
    @State private var showSearchResults = false
    @FocusState private var searchFocused: Bool
    @AppStorage("graphShowTags") private var showTags = true
    /// The in-page settings panel's values, verbatim as it posts them. The page owns
    /// their meaning and clamps them on the way back in, so this is a passthrough
    /// store — no key here needs to be known on this side.
    @AppStorage("graphViewSettings") private var graphSettingsJSON = ""

    /// Identifies the drawn store to the page, which resets itself whenever this
    /// changes: two projects can use the same item ids, so the page cannot tell a
    /// scope switch from a reload of the same graph on its own.
    private var scopeKey: String {
        switch appState.graphScope {
        case .project:
            return "project:" + (appState.store?.rootURL.path ?? "")
        case .source(let slug):
            return "source:" + slug
        }
    }

    /// The selected item *in the scope being drawn*. Source scope parks its selection
    /// in `selectedSourceItemID`; reading `selectedItemID` here is what used to leave
    /// "What it needs" and "What builds on it" dead on a source's graph.
    private var scopedSelectionID: String? {
        switch appState.graphScope {
        case .project: return appState.selectedItemID
        case .source: return appState.selectedSourceItemID
        }
    }

    /// The store the graph draws: the project, or a chosen attached source.
    private var scopedStore: ProjectStore? {
        switch appState.graphScope {
        case .project:
            return appState.store
        case .source(let slug):
            return appState.attachedSources.first { $0.ref.slug == slug }?.store
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Raised above the web view so the search results list, which overhangs
            // the control bar, is not covered by the hosted WKWebView layer.
            controlBar
                .zIndex(1)
            Divider()
            if graphCycle != nil || !missingReferences.isEmpty {
                warningsBar
                Divider()
            }
            WebViewRepresentable(box: box)
        }
        // NavigationSplitView sizes the detail column from the width its content *demands*,
        // and `controlBar` is a row of .fixedSize() pickers and menus that demands ~700pt.
        // Without a floor the column reports that as its minimum, the split view outgrows
        // the window, and SwiftUI centres it — clipping the sidebar on the left and the
        // page on the right. Declaring a smaller floor lets the column be narrower than the
        // bar wants; the bar then truncates on its own instead of shoving the window apart.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            wireBridge()
            box.call("setTagsVisible", showTags)
            // Before the first setGraph: node radii are computed as the graph lands.
            if !graphSettingsJSON.isEmpty { box.call("setGraphSettings", graphSettingsJSON) }
            pushGraph()
            pushFilter()
            applyTrace()
        }
        .onChange(of: showTags) { _, visible in
            box.call("setTagsVisible", visible)
        }
        .onChange(of: appState.itemsVersion) { _, _ in
            pushGraph()
            pushFilter()
            applyTrace()
        }
        .onChange(of: appState.graphScope) { _, _ in
            sectionFilter = nil
            // A trace belongs to the item it started from, which the other store does
            // not contain; the page drops its own copy on the scope switch, so this
            // keeps the app's side of it from re-arming a trace on a stale id.
            traceMode = .off
            pushGraph()
            pushFilter()
        }
        .onChange(of: appState.selectedItemID) { _, _ in applyTrace() }
        .onChange(of: appState.selectedSourceItemID) { _, _ in applyTrace() }
        // Explore writes new items; re-layout only rearranges what is on screen.
        // They sat in one pill and read as related — re-layout now lives in the
        // control bar with the other view-only controls.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExplorer = true
                } label: {
                    Label("Explore", systemImage: "sparkles")
                }
                .disabled(appState.graphScope != .project)
                .help("Ask Prismo to propose new candidate conjectures extending this theory (project scope only)")
            }
        }
        .sheet(isPresented: $showExplorer) {
            ExplorerSheet()
        }
    }

    // MARK: - Controls (search, filters, trace)

    private var hasFilter: Bool {
        !typeFilter.isEmpty || !statusFilter.isEmpty || sectionFilter != nil
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            if !appState.attachedSources.isEmpty {
                Picker("Scope", selection: $appState.graphScope) {
                    Text(appState.store?.meta.name ?? "Project").tag(GraphScope.project)
                    ForEach(appState.attachedSources, id: \.ref.slug) { source in
                        Text(source.store.meta.name).tag(GraphScope.source(source.ref.slug))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show the project's graph, or the internal graph of one attached source")
            }

            searchField

            Menu {
                ForEach(ItemType.ShapeFamily.allCases) { family in
                    Section(family.displayName) {
                        ForEach(ItemType.allCases.filter { $0.shapeFamily == family }) { type in
                            Toggle(type.pluralName, isOn: toggleBinding(for: type, in: $typeFilter))
                        }
                    }
                }
            } label: {
                filterChip("Type", active: !typeFilter.isEmpty,
                           detail: typeFilter.map(\.displayName).sorted().joined(separator: ", "))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(ItemStatus.allCases) { status in
                    Toggle(status.displayName, isOn: toggleBinding(for: status, in: $statusFilter))
                }
            } label: {
                filterChip("Status", active: !statusFilter.isEmpty,
                           detail: statusFilter.map(\.displayName).sorted().joined(separator: ", "))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if !allSections.isEmpty {
                Menu {
                    Button("All sections") { sectionFilter = nil }
                    Divider()
                    ForEach(allSections, id: \.self) { slug in
                        Button {
                            sectionFilter = slug
                        } label: {
                            if sectionFilter == slug { Image(systemName: "checkmark") }
                            Text(TheoryItem.sectionDisplayName(slug))
                        }
                    }
                } label: {
                    filterChip("Section", active: sectionFilter != nil,
                               detail: TheoryItem.sectionDisplayName(sectionFilter))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if hasFilter {
                Button("Clear") {
                    typeFilter = []
                    statusFilter = []
                    sectionFilter = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(isOn: $showTags) {
                Text("#")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show tag nodes in the graph")

            Button {
                box.call("relayout")
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Re-seed the layout and let the graph settle again")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: typeFilter) { _, _ in pushFilter() }
        .onChange(of: statusFilter) { _, _ in pushFilter() }
        .onChange(of: sectionFilter) { _, _ in pushFilter() }
        .onChange(of: traceMode) { _, _ in applyTrace() }
    }

    // MARK: - Search

    /// Best matches for the current query. One word often matches many items, so the
    /// field offers a ranked shortlist instead of silently jumping to the first hit.
    private var searchMatches: [TheoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let items = scopedStore?.items else { return [] }

        func rank(_ item: TheoryItem) -> Int? {
            let id = item.id.lowercased()
            let name = item.name.lowercased()
            if id == query || name == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            if id.hasPrefix(query) { return 2 }
            // Match at a word boundary before a match buried mid-token.
            if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 3 }
            if name.contains(query) { return 4 }
            if id.contains(query) { return 5 }
            return nil
        }

        return items
            .compactMap { item in rank(item).map { (item: item, rank: $0) } }
            .sorted { a, b in
                a.rank != b.rank ? a.rank < b.rank : TheoryItem.documentOrder(a.item, b.item)
            }
            .prefix(7)
            .map(\.item)
    }

    private func choose(_ item: TheoryItem) {
        box.call("focusNode", item.id)
        searchFocused = false
        showSearchResults = false
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find item…", text: $searchText)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit {
                    if let first = searchMatches.first { choose(first) }
                }
                .onChange(of: searchText) { _, _ in
                    showSearchResults = true
                }
                // Only ever opens on focus — closing here would race the click
                // that lands on a result row.
                .onChange(of: searchFocused) { _, focused in
                    if focused, !searchText.isEmpty { showSearchResults = true }
                }
                .onExitCommand { showSearchResults = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    showSearchResults = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .overlay(alignment: .topLeading) {
            if showSearchResults, !searchMatches.isEmpty {
                searchResults
                    .offset(y: 30)
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(searchMatches) { item in
                Button {
                    choose(item)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(item.type.displayName) · \(item.id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.id != searchMatches.last?.id {
                    Divider().padding(.leading, 8)
                }
            }
        }
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .shadow(radius: 8, y: 3)
    }

    private func filterChip(_ name: String, active: Bool, detail: String) -> some View {
        HStack(spacing: 3) {
            Text(active ? "\(name): \(detail)" : name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: Capsule())
        .foregroundStyle(active ? Color.accentColor : Color.primary)
    }

    private func toggleBinding<T: Hashable>(for value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { on in
                if on { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
            }
        )
    }

    /// Distinct section slugs in the scoped store, parents before children.
    private var allSections: [String] {
        let slugs = Set((scopedStore?.items ?? []).compactMap(\.section))
        let parents = Set(slugs.compactMap { $0.split(separator: "/").first.map(String.init) })
        return (slugs.union(parents)).sorted(by: TheoryItem.sectionSlugOrder)
    }

    // MARK: - Bridge

    private func wireBridge() {
        box.onMessage = { message in
            guard let type = message["type"] as? String else { return }
            let sourceScope: String? = {
                if case .source(let slug) = appState.graphScope { return slug }
                return nil
            }()
            // The settings panel keeps its own sliders; only the trace mode needs the
            // app, which is the side that knows which item is selected.
            if type == "traceMode" {
                traceMode = TraceMode(jsMode: message["mode"] as? String ?? "none")
                return
            }
            if type == "graphSettings" {
                if let values = message["values"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: values),
                   let json = String(data: data, encoding: .utf8) {
                    graphSettingsJSON = json
                }
                return
            }
            // Clicking empty canvas deselects. The app owns the trace, so without
            // this the pulses would outlive the selection that started them.
            if type == "selectionCleared" {
                if sourceScope != nil {
                    appState.selectedSourceItemID = nil
                } else {
                    appState.selectedItemID = nil
                }
                applyTrace()
                return
            }
            guard let id = message["id"] as? String else { return }
            switch type {
            case "nodeSelected":
                if sourceScope != nil {
                    appState.selectedSourceItemID = id
                } else {
                    appState.selectedItemID = id
                }
            case "nodeOpened":
                if let slug = sourceScope {
                    appState.selectedSourceSlug = slug
                    appState.selectedSourceItemID = id
                    appState.selection = .sources
                } else {
                    appState.selectedItemID = id
                    appState.selection = .library
                }
            default:
                break
            }
        }
    }

    private func pushGraph() {
        guard let store = scopedStore else { return }
        // A source's cross-references are internal; only the project scope resolves
        // external slug:item-id refs against the attached sources.
        let resolveExternal: (String) -> TheoryItem? =
            appState.graphScope == .project ? { appState.sourceItem(ref: $0) } : { _ in nil }
        guard let json = try? store.graph.webJSON(resolveExternal: resolveExternal) else { return }
        box.call("setMathMacros", store.macroDictionary)
        box.call("setGraph", json, scopeKey)
    }

    private func pushFilter() {
        box.call("applyFilter", [
            "types": typeFilter.map(\.rawValue).sorted(),
            "statuses": statusFilter.map(\.rawValue).sorted(),
            "section": sectionFilter ?? ""
        ])
    }

    private func applyTrace() {
        guard traceMode != .off, let id = scopedSelectionID else {
            box.call("highlightRelated", "", "none")
            return
        }
        box.call("highlightRelated", id, traceMode.jsMode)
    }

    // MARK: - Warnings
    // The color/solidity legend lives inside the web page (single source of truth with
    // the canvas palette); only store-level warnings stay in SwiftUI.

    private var graphCycle: [String]? { scopedStore?.graph.findCycle() }
    private var missingReferences: [DependencyGraph.Edge] {
        scopedStore?.graph.missingReferences ?? []
    }

    private var warningsBar: some View {
        HStack(spacing: 12) {
            if let cycle = graphCycle {
                Label("Circular dependency: \(cycle.joined(separator: " → "))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            let missing = missingReferences
            if !missing.isEmpty {
                Label("\(missing.count) unresolved reference(s)", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(missing.map { "\($0.from) → \($0.to)" }.joined(separator: "\n"))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
