import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Every assignment as a one-line row, and the selected one in full beside it. Objectives
/// and reports are paragraphs written for the next agent; the list shows the director's
/// short title and the worker's one-line headline, and the detail pane has room for the rest.
struct PersistentAssignmentsTab: View {
    enum Presentation: String, CaseIterable, Identifiable {
        case list, map
        var id: String { rawValue }
    }

    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    let live: Bool
    let assignmentTokens: [String: Int]
    let navigation: ResearchNavigation
    @Binding var selection: String?

    @State private var presentation: Presentation = .list

    private var assignments: [ResearchAssignment] { program.execution?.assignments ?? [] }
    private var ordered: [ResearchAssignment] { assignments.prioritized }
    private var selected: ResearchAssignment? {
        assignments.first { $0.id == selection } ?? ordered.first
    }

    private func tokens(for assignment: ResearchAssignment) -> Int {
        assignmentTokens[assignment.id] ?? assignment.latestReport?.tokensUsed ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("View", selection: $presentation) {
                    Label("List", systemImage: "list.bullet").tag(Presentation.list)
                    Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(Presentation.map)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let summary = AssignmentCounts(assignments).activitySummary {
                    Text("\(assignments.count) assignment\(assignments.count == 1 ? "" : "s") · \(summary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            switch presentation {
            case .list:
                list
            case .map:
                ContentUnavailableView("Lineage map", systemImage: "map",
                    description: Text("A visual map of how findings route between assignments is coming in a future update. Use the list for now."))
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: assignments.map(\.id)) { _, _ in normalizeSelection() }
    }

    @ViewBuilder private var list: some View {
        if assignments.isEmpty {
            ContentUnavailableView {
                Label("No assignments yet", systemImage: "square.stack.3d.up")
            } description: {
                Text(live ? "The director is reading the goal and choosing the first piece of work."
                          : "Assignments appear here once the director dispatches work.")
            }
            .frame(maxHeight: .infinity)
        } else {
            let active = ordered.filter { $0.status.isActive }
            let completed = ordered.filter { !$0.status.isActive }
            HSplitView {
                List(selection: $selection) {
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { assignment in
                                AssignmentRow(assignment: assignment, tokens: tokens(for: assignment), live: live)
                                    .tag(assignment.id)
                            }
                        }
                    }
                    if !completed.isEmpty {
                        Section("Completed") {
                            ForEach(completed) { assignment in
                                AssignmentRow(assignment: assignment, tokens: tokens(for: assignment), live: live)
                                    .tag(assignment.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 260, idealWidth: 330, maxWidth: 480)

                Group {
                    if let selected {
                        AssignmentDetail(assignment: selected, program: program, research: research,
                                         tokens: tokens(for: selected), live: live, navigation: navigation)
                            .id(selected.id)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func normalizeSelection() {
        if selection == nil || !assignments.contains(where: { $0.id == selection }) {
            selection = ordered.first?.id
        }
    }
}

// MARK: - Detail

struct AssignmentDetail: View {
    @EnvironmentObject private var appState: AppState
    let assignment: ResearchAssignment
    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    let tokens: Int
    let live: Bool
    let navigation: ResearchNavigation

    private var macros: [String: String] { appState.store?.macroDictionary ?? [:] }

    private var events: [ResearchProgramEvent] {
        (program.execution?.events ?? []).filter {
            guard let id = $0.assignmentID else { return false }
            return id == assignment.id || id == assignment.planID
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                facts
                objective
                report
                if !assignment.messages.isEmpty { messages }
                if assignment.reports.count > 1 { earlierReports }
                if !events.isEmpty { activity }
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .researchScrollGutter()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ResearchChip(text: assignment.status.label, systemImage: assignment.status.systemImage,
                             tint: assignment.status.tint)
                ResearchChip(text: assignment.mode == .direct ? "Direct worker" : "Planned branch",
                             systemImage: assignment.mode == .direct ? "person" : "list.bullet.rectangle")
                if assignment.revision > 1 {
                    ResearchChip(text: "Revision \(assignment.revision)", systemImage: "arrow.clockwise")
                }
                if assignment.targetRevisionID != program.activeTargetRevisionID {
                    ResearchChip(text: "Earlier goal", systemImage: "clock.arrow.circlepath", tint: .orange)
                }
                Spacer(minLength: 8)
                actions
            }
            ItemNameText(name: assignment.displayTitle, macros: macros, fontSize: 20, lineLimit: 3)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
            if let parentID = assignment.parentAssignmentID, let parent = program.assignment(id: parentID) {
                Button { navigation.openAssignment(parent.id) } label: {
                    Label("Follows “\(parent.displayTitle)”", systemImage: "arrow.turn.down.right")
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let planID = assignment.planID, appState.store?.plan(id: planID) != nil {
            Button { appState.researchPage = .branch(programID: program.id, planID: planID) } label: {
                Label("Open plan", systemImage: "list.bullet.rectangle")
            }
        }
        if !live, program.execution?.resolution == nil {
            Button {
                research.guidePersistentProgram(program,
                    text: "Continue assignment \(assignment.id); inspect its saved report and unresolved gaps first.")
            } label: {
                Label("Continue this work", systemImage: "play.fill")
            }
            .disabled(research.isRunning)
            .help("Resume the director and ask it to continue this assignment")
        }
        Menu {
            Button("Copy assignment ID") { ResearchIDText.copy(assignment.id) }
            Button("Copy objective") { ResearchIDText.copy(assignment.objective) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: 30) {
            fact("Tokens", assignment.tokenLimit.value.map { "\(tokens.compactTokens) of \($0.compactTokens)" }
                    ?? "\(tokens.compactTokens) · no cap") {
                if let limit = assignment.tokenLimit.value {
                    ProgressView(value: min(1, Double(tokens) / Double(max(1, limit))))
                        .frame(width: 120)
                }
            }
            fact("Dispatched", assignment.createdAt.formatted(.relative(presentation: .named)))
                .help(assignment.createdAt.formatted(date: .abbreviated, time: .shortened))
            fact("Reports", "\(assignment.reports.count)")
            fact("ID", ResearchIDText.short(assignment.id))
                .help("\(assignment.id) — click to copy")
                .onTapGesture { ResearchIDText.copy(assignment.id) }
            Spacer(minLength: 0)
        }
    }

    private func fact<Extra: View>(_ label: String, _ value: String,
                                   @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
            extra()
        }
    }

    private var objective: some View {
        DetailSection(title: "Objective", systemImage: "scope") {
            CollapsibleMath(markdown: assignment.objective, id: "objective-\(assignment.id)", collapsedHeight: 140)
            if !assignment.constraints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Constraints").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(assignment.constraints.enumerated()), id: \.offset) { _, constraint in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            ItemNameText(name: constraint, macros: macros, lineLimit: 6).font(.callout)
                        }
                    }
                }
            }
            if !(assignment.itemIDs + assignment.evidenceIDs).isEmpty {
                ReferenceList(title: "Given to the worker", ids: assignment.itemIDs + assignment.evidenceIDs,
                              program: program, navigation: navigation)
            }
        }
    }

    @ViewBuilder private var report: some View {
        if let latest = assignment.latestReport {
            AssignmentReportCard(report: latest, title: "Latest report",
                                 renderID: "report-\(assignment.id)-\(assignment.reports.count)",
                                 program: program, navigation: navigation)
        } else {
            DetailSection(title: "Report", systemImage: "doc.text") {
                HStack(spacing: 8) {
                    if assignment.status == .running && live {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    }
                    Text(pendingText).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pendingText: String {
        switch assignment.status {
        case .running:
            return live ? "Working. The report arrives when the worker finishes."
                        : "Interrupted before reporting. Continue the program to resume it."
        case .queued: return "Waiting for a free slot; it starts when running work finishes."
        case .paused: return "Paused before reporting."
        case .stopped: return "Stopped before reporting."
        case .errored: return "Stopped on an error before reporting."
        case .finished: return "Finished without a report."
        }
    }

    private var messages: some View {
        DetailSection(title: "From the director", systemImage: "bubble.left.and.bubble.right") {
            let ordered = Array(assignment.messages.reversed())
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(message.createdAt, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if assignment.deliveredMessageIDs?.contains(message.id) == true {
                            Label("Delivered", systemImage: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ExpandableText(text: message.text, lineLimit: 4, fontSize: NSFont.systemFontSize)
                        .textSelection(.enabled)
                    if !message.evidenceIDs.isEmpty {
                        ReferenceList(title: "Attached", ids: message.evidenceIDs, program: program, navigation: navigation)
                    }
                }
            }
        }
    }

    private var earlierReports: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 18) {
                let earlier = Array(assignment.reports.dropLast().enumerated()).reversed()
                ForEach(Array(earlier), id: \.offset) { index, report in
                    AssignmentReportCard(report: report, title: "Report \(index + 1)",
                                         renderID: "report-\(assignment.id)-\(index + 1)",
                                         program: program, navigation: navigation)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Earlier reports (\(assignment.reports.count - 1))").font(.headline)
        }
    }

    private var activity: some View {
        DetailSection(title: "Activity", systemImage: "clock.arrow.circlepath") {
            let ordered = Array(events.reversed())
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, event in
                    ProgramEventRow(event: event, program: program, navigation: navigation, lineLimit: 2,
                                    showsAssignment: false, connectsBelow: index < ordered.count - 1)
                }
            }
        }
    }
}

struct AssignmentReportCard: View {
    @EnvironmentObject private var appState: AppState
    let report: AssignmentReport
    let title: String
    let renderID: String
    let program: ResearchProgram
    let navigation: ResearchNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
                Text(report.createdAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(report.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ResearchChip(text: report.outcome.label, systemImage: report.outcome.systemImage, tint: report.outcome.tint)
                    ResearchChip(text: report.stopReason.label, systemImage: report.stopReason.systemImage)
                    Spacer()
                    if report.tokensUsed > 0 {
                        Text("\(report.tokensUsed.compactTokens) tokens")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                // Only a headline the worker wrote: a derived one would just repeat the
                // summary's first sentence directly above it.
                if let headline = report.headline, !headline.isEmpty {
                    ItemNameText(name: headline, macros: appState.store?.macroDictionary ?? [:],
                                 fontSize: 14, lineLimit: 3)
                        .font(.system(size: 14, weight: .medium))
                        .textSelection(.enabled)
                }
                CollapsibleMath(markdown: report.summary, id: "\(renderID)-summary", collapsedHeight: 120)
                if !report.unresolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Remaining gap", systemImage: "exclamationmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        CollapsibleMath(markdown: report.unresolved, id: "\(renderID)-gap", collapsedHeight: 80)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
                }
                if !report.references.isEmpty {
                    ReferenceList(title: "Evidence", ids: report.references, program: program, navigation: navigation)
                }
                Text("The worker's own account. Acceptance comes only from independent review.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .researchCard()
        }
    }
}
