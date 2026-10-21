import SwiftUI
import AppKit
import ManifieldCore
import ManifieldAgents

// MARK: - Navigation

/// Where a click inside one tab of a program page can take you. The page owns the tab and
/// selection state; a row or a chip only asks to go somewhere, so every count, title and
/// evidence reference can be a link without each view knowing how the page is built.
struct ResearchNavigation {
    var openAssignment: (String) -> Void = { _ in }
    /// Opens one evidence entry by its `EvidenceEntry.id`.
    var openEvidence: (String) -> Void = { _ in }
    var showEvidence: (EvidenceFilter) -> Void = { _ in }
    var openLibraryItem: (String) -> Void = { _ in }

    func open(_ reference: ResearchReference) {
        switch reference {
        case .item(let id): openLibraryItem(id)
        case .assignment(let id): openAssignment(id)
        case .finding(let id): openEvidence("finding:\(id)")
        case .claim(let id): openEvidence("claim:\(id)")
        case .challenge(let id): openEvidence("challenge:\(id)")
        case .unknown: break
        }
    }
}

/// A bare ID from a report or a ruling, resolved to the thing it names. Reports cite library
/// items, findings, claims and challenges interchangeably in one array; a reader wants the
/// name, and a click that goes there.
enum ResearchReference: Hashable {
    case item(String), assignment(String), finding(String), claim(String), challenge(String), unknown(String)

    static func resolve(_ id: String, in program: ResearchProgram, store: ProjectStore?) -> ResearchReference {
        if program.challenges.contains(where: { $0.id == id }) { return .challenge(id) }
        if program.solutions.contains(where: { $0.id == id }) { return .claim(id) }
        if program.findings.contains(where: { $0.id == id }) { return .finding(id) }
        if program.assignment(id: id) != nil { return .assignment(id) }
        if store?.item(id: id) != nil { return .item(id) }
        return .unknown(id)
    }

    var id: String {
        switch self {
        case .item(let id), .assignment(let id), .finding(let id), .claim(let id),
             .challenge(let id), .unknown(let id):
            return id
        }
    }

    var isNavigable: Bool {
        if case .unknown = self { return false }
        return true
    }

    var kindName: String {
        switch self {
        case .item: return "Library item"
        case .assignment: return "Assignment"
        case .finding: return "Finding"
        case .claim: return "Solution claim"
        case .challenge: return "Problem challenge"
        case .unknown: return "Reference"
        }
    }

    var systemImage: String {
        switch self {
        case .item: return "doc.text"
        case .assignment: return "square.stack.3d.up"
        case .finding: return "lightbulb"
        case .claim: return "star"
        case .challenge: return "exclamationmark.bubble"
        case .unknown: return "number"
        }
    }

    var tint: Color {
        switch self {
        case .item, .unknown: return .secondary
        case .assignment: return .blue
        case .finding: return .yellow
        case .claim: return .orange
        case .challenge: return .pink
        }
    }

    func label(in program: ResearchProgram, store: ProjectStore?) -> String {
        switch self {
        case .item(let id):
            return ResearchText.clamp(store?.item(id: id)?.name ?? id, maxLength: 56)
        case .assignment(let id):
            return ResearchText.clamp(program.assignment(id: id)?.displayTitle ?? id, maxLength: 56)
        case .finding(let id):
            return program.findings.first { $0.id == id }
                .map { ResearchText.headline($0.statement, maxLength: 56) } ?? id
        case .claim(let id):
            guard let claim = program.solutions.first(where: { $0.id == id }) else { return id }
            return "Claim · " + ResearchText.clamp(store?.item(id: claim.primaryItemID)?.name ?? claim.primaryItemID, maxLength: 48)
        case .challenge(let id):
            return program.challenges.first { $0.id == id }
                .map { "Challenge · " + ResearchText.headline($0.description, maxLength: 44) } ?? id
        case .unknown(let id):
            return ResearchIDText.short(id)
        }
    }
}

enum ResearchIDText {
    /// A UUID is unreadable at a glance; its first block is enough to tell two apart.
    static func short(_ id: String) -> String {
        id.count == 36 && id.filter({ $0 == "-" }).count == 4 ? String(id.prefix(8)) : id
    }

    /// Generated summaries name records by full UUID ("Filed problem challenge 519922C3-…");
    /// in running text the first block reads as a reference without drowning the sentence.
    static func shortenUUIDs(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\b([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            with: "$1", options: .regularExpression)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ResearchProgram {
    /// The human name of whatever filed a record: an assignment's title for persistent
    /// programs, a branch title for legacy ones, never a raw UUID when anything better exists.
    func workTitle(for id: String) -> String {
        assignment(id: id)?.displayTitle ?? branch(planID: id)?.title ?? ResearchIDText.short(id)
    }
}

// MARK: - Formatting

extension Int {
    /// 299 626 → "299.6K". For glanceable spend; the exact figure sits one level deeper.
    var compactTokens: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

/// Live counts over a program's assignments — what makes "2 assignments" read as
/// "2 assignments · 1 running" everywhere they are counted.
struct AssignmentCounts {
    var total = 0, running = 0, queued = 0, paused = 0, finished = 0, stopped = 0, errored = 0

    init(_ assignments: [ResearchAssignment]) {
        total = assignments.count
        for assignment in assignments {
            switch assignment.status {
            case .running: running += 1
            case .queued: queued += 1
            case .paused: paused += 1
            case .finished: finished += 1
            case .stopped: stopped += 1
            case .errored: errored += 1
            }
        }
    }

    var inFlight: Int { running + queued }

    /// "1 running · 2 queued", or how the work ended when nothing is in flight.
    var activitySummary: String? {
        guard total > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if paused > 0 { parts.append("\(paused) paused") }
        if errored > 0 { parts.append("\(errored) errored") }
        if parts.isEmpty { return finished == total ? "all finished" : "\(finished) finished" }
        return parts.joined(separator: " · ")
    }
}

extension Array where Element == ResearchAssignment {
    /// Live work first, then everything else newest first.
    var prioritized: [ResearchAssignment] {
        enumerated().sorted { lhs, rhs in
            if lhs.element.status.rank != rhs.element.status.rank {
                return lhs.element.status.rank < rhs.element.status.rank
            }
            return lhs.offset > rhs.offset
        }.map(\.element)
    }
}

// MARK: - Styles

extension ResearchAssignment.Status {
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .errored: return "Errored"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "circle.dashed"
        case .running: return "circle.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .errored: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queued: return .secondary
        case .running: return .blue
        case .paused: return .orange
        case .finished: return .green
        case .stopped: return .secondary
        case .errored: return .red
        }
    }

    var isActive: Bool { self == .running || self == .queued || self == .paused }

    fileprivate var rank: Int {
        switch self {
        case .running: return 0
        case .queued: return 1
        case .paused: return 2
        case .errored: return 3
        case .finished, .stopped: return 4
        }
    }
}

extension AssignmentReport.Outcome {
    var label: String {
        switch self {
        case .achieved: return "Achieved"
        case .partial: return "Partial progress"
        case .unresolved: return "Unresolved"
        }
    }

    var systemImage: String {
        switch self {
        case .achieved: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .unresolved: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .achieved: return .green
        case .partial: return .blue
        case .unresolved: return .secondary
        }
    }
}

extension AssignmentReport.StopReason {
    var label: String {
        switch self {
        case .completed: return "Finished"
        case .review: return "Submitted for review"
        case .question: return "Asked a question"
        case .tokenLimit: return "Token allocation spent"
        case .toolLimit: return "Tool-call limit"
        case .timeLimit: return "Time limit"
        case .stopped: return "Stopped"
        case .interrupted: return "Interrupted"
        case .error: return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .completed: return "flag.checkered"
        case .review: return "checkmark.seal"
        case .question: return "questionmark.bubble"
        case .tokenLimit: return "gauge.high"
        case .toolLimit: return "wrench.and.screwdriver"
        case .timeLimit: return "clock"
        case .stopped: return "stop.circle"
        case .interrupted: return "bolt.horizontal"
        case .error: return "exclamationmark.triangle"
        }
    }
}

extension ResearchProgramEvent.Kind {
    var label: String {
        switch self {
        case .dispatched: return "Dispatched"
        case .started: return "Started"
        case .reported: return "Reported"
        case .evidence: return "Evidence filed"
        case .reviewed: return "Reviewed"
        case .guidance: return "Guidance"
        case .stopped: return "Stopped"
        case .targetChanged: return "Goal revised"
        case .directorPaused: return "Director paused"
        }
    }

    var systemImage: String {
        switch self {
        case .dispatched: return "paperplane.fill"
        case .started: return "play.fill"
        case .reported: return "doc.text.fill"
        case .evidence: return "tray.and.arrow.down.fill"
        case .reviewed: return "checkmark.seal.fill"
        case .guidance: return "bubble.left.fill"
        case .stopped: return "stop.fill"
        case .targetChanged: return "target"
        case .directorPaused: return "pause.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dispatched, .started: return .blue
        case .reported: return .indigo
        case .evidence: return .purple
        case .reviewed: return .green
        case .guidance: return .teal
        case .stopped: return .secondary
        case .targetChanged, .directorPaused: return .orange
        }
    }
}

extension ResearchProgramEvent {
    var tint: Color {
        kind == .reviewed && summary.localizedCaseInsensitiveContains("rejected") ? .red : kind.tint
    }
}

// MARK: - Building blocks

struct ResearchCardModifier: ViewModifier {
    var padding: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        let base = tint ?? .primary
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(base.opacity(tint == nil ? 0.04 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(base.opacity(tint == nil ? 0.08 : 0.22), lineWidth: 1))
    }
}

extension View {
    func researchCard(padding: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(ResearchCardModifier(padding: padding, tint: tint))
    }

    /// Keeps macOS's overlay scroller in a dedicated gutter instead of drawing it over
    /// cards or selectable text. The indicator stays at the viewport edge; only the
    /// scrollable content is inset.
    func researchScrollGutter() -> some View {
        contentMargins(.trailing, 16, for: .scrollContent)
    }
}

struct ResearchChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
        .foregroundStyle(tint)
        .fixedSize()
    }
}

struct PulsingDot: View {
    var tint: Color = .green
    var size: CGFloat = 7
    @State private var pulsing = false

    var body: some View {
        Circle().fill(tint)
            .frame(width: size, height: size)
            .background(
                Circle().fill(tint.opacity(0.45))
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 1))
            .onAppear {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            PulsingDot(tint: .green, size: 6)
            Text("Live")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.green.opacity(0.13)))
        .fixedSize()
    }
}

struct AssignmentStatusIcon: View {
    let status: ResearchAssignment.Status
    var live = false

    var body: some View {
        Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .running && live)
    }
}

struct ResearchSectionHeader: View {
    let title: String
    var count: Int? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let count {
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tint)
            }
        }
    }
}

/// A titled card, for the stacked sections of a detail pane.
struct DetailSection<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .researchCard()
        }
    }
}

/// A count that is also the way to its detail — the Overview's tiles open the tab that
/// lists what they count, already filtered.
struct MetricTile: View {
    let value: String
    let label: String
    var detail: String?
    var detailTint: Color
    let systemImage: String
    var pulsing: Bool
    var action: (() -> Void)?

    @State private var hovering = false

    init(value: String, label: String, detail: String? = nil, detailTint: Color = .secondary,
         systemImage: String, pulsing: Bool = false, action: (() -> Void)? = nil) {
        self.value = value; self.label = label; self.detail = detail; self.detailTint = detailTint
        self.systemImage = systemImage; self.pulsing = pulsing; self.action = action
    }

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                    Text(label).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if action != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 5) {
                    if pulsing { PulsingDot(tint: detailTint, size: 6) }
                    Text(detail ?? " ").font(.caption).foregroundStyle(detailTint).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { hovering = action != nil && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A full-width clickable row with a hover wash and a trailing chevron.
struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.35)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Plain generated text that stays a few lines until asked — native, so a list of fifty
/// events costs no web views. Offers "Show more" only when the text is actually cut.
struct ExpandableText: View {
    @EnvironmentObject private var appState: AppState
    let text: String
    var lineLimit = 3
    var fontSize: CGFloat = NSFont.systemFontSize - 1

    @State private var expanded = false
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var macros: [String: String] { appState.store?.macroDictionary ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ItemNameText(name: text, macros: macros, fontSize: fontSize, lineLimit: expanded ? 400 : lineLimit)
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    ItemNameText(name: text, macros: macros, fontSize: fontSize, lineLimit: 400)
                        .font(.system(size: fontSize))
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if expanded || fullHeight > shownHeight + 1 {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }
        }
    }
}

/// Wraps its children onto as many lines as they need — for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if x > 0, x + width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, bounds.width)
            if x > bounds.minX, x + width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX; lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
            x += width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct ReferenceChip: View {
    @EnvironmentObject private var appState: AppState
    let id: String
    let program: ResearchProgram
    let navigation: ResearchNavigation

    @State private var hovering = false

    var body: some View {
        let reference = ResearchReference.resolve(id, in: program, store: appState.store)
        Button { navigation.open(reference) } label: {
            HStack(spacing: 4) {
                Image(systemName: reference.systemImage).imageScale(.small).foregroundStyle(reference.tint)
                ItemNameText(name: reference.label(in: program, store: appState.store),
                             macros: appState.store?.macroDictionary ?? [:],
                             fontSize: NSFont.smallSystemFontSize, lineLimit: 1)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hovering && reference.isNavigable ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(reference.kindName) · \(id)")
        .contextMenu {
            Button("Copy ID") { ResearchIDText.copy(id) }
        }
    }
}

struct ReferenceList: View {
    let title: String
    let ids: [String]
    let program: ResearchProgram
    let navigation: ResearchNavigation

    private var unique: [String] {
        ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(unique, id: \.self) { ReferenceChip(id: $0, program: program, navigation: navigation) }
            }
        }
    }
}

/// "Filed by": the assignment's title, as a link to it.
struct WorkLink: View {
    let id: String
    let program: ResearchProgram
    let navigation: ResearchNavigation

    var body: some View {
        if let assignment = program.assignment(id: id) {
            Button { navigation.openAssignment(assignment.id) } label: {
                Label(assignment.displayTitle, systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.link)
            .font(.callout)
        } else {
            Text(program.workTitle(for: id)).font(.callout)
        }
    }
}

// MARK: - Rows

struct AssignmentRow: View {
    @EnvironmentObject private var appState: AppState
    let assignment: ResearchAssignment
    let tokens: Int
    let live: Bool

    private var macros: [String: String] { appState.store?.macroDictionary ?? [:] }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            AssignmentStatusIcon(status: assignment.status, live: live)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                ItemNameText(name: assignment.displayTitle, macros: macros, lineLimit: 1)
                    .font(.body.weight(.medium))
                if let report = assignment.latestReport {
                    ItemNameText(name: report.displayHeadline, macros: macros,
                                 fontSize: NSFont.smallSystemFontSize, lineLimit: 2)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Text(assignment.status.label).foregroundStyle(assignment.status.tint)
                    Text("·")
                    Text(assignment.mode == .direct ? "Direct" : "Planned")
                    if tokens > 0 {
                        Text("·")
                        Text("\(tokens.compactTokens) tokens").monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ProgramEventRow: View {
    @EnvironmentObject private var appState: AppState
    let event: ResearchProgramEvent
    let program: ResearchProgram
    let navigation: ResearchNavigation
    var lineLimit = 2
    var showsAssignment = true
    /// Draws the timeline rail down to the next row.
    var connectsBelow = false

    /// A "started" event repeats the objective its "dispatched" event already showed.
    private var summary: String? {
        if event.kind == .started, let id = event.assignmentID,
           program.assignment(id: id)?.objective == event.summary {
            return nil
        }
        return ResearchIDText.shortenUUIDs(in: event.summary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(event.tint.opacity(0.16))
                Image(systemName: event.kind.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(event.tint)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.kind.label).font(.callout.weight(.semibold))
                    if showsAssignment, let id = event.assignmentID, let assignment = program.assignment(id: id) {
                        Button { navigation.openAssignment(assignment.id) } label: {
                            ItemNameText(name: assignment.displayTitle,
                                         macros: appState.store?.macroDictionary ?? [:],
                                         fontSize: NSFont.smallSystemFontSize, lineLimit: 1)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help("Open this assignment")
                    }
                    Spacer(minLength: 8)
                    Text(event.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(event.createdAt.formatted(date: .abbreviated, time: .standard))
                        .fixedSize()
                }
                if let summary {
                    ExpandableText(text: summary, lineLimit: lineLimit)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, connectsBelow ? 14 : 2)
        }
        .background(alignment: .topLeading) {
            if connectsBelow {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1.5)
                    .padding(.top, 25)
                    .padding(.leading, 10.25)
            }
        }
    }
}

/// The raw stream of the running director and its workers. Deliberately monospaced and
/// unrendered: it is a console, not prose.
struct LiveConsole: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                PulsingDot(tint: .green, size: 6)
                Text("Live output").font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty ? "Waiting for output…" : text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("console-end")
                    }
                }
                .onAppear { proxy.scrollTo("console-end", anchor: .bottom) }
                .onChange(of: text) { _, _ in proxy.scrollTo("console-end", anchor: .bottom) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
