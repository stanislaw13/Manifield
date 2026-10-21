import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The portfolio: every research program in the project, one row each, at full width.
///
/// Deliberately more than a table of contents. A program is something you *monitor*, so
/// each row carries the same projection its page opens with — where it stands, whether it
/// is live, what it has spent — and the list answers "is anything waiting on me?" without
/// opening anything.
struct ProgramListPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    @State private var showArchive = false
    @State private var pendingDelete: ResearchProgram?
    @State private var actionError: String?

    private var programs: [ResearchProgram] { appState.allPrograms }

    private var working: [ResearchProgram] { programs.filter { !isArchived($0) } }
    private var archived: [ResearchProgram] { programs.filter { isArchived($0) } }
    /// A small teaser of what wrapped up most recently — a glance, not a full history.
    /// The complete archive is still the disclosure below; this just surfaces the recent
    /// edge of it without needing any new "last visited" tracking.
    private var recentlyConcluded: [ResearchProgram] {
        Array(archived.sorted { $0.updated > $1.updated }.prefix(4))
    }

    /// A virtual program has no manifest, so its plan's status is the authority.
    private func isArchived(_ program: ResearchProgram) -> Bool {
        if program.isVirtual {
            return appState.branchPlans(of: program).first?.status.isArchived ?? false
        }
        return program.status.isArchived
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let actionError {
                Text(actionError)
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6)
                Divider()
            }
            if programs.isEmpty && !appState.planning.hasSession {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Delete this program?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { program in
            Button("Delete", role: .destructive) {
                perform { try appState.deleteProgram(program) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { program in
            Text(deleteMessage(program))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Research").font(.largeTitle.weight(.bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings", systemImage: "gearshape") { openSettings() }
                .help("Global defaults — providers, roles, limits")
            Button {
                appState.planningPhase = .brainstorming
            } label: {
                Label("Start research…", systemImage: "lightbulb")
            }
            .buttonStyle(.borderedProminent)
            .help("Formalize a goal and hand it to the persistent research director")
        }
        .padding()
    }

    private var subtitle: String {
        guard !programs.isEmpty else { return "A continuing director conversation delegates work and evaluates its reports." }
        let activeCount = working.count
        return activeCount > 0
            ? "\(activeCount) active · \(programs.count) total"
            : "\(programs.count) program\(programs.count == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No research programs", systemImage: "map")
        } description: {
            Text("Start research, choose limits, and hand a problem to the director. It can commission focused workers or planned branches.")
        } actions: {
            Button("Start research…") { appState.planningPhase = .brainstorming }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            PlanningSessionRow(
                planning: appState.planning,
                // Before pass 2 there is no setup, and `.reviewing` renders nothing without
                // one — so during the audit, the contract and the pilots the way back is the
                // planner pane, which is where that work is actually streaming.
                onOpen: {
                    appState.planningPhase =
                        appState.planning.hasSession ? .reviewing : .brainstorming
                },
                onDiscard: {
                    appState.planning.reset()
                    appState.pendingApproachProposal = nil
                })
            if !recentlyConcluded.isEmpty {
                Section("Concluded") {
                    ForEach(recentlyConcluded, id: \.id) { concludedRow($0) }
                }
            }
            if !working.isEmpty {
                Section("Active") {
                    ForEach(working, id: \.id) { row($0) }
                }
            }
            if !archived.isEmpty {
                // A plain header with its own toggle rather than `Section(isExpanded:)`,
                // which only draws its disclosure control under the sidebar list style —
                // and this page is not a sidebar any more.
                Section {
                    if showArchive {
                        ForEach(archived, id: \.id) { row($0) }
                    }
                } header: {
                    Button {
                        withAnimation { showArchive.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showArchive ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Archive (\(archived.count))")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }

    /// A one-line glance at something already concluded — not the full projection `row`
    /// gives an active program, since there is nothing left here to monitor.
    private func concludedRow(_ program: ResearchProgram) -> some View {
        Button {
            appState.researchPage = .program(id: program.id)
        } label: {
            HStack(spacing: 8) {
                if program.isVirtual, let plan = appState.branchPlans(of: program).first {
                    PlanStatusChip(status: plan.status)
                } else {
                    ProgramStatusChip(status: program.status)
                }
                ItemNameText(name: program.displayName,
                             macros: appState.store?.macroDictionary ?? [:],
                             fontSize: NSFont.systemFontSize, lineLimit: 1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One program, as a button into its page. The subtitle is the same `oneLiner` its
    /// dashboard opens with — a projection of durable state, never a generated summary.
    private func row(_ program: ResearchProgram) -> some View {
        let isLive = appState.research.isActive(programID: program.id) && appState.research.isRunning
        let status = ProgramStatus.make(
            program: program,
            records: recordsFor(program),
            items: appState.store?.items ?? [],
            programRecord: nil,
            tokensSpent: appState.store?.usageTokens(program: program))
        return Button {
            appState.researchPage = .program(id: program.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ItemNameText(name: program.displayName,
                                     macros: appState.store?.macroDictionary ?? [:],
                                     fontSize: NSFont.systemFontSize, lineLimit: 1)
                            .font(.body.weight(.medium))
                        if program.isVirtual {
                            if let plan = appState.branchPlans(of: program).first {
                                PlanStatusChip(status: plan.status)
                            }
                        } else {
                            ProgramStatusChip(status: program.status)
                        }
                        if isLive {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("running").font(.caption2).foregroundStyle(.green)
                            }
                        }
                        if needsAttention(program) {
                            Label("needs you", systemImage: "exclamationmark.circle.fill")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if program.isVirtual {
                        Text("Standalone plan").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ItemNameText(name: program.execution.map(executionSubtitle) ?? status.oneLiner,
                                     macros: appState.store?.macroDictionary ?? [:],
                                     fontSize: NSFont.smallSystemFontSize, lineLimit: 2)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(program.branches, id: \.planID) { branch in
                            if branch.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true, compact: true) }
                        }
                        if status.tokensSpent > 0 {
                            Text("· \(status.tokensSpent / 1000)k tokens")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .contextMenu {
            Button("Open") { appState.researchPage = .program(id: program.id) }
            Divider()
            Button("Delete program…", role: .destructive) { pendingDelete = program }
        }
    }

    /// "3 assignments · 1 running · Reported: …" — live counts, then the latest event's first
    /// sentence; a resolved program shows its resolution's first sentence instead.
    private func executionSubtitle(_ execution: ResearchExecution) -> String {
        if let resolution = execution.resolution { return ResearchText.headline(resolution.explanation) }
        let counts = AssignmentCounts(execution.assignments)
        var parts = ["\(counts.total) assignment\(counts.total == 1 ? "" : "s")"]
        if counts.inFlight > 0, let activity = counts.activitySummary { parts.append(activity) }
        if let last = execution.events.last {
            parts.append("\(last.kind.label): \(ResearchText.headline(last.summary, maxLength: 90))")
        } else {
            parts.append("Director ready")
        }
        return parts.joined(separator: " · ")
    }

    /// True when this program is stopped on something only the user can clear. The point of
    /// the list page for an unattended run: which of these is blocked on me right now?
    ///
    /// Reads persisted records, not only live ones. Gated on the active program this answered
    /// the question for at most one row, so a portfolio where an overnight run parked on a
    /// question three hours ago showed no flag anywhere — which is precisely the morning this
    /// page exists for.
    private func needsAttention(_ program: ResearchProgram) -> Bool {
        if let execution = program.execution {
            return execution.resolution == nil && program.status == .paused
        }
        if appState.research.pause(of: program) != nil {
            return true
        }
        return program.branches.contains { branch in
            guard let record = appState.research.pendingRecord(for: branch.planID) else {
                return false
            }
            switch record.state {
            case .waitingForUser, .budgetPause, .checkpoint: return true
            default: return false
            }
        }
    }

    /// Live records for the running program, persisted ones otherwise — so a program that
    /// ran last week still shows what it spent and where it got to.
    private func recordsFor(_ program: ResearchProgram) -> [String: RunRecord] {
        var records: [String: RunRecord] = [:]
        for branch in program.branches {
            if appState.research.isActive(programID: program.id),
               let live = appState.research.record(of: branch.planID) {
                records[branch.planID] = live
            } else if let saved = appState.research.pendingRecord(for: branch.planID) {
                records[branch.planID] = saved
            }
        }
        return records
    }

    private func deleteMessage(_ program: ResearchProgram) -> String {
        let branchCount = program.branches.count
        var parts = ["“\(program.displayName)”"]
        if branchCount > 0 {
            parts.append("\(branchCount) branch plan\(branchCount == 1 ? "" : "s") and their research memories")
        }
        if program.reportPath != nil { parts.append("the synthesis report") }
        return "This permanently deletes " + parts.joined(separator: ", ")
            + ". Theory items and artifacts the program produced are not touched."
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// The way back into a program that is still being planned. Pass 2 keeps generating while
/// you are on another tab, so without this row a session in flight is invisible *and*
/// unstoppable — you can neither watch it nor call it off. Observes the controller
/// directly, since nested ObservableObjects don't propagate through AppState on their own.
struct PlanningSessionRow: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var planning: ProgramPlanningController
    let onOpen: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        if planning.hasSession || planning.isGenerating {
            Section("In planning — not yet approved") {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 3) {
                        ItemNameText(name: planning.goal.isEmpty ? "New program" : planning.goal,
                                     macros: appState.store?.macroDictionary ?? [:], lineLimit: 2)
                            .font(.callout)
                        HStack(spacing: 6) {
                            if planning.isGenerating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: planning.allDone
                                      ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(planning.allDone ? Color.green : Color.orange)
                            }
                            Text(planning.sessionStatus)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the branch plans being generated for this program")
                .contextMenu {
                    Button("Open", action: onOpen)
                    if planning.isGenerating {
                        Button("Stop generating") { planning.cancel() }
                    }
                    Divider()
                    Button("Discard this planning session", role: .destructive, action: onDiscard)
                }
            }
        }
    }
}
