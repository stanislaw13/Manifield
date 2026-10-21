import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The Research tab's router.
///
/// Three full-width pages rather than a permanent split view — a portfolio, one program's
/// dashboard, one branch's plan. The split view it replaces gave the detail column ~440pt
/// and stacked eight sections into it, which is most of why the tab was unreadable.
///
/// Planning is a separate axis: while `planningPhase` is not `.idle` it takes over the tab,
/// because a planning session is a flow the user is inside rather than a place they are.
struct ResearchView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Every page is measured against the container and pinned to exactly its size.
        // `maxHeight: .infinity` is not enough on its own: it can only stretch a page, and
        // a page whose content exceeds the window — a long portfolio, a program with many
        // routes — otherwise keeps its content height and pushes the whole thing past the
        // top of the window, clipping its own header off the screen.
        GeometryReader { geo in
            page.frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // NavigationSplitView sizes its detail column from the minimum width its content
        // *demands*, not from what it will accept — without a floor the column collapses.
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch appState.planningPhase {
            case .brainstorming:
                PlannerPane(onCancel: { appState.planningPhase = .idle })
            case .selecting:
                if let proposal = appState.pendingApproachProposal {
                    ApproachSelectionPane(
                        proposal: proposal,
                        onGenerate: { setup in
                            appState.planning.generate(setup: setup)
                            appState.planningPhase = .reviewing
                        },
                        onReplan: { replan(goal: proposal.goal) },
                        onCancel: { discardPlanning() })
                        // A new proposal is a new pane: selection and lens edits are keyed
                        // by approach title, and carrying them over silently drops the
                        // user's typing on titles the old portfolio didn't have.
                        .id(proposal.id)
                } else {
                    routedPage
                }
            case .reviewing:
                // Read from the controller, not from view state: this view is destroyed
                // and rebuilt on every tab switch, and a session held in `@State` came
                // back nil while its generation was still running.
                if let setup = appState.planning.setup {
                    ProgramReviewPane(
                        setup: setup,
                        planning: appState.planning,
                        onBack: { appState.planningPhase = .selecting },
                        onClose: { appState.planningPhase = .idle },
                        onFinished: { program in
                            discardPlanning()
                            appState.researchPage = .program(id: program.id)
                        })
                } else {
                    routedPage
                }
            case .idle:
                routedPage
            }
        }
    }

    @ViewBuilder
    private var routedPage: some View {
        switch appState.researchPage {
        case .list:
            ProgramListPage()
        case .program(let id):
            if let program = appState.allPrograms.first(where: { $0.id == id }) {
                // Keyed by id so switching programs resets the page's segment and scroll
                // rather than showing one program's tab selection over another's content.
                ProgramPage(program: program).id(id)
            } else {
                missingProgram
            }
        case .branch(let programID, let planID):
            if let program = appState.allPrograms.first(where: { $0.id == programID }),
               let plan = appState.plans.first(where: { $0.id == planID }) {
                BranchPage(program: program, plan: plan).id(planID)
            } else {
                missingProgram
            }
        }
    }

    /// The program was deleted (or its project closed) while the route still pointed at it.
    private var missingProgram: some View {
        ContentUnavailableView {
            Label("This program is no longer here", systemImage: "questionmark.folder")
        } description: {
            Text("It may have been deleted.")
        } actions: {
            Button("Back to programs") { appState.researchPage = .list }
        }
    }

    private func discardPlanning() {
        appState.planning.reset()
        appState.pendingApproachProposal = nil
        appState.plannerSeed = nil
        appState.planningPhase = .idle
    }

    /// Throws away the portfolio and designs it again from the same problem.
    private func replan(goal: String) {
        appState.planning.reset()
        appState.pendingApproachProposal = nil
        appState.plannerSeed = PlannerSeed(problem: goal)
        appState.planningPhase = .brainstorming
    }
}

// MARK: - Chips

/// Marks the branch whose job is to attack the leading answer. Only that role is worth a
/// chip — every other branch is simply building toward an answer, and a chip saying so on
/// each of them is noise.
struct ChallengerChip: View {
    let challengesLeadingAnswer: Bool
    var compact = false

    var body: some View {
        Text(compact ? "chal" : "Challenger")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    /// Red, because the only thing this chip marks is the branch trying to break the
    /// leading answer — the one a reader scanning a portfolio is looking for.
    private var color: Color { .red }
}

struct PlanStatusChip: View {
    let status: PlanStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .draft: return .gray
        case .approved: return .blue
        case .active: return .green
        case .paused: return .orange
        case .done: return .green
        case .abandoned: return .gray
        case .failed: return .red
        }
    }
}

struct ProgramStatusChip: View {
    let status: ResearchProgram.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .active: return .green
        case .paused: return .orange
        case .done: return .green
        case .abandoned: return .gray
        case .failed: return .red
        }
    }
}

/// Shared task-status glyphs (Research tab task list + the toolbar run chip's checklist).
extension PlanTask.Status {
    var iconName: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "arrow.triangle.2.circlepath.circle"
        case .completed: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle"
        case .failed: return "xmark.circle.fill"
        // Never attempted, so it reads as struck out rather than as a failure.
        case .dropped: return "minus.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .blocked: return .orange
        case .failed: return .red
        case .dropped: return .secondary
        }
    }
}

extension BranchRunStatus {
    var iconName: String {
        switch self {
        case .queued: return "circle"
        case .running: return "arrow.triangle.2.circlepath.circle"
        case .waitingUser: return "questionmark.bubble"
        case .budgetPaused, .assignmentExhausted: return "gauge.high"
        case .checkpoint: return "pause.circle"
        case .errored: return "exclamationmark.triangle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .killed: return "stop.circle"
        }
    }

    var displayName: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .waitingUser: return "waiting on you"
        case .budgetPaused: return "budget reached"
        case .assignmentExhausted: return "allocation spent"
        case .checkpoint: return "at a checkpoint"
        case .errored: return "errored"
        case .finished: return "finished"
        case .failed: return "failed"
        case .killed: return "stopped"
        }
    }

    var iconColor: Color {
        switch self {
        case .queued: return .secondary
        case .running: return .blue
        case .waitingUser, .checkpoint, .budgetPaused, .assignmentExhausted: return .orange
        case .errored, .failed: return .red
        case .finished: return .green
        case .killed: return .gray
        }
    }
}

// MARK: - Task list

struct TaskList: View {
    let plan: PlanDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.tasks, id: \.index) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: task.status.iconName)
                        .foregroundStyle(task.status.iconColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(task.index). \(task.title)").font(.callout)
                        HStack(spacing: 8) {
                            if case .prove(let target) = task.kind {
                                Text("prove \(target)").font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if !task.dependsOn.isEmpty {
                                Text("after \(task.dependsOn.map(String.init).joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if task.reviewGate {
                                Text("review").font(.caption2).foregroundStyle(.purple)
                            }
                            if let needs = task.needs, !needs.isEmpty {
                                Text("needs: \(needs)").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Branch card

/// One branch of a program: its lens and stance, live status, tasks, and the run
/// controls that apply to it alone.
struct BranchCard: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let plan: PlanDocument
    let branch: ResearchProgram.Branch?
    @ObservedObject var research: ResearchController
    /// Opens the branch on its own page. Nil on that page itself — there is nowhere
    /// further to go, and the title should not look clickable there.
    var startExpanded = false
    /// Asks the Research tab to raise its delete confirmation for this branch.
    var onRequestDelete: () -> Void = {}
    var onOpenFully: (() -> Void)?

    @State private var expanded = false
    @State private var didApplyStartExpanded = false
    @State private var editing = false
    @State private var actionError: String?

    private var status: BranchRunStatus? { research.status(of: plan.id) }

    /// Per-branch close-out. "This approach failed" is the common case and the whole
    /// reason `failed` is separate from `discarded`: it is a finding about the approach,
    /// not a plan someone lost interest in.
    private var branchMenu: some View {
        Menu {
            Section("Mark branch as") {
                ForEach(PlanStatus.userSettable, id: \.self) { status in
                    Button {
                        act { try appState.setPlanStatus(status, forPlan: plan.id) }
                    } label: {
                        if plan.status == status { Image(systemName: "checkmark") }
                        Text(status.userActionLabel)
                    }
                }
            }
            Divider()
            if let onOpenFully {
                Button("Open on its own page", action: onOpenFully)
            }
            Button {
                appState.showMemory(forBranch: plan.id)
            } label: {
                Label("Open branch memory", systemImage: "brain")
            }
            Divider()
            Button("Delete branch…", role: .destructive) { onRequestDelete() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mark this branch done or failed, open its memory, or delete it")
    }

    private func act(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let branch { if branch.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true) } }
                ItemNameText(name: branch?.title ?? plan.id,
                             macros: appState.store?.macroDictionary ?? [:], lineLimit: 1)
                    .font(.callout.weight(.medium))
                PlanStatusChip(status: plan.status)
                if let status {
                    Label(status.displayName, systemImage: status.iconName)
                        .font(.caption2)
                        .foregroundStyle(status.iconColor)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Text("\(plan.tasks.filter { $0.status == .completed }.count)/\(plan.tasks.count) tasks")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if let record = research.record(of: plan.id) {
                    Text("\(record.tokensUsed / 1000)k")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                // A visible jump to this branch's memory, not only a menu item: the
                // isolated memory is the thing you most often want to read while judging
                // what a branch actually concluded.
                Button {
                    appState.showMemory(forBranch: plan.id)
                } label: {
                    Image(systemName: "brain")
                }
                .buttonStyle(.borderless)
                .help("Open this branch's research memory")
                // An explicit control rather than a double-click on the title: a
                // TapGesture(count: 2) on a row delays every single click by the
                // double-click interval, which makes the whole list feel unresponsive.
                if let onOpenFully {
                    Button {
                        onOpenFully()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Open this branch on its own page")
                }
                branchMenu
            }

            if let actionError {
                Text(actionError).font(.caption2).foregroundStyle(.red)
            }

            if let kill = plan.kill, !kill.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("Kill criterion:")
                    ItemNameText(name: kill, macros: appState.store?.macroDictionary ?? [:],
                                 fontSize: NSFont.smallSystemFontSize, lineLimit: 4)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            // Running one branch overrides the scheduler — useful when you have a hunch
            // about which approach deserves the compute, whatever the ordering says.
            if !research.isRunning, !plan.isFinished, !plan.status.isArchived {
                HStack(spacing: 8) {
                    Button {
                        research.runBranch(program: program, planID: plan.id, mode: .auto)
                    } label: {
                        Label("Run this branch", systemImage: "play.circle")
                    }
                    .controlSize(.small)
                    Button {
                        research.runBranch(program: program, planID: plan.id, mode: .checkpoint)
                    } label: {
                        Label("Checkpoint", systemImage: "pause.circle")
                    }
                    .controlSize(.small)
                    .help("Run this branch alone, pausing after each task")
                    Spacer()
                }
            }

            BranchRunControls(research: research, program: program, plan: plan)

            GuidanceBox(plan: plan)

            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if editing {
                        BranchEditor(plan: plan, onDone: { editing = false })
                    } else {
                        if !plan.lens.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Research lens").font(.caption.weight(.semibold))
                                RenderedMath(markdown: plan.lens, id: "lens-\(plan.id)")
                            }
                        }
                        TaskList(plan: plan)
                        HStack {
                            Button {
                                appState.openInChat(program: program, planID: plan.id)
                            } label: {
                                Label("Open in chat", systemImage: "bubble.left.and.text.bubble.right")
                            }
                            .controlSize(.small)
                            .help("Start a chat with this branch's plan, journal, memory and findings attached")
                            Button {
                                editing = true
                            } label: {
                                Label("Edit branch", systemImage: "pencil")
                            }
                            .controlSize(.small)
                            .disabled(research.isRunning)
                            .help(research.isRunning
                                  ? "Stop the run before editing the plan"
                                  : "Edit the lens, kill criterion, budget and tasks")
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Lens & tasks").font(.caption)
            }
        }
        // The branch page opens its detail already unfolded; the card in the program view
        // stays collapsed, which is what makes that view scannable.
        .onAppear {
            guard startExpanded, !didApplyStartExpanded else { return }
            didApplyStartExpanded = true
            expanded = true
        }
    }
}

/// A published finding, with the ruling that decides whether siblings keep seeing it.
struct FindingRow: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let finding: ProgramFinding
    let icon: String
    let color: Color

    @State private var note = ""
    @State private var writingNote = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    ItemNameText(name: finding.statement,
                                 macros: appState.store?.macroDictionary ?? [:],
                                 lineLimit: 20)
                        .font(.callout)
                        .foregroundStyle(finding.isRejected ? .secondary : .primary)
                    HStack(spacing: 8) {
                        Text(finding.kind.displayName)
                            .font(.caption2.weight(.medium)).foregroundStyle(color)
                        Text(program.branch(planID: finding.branchPlanID)?.title
                             ?? finding.branchPlanID)
                            .font(.caption2).foregroundStyle(.secondary)
                        if !finding.itemIDs.isEmpty {
                            Text(finding.itemIDs.joined(separator: ", "))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        if let path = finding.artifactPath {
                            Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        verdictChip
                    }
                    if let note = finding.verdictNote, !note.isEmpty {
                        ItemNameText(name: note, macros: appState.store?.macroDictionary ?? [:],
                                     fontSize: NSFont.smallSystemFontSize, lineLimit: 6)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                verdictControls
            }
            if writingNote {
                HStack {
                    TextField("Why? (optional — confirmations pass this to the other branches)",
                              text: $note)
                        .textFieldStyle(.roundedBorder)
                    Button("Confirm") { rule(.confirmed) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Reject", role: .destructive) { rule(.rejected) }
                        .controlSize(.small)
                    Button("Cancel") { writingNote = false }.controlSize(.small)
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var verdictChip: some View {
        switch finding.verdict {
        case .confirmed:
            Label("confirmed", systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        case .rejected:
            Label("rejected — withheld from other branches", systemImage: "nosign")
                .font(.caption2).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var verdictControls: some View {
        if program.isVirtual {
            EmptyView()
        } else if finding.verdict == nil {
            if !writingNote {
                Button("Review…") {
                    note = ""
                    writingNote = true
                }
                .controlSize(.small)
                .help("Confirm it (siblings may rely on it) or reject it (siblings stop seeing it)")
            }
        } else {
            Button("Undo") { rule(nil) }
                .controlSize(.small)
                .help("Return this finding to unreviewed")
        }
    }

    private func rule(_ verdict: ProgramFinding.Verdict?) {
        do {
            try appState.setFindingVerdict(verdict, note: note, findingID: finding.id,
                                           programID: program.id)
            writingNote = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Mid-run steering: a standing instruction the branch reads at its next task. This is the
/// difference between watching an agent go down a bad path and redirecting it.
struct GuidanceBox: View {
    @EnvironmentObject private var appState: AppState
    let plan: PlanDocument

    @State private var draft = ""
    @State private var editing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing {
                TextField("e.g. “Stop on the δ=2 case — try the wheel family instead.”",
                          text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save guidance") { save(draft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Cancel") { editing = false }
                        .controlSize(.small)
                    if !plan.guidance.isEmpty {
                        Button("Clear", role: .destructive) { save("") }
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("Applies at the branch's next task — no restart needed.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if plan.guidance.isEmpty {
                Button {
                    draft = ""
                    editing = true
                } label: {
                    Label("Guide this branch", systemImage: "hand.point.right")
                }
                .controlSize(.small)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hand.point.right.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your guidance").font(.caption.weight(.semibold))
                        ItemNameText(name: plan.guidance, macros: appState.store?.macroDictionary ?? [:],
                                     fontSize: NSFont.smallSystemFontSize, lineLimit: 6)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Change") {
                        draft = plan.guidance
                        editing = true
                    }
                    .controlSize(.small)
                }
                .padding(6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func save(_ text: String) {
        do {
            try appState.setGuidance(text, forPlan: plan.id)
            editing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Editing an approved branch: lens, kill criterion, budget, and the tasks that haven't
/// started yet. Disabled while the branch runs — the workbench rewrites the same file.
struct BranchEditor: View {
    @EnvironmentObject private var appState: AppState
    let plan: PlanDocument
    let onDone: () -> Void

    @State private var lens = ""
    @State private var kill = ""
    @State private var budgetMillions: Double = 2
    @State private var tasks: [PlanTask] = []
    @State private var newTaskTitle = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Research lens").font(.caption.weight(.semibold))
                TextEditor(text: $lens)
                    .font(.callout)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Kill criterion").font(.caption.weight(.semibold))
                TextField("", text: $kill, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Branch budget").font(.caption)
                Slider(value: $budgetMillions, in: 0.5...20, step: 0.5).frame(width: 200)
                Text("\(budgetMillions, specifier: "%.1f")M tokens")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }

            Text("Tasks").font(.caption.weight(.semibold))
            ForEach(Array(tasks.enumerated()), id: \.element.index) { position, task in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: task.status.iconName)
                        .foregroundStyle(task.status.iconColor)
                    TextField("", text: Binding(
                        get: { tasks[position].title },
                        set: { tasks[position].title = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(task.status != .pending)
                    Toggle("review", isOn: Binding(
                        get: { tasks[position].reviewGate },
                        set: { tasks[position].reviewGate = $0 }))
                        .toggleStyle(.checkbox).font(.caption)
                    Button {
                        tasks.remove(at: position)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(task.status != .pending)
                    .help(task.status == .pending
                          ? "Remove this task"
                          : "Only tasks that haven't started can be removed — the journal refers to the rest")
                }
            }
            HStack {
                TextField("Add a task…", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let index = (tasks.map(\.index).max() ?? 0) + 1
                    tasks.append(PlanTask(index: index, title: newTaskTitle))
                    newTaskTitle = ""
                }
                .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Save changes") { save() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { onDone() }
                Spacer()
            }
        }
        .onAppear {
            lens = plan.lens
            kill = plan.kill ?? ""
            budgetMillions = Double(plan.tokenBudget) / 1_000_000
            tasks = plan.tasks
        }
    }

    /// Rebuilds the plan through PlanDocument's own editing helpers, so removals renumber
    /// and remap dependencies instead of leaving dangling references. Tasks are tracked by
    /// their original index — titles are exactly what the user may have just changed.
    private func save() {
        var edited = plan
        edited.lens = lens.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.kill = kill.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.tokenBudget = Int(budgetMillions * 1_000_000)

        let originalIndices = Set(plan.tasks.map(\.index))
        let keptIndices = Set(tasks.map(\.index))
        // Highest first, so the lower original numbers stay addressable as we go.
        let removals = originalIndices.subtracting(keptIndices).sorted(by: >)
        for index in removals {
            guard edited.removeTask(index: index) else {
                error = "Task \(index) has already started and can't be removed."
                return
            }
        }

        // Each surviving task shifted down by however many removals sat below it.
        func currentIndex(forOriginal original: Int) -> Int {
            original - removals.filter { $0 < original }.count
        }
        for task in tasks {
            if originalIndices.contains(task.index) {
                let target = currentIndex(forOriginal: task.index)
                guard let position = edited.tasks.firstIndex(where: { $0.index == target }) else { continue }
                edited.tasks[position].title = task.title
                edited.tasks[position].reviewGate = task.reviewGate
            } else {
                edited.appendTask(title: task.title, kind: task.kind, reviewGate: task.reviewGate)
            }
        }

        do {
            try appState.saveEditedPlan(edited)
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Per-branch pause handling: answer a question, continue a checkpoint, raise a budget.
struct BranchRunControls: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var research: ResearchController
    let program: ResearchProgram
    let plan: PlanDocument

    @State private var answerDraft = ""

    var body: some View {
        switch research.state(of: plan.id) {
        case .waitingForUser(let question):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "questionmark.bubble")
                    ItemNameText(name: question.question,
                                 macros: appState.store?.macroDictionary ?? [:],
                                 lineLimit: 4)
                }
                .font(.callout.weight(.medium))
                if !question.context.isEmpty {
                    RenderedMath(markdown: question.context, id: "question-\(plan.id)")
                }
                HStack {
                    TextField("Your answer…", text: $answerDraft, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    Button("Answer & continue") {
                        research.answerBranch(program: program, planID: plan.id, text: answerDraft)
                        answerDraft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(answerDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || research.isRunning)
                }
            }
        case .checkpoint(let afterTask):
            HStack {
                Label("Task \(afterTask) finished — review, then continue.", systemImage: "pause.circle")
                    .font(.callout)
                Spacer()
                Button("Continue") { research.continueBranch(program: program, planID: plan.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(research.isRunning)
            }
        case .budgetPause:
            HStack {
                Label("This branch's token budget is spent.", systemImage: "gauge.high").font(.callout)
                Spacer()
                Button("+1M & continue") {
                    research.raiseBranchBudget(program: program, planID: plan.id, extraTokens: 1_000_000)
                }
                .buttonStyle(.borderedProminent)
                .disabled(research.isRunning)
            }
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
        default:
            if research.status(of: plan.id) == .errored, !research.isRunning {
                HStack {
                    Label("The branch stopped on an error.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Spacer()
                    Button("Retry branch") { research.continueBranch(program: program, planID: plan.id) }
                }
            }
        }
    }
}

// MARK: - Run panel (single plans)

// MARK: - Planner sheet (pass 1)

/// Where a research program starts: a problem statement, then the pipeline that turns it
/// into a portfolio.
///
/// The statement is audited first and the contract frozen from that reading alone, before any
/// attempt at the problem. The contract used to be drafted last, from what the pilots had
/// reached — which let what turned out to be *achievable* decide what counted as an answer.
struct PlannerPane: View {
    @EnvironmentObject private var appState: AppState
    let onCancel: () -> Void

    @State private var problem = ""
    @State private var limits = RunLimits()

    var body: some View {
        PlannerPaneBody(problem: $problem, limits: $limits,
                        planning: appState.planning, onCancel: onCancel)
    }
}

/// What a run may spend and how far it may go without a person.
///
/// Set **before** the run rather than after. "Attach this problem" — the least supervised path,
/// the one that runs overnight without stopping — had no settings at all and hardcoded full
/// autonomy with a 6M ceiling; the supervised path at least got an autonomy picker at approval.
/// That is exactly backwards, so both paths read these.
struct RunLimits: Equatable {
    var execution = AppSettings.researchLimits
    var includePilots = true
    var autonomy: AutonomyLevel = .supervised
    var programTokenBudget = 6_000_000
    var maxConcurrentBranches = 1
    /// Per-run model choice by role — nil for a role means it uses the global default from
    /// Settings > Roles. Raw-string shape (not `ModelChoice`) so it binds straight to
    /// `BranchModelPicker`, the same widget a branch already uses to override its researcher.
    var roleModelOverrides: [AgentTask: RoleModelChoice] = [:]

    var policy: ContinuationPolicy { autonomy.policy }

    /// The roles worth overriding for a run — the rest of `AgentTask` (chat, explorer, …)
    /// plays no part in executing a research program.
    static let overridableRoles: [AgentTask] = [.director, .researcher, .prover, .reviewer, .importer]
}

/// A pending per-role model choice, still being edited in the Start Research view — mirrors
/// `ResearchProgram.Branch`'s raw provider/model pair so it can bind to `BranchModelPicker`.
struct RoleModelChoice: Equatable {
    var providerKind: String?
    var model: String?
}

private struct PlannerPaneBody: View {
    @EnvironmentObject private var appState: AppState
    @Binding var problem: String
    @Binding var limits: RunLimits
    @ObservedObject var planning: ProgramPlanningController
    let onCancel: () -> Void
    @State private var showLimits = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start research").font(.title2.weight(.semibold))
                        Text("The goal is formalized and frozen, then the director chooses direct workers or planned branches. Reports and evidence return to its continuing conversation.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(planning.isGenerating ? "Leave running" : "Close", action: onCancel)
                }
                TextField("Problem to investigate", text: $problem, axis: .vertical)
                    .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(planning.isGenerating)
                HStack {
                    Button("Hand to the director", action: startDirector)
                        .buttonStyle(.borderedProminent)
                        .disabled(planning.isGenerating || appState.research.isRunning || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(showLimits ? "Hide run settings" : "Run settings…") { withAnimation { showLimits.toggle() } }
                        .disabled(planning.isGenerating)
                    Spacer()
                    if planning.isGenerating {
                        ProgressView().controlSize(.small)
                        Text(planning.fullAutoStage ?? "Formalizing goal…").font(.caption)
                        Button("Stop") { planning.cancel() }
                    }
                }
                Text("Program tokens: \(limits.execution.programTokens.displayName) · tool calls: \(limits.execution.toolCalls.displayName)\(overrideSummary)")
                    .font(.caption).foregroundStyle(.secondary)
                if showLimits {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox("Limits for this run") {
                            VStack(alignment: .leading, spacing: 8) {
                                ResearchLimitsEditor(limits: $limits.execution)
                                Stepper("Concurrent assignments: \(limits.maxConcurrentBranches)", value: $limits.maxConcurrentBranches, in: 1...4)
                            }.disabled(planning.isGenerating)
                        }
                        GroupBox("Models for this run") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Overrides the global default from Settings > Roles for this program only.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(RunLimits.overridableRoles) { task in roleRow(task) }
                            }.disabled(planning.isGenerating)
                        }
                    }
                }
                if let error = planning.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(planning.activityLog.isEmpty ? "Goal formalization appears here. The program page shows the director and its assignments." : planning.activityLog)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).id("plannerLogEnd")
                    }
                    .frame(minHeight: 160)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: planning.activityLog) { _, _ in proxy.scrollTo("plannerLogEnd", anchor: .bottom) }
                }
            }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if problem.isEmpty, !planning.problem.isEmpty { problem = planning.problem; limits = planning.proposedLimits }
            if let seed = appState.plannerSeed { appState.plannerSeed = nil; problem = seed.problem }
        }
    }

    private var overrideSummary: String {
        let count = limits.roleModelOverrides.values.filter { $0.providerKind != nil }.count
        guard count > 0 else { return "" }
        return " · \(count) role\(count == 1 ? "" : "s") overridden"
    }

    private func roleRow(_ task: AgentTask) -> some View {
        HStack {
            Text(task.displayName).font(.callout)
            Spacer()
            BranchModelPicker(
                providerKind: Binding(
                    get: { limits.roleModelOverrides[task]?.providerKind },
                    set: { limits.roleModelOverrides[task, default: RoleModelChoice()].providerKind = $0 }),
                model: Binding(
                    get: { limits.roleModelOverrides[task]?.model },
                    set: { limits.roleModelOverrides[task, default: RoleModelChoice()].model = $0 }),
                defaultLabel: "\(task.displayName) setting")
        }
    }

    private func startDirector() {
        planning.proposedLimits = limits
        let overrides = limits.roleModelOverrides.compactMapValues { choice -> ResearchProgram.ModelOverride? in
            guard let kind = choice.providerKind, let model = choice.model else { return nil }
            return ResearchProgram.ModelOverride(providerKind: kind, model: model)
        }
        let keyedOverrides = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        planning.runDirectorFirst(problem: problem, maxConcurrentBranches: limits.maxConcurrentBranches,
                                  limits: limits.execution, roleModelOverrides: keyedOverrides) { program in
            appState.researchPage = .program(id: program.id)
            appState.research.startProgram(program, mode: .auto)
            appState.planningPhase = .idle
        }
    }
}
