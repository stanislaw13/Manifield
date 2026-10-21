import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The program as a lineage graph: routes as lanes, time running down, findings travelling
/// sideways between them.
///
/// Drawn with `Canvas` over a pure layout rather than reusing the dependency graph's d3 page:
/// that one is a force simulation tuned for an organic blob of theory items, and this layout is
/// deterministic (lanes × time) and has to hit-test into native detail panes.
struct MapSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let records: [String: RunRecord]

    @State private var selection: MapSelection?
    /// Dims everything a branch never knew about. The question routing exists to answer, one
    /// click away — and the reason the lateral edges are the graph's subject rather than
    /// decoration on it.
    @State private var isolatedLane: Int?
    @State private var hoveredNode: String?

    private var graph: ProgramGraph {
        ProgramGraph.build(program: program, records: records,
                           plans: Dictionary(appState.branchPlans(of: program).map { ($0.id, $0) },
                                             uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        let graph = self.graph
        return Group {
            if graph.isEmpty {
                empty
            } else {
                VStack(spacing: 0) {
                    toolbar(graph)
                    Divider()
                    HSplitView {
                        canvas(graph)
                            .frame(minWidth: 360)
                        MapInspector(program: program, selection: selection,
                                     onIsolate: { isolatedLane = $0 })
                            .frame(minWidth: 260, idealWidth: 300)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing to map yet.")
                .font(.callout).foregroundStyle(.secondary)
            Text("The map draws routes as lanes with time running down, and the findings that travelled between them. It fills in as the program runs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toolbar(_ graph: ProgramGraph) -> some View {
        HStack(spacing: 10) {
            if let isolatedLane, graph.lanes.indices.contains(isolatedLane) {
                Label("Showing what “\(graph.lanes[isolatedLane].title)” knew",
                      systemImage: "eye")
                    .font(.caption).foregroundStyle(Color.accentColor)
                Button("Show everything") { self.isolatedLane = nil }
                    .controlSize(.small)
            } else {
                Text("Select a branch to dim everything it never knew about.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MapLegend()
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func canvas(_ graph: ProgramGraph) -> some View {
        GeometryReader { geo in
            let layout = MapGeometry(graph: graph, size: geo.size)
            ScrollView([.vertical, .horizontal]) {
                Canvas { context, _ in
                    MapPainter(graph: graph, layout: layout,
                               isolated: isolatedLane, hovered: hoveredNode)
                        .paint(into: context)
                }
                .frame(width: layout.width, height: layout.height)
                .contentShape(Rectangle())
                .onTapGesture { point in
                    selection = layout.hitTest(point, graph: graph)
                    if case .lane(let index) = selection { isolatedLane = index }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if case .node(let id) = layout.hitTest(point, graph: graph) {
                            hoveredNode = id
                        } else {
                            hoveredNode = nil
                        }
                    case .ended:
                        hoveredNode = nil
                    }
                }
            }
        }
    }
}

/// What the user clicked.
enum MapSelection: Equatable {
    case lane(Int)
    case node(String)
}

// MARK: - Geometry

/// Domain coordinates to pixels. Split from the painter so hit-testing and drawing cannot
/// disagree about where anything is.
struct MapGeometry {
    let laneSpacing: CGFloat = 190
    let leftInset: CGFloat = 90
    let topInset: CGFloat = 64
    let bottomInset: CGFloat = 40
    /// Time is stretched to at least this so a short run is not squashed into a line, and grows
    /// with the number of events so a long one stays legible.
    let timeHeight: CGFloat

    let width: CGFloat
    let height: CGFloat
    private let graph: ProgramGraph

    init(graph: ProgramGraph, size: CGSize) {
        self.graph = graph
        let events = graph.nodes.count + graph.boundaries.count
        timeHeight = max(360, min(2400, CGFloat(events) * 54 + 240))
        width = max(size.width,
                    leftInset + CGFloat(max(graph.lanes.count, 1)) * laneSpacing + 60)
        height = topInset + timeHeight + bottomInset
    }

    func x(ofLane index: Int) -> CGFloat {
        leftInset + CGFloat(index) * laneSpacing
    }

    func y(at date: Date) -> CGFloat {
        topInset + CGFloat(graph.fraction(of: date)) * timeHeight
    }

    /// Lane headers first (they sit above the time axis), then nodes, then lanes. Nodes win
    /// over lanes because a node always sits on one.
    func hitTest(_ point: CGPoint, graph: ProgramGraph) -> MapSelection? {
        for node in graph.nodes {
            let centre = CGPoint(x: x(ofLane: node.laneIndex), y: y(at: node.at))
            if hypot(point.x - centre.x, point.y - centre.y) < 13 {
                return .node(node.id)
            }
        }
        for index in graph.lanes.indices {
            if abs(point.x - x(ofLane: index)) < 26 { return .lane(index) }
        }
        return nil
    }
}

// MARK: - Painting

private struct MapPainter {
    let graph: ProgramGraph
    let layout: MapGeometry
    let isolated: Int?
    let hovered: String?

    /// Lanes a finding actually reached, plus the isolated lane itself. Everything else dims.
    private var visibleLanes: Set<Int> {
        guard let isolated else { return Set(graph.lanes.indices) }
        var lanes: Set<Int> = [isolated]
        for edge in graph.edges where edge.toLane == isolated { lanes.insert(edge.fromLane) }
        return lanes
    }

    private func alpha(forLane index: Int) -> Double {
        isolated == nil || visibleLanes.contains(index) ? 1 : 0.16
    }

    func paint(into context: GraphicsContext) {
        paintBoundaries(context)
        paintLineage(context)
        paintLanes(context)
        paintEdges(context)
        paintNodes(context)
        paintHeaders(context)
    }

    private func paintBoundaries(_ context: GraphicsContext) {
        for boundary in graph.boundaries {
            let y = layout.y(at: boundary.at)
            var path = Path()
            path.move(to: CGPoint(x: 16, y: y))
            path.addLine(to: CGPoint(x: layout.width - 16, y: y))
            context.stroke(path, with: .color(.accentColor.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            context.draw(Text(boundary.label).font(.caption2).foregroundStyle(.tint),
                         at: CGPoint(x: 20, y: y - 9), anchor: .topLeading)
        }
    }

    /// Where a route came from. Dashed, because lineage is a relationship rather than a flow of
    /// work — nothing travels along it.
    private func paintLineage(_ context: GraphicsContext) {
        for (index, lane) in graph.lanes.enumerated() {
            guard let start = lane.startedAt else { continue }
            for parent in lane.parentLaneIndices {
                let from = CGPoint(x: layout.x(ofLane: parent),
                                   y: layout.y(at: start) - 26)
                let to = CGPoint(x: layout.x(ofLane: index), y: layout.y(at: start))
                var path = Path()
                path.move(to: from)
                path.addCurve(to: to,
                              control1: CGPoint(x: from.x, y: (from.y + to.y) / 2),
                              control2: CGPoint(x: to.x, y: (from.y + to.y) / 2))
                context.stroke(path,
                               with: .color(.accentColor.opacity(0.6 * alpha(forLane: index))),
                               style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
            }
        }
    }

    private func paintLanes(_ context: GraphicsContext) {
        for (index, lane) in graph.lanes.enumerated() {
            let x = layout.x(ofLane: index)
            let opacity = alpha(forLane: index)
            let top = lane.startedAt.map { layout.y(at: $0) } ?? layout.topInset
            let bottom = lane.endedAt.map { layout.y(at: $0) } ?? top

            // The spine: faint for the whole window, solid where the branch actually worked.
            var spine = Path()
            spine.move(to: CGPoint(x: x, y: layout.topInset))
            spine.addLine(to: CGPoint(x: x, y: layout.topInset + layout.timeHeight))
            context.stroke(spine, with: .color(.secondary.opacity(0.15 * opacity)),
                           lineWidth: 1)

            if bottom > top {
                var worked = Path()
                worked.move(to: CGPoint(x: x, y: top))
                worked.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(worked,
                               with: .color(color(for: lane.status).opacity(opacity)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }

            // Task boundaries as texture, not as nodes: a dozen per branch, carrying no
            // relational information, would be a dozen hit targets that say nothing.
            for tick in lane.taskTicks {
                let y = layout.y(at: tick.at)
                var mark = Path()
                mark.move(to: CGPoint(x: x - 7, y: y))
                mark.addLine(to: CGPoint(x: x + 7, y: y))
                context.stroke(mark,
                               with: .color((tick.completed ? Color.white : Color.orange)
                                   .opacity((tick.completed ? 0.55 : 0.9) * opacity)),
                               lineWidth: 1.5)
            }

            // Start cap.
            if lane.startedAt != nil {
                context.stroke(Path(ellipseIn: CGRect(x: x - 5, y: top - 5, width: 10, height: 10)),
                               with: .color(color(for: lane.status).opacity(opacity)),
                               lineWidth: 2.4)
            }
        }
    }

    private func paintEdges(_ context: GraphicsContext) {
        for edge in graph.edges {
            let opacity = min(alpha(forLane: edge.fromLane), alpha(forLane: edge.toLane))
            let from = CGPoint(x: layout.x(ofLane: edge.fromLane), y: layout.y(at: edge.at))
            let to = CGPoint(x: layout.x(ofLane: edge.toLane), y: layout.y(at: edge.at) + 22)
            var path = Path()
            path.move(to: from)
            path.addCurve(to: to,
                          control1: CGPoint(x: (from.x + to.x) / 2, y: from.y),
                          control2: CGPoint(x: (from.x + to.x) / 2, y: to.y))
            context.stroke(path, with: .color(.teal.opacity(0.85 * opacity)), lineWidth: 1.6)
            // Arrow head at the receiving lane.
            var head = Path()
            head.move(to: CGPoint(x: to.x, y: to.y))
            head.addLine(to: CGPoint(x: to.x - 4, y: to.y - 6))
            head.addLine(to: CGPoint(x: to.x + 4, y: to.y - 6))
            head.closeSubpath()
            context.fill(head, with: .color(.teal.opacity(0.85 * opacity)))
        }
    }

    private func paintNodes(_ context: GraphicsContext) {
        for node in graph.nodes {
            let centre = CGPoint(x: layout.x(ofLane: node.laneIndex), y: layout.y(at: node.at))
            let opacity = alpha(forLane: node.laneIndex)
            let isHovered = hovered == node.id
            let tint = color(for: node.kind).opacity(opacity)

            switch node.kind {
            case .finding(_, let decision):
                let size: CGFloat = isHovered ? 13 : 10
                var diamond = Path()
                diamond.move(to: CGPoint(x: centre.x, y: centre.y - size / 2))
                diamond.addLine(to: CGPoint(x: centre.x + size / 2, y: centre.y))
                diamond.addLine(to: CGPoint(x: centre.x, y: centre.y + size / 2))
                diamond.addLine(to: CGPoint(x: centre.x - size / 2, y: centre.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(tint))
                // A held finding gets a stub that ends in a bar and reaches nothing — the
                // visual form of a decision to withhold.
                if decision == .hold {
                    var stub = Path()
                    stub.move(to: CGPoint(x: centre.x + 8, y: centre.y))
                    stub.addLine(to: CGPoint(x: centre.x + 34, y: centre.y))
                    context.stroke(stub, with: .color(.orange.opacity(0.9 * opacity)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    var bar = Path()
                    bar.move(to: CGPoint(x: centre.x + 34, y: centre.y - 6))
                    bar.addLine(to: CGPoint(x: centre.x + 34, y: centre.y + 6))
                    context.stroke(bar, with: .color(.orange.opacity(0.9 * opacity)),
                                   lineWidth: 2.2)
                }

            case .libraryChange(_, let downgrade):
                let size: CGFloat = isHovered ? 11 : 8
                let rect = CGRect(x: centre.x - size / 2, y: centre.y - size / 2,
                                  width: size, height: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint))
                if downgrade {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3),
                                        cornerRadius: 3),
                                   with: .color(.orange.opacity(opacity)), lineWidth: 1.2)
                }

            case .claim:
                let r: CGFloat = isHovered ? 11 : 9
                context.fill(star(at: centre, radius: r), with: .color(tint))

            case .routeClosed(let status):
                if status == .falsified {
                    var cross = Path()
                    cross.move(to: CGPoint(x: centre.x - 7, y: centre.y - 7))
                    cross.addLine(to: CGPoint(x: centre.x + 7, y: centre.y + 7))
                    cross.move(to: CGPoint(x: centre.x + 7, y: centre.y - 7))
                    cross.addLine(to: CGPoint(x: centre.x - 7, y: centre.y + 7))
                    context.stroke(cross, with: .color(tint),
                                   style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - 6, y: centre.y - 6,
                                                        width: 12, height: 12)),
                                 with: .color(tint))
                }
            }

            if isHovered {
                context.draw(
                    Text(node.label.prefix(70)).font(.caption2),
                    at: CGPoint(x: centre.x + 16, y: centre.y - 14), anchor: .topLeading)
            }
        }
    }

    private func paintHeaders(_ context: GraphicsContext) {
        for (index, lane) in graph.lanes.enumerated() {
            let x = layout.x(ofLane: index)
            let opacity = alpha(forLane: index)
            context.draw(
                Text(lane.title).font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(opacity)),
                at: CGPoint(x: x, y: 16), anchor: .top)
            var subtitle = "gen \(lane.generation)"
            if lane.tokensSpent > 0 { subtitle += " · \(lane.tokensSpent / 1000)k" }
            if lane.challengesLeadingAnswer { subtitle += " · challenger" }
            context.draw(
                Text(subtitle).font(.caption2)
                    .foregroundStyle(.secondary.opacity(opacity)),
                at: CGPoint(x: x, y: 34), anchor: .top)
        }
    }

    private func star(at centre: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for point in 0..<10 {
            let angle = Double(point) * .pi / 5 - .pi / 2
            let r = point.isMultiple(of: 2) ? radius : radius * 0.45
            let position = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            if point == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }

    private func color(for status: ResearchRoute.Status) -> Color {
        switch status {
        case .proposed: return .gray
        case .active: return .accentColor
        case .blocked: return .orange
        case .falsified: return .red
        case .merged: return .purple
        case .proved: return .green
        }
    }

    private func color(for kind: ProgramGraph.Node.Kind) -> Color {
        switch kind {
        case .finding(_, let decision):
            switch decision {
            case .some(.hold): return .orange
            case .some(.doNotSend): return .secondary
            case .some(.sendNow), .some(.global): return .teal
            case nil: return .orange.opacity(0.7)
            }
        case .libraryChange(_, let downgrade): return downgrade ? .orange : .indigo
        case .claim(let status): return ClaimStyle.color(status)
        case .routeClosed(let status): return status == .falsified ? .red : .green
        }
    }
}

// MARK: - Inspector

/// What the selected lane or node is. Reuses the vocabulary of the Evidence pane rather than
/// inventing a second one for the same objects.
private struct MapInspector: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let selection: MapSelection?
    let onIsolate: (Int?) -> Void

    private var graph: ProgramGraph {
        ProgramGraph.build(program: program,
                           records: Dictionary(program.branches.compactMap { branch in
                               appState.research.pendingRecord(for: branch.planID)
                                   .map { (branch.planID, $0) }
                           }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch selection {
                case .lane(let index):
                    laneDetail(index)
                case .node(let id):
                    nodeDetail(id)
                case nil:
                    Text("Click a lane or a node.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func laneDetail(_ index: Int) -> some View {
        let graph = self.graph
        if graph.lanes.indices.contains(index) {
            let lane = graph.lanes[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(lane.title).font(.headline)
                    if lane.challengesLeadingAnswer {
                        ChallengerChip(challengesLeadingAnswer: true, compact: true)
                    }
                }
                RenderedMath(markdown: lane.mechanism, id: "lane-\(lane.id)")
                HStack(spacing: 8) {
                    Text(lane.status.displayName).font(.caption)
                        .foregroundStyle(lane.isClosed ? .secondary : .primary)
                    Text("generation \(lane.generation)").font(.caption)
                        .foregroundStyle(.secondary)
                    if lane.tokensSpent > 0 {
                        Text("\(lane.tokensSpent / 1000)k tokens")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text("\(lane.taskTicks.filter(\.completed).count)/\(lane.taskTicks.count) tasks completed")
                    .font(.caption).foregroundStyle(.secondary)
                if let planID = lane.planID {
                    Button("Open this branch") {
                        appState.researchPage = .branch(programID: program.id, planID: planID)
                    }
                    .controlSize(.small)
                }
                Button("Show everything again") { onIsolate(nil) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func nodeDetail(_ id: String) -> some View {
        if let node = graph.nodes.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                RenderedMath(markdown: node.label, id: "node-\(node.id)")
                Text(node.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)

                switch node.kind {
                case .finding(let kind, let decision):
                    Text(kind.displayName).font(.caption)
                        .foregroundStyle(FindingStyle.color(kind))
                    if let routing = program.routing(forFinding: node.subjectID) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routing.decision.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(RoutingStyle.color(routing.decision))
                            if !routing.rationale.isEmpty {
                                RenderedMath(markdown: routing.rationale, id: "map-rationale-\(node.id)")
                            }
                        }
                    } else if decision == nil {
                        Text("Not routed — this reaches nobody until the director decides.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .libraryChange:
                    Button("Open in the library") {
                        appState.selectedItemID = node.subjectID
                        appState.selection = .library
                    }
                    .controlSize(.small)

                case .claim(let status):
                    Text(status.displayName).font(.caption)
                        .foregroundStyle(ClaimStyle.color(status))
                    if let candidate = program.solutions.first(where: { $0.id == node.subjectID }) {
                        ClaimChain(candidate: candidate)
                    }

                case .routeClosed:
                    Text("This route ended here.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MapLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(.teal, "routed")
            item(.orange, "held")
            item(.indigo, "library")
            item(.red, "falsified")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}
