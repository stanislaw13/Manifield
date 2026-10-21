import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Planning pass 1's output: the user picks which approaches become branches, edits their
/// lenses, and sets the program's budget and concurrency. Selecting several approaches is
/// the point — they run in isolation from each other under contradictory priors.
///
/// Rendered inline in the Research tab (not as a sheet) so a long portfolio gets the full
/// window and the sidebar stays reachable while you read it.
struct ApproachSelectionPane: View {
    @EnvironmentObject private var appState: AppState

    let proposal: ApproachProposal
    /// Carries the user's choices forward to the review step.
    let onGenerate: (ProgramSetup) -> Void
    /// The user rejected the portfolio wholesale; design it again from the same problem.
    let onReplan: () -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []
    @State private var edited: [String: EditedApproach] = [:]
    @State private var programBudgetMillions: Double = 6
    @State private var maxConcurrent = 1
    /// Seeded once from the limits set before planning started, so the user is asked for
    /// budgets once rather than at every gate.
    @State private var didSeedLimits = false
    @State private var runMode: RunMode = .auto

    /// The user's edits to one approach, kept separate from the model's proposal.
    private struct EditedApproach {
        var bias: String
        var kill: String
        var providerKind: String?
        var model: String?
    }

    private var selectedApproaches: [ApproachProposal.Approach] {
        proposal.approaches.filter { selected.contains($0.title) }
    }

    /// A portfolio in which nothing attacks the leading answer is the failure the whole
    /// mechanism exists to prevent, so the pane says so before the user commits to one.
    private var hasBreaker: Bool {
        selectedApproaches.contains(where: \.challengesLeadingAnswer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(proposal.approaches) { approach in
                        approachCard(approach)
                    }
                    if !hasBreaker, !selected.isEmpty {
                        Label("No route that challenges the leading answer is selected — nothing in this program will attack the answer it arrives at.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    skippedCells
                    advanced
                }
                .padding()
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Budgets carry over from what the user set before planning began. Asking again
            // here with different defaults would quietly override the answer they gave.
            if !didSeedLimits {
                didSeedLimits = true
                let limits = appState.planning.proposedLimits
                programBudgetMillions = Double(limits.programTokenBudget) / 1_000_000
                maxConcurrent = limits.maxConcurrentBranches
            }
            for approach in proposal.approaches {
                edited[approach.title] = EditedApproach(bias: approach.prior,
                                                        kill: approach.killCriterion)
            }
            // Pre-select the planner's own activation picks — the same set a full-auto run
            // would execute, here as a default the user can override. Manifests written by
            // an older planner default every approach to activated; in that case fall back
            // to the cheapest breaker so the pre-selection stays meaningful.
            let activated = proposal.approaches.filter(\.activate)
            if !activated.isEmpty, activated.count < proposal.approaches.count {
                selected = Set(activated.map(\.title))
            } else if let challenger = proposal.approaches
                .filter(\.challengesLeadingAnswer)
                .min(by: { $0.costClass.order < $1.costClass.order }) {
                selected.insert(challenger.title)
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose approaches").font(.title3.weight(.semibold))
                RenderedMath(markdown: proposal.goal, id: "approach-goal")
                Text("Each selected approach becomes a branch that runs in isolation under its own lens. Only hard results cross between them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                goalKindRow
            }
            Spacer()
        }
        .padding()
    }

    /// The escape hatch when the portfolio itself is wrong. There is no longer a goal-kind
    /// picker here: the framing the planner used to choose is now the success contract's,
    /// settled before any of this ran and reviewed on its own screen.
    private var goalKindRow: some View {
        HStack(spacing: 8) {
            Text("None of these routes is worth running?")
                .font(.caption).foregroundStyle(.secondary)
            Button("Design the portfolio again") { onReplan() }
                .font(.caption)
            Spacer()
        }
        .help("Throws this portfolio away and runs the design pass again on the same problem. The success contract and the pilots are kept — they cost the most and do not depend on the portfolio.")
    }

    private func approachCard(_ approach: ApproachProposal.Approach) -> some View {
        let isSelected = selected.contains(approach.title)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { isSelected },
                        set: { on in
                            if on { selected.insert(approach.title) } else { selected.remove(approach.title) }
                        })) {
                        ItemNameText(name: approach.title,
                                     macros: appState.store?.macroDictionary ?? [:], lineLimit: 1)
                            .font(.callout.weight(.semibold))
                    }
                    .toggleStyle(.checkbox)
                    if approach.challengesLeadingAnswer { ChallengerChip(challengesLeadingAnswer: true) }
                    Text(approach.costClass.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                RenderedMath(markdown: approach.mechanism, id: "approach-mechanism-\(approach.title)")
                if !approach.ontologyCells.isEmpty {
                    Text(approach.ontologyCells.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if isSelected {
                    DisclosureGroup("Lens & settings") {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Research lens — the standing prior this branch works under")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: Binding(
                                    get: { edited[approach.title]?.bias ?? approach.prior },
                                    set: { edited[approach.title]?.bias = $0 }))
                                    .font(.callout)
                                    .frame(height: 76)
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3)))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Kill criterion — what ends this branch")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("", text: Binding(
                                    get: { edited[approach.title]?.kill ?? approach.killCriterion },
                                    set: { edited[approach.title]?.kill = $0 }), axis: .vertical)
                                    .lineLimit(1...3)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Spacer()
                                BranchModelPicker(
                                    providerKind: Binding(
                                        get: { edited[approach.title]?.providerKind },
                                        set: { edited[approach.title]?.providerKind = $0 }),
                                    model: Binding(
                                        get: { edited[approach.title]?.model },
                                        set: { edited[approach.title]?.model = $0 }))
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var skippedCells: some View {
        if !proposal.skippedCells.isEmpty {
            DisclosureGroup("Approaches the planner deliberately skipped (\(proposal.skippedCells.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(proposal.skippedCells.enumerated()), id: \.offset) { _, cell in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(cell.cell).font(.caption.weight(.medium))
                            Text(cell.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Program ceiling").font(.callout)
                    Slider(value: $programBudgetMillions, in: 1...60, step: 0.5)
                        .frame(width: 220)
                    Text("\(programBudgetMillions, specifier: "%.1f")M tokens total")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Picker("Run mode", selection: $runMode) {
                    ForEach(RunMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(width: 380)
                if runMode == .checkpoint {
                    Text("Checkpoint mode pauses after every task of every branch — with several branches that is a lot of pauses.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Branches running at once: \(maxConcurrent)",
                        value: $maxConcurrent, in: 1...3)
                    .frame(width: 380)
                if maxConcurrent > 1 {
                    Label("Experimental — the providers have no rate-limit retry, so a 429 stops that branch until you resume it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button("Discard") { onCancel() }
            Spacer()
            Text("\(selected.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Button("Generate branch plans") { generate() }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
        }
        .padding()
    }

    // MARK: Actions

    private func generate() {
        let legs = selectedApproaches.map { approach -> ProgramPlanningController.Leg in
            var approach = approach
            if let edit = edited[approach.title] {
                approach = ApproachProposal.Approach(
                    title: approach.title, mechanism: approach.mechanism,
                    prior: edit.bias, expectedPayoff: approach.expectedPayoff,
                    challengesLeadingAnswer: approach.challengesLeadingAnswer,
                    ontologyCells: approach.ontologyCells,
                    killCriterion: edit.kill, costClass: approach.costClass,
                    activate: approach.activate, modelTier: approach.modelTier)
            }
            let edit = edited[approach.title]
            return ProgramPlanningController.Leg(
                approach: approach,
                // Retained on the plan for backward-compatible serialization; execution uses
                // only the program-wide ceiling.
                tokenBudget: Int(programBudgetMillions * 1_000_000),
                providerKind: edit?.providerKind,
                model: edit?.model)
        }
        onGenerate(ProgramSetup(
            title: proposal.title,
            goal: proposal.goal,
            legs: legs,
            skippedCells: proposal.skippedCells,
            programTokenBudget: Int(programBudgetMillions * 1_000_000),
            maxConcurrentBranches: maxConcurrent,
            runMode: runMode))
    }
}

/// Everything the review step needs that isn't already in the planning controller.
struct ProgramSetup {
    /// Short name for the program; the goal statement is the full directive sentence.
    var title: String
    var goal: String
    var legs: [ProgramPlanningController.Leg]
    var skippedCells: [ResearchProgram.SkippedCell]
    var programTokenBudget: Int
    var maxConcurrentBranches: Int
    var runMode: RunMode
}

/// Per-branch model override — a cheap model for a scan branch, an expensive one for the
/// deep proof. Lists only providers with a key configured, like ModelTaskPicker.
struct BranchModelPicker: View {
    @ObservedObject private var modelCache = ModelListCache.shared
    @Binding var providerKind: String?
    @Binding var model: String?
    /// What "Default" falls back to — the researcher role for a branch override, but any
    /// other role's display name when this picker is reused for a role-level override.
    var defaultLabel = "Researcher setting"

    private var listedKinds: [ProviderKind] {
        let configured = ProviderKind.allCases.filter(AppSettings.isProviderConfigured)
        return configured.isEmpty ? ProviderKind.allCases : configured
    }

    var body: some View {
        Menu {
            Button {
                providerKind = nil
                model = nil
            } label: {
                if providerKind == nil { Image(systemName: "checkmark") }
                Text("Default (\(defaultLabel))")
            }
            ForEach(listedKinds) { kind in
                Section(kind.displayName) { modelButtons(for: kind) }
            }
        } label: {
            Text(label).font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var label: String {
        guard let model else { return "Default model" }
        return String(model.suffix(22))
    }

    @ViewBuilder
    private func modelButtons(for kind: ProviderKind) -> some View {
        ForEach(modelCache.options(for: kind)) { option in
            let isChosen = providerKind == kind.rawValue && model == option.id
            Button {
                providerKind = kind.rawValue
                model = option.id
            } label: {
                if isChosen { Image(systemName: "checkmark") }
                Text(option.displayName)
            }
        }
    }
}
