import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The first thing a program page shows: where the work stands and whether it needs you,
/// then live counts that each open the tab holding their detail, then the latest work and
/// activity as short rows rather than paragraphs.
struct PersistentOverviewTab: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    let live: Bool
    let usage: ProgramUsageSummary
    let assignmentTokens: [String: Int]
    let contextTokens: Int
    let navigation: ResearchNavigation
    let openTab: (PersistentProgramPage.ProgramTab) -> Void
    let openLimits: () -> Void

    @State private var guidance = ""
    @State private var width: CGFloat = 900

    private var execution: ResearchExecution { program.execution! }
    private var counts: AssignmentCounts { AssignmentCounts(execution.assignments) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                standing
                metrics
                let columns = width > 780
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
                columns {
                    assignmentsPreview.frame(maxWidth: .infinity, alignment: .topLeading)
                    activityPreview.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                spend
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .researchScrollGutter()
    }

    // MARK: Where it stands

    private enum Standing { case answered, invalid, unresolved, working, needsYou, stopped }

    private var standingKind: Standing {
        if let resolution = execution.resolution {
            switch resolution.kind {
            case .answered: return .answered
            case .invalidTarget: return .invalid
            case .unresolved: return .unresolved
            }
        }
        if live { return .working }
        return program.status == .paused ? .needsYou : .stopped
    }

    private var standingStyle: (title: String, systemImage: String, tint: Color) {
        switch standingKind {
        case .answered: return ("Answered", "checkmark.seal.fill", .green)
        case .invalid: return ("The goal as stated is invalid", "exclamationmark.triangle.fill", .orange)
        case .unresolved: return ("Concluded without an answer", "flag.checkered", .secondary)
        case .working: return ("The director is working", "sparkles", .blue)
        case .needsYou: return ("Waiting for you", "hand.raised.fill", .orange)
        case .stopped: return ("Not running", "pause.circle.fill", .secondary)
        }
    }

    private var pauseEvent: ResearchProgramEvent? {
        execution.events.last { $0.kind == .directorPaused }
    }

    private var standing: some View {
        let style = standingStyle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: style.systemImage)
                    .font(.title2)
                    .foregroundStyle(style.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: live)
                Text(style.title).font(.title3.weight(.semibold))
                Spacer()
                if let date = execution.resolution?.createdAt ?? execution.events.last?.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            switch standingKind {
            case .answered, .invalid, .unresolved:
                if let resolution = execution.resolution {
                    CollapsibleMath(markdown: resolution.explanation, id: "resolution-\(program.id)", collapsedHeight: 92)
                    if !resolution.evidenceIDs.isEmpty {
                        ReferenceList(title: "Decided by", ids: resolution.evidenceIDs, program: program, navigation: navigation)
                    }
                }
            case .needsYou:
                if let pauseEvent {
                    CollapsibleMath(markdown: pauseEvent.summary, id: "pause-\(program.id)-\(pauseEvent.sequence)", collapsedHeight: 92)
                }
                composer(placeholder: "Answer the director or tell it where to go next…",
                         footnote: "Sending resumes the program with your message.")
            case .working:
                if let latest = execution.events.last {
                    ProgramEventRow(event: latest, program: program, navigation: navigation, lineLimit: 2)
                } else {
                    Text("Reading the goal and choosing the first piece of work.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                composer(placeholder: "Guide the director…",
                         footnote: "Delivered at the director's next step; running work is not interrupted.")
            case .stopped:
                Text(execution.events.isEmpty
                     ? "The director has not started yet. Continue to begin, or send guidance to begin with it."
                     : "The program is not running. Continue to resume, or send guidance to resume with it.")
                    .font(.callout).foregroundStyle(.secondary)
                composer(placeholder: "Guidance for the director…",
                         footnote: "Sending resumes the program with your message.")
            }
        }
        .researchCard(padding: 16, tint: standingKind == .stopped || standingKind == .unresolved ? nil : style.tint)
    }

    private func composer(placeholder: String, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $guidance, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14)))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 25))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                .disabled(!canSend)
                .help(live ? "Send to the director" : "Send and resume the director")
                .padding(.bottom, 3)
            }
            Text(research.isRunning && !live
                 ? "Another program is running. Guidance can be sent once it stops."
                 : footnote)
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var canSend: Bool {
        !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && execution.resolution == nil && (!research.isRunning || live)
    }

    private func send() {
        let text = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        research.guidePersistentProgram(program, text: text)
        guidance = ""
    }

    // MARK: Counts

    /// Adaptive grids reserve an empty sixth track on wide screens because there are only
    /// five metrics. Explicit rows keep both their left and right edges aligned with every
    /// other card while still giving labels enough room in the narrow layout.
    private var metrics: some View {
        Group {
            if width >= 900 {
                HStack(spacing: 12) {
                    assignmentsMetric
                    findingsMetric
                    claimsMetric
                    challengesMetric
                    tokensMetric
                }
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        assignmentsMetric
                        findingsMetric
                        claimsMetric
                    }
                    HStack(spacing: 12) {
                        challengesMetric
                        tokensMetric
                    }
                }
            }
        }
    }

    private var assignmentsMetric: some View {
        MetricTile(value: "\(counts.total)", label: "Assignments",
                   detail: counts.activitySummary ?? "none yet",
                   detailTint: counts.running > 0 ? .blue : .secondary,
                   systemImage: "square.stack.3d.up",
                   pulsing: live && counts.running > 0) { openTab(.assignments) }
    }

    private var findingsMetric: some View {
        MetricTile(value: "\(program.findings.count)", label: "Findings",
                   detail: findingsDetail, systemImage: "lightbulb") {
            navigation.showEvidence(.findings)
        }
    }

    private var claimsMetric: some View {
        MetricTile(value: "\(program.solutions.count)", label: "Solution claims",
                   detail: claimsDetail.text, detailTint: claimsDetail.tint,
                   systemImage: "star") { navigation.showEvidence(.claims) }
    }

    private var challengesMetric: some View {
        MetricTile(value: "\(program.challenges.count)", label: "Challenges",
                   detail: challengesDetail.text, detailTint: challengesDetail.tint,
                   systemImage: "exclamationmark.bubble") {
            navigation.showEvidence(.challenges)
        }
    }

    private var tokensMetric: some View {
        MetricTile(value: usage.totalTokens.compactTokens, label: "Tokens",
                   detail: tokensDetail.text, detailTint: tokensDetail.tint,
                   systemImage: "gauge.medium") { openLimits() }
    }

    private var findingsDetail: String {
        guard let latest = program.findings.map(\.createdAt).max() else { return "none yet" }
        return "latest " + latest.formatted(.relative(presentation: .named))
    }

    private var claimsDetail: (text: String, tint: Color) {
        let accepted = program.solutions.filter { $0.status == .accepted }.count
        let pending = program.solutions.filter { [.filed, .contractChecking, .underReview].contains($0.status) }.count
        if accepted > 0 { return ("\(accepted) accepted", .green) }
        if pending > 0 { return ("\(pending) in review", .orange) }
        return (program.solutions.isEmpty ? "none yet" : "none accepted", .secondary)
    }

    private var challengesDetail: (text: String, tint: Color) {
        let accepted = program.challenges.filter { $0.status == .accepted || $0.status == .governed }.count
        let rejected = program.challenges.filter { $0.status.isRejected }.count
        let pending = program.challenges.count - accepted - rejected
        if pending > 0 { return ("\(pending) in review", .orange) }
        if accepted > 0 { return ("\(accepted) accepted", .green) }
        return (program.challenges.isEmpty ? "none yet" : "all rejected", .secondary)
    }

    private var tokensDetail: (text: String, tint: Color) {
        guard let ceiling = execution.limits.programTokens.value else { return ("no ceiling", .secondary) }
        let fraction = Double(usage.totalTokens) / Double(max(1, ceiling))
        return ("\(fraction.formatted(.percent.precision(.fractionLength(0)))) of \(ceiling.compactTokens)",
                fraction > 0.85 ? .orange : .secondary)
    }

    // MARK: Work and activity

    private var assignmentsPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResearchSectionHeader(title: "Assignments", count: counts.total,
                                  actionTitle: counts.total > 0 ? "View all" : nil) { openTab(.assignments) }
            VStack(alignment: .leading, spacing: 0) {
                if execution.assignments.isEmpty {
                    Text(live ? "The director is choosing the first piece of work." : "No work dispatched yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(10)
                }
                let shown = Array(execution.assignments.prioritized.prefix(5))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, assignment in
                    if index > 0 { Divider().padding(.leading, 36) }
                    HoverRow(action: { navigation.openAssignment(assignment.id) }) {
                        AssignmentRow(assignment: assignment,
                                      tokens: assignmentTokens[assignment.id] ?? assignment.latestReport?.tokensUsed ?? 0,
                                      live: live)
                    }
                }
                if counts.total > shown.count {
                    Button("\(counts.total - shown.count) more…") { openTab(.assignments) }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.tint)
                        .padding(.horizontal, 36).padding(.vertical, 8)
                }
            }
            .researchCard(padding: 4)
        }
    }

    private var activityPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResearchSectionHeader(title: "Recent activity",
                                  actionTitle: execution.events.isEmpty ? nil : "Open log") { openTab(.log) }
            VStack(alignment: .leading, spacing: 0) {
                if execution.events.isEmpty {
                    Text("Nothing has happened yet.").font(.callout).foregroundStyle(.secondary)
                }
                let recent = Array(execution.events.suffix(5).reversed())
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                    ProgramEventRow(event: event, program: program, navigation: navigation,
                                    lineLimit: 2, connectsBelow: index < recent.count - 1)
                }
            }
            .researchCard(padding: 12)
        }
    }

    // MARK: Spend

    private struct SpendSegment: Identifiable {
        let label: String
        let value: Int
        let color: Color
        var id: String { label }
    }

    private var spendSegments: [SpendSegment] {
        var segments = [
            SpendSegment(label: "Fresh input", value: max(0, usage.inputTokens - usage.cachedInputTokens), color: .blue),
            SpendSegment(label: "Cached input", value: usage.cachedInputTokens, color: .teal),
            SpendSegment(label: "Output", value: usage.outputTokens, color: .purple),
        ]
        if usage.earlierPlanningTokens > 0 {
            segments.append(SpendSegment(label: "Formalization & planning", value: usage.earlierPlanningTokens, color: .gray))
        }
        return segments
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResearchSectionHeader(title: "Spend", actionTitle: "Limits", action: openLimits)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(usage.totalTokens.formatted())
                        .font(.title2.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    if let ceiling = execution.limits.programTokens.value {
                        Text("of \(ceiling.formatted()) tokens").foregroundStyle(.secondary)
                    } else {
                        Text("tokens · no program ceiling").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let ceiling = execution.limits.programTokens.value {
                    let fraction = Double(usage.totalTokens) / Double(max(1, ceiling))
                    ProgressView(value: min(1, fraction))
                        .tint(fraction > 0.85 ? .orange : .accentColor)
                }
                SpendBar(segments: spendSegments.map { ($0.value, $0.color) })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(spendSegments) { segment in
                        HStack(alignment: .top, spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 9, height: 9).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(segment.value.formatted()).font(.callout.weight(.medium)).monospacedDigit()
                                Text(segment.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
                HStack(spacing: 18) {
                    Label("Director context ≈ \(contextTokens.compactTokens) tokens", systemImage: "text.bubble")
                    if let seconds = execution.limits.elapsedSeconds.value {
                        Label("Time limit \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                              systemImage: "clock")
                    }
                    if let calls = execution.limits.toolCalls.value {
                        Label("\(calls) director tool calls per session", systemImage: "wrench.and.screwdriver")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .researchCard()
        }
    }
}

/// One horizontal bar split by share — what the spend is made of, at a glance.
struct SpendBar: View {
    let segments: [(value: Int, color: Color)]

    var body: some View {
        let visible = segments.filter { $0.value > 0 }
        let total = CGFloat(max(1, visible.reduce(0) { $0 + $1.value }))
        GeometryReader { geometry in
            let available = geometry.size.width - CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(2, available * CGFloat(segment.value) / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }
}
