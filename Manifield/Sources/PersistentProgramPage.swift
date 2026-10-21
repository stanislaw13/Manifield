import SwiftUI
import ManifieldCore
import ManifieldAgents

/// One responsive column for the whole program dashboard. Keeping the width policy here
/// prevents individual tabs from ending at different x positions on a large display.
private enum PersistentProgramLayout {
    static let maximumContentWidth: CGFloat = 1_180
    static let maximumPaddedWidth: CGFloat = maximumContentWidth + 32
}

/// The program page for the persistent director/assignment model — the only kind of program
/// a new run can ever produce. Four tabs (Overview/Assignments/Evidence/Log); ceilings and
/// per-role models live behind the Limits button, not in a tab, because they are
/// configuration frozen at launch, not something read while a run is in flight.
///
/// The page owns tab and selection state so that anything countable or named on one tab —
/// a tile, an assignment title in the log, an evidence ID in a report — can open it on another.
struct PersistentProgramPage: View {
    enum ProgramTab: String, CaseIterable, Identifiable {
        case overview, assignments, evidence, log
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return "Overview"
            case .assignments: return "Assignments"
            case .evidence: return "Evidence"
            case .log: return "Log"
            }
        }
        var systemImage: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .assignments: return "square.stack.3d.up"
            case .evidence: return "checkmark.seal"
            case .log: return "list.bullet.rectangle"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    @State private var tab: ProgramTab = .overview
    @State private var selectedAssignmentID: String?
    @State private var evidenceSelection: String?
    @State private var evidenceFilter: EvidenceFilter = .all
    @State private var editedLimits = ResearchLimits()
    @State private var usage = ProgramUsageSummary()
    @State private var assignmentTokens: [String: Int] = [:]
    @State private var contextTokens = 0
    @State private var showGoal = false
    @State private var showLimits = false
    @Namespace private var tabIndicator

    private var execution: ResearchExecution { program.execution! }
    private var live: Bool { research.isActive(programID: program.id) && research.isRunning }
    private var counts: AssignmentCounts { AssignmentCounts(execution.assignments) }
    private var macros: [String: String] { appState.store?.macroDictionary ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let error = research.lastError, research.activeProgramID == program.id {
                errorBanner(error)
            }
            tabBar
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding()
        .frame(maxWidth: PersistentProgramLayout.maximumPaddedWidth,
               maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: program.updated) {
            editedLimits = execution.limits
            refreshUsage()
            loadContextTokens()
        }
        // Spend lands in the ledger call by call, between manifest writes; poll while live
        // so the numbers move with the run instead of jumping at the next event.
        .task(id: live) {
            guard live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                refreshUsage()
            }
        }
        .sheet(isPresented: $showGoal) { goalSheet }
        .sheet(isPresented: $showLimits) { limitsSheet }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { appState.researchPage = .list } label: {
                    Label("Programs", systemImage: "chevron.left")
                }
                .help("Back to all programs")
                Spacer()
                Button { showGoal = true } label: { Label(goalLabel, systemImage: "target") }
                    .help("The frozen goal this program works toward")
                Button { showLimits = true } label: { Label("Limits", systemImage: "slider.horizontal.3") }
                    .help("Ceilings and per-role models for this program")
                runButton
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ItemNameText(name: program.displayName, macros: macros, fontSize: 22, lineLimit: 2)
                    .font(.system(size: 22, weight: .bold))
                    .textSelection(.enabled)
                ProgramStatusChip(status: program.status)
                if live { LiveBadge() }
                Spacer(minLength: 0)
            }
            metaLine
        }
    }

    @ViewBuilder private var runButton: some View {
        if live {
            Button { research.cancel() } label: { Label("Pause", systemImage: "pause.fill") }
                .help("Pause the director and every running assignment; work so far is saved")
        } else if execution.resolution == nil {
            Button { research.startProgram(program) } label: { Label("Continue", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(research.isRunning)
                .help(research.isRunning ? "Another program is running" : "Resume the director")
        }
    }

    private var goalLabel: String {
        guard program.targetRevisions.count > 1,
              let index = program.targetRevisions.firstIndex(where: { $0.id == program.activeTargetRevisionID })
        else { return "Goal" }
        return "Goal · rev. \(index + 1)"
    }

    private var metaLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 16) {
                Button { select(.assignments) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                        Text("\(counts.total) assignment\(counts.total == 1 ? "" : "s")")
                        if counts.inFlight > 0, let activity = counts.activitySummary {
                            Text("· \(activity)").foregroundStyle(counts.running > 0 ? Color.blue : Color.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Open assignments")
                Label("\(usage.totalTokens.compactTokens) tokens\(execution.limits.programTokens.value.map { " of \($0.compactTokens)" } ?? "")",
                      systemImage: "gauge.medium")
                    .help("\(usage.totalTokens.formatted()) tokens")
                if let elapsed = elapsedText(at: context.date) {
                    Label(elapsed, systemImage: "clock")
                }
                if let last = execution.events.last {
                    Label("updated \(last.createdAt.formatted(.relative(presentation: .named)))",
                          systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Wall time from start to the resolution, to now while running, or to the last event —
    /// a program that finished yesterday should not keep ageing on screen.
    private func elapsedText(at now: Date) -> String? {
        guard let started = execution.startedAt else { return nil }
        let end = execution.resolution?.createdAt ?? (live ? now : (execution.events.last?.createdAt ?? now))
        let seconds = end.timeIntervalSince(started)
        guard seconds > 1 else { return nil }
        let text = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        if execution.resolution != nil { return "took \(text)" }
        return live ? "\(text) elapsed" : "\(text) so far"
    }

    private func errorBanner(_ error: String) -> some View {
        Label {
            Text(error).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(ProgramTab.allCases) { item in
                let isSelected = tab == item
                Button { select(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.systemImage).imageScale(.small)
                        Text(item.label)
                        if let badge = badge(for: item) {
                            Text(badge)
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.14 : 0.08)))
                        }
                        if item == .assignments, live, counts.running > 0 {
                            PulsingDot(tint: .blue, size: 6)
                        }
                    }
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "selected-tab", in: tabIndicator)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func badge(for item: ProgramTab) -> String? {
        switch item {
        case .overview, .log:
            return nil
        case .assignments:
            return counts.total > 0 ? "\(counts.total)" : nil
        case .evidence:
            let count = program.solutions.count + program.challenges.count + program.findings.count
            return count > 0 ? "\(count)" : nil
        }
    }

    private func select(_ item: ProgramTab) {
        withAnimation(.snappy(duration: 0.25)) { tab = item }
    }

    private var navigation: ResearchNavigation {
        ResearchNavigation(
            openAssignment: { id in
                selectedAssignmentID = program.assignment(id: id)?.id ?? id
                select(.assignments)
            },
            openEvidence: { entryID in
                evidenceFilter = .all
                evidenceSelection = entryID
                select(.evidence)
            },
            showEvidence: { filter in
                evidenceFilter = filter
                evidenceSelection = nil
                select(.evidence)
            },
            openLibraryItem: { id in
                appState.selectedItemID = id
                appState.selection = .library
            })
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview:
            PersistentOverviewTab(program: program, research: research, live: live, usage: usage,
                                  assignmentTokens: assignmentTokens, contextTokens: contextTokens,
                                  navigation: navigation, openTab: select, openLimits: { showLimits = true })
        case .assignments:
            PersistentAssignmentsTab(program: program, research: research, live: live,
                                     assignmentTokens: assignmentTokens, navigation: navigation,
                                     selection: $selectedAssignmentID)
        case .evidence:
            EvidenceSegment(program: program, findings: program.findings, changes: program.lastRunChanges ?? [],
                            selection: $evidenceSelection, filter: $evidenceFilter, navigation: navigation)
        case .log:
            PersistentLogTab(program: program, research: research, live: live, navigation: navigation)
        }
    }

    // MARK: Data

    private func refreshUsage() {
        guard let store = appState.store else { return }
        usage = store.usageSummary(program: program)
        var bySubject: [String: Int] = [:]
        for entry in store.loadUsageLedger(programID: program.id) {
            if let subject = entry.subjectID { bySubject[subject, default: 0] += entry.actualTokens }
        }
        assignmentTokens = bySubject
    }

    private func loadContextTokens() {
        if let data = appState.store?.loadSession(named: "director-\(program.id)"),
           let session = try? JSONDecoder().decode(ResearchConversationRecord.self, from: data) {
            contextTokens = BranchConversation(system: DirectorWorkbench.system, messages: session.messages).estimatedTokens
        }
    }

    // MARK: Sheets

    private var goalSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("The frozen goal", systemImage: "target").font(.headline)
                Spacer()
                Button("Done") { showGoal = false }
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        ResearchChip(text: goalLabel == "Goal" ? "Revision 1" : goalLabel.replacingOccurrences(of: "Goal · rev. ", with: "Revision "),
                                     systemImage: "target", tint: .accentColor)
                        Text(program.activeTargetRevisionID)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    RenderedMath(markdown: program.activeTargetRevision.statement.isEmpty
                        ? program.activeTargetRevision.requestText : program.activeTargetRevision.statement,
                        id: "persistent-goal-\(program.activeTargetRevisionID)", maxHeight: .infinity)
                    DisclosureGroup("Original request") {
                        RenderedMath(markdown: program.goal, id: "persistent-request-\(program.id)", maxHeight: .infinity)
                            .padding(.top, 6)
                    }
                }.textSelection(.enabled).padding()
            }
        }.frame(minWidth: 520, minHeight: 380)
    }

    private var limitsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Research settings").font(.headline)
                Spacer()
                Button("Done") { showLimits = false }
            }.padding()
            Divider()
            PersistentResearchLimitsPane(program: program, limits: $editedLimits, savedLimits: execution.limits,
                live: live, concurrentAssignments: program.maxConcurrentBranches,
                onSave: { research.setPersistentLimits(program, limits: editedLimits) })
                .padding()
        }.frame(minWidth: 520, minHeight: 480)
    }
}

/// A scrollable, explicitly sized limits pane. A macOS `Form` in the flexible tab region can
/// collapse to an empty presentation even though the bound limits are present on disk.
struct PersistentResearchLimitsPane: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @Binding var limits: ResearchLimits
    let savedLimits: ResearchLimits
    let live: Bool
    let concurrentAssignments: Int
    let onSave: () -> Void

    @State private var editedRoles: [AgentTask: RoleModelChoice] = [:]
    @State private var roleError: String?

    private var savedRoles: [AgentTask: RoleModelChoice] {
        Dictionary(uniqueKeysWithValues: program.roleModelOverrides.compactMap { key, value -> (AgentTask, RoleModelChoice)? in
            guard let task = AgentTask(rawValue: key) else { return nil }
            return (task, RoleModelChoice(providerKind: value.providerKind, model: value.model))
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ResearchLimitsEditor(limits: $limits).disabled(live)
                Divider()
                Text("These limits are saved with this program. Pause before changing them; accumulated usage is retained.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save limits", action: onSave)
                    .disabled(live || limits == savedLimits)
                Text("Concurrent assignments: \(concurrentAssignments)")
                Text("Program token ceiling: \(savedLimits.programTokens.displayName)")
                Divider()
                GroupBox("Models by role") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Overrides the global default from Settings > Roles, for this program only.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(RunLimits.overridableRoles) { task in
                            HStack {
                                Text(task.displayName).font(.callout)
                                Spacer()
                                BranchModelPicker(
                                    providerKind: Binding(
                                        get: { editedRoles[task]?.providerKind },
                                        set: { editedRoles[task, default: RoleModelChoice()].providerKind = $0 }),
                                    model: Binding(
                                        get: { editedRoles[task]?.model },
                                        set: { editedRoles[task, default: RoleModelChoice()].model = $0 }),
                                    defaultLabel: "\(task.displayName) setting")
                            }
                        }
                        if let roleError { Text(roleError).font(.caption).foregroundStyle(.red) }
                        Button("Save models", action: saveRoles)
                            .disabled(live || editedRoles == savedRoles)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(live)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
        .accessibilityIdentifier("persistent-research-limits")
        .onAppear { editedRoles = savedRoles }
    }

    private func saveRoles() {
        do {
            try appState.updateProgram(program) { p in
                var overrides: [String: ResearchProgram.ModelOverride] = [:]
                for (task, choice) in editedRoles {
                    if let kind = choice.providerKind, let model = choice.model {
                        overrides[task.rawValue] = ResearchProgram.ModelOverride(providerKind: kind, model: model)
                    }
                }
                p.roleModelOverrides = overrides
            }
            roleError = nil
        } catch {
            roleError = error.localizedDescription
        }
    }
}
