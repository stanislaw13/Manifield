import SwiftUI
import ManifieldCore
import ManifieldAgents

/// When the user last opened a program's page, so it can lead with what has happened since.
///
/// `UserDefaults`, not the manifest: this is one reader's view state, and the manifest is
/// read by agents. A program that has never been opened reports `nil`, which the page reads
/// as "everything is new" — correct for a run the user has not seen at all yet.
enum ProgramVisits {
    private static func key(_ programID: String) -> String {
        "research.lastViewed.\(programID)"
    }

    static func lastViewed(_ programID: String) -> Date? {
        UserDefaults.standard.object(forKey: key(programID)) as? Date
    }

    static func markViewed(_ programID: String) {
        UserDefaults.standard.set(Date(), forKey: key(programID))
    }
}

/// The program page's sections. Overview is the hub; the rest are its spokes.
enum ProgramSegment: String, CaseIterable, Identifiable {
    case overview, origin, map, routes, branches, evidence, setup, log

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .origin: return "Origin"
        case .map: return "Map"
        case .routes: return "Routes"
        case .branches: return "Branches"
        case .evidence: return "Evidence"
        case .setup: return "Setup"
        case .log: return "Log"
        }
    }
}

/// One research program, at full width: a fixed status header over a segmented body.
///
/// The header answers "where does this stand" without scrolling — the director's verdict,
/// what would answer the question, the budget. Overview is the hub: the most important thing
/// from each section, with a way into that section's own page. Everything on it is a projection
/// of durable state, never a generated summary, so it cannot drift from what actually happened.
struct ProgramPage: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram

    var body: some View {
        if program.execution != nil {
            PersistentProgramPage(program: program, research: appState.research)
        } else {
            ProgramPageBody(program: program, research: appState.research)
        }
    }
}

private struct ProgramPageBody: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    /// Nested ObservableObjects do not propagate through AppState, so the controller is
    /// observed directly or the page never updates while a run is live.
    @ObservedObject var research: ResearchController

    @State private var segment: ProgramSegment = .overview
    @State private var pendingDeleteBranch: String?
    @State private var actionError: String?
    /// Captured once on appear: it must not move while the user is reading the page.
    @State private var lastViewed: Date?

    /// A standalone plan has no contract, routes or director — the segments that would be
    /// empty are not offered rather than shown blank.
    private var segments: [ProgramSegment] {
        program.isVirtual ? [.overview, .branches, .evidence, .log] : ProgramSegment.allCases
    }

    private var isLive: Bool { research.isActive(programID: program.id) }

    private var status: ProgramStatus {
        ProgramStatus.make(program: program, records: records, items: appState.store?.items ?? [],
                           programRecord: nil,
                           tokensSpent: appState.store?.usageTokens(program: program))
    }

    private var records: [String: RunRecord] {
        var records: [String: RunRecord] = [:]
        for branch in program.branches {
            if isLive, let live = research.record(of: branch.planID) {
                records[branch.planID] = live
            } else if let saved = research.pendingRecord(for: branch.planID) {
                records[branch.planID] = saved
            }
        }
        return records
    }

    private var findings: [ProgramFinding] {
        isLive ? research.findings : program.findings
    }

    private var changes: [LibraryChange] {
        isLive && !research.libraryChanges.isEmpty
            ? research.libraryChanges
            : (program.lastRunChanges ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgramHeader(program: program, status: status, research: research,
                          actionError: $actionError,
                          onDelete: { appState.researchPage = .list })
            Divider()
            Picker("", selection: $segment) {
                ForEach(segments) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            body(for: segment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { lastViewed = ProgramVisits.lastViewed(program.id) }
        // Marked on the way out, so "since you last looked" stays on screen for as long as
        // the user is actually looking at it.
        .onDisappear { ProgramVisits.markViewed(program.id) }
        .confirmationDialog(
            "Delete this branch?",
            isPresented: Binding(get: { pendingDeleteBranch != nil },
                                 set: { if !$0 { pendingDeleteBranch = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteBranch
        ) { planID in
            Button("Delete", role: .destructive) {
                do { try appState.deleteBranch(planID: planID, from: program) }
                catch { actionError = error.localizedDescription }
                pendingDeleteBranch = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteBranch = nil }
        } message: { planID in
            Text("This permanently deletes the branch “\(program.branch(planID: planID)?.title ?? planID)”, its research memory, and any findings it published. The rest of the program is untouched.")
        }
    }

    @ViewBuilder
    private func body(for segment: ProgramSegment) -> some View {
        switch segment {
        case .origin:
            OriginSegment(program: program)
        case .map:
            MapSegment(program: program, records: records)
        case .overview:
            OverviewSegment(
                program: program, status: status, research: research,
                findings: findings, changes: changes, lastViewed: lastViewed,
                onGo: { self.segment = $0 })
        case .routes:
            RoutesSegment(status: status, program: program)
        case .branches:
            BranchesSegment(program: program, research: research,
                            onRequestDelete: { pendingDeleteBranch = $0 })
        case .evidence:
            EvidenceSegment(program: program, findings: findings, changes: changes)
        case .setup:
            SetupSegment(program: program, research: research)
        case .log:
            LogSegment(program: program, research: research)
        }
    }
}

// MARK: - Header

/// The three-second read, pinned above every segment.
private struct ProgramHeader: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let status: ProgramStatus
    @ObservedObject var research: ResearchController
    @Binding var actionError: String?
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    private var isLive: Bool { research.isActive(programID: program.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    appState.researchPage = .list
                } label: {
                    Label("Programs", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to all research programs")

                ItemNameText(name: program.displayName,
                             macros: appState.store?.macroDictionary ?? [:],
                             fontSize: NSFont.systemFontSize + 3, lineLimit: 1)
                    .font(.title3.weight(.semibold))
                if !program.isVirtual { ProgramStatusChip(status: program.status) }
                Spacer()
                runControls
                programMenu
            }

            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }

            // The director's own words, written by a turn that was happening anyway.
            if let headline = status.headline ?? research.directorStatus, isLive || !headline.isEmpty {
                RenderedMath(markdown: headline, id: "headline-\(program.id)")
                    .padding(8)
                    .background(Color.accentColor.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            if status.contractUnreviewed {
                Label("The formal goal was interpreted automatically and not confirmed by a user — a “settled” verdict means settled against that frozen reading.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !status.completions.isEmpty {
                CompletionStrip(completions: status.completions,
                                solutions: status.solutions,
                                completenessRationale: program.contract?.completenessRationale ?? "")
            }

            HStack(spacing: 10) {
                if !program.isVirtual {
                    Text("generation \(status.generation)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                }
                ProgressView(value: Double(min(status.tokensSpent, max(status.tokensBudget, 1))),
                             total: Double(max(status.tokensBudget, 1)))
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                Text("\(status.tokensSpent / 1000)k / \(status.tokensBudget / 1000)k tokens")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                // Token spend above is a dollar proxy the researcher's budget actually
                // constrains on; for a branch running on Codex the binding constraint is
                // the ChatGPT plan's usage window instead, which token counts don't reflect
                // at all — shown alongside so both limits are visible while a program runs.
                CodexPlanUsageIndicator()
            }

            if let pause = research.pause(of: program) {
                PauseBanner(pause: pause, program: program)
            }
        }
        .padding()
        .confirmationDialog("Delete this program?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try appState.deleteProgram(program)
                    onDelete()
                } catch {
                    actionError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the program, its \(program.branches.count) branch plan(s) and their research memories. Theory items and artifacts it produced are not touched.")
        }
    }

    @ViewBuilder
    private var runControls: some View {
        if isLive, research.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Button("Stop", role: .destructive) { research.cancel() }
            }
        } else if program.status != .done {
            Button {
                research.startProgram(program, mode: .auto)
            } label: {
                Label(isLive ? "Resume" : "Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Runs the branches in the order the planner chose")
        }
    }

    private var programMenu: some View {
        Menu {
            Section("Mark as") {
                ForEach([ResearchProgram.Status.active, .paused, .done, .failed, .abandoned],
                        id: \.self) { status in
                    Button {
                        do { try appState.setProgramStatus(status, for: program) }
                        catch { actionError = error.localizedDescription }
                    } label: {
                        if !program.isVirtual && program.status == status {
                            Image(systemName: "checkmark")
                        }
                        Text(status.displayName)
                    }
                }
            }
            Divider()
            Button("Run — checkpoint (pause after each task)") {
                research.startProgram(program, mode: .checkpoint)
            }
            .disabled(research.isRunning)
            Button("Open project memory") { appState.selection = .memory }
            Divider()
            Button("Delete program…", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mark this program done, failed or discarded — or delete it")
    }
}

/// What would completely answer this question, and where any claim on it stands.
///
/// This is the page's spine, and it replaced a ladder of graded rungs. The ladder implied a
/// single scale with the answer at the top and drew it left-to-right as progress; these are
/// alternatives, any one of which settles the problem, so they are an unordered set with no
/// "current" one and nothing partially reached.
///
/// Each form carries its evidence rule, because "how would anyone know" is the discipline that
/// makes the form mean anything, and the claim chain sits under the form it was filed against so
/// "a claim on A2 failed review" is legible without opening anything.
struct CompletionStrip: View {
    let completions: [ProgramStatus.CompletionLine]
    let solutions: [SolutionCandidate]
    /// Why the listed forms are exhaustive. The guard the whole contract turns on — and, before
    /// this, visible exactly once, in a sheet, before approval.
    var completenessRationale: String = ""

    @State private var showRationale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(completions) { line in
                    card(line)
                }
            }
            if !completenessRationale.isEmpty {
                DisclosureGroup(isExpanded: $showRationale) {
                    RenderedMath(markdown: completenessRationale, id: "completeness")
                        .padding(.top, 2)
                } label: {
                    Text("Why these cover every way of answering it")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func card(_ line: ProgramStatus.CompletionLine) -> some View {
        // A candidate still in play against this form; a rejected one is history, not a claim.
        let live = solutions.first {
            !$0.status.isRejected
                && $0.effectiveCompletionIDs.contains { $0.lowercased() == line.id.lowercased() }
        }
        let rejected = solutions.filter {
            $0.status.isRejected
                && $0.effectiveCompletionIDs.contains { $0.lowercased() == line.id.lowercased() }
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: line.accepted
                      ? "checkmark.circle.fill"
                      : (line.claimed ? "clock.badge.questionmark" : "circle"))
                    .font(.caption)
                    .foregroundStyle(line.accepted ? Color.green
                                     : (line.claimed ? Color.orange : Color.secondary.opacity(0.5)))
                Text(line.id).font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            RenderedMath(markdown: line.statement, id: "completion-\(line.id)")
            if !line.evidence.isEmpty {
                Text("shown by \(line.evidence)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let live { ClaimChain(candidate: live) }
            if !rejected.isEmpty {
                Text("\(rejected.count) earlier claim(s) did not survive")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.accepted ? Color.green.opacity(0.08) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(line.accepted ? Color.green.opacity(0.35) : Color.primary.opacity(0.07)))
    }
}

/// A claim's two gates, in the order they run. The order is the mechanism, not decoration:
/// contract adjudication is cheap and comes first, and only a candidate that would answer the
/// right question if its mathematics held is worth paying for review.
struct ClaimChain: View {
    let candidate: SolutionCandidate

    var body: some View {
        HStack(spacing: 4) {
            gate("contract", ruling: candidate.contractRuling.map(\.accepted),
                 reached: true)
            Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary)
            gate("review", ruling: candidate.reviewRuling.map(\.accepted),
                 reached: candidate.contractRuling?.accepted == true)
        }
    }

    private func gate(_ name: String, ruling: Bool?, reached: Bool) -> some View {
        let color: Color = {
            guard reached else { return .secondary.opacity(0.4) }
            guard let ruling else { return .orange }
            return ruling ? .green : .red
        }()
        return Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

@ViewBuilder
private func PauseBanner(pause: ProgramPause, program: ResearchProgram) -> some View {
    switch pause {
    case .programBudgetReached:
        ProgramBudgetBanner(program: program)
    case .wallClockReached:
        ProgramTimeBanner(program: program)
    }
}


private struct ProgramTimeBanner: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    var body: some View {
        GroupBox {
            HStack {
                Label("The program's wall-clock limit was reached.", systemImage: "clock.badge.exclamationmark")
                Spacer()
                Button("+1 hour & continue") { appState.research.extendProgramTimeLimit(program) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct ProgramBudgetBanner: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram

    var body: some View {
        GroupBox {
            HStack {
                Label("The program's token ceiling was reached — no further branches will start.",
                      systemImage: "gauge.high")
                    .font(.callout)
                Spacer()
                Button("+2M tokens & continue") {
                    appState.research.raiseProgramBudget(program, extraTokens: 2_000_000)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
