import SwiftUI
import ManifieldCore
import ManifieldAgents

/// The last gate before a program exists on disk: the generated branch plans, each still
/// editable — task titles, review gates, the lens and kill criterion the branch will run
/// under. Approving writes one plan file per branch plus the program manifest.
///
/// Rendered inline in the Research tab so a long plan is readable at full width.
struct ProgramReviewPane: View {
    @EnvironmentObject private var appState: AppState

    let setup: ProgramSetup
    @ObservedObject var planning: ProgramPlanningController
    let onBack: () -> Void
    /// Leaves the pane without touching the session — generation keeps running and the
    /// program list keeps a row that leads back here.
    let onClose: () -> Void
    let onFinished: (ResearchProgram) -> Void

    @State private var selectedLegID: String?
    @State private var saveError: String?
    /// The user's ruling on the drafted contract. Nothing binds until this is on: a contract
    /// nobody checked still runs, but its verdicts have to say so.
    @State private var contractApproved = false
    @State private var autonomy: AutonomyLevel = .supervised
    @State private var showContractSheet = false
    @State private var didSeedAutonomy = false

    private var selectedLeg: ProgramPlanningController.Leg? {
        planning.legs.first { $0.id == selectedLegID } ?? planning.legs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HSplitView {
                branchList.frame(minWidth: 220, idealWidth: 260)
                branchDetail.frame(minWidth: 420)
            }
            Divider()
            contractBar
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Seeded from what the user set before planning began; they are asked once, and this
        // pane is where they get to change their mind rather than state it for the first time.
        .onAppear {
            guard !didSeedAutonomy else { return }
            didSeedAutonomy = true
            autonomy = planning.proposedLimits.autonomy
        }
        .sheet(isPresented: $showContractSheet) {
            ContractReviewSheet(
                draft: planning.contractDraft,
                goal: planning.goalDraft,
                onDone: { showContractSheet = false })
        }
    }

    /// What the run will be measured against, and how far it may go without a person. Both are
    /// optional: leaving them alone gives exactly the behaviour every earlier program had.
    private var contractBar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Research goal").font(.callout.weight(.medium))
                    if planning.contractDraft != nil {
                        Button("View") { showContractSheet = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                if planning.isGenerating, planning.contractDraft == nil,
                   planning.runningPilot != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(planning.runningPilot.map { "Pilot: \($0.title)" } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let draft = planning.contractDraft {
                    // Drafted from the audited statement before any of this ran — all that
                    // is left here is reading it and signing off.
                    Text(planning.goalDraft.map {
                        "\($0.item.name) · `\($0.item.id)` · automatic interpretation not yet confirmed"
                    } ?? draft.contract.statement)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Toggle("I confirm this item states the intended research goal",
                           isOn: $contractApproved)
                        .font(.caption)
                        // A redraft is a different contract; the old approval must not carry.
                        .onChange(of: draft.contract.statement) { _, _ in contractApproved = false }
                        .help("Unapproved, the run still uses it — but a 'settled' verdict "
                              + "reports as settled against a contract nobody checked.")
                } else {
                    // The drafting turn failed, or this session predates the pilots-first
                    // ordering. The run is allowed to proceed without a contract — it just
                    // has nothing to measure itself against, and says so.
                    Text("No contract drafted. The run will have no definition of what would "
                         + "completely answer the question, so nothing can be claimed against it.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Draft the success contract") {
                        planning.draftContract(goal: setup.goal)
                    }
                    .font(.caption)
                    .disabled(planning.isGenerating)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Autonomy").font(.callout.weight(.medium))
                Picker("", selection: $autonomy) {
                    ForEach(AutonomyLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(autonomy.explanation)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setup.title.isEmpty ? "Review the program" : setup.title)
                    .font(.title3.weight(.semibold))
                RenderedMath(markdown: setup.goal, id: "review-goal")
            }
            Spacer()
            if planning.isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    // `isGenerating` covers both phases; saying "planned" during the pilots
                    // would report progress on work that has not started.
                    Text(planning.runningPilot.map { "Pilot: \($0.title)" }
                         ?? "\(planning.completedCount)/\(planning.legs.count) planned")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { planning.cancel() }
                        .help("Stops the current phase; anything already generated stays")
                }
            }
            Button("Close") { onClose() }
                .help("Returns to the program list — planning keeps running and this stays reachable there")
        }
        .padding()
    }

    private var branchList: some View {
        List(selection: $selectedLegID) {
            ForEach(planning.legs) { leg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if leg.approach.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true) }
                        ItemNameText(name: leg.approach.title,
                                     macros: appState.store?.macroDictionary ?? [:], lineLimit: 2)
                            .font(.callout)
                    }
                    legStatus(leg)
                }
                .padding(.vertical, 2)
                .tag(leg.id)
            }
        }
    }

    @ViewBuilder
    private func legStatus(_ leg: ProgramPlanningController.Leg) -> some View {
        switch leg.status {
        case .pending:
            Text("queued").font(.caption2).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("planning…").font(.caption2).foregroundStyle(.secondary)
            }
        case .done:
            Text("\(leg.option?.tasks.count ?? 0) tasks")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder
    private var branchDetail: some View {
        if let leg = selectedLeg {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ItemNameText(name: leg.approach.title,
                                         macros: appState.store?.macroDictionary ?? [:], lineLimit: 2)
                                .font(.headline)
                            if leg.approach.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true) }
                            Spacer()
                            if case .failed = leg.status {
                                Button("Retry") { planning.retry(legID: leg.id) }
                                    .disabled(planning.isGenerating)
                            }
                        }
                        RenderedMath(markdown: leg.approach.mechanism, id: "mechanism-\(leg.id)")
                    }

                    GroupBox("Research lens") {
                        TextEditor(text: Binding(
                            get: { leg.approach.prior },
                            set: { newValue in
                                planning.updateLeg(id: leg.id) { updating in
                                    updating.approach = ApproachProposal.Approach(
                                        title: updating.approach.title,
                                        mechanism: updating.approach.mechanism,
                                        prior: newValue,
                                        expectedPayoff: updating.approach.expectedPayoff,
                                        challengesLeadingAnswer:
                                            updating.approach.challengesLeadingAnswer,
                                        ontologyCells: updating.approach.ontologyCells,
                                        killCriterion: updating.approach.killCriterion,
                                        costClass: updating.approach.costClass)
                                }
                            }))
                            .font(.callout)
                            .frame(height: 84)
                    }

                    GroupBox("Kill criterion") {
                        TextField("", text: Binding(
                            get: { leg.approach.killCriterion },
                            set: { newValue in
                                planning.updateLeg(id: leg.id) { updating in
                                    updating.approach = ApproachProposal.Approach(
                                        title: updating.approach.title,
                                        mechanism: updating.approach.mechanism,
                                        prior: updating.approach.prior,
                                        expectedPayoff: updating.approach.expectedPayoff,
                                        challengesLeadingAnswer:
                                            updating.approach.challengesLeadingAnswer,
                                        ontologyCells: updating.approach.ontologyCells,
                                        killCriterion: newValue,
                                        costClass: updating.approach.costClass)
                                }
                            }), axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let option = leg.option {
                        GroupBox("Plan — \(option.summary)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(option.tasks.enumerated()), id: \.offset) { index, task in
                                    taskRow(legID: leg.id, index: index, task: task)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if case .running = leg.status {
                        HStack { ProgressView().controlSize(.small); Text("Planning this branch…") }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No branches", systemImage: "arrow.triangle.branch")
        }
    }

    private func taskRow(legID: String, index: Int, task: PlanTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(task.index).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(
                    get: { task.title },
                    set: { newValue in
                        planning.updateLeg(id: legID) { leg in
                            leg.option?.tasks[index].title = newValue
                        }
                    }))
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    if case .prove(let target) = task.kind {
                        Text("prove \(target)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    if !task.dependsOn.isEmpty {
                        Text("after \(task.dependsOn.map(String.init).joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("review", isOn: Binding(
                get: { task.reviewGate },
                set: { newValue in
                    planning.updateLeg(id: legID) { leg in
                        leg.option?.tasks[index].reviewGate = newValue
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { onBack() }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Text("Writes programs/<id>.json and one plan file per branch.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Approve program & save") { approve() }
                .buttonStyle(.borderedProminent)
                .disabled(planning.isGenerating || planning.approvedBranches.isEmpty)
        }
        .padding()
    }

    private func approve() {
        do {
            // The approval stamp is the only thing that marks a contract reviewed. An
            // unapproved draft still binds the run — it is what enforcement measures against —
            // but `reviewedAt` stays nil so a verdict has to report itself as unchecked.
            var contract = planning.contractDraft?.contract
            if contractApproved { contract?.reviewedAt = Date() }
            guard let targetItemID = planning.goalDraft?.item.id else {
                throw CoreError.io("No formal research-goal item was selected")
            }

            let program = try appState.approveProgram(
                goal: planning.problem,
                title: setup.title,
                branches: planning.approvedBranches,
                skippedCells: setup.skippedCells,
                programTokenBudget: setup.programTokenBudget,
                maxConcurrentBranches: setup.maxConcurrentBranches,
                runMode: setup.runMode,
                contract: contract,
                continuation: autonomy.policy,
                pilotsEnabled: planning.proposedLimits.includePilots,
                targetItemID: targetItemID,
                initialFindings: planning.recognition?.finding.map { [$0] } ?? [],
                initialSolutions: planning.recognition?.candidate.map { [$0] } ?? [],
                adoptTurnsFromSession: planning.sessionID)
            onFinished(program)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// How far a program runs without a person — the supervision dial, as three named levels
/// rather than a toggle. The rungs differ in exactly one thing each: what still stops the run.
enum AutonomyLevel: String, CaseIterable, Identifiable {
    /// Every pause waits for a human. What every program did before policies existed.
    case supervised
    /// Runs the night. A counterexample is verified in fresh context and routed to the
    /// director; only a question about the statement itself still stops.
    case unattended
    /// Nothing stops it but its budgets — statement-level questions proceed under a
    /// journalled assumption.
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .supervised: return "Supervised"
        case .unattended: return "Unattended"
        case .full: return "Full auto"
        }
    }

    var policy: ContinuationPolicy {
        switch self {
        case .supervised: return .manual
        case .unattended: return .overnight
        case .full: return .fullAuto
        }
    }

    var explanation: String {
        switch self {
        case .supervised:
            return "Every pause waits for you."
        case .unattended:
            return "Continues past checkpoints, tops up budgets, and proceeds on task questions under a recorded assumption. A counterexample is verified by an independent adjudicator and handed to the director instead of to you; only a question about the statement itself stops the run."
        case .full:
            return "Nothing stops the run but its budgets — including questions about the statement, which proceed under a recorded assumption. You are told when it succeeds or gives up."
        }
    }
}

/// The drafted contract, in full. Read-only: editing a ladder in a sheet is a bigger surface
/// than it is worth right now, and the draft is regenerable. What matters is that the reviewer
/// can actually see what they are approving — a five-line ladder is a cheap thing to check,
/// which is the whole reason the ladder is the gate rather than the transcript.
private struct ContractReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    let draft: ContractDrafter.Draft?
    let goal: ResearchGoalEditor.Result?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Research goal item").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let draft {
                        if let goal {
                            section("Theory item") {
                                Text(goal.item.name).font(.headline)
                                Text("\(goal.item.id) · \(goal.item.type.rawValue)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(goal.createdItem
                                     ? "Created for this request; interpretation is automatic and not user-confirmed."
                                     : "Selected from the existing library; interpretation is automatic and not user-confirmed.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let note = draft.ambiguityNote {
                            section("Ambiguity in the statement") {
                                RenderedMath(markdown: note, id: "ambiguity-note")
                                Text("This is the cheapest thing to fix now — far cheaper "
                                     + "than after branches are planned against the wrong reading.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        section("Statement") {
                            RenderedMath(markdown: draft.contract.statement, id: "review-statement")
                        }
                        if !draft.contract.completenessRationale.isEmpty {
                            section("Why that list is complete") {
                                RenderedMath(markdown: draft.contract.completenessRationale, id: "review-rationale")
                                Text("The argument that nothing else would answer the question. "
                                     + "If a valid answer is missing here, a branch that "
                                     + "produces it has no way to report success.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !draft.contract.ambiguities.isEmpty {
                            section("Readings the statement admits") {
                                ForEach(draft.contract.ambiguities, id: \.self) { line in
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text("•")
                                        ItemNameText(name: line,
                                                     macros: appState.store?.macroDictionary ?? [:],
                                                     fontSize: NSFont.systemFontSize, lineLimit: 6)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    } else {
                        Text("No contract drafted.").foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 620, height: 520)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
