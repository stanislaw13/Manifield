import SwiftUI
import ManifieldCore
import ManifieldAgents

/// A program's settings, after approval.
///
/// Autonomy, budgets, concurrency and per-branch models were all frozen at the moment a
/// program was approved, with no way even to *read* them afterwards — so retuning an
/// overnight run meant rebuilding it. They are editable here, and refused while the program
/// is running, because the runner captured its manifest at launch.
struct SetupSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController

    @State private var error: String?

    private var isRunning: Bool {
        research.isRunning && research.isActive(programID: program.id)
    }

    private var policy: ContinuationPolicy { program.continuation ?? .manual }

    private var autonomy: AutonomyLevel {
        if !policy.isUnattended { return .supervised }
        return policy.questionHandling == .assumeAll ? .full : .unattended
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isRunning {
                    Label("This program is running. Stop it to change these — it is using the values it started with.",
                          systemImage: "lock")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                autonomyBox
                budgetBox
                modelsBox
                if let contract = program.contract { contractBox(contract) }
            }
            .padding()
            .disabled(program.isVirtual)
        }
    }

    // MARK: Autonomy

    private var autonomyBox: some View {
        GroupBox("Autonomy") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(
                    get: { autonomy },
                    set: { level in edit { $0.continuation = level.policy } })) {
                    ForEach(AutonomyLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(autonomy.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if autonomy != .supervised {
                    LabeledContent("Wall-clock ceiling") {
                        Text(policy.maxWallClockSeconds > 0
                             ? "\(Int(policy.maxWallClockSeconds / 3600))h"
                             : "none")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Toggle("Check decisive findings before they circulate", isOn: Binding(
                        get: { policy.autoAdjudicateCounterexamples },
                        set: { on in
                            edit {
                                var next = $0.continuation ?? .overnight
                                next.autoAdjudicateCounterexamples = on
                                $0.continuation = next
                            }
                        }))
                        .font(.callout)
                        .help("A fresh-context adjudicator independently recomputes a finding before it enters the pool, and can refuse it. Off, findings publish on the branch's own say-so.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isRunning)
        }
    }

    // MARK: Budgets

    private var budgetBox: some View {
        GroupBox("Budgets") {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: Binding(
                    get: { program.programTokenBudget / 1_000_000 },
                    set: { value in edit { $0.programTokenBudget = max(1, value) * 1_000_000 } }),
                        in: 1...100) {
                    Text("Program ceiling: \(program.programTokenBudget / 1_000_000)M tokens across all branches")
                        .font(.callout)
                }
                Stepper(value: Binding(
                    get: { program.maxConcurrentBranches },
                    set: { value in edit { $0.maxConcurrentBranches = max(1, value) } }),
                        in: 1...4) {
                    Text("\(program.maxConcurrentBranches) branch\(program.maxConcurrentBranches == 1 ? "" : "es") at a time")
                        .font(.callout)
                }
                Text("One at a time is the default on purpose: a later branch can read what killed an earlier one, which branches running in parallel cannot.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isRunning)
        }
    }

    // MARK: Models

    private var modelsBox: some View {
        GroupBox("Models") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Roles are configured globally in Settings. A branch can override the researcher model for itself — spend the strong model where the decisive reasoning is.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(program.branches, id: \.planID) { branch in
                    HStack(spacing: 8) {
                        if branch.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true) }
                        ItemNameText(name: branch.title,
                                     macros: appState.store?.macroDictionary ?? [:], lineLimit: 1)
                            .font(.callout)
                        if let priority = branch.priority {
                            Text("#\(priority + 1)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .help("Attack order — the planner or the director chose this")
                        }
                        Spacer()
                        BranchModelPicker(
                            providerKind: Binding(
                                get: { branch.providerKind },
                                set: { value in setBranch(branch.planID) { $0.providerKind = value } }),
                            model: Binding(
                                get: { branch.model },
                                set: { value in setBranch(branch.planID) { $0.model = value } }))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isRunning)
        }
    }

    // MARK: Contract

    private func contractBox(_ contract: SuccessContract) -> some View {
        GroupBox("Success contract") {
            VStack(alignment: .leading, spacing: 8) {
                if !contract.isReviewed {
                    Label("Nobody has approved this contract. The run still measures against it — but a “settled” verdict would be settled against an unchecked definition.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("I have read and approve this contract") {
                        edit { $0.contract?.reviewedAt = Date() }
                    }
                    .controlSize(.small)
                    .disabled(isRunning)
                } else {
                    Label("Approved", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }

                RenderedMath(markdown: contract.statement, id: "contract-\(program.id)")

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(contract.completeAnswers) { answer in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(answer.id).font(.caption.monospaced().weight(.semibold))
                                .frame(width: 30, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                RenderedMath(markdown: answer.statement, id: "answer-\(program.id)-\(answer.id)")
                                Text("established by \(answer.evidence)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !contract.notCounted.isEmpty {
                    DisclosureGroup("Does not count as a solution (\(contract.notCounted.count))") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(contract.notCounted, id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("•")
                                    ItemNameText(name: line,
                                                 macros: appState.store?.macroDictionary ?? [:],
                                                 fontSize: NSFont.smallSystemFontSize, lineLimit: 6)
                                }
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                    }
                    .font(.callout)
                }

                if !contract.completenessRationale.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Why these cover every way of answering it")
                            .font(.caption.weight(.medium))
                        RenderedMath(markdown: contract.completenessRationale, id: "rationale-\(program.id)")
                    }
                }

                if !contract.ambiguities.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Readings that were settled")
                            .font(.caption.weight(.medium))
                        ForEach(contract.ambiguities, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("•")
                                ItemNameText(name: line,
                                             macros: appState.store?.macroDictionary ?? [:],
                                             fontSize: NSFont.smallSystemFontSize, lineLimit: 6)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Text("The contract is frozen for the run — that immutability is what stops a weaker result being reported as the answer.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Editing

    private func edit(_ mutate: @escaping (inout ResearchProgram) -> Void) {
        do {
            try appState.updateProgram(program, mutate)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setBranch(_ planID: String,
                           _ mutate: @escaping (inout ResearchProgram.Branch) -> Void) {
        edit { program in
            guard let index = program.branches.firstIndex(where: { $0.planID == planID }) else { return }
            mutate(&program.branches[index])
        }
    }
}
