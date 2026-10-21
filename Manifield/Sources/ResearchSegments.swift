import SwiftUI
import ManifieldCore
import ManifieldAgents

// MARK: - Overview

/// The hub: the most important thing from each section, each card a way into that section.
///
/// Ordered by the questions a returning reader asks, in order — what happened while I was
/// away, is it alive, what is it attacking, what did it find, what did it change to my
/// library. Nothing here is generated for the view; every line is durable state rendered.
struct OverviewSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let status: ProgramStatus
    @ObservedObject var research: ResearchController
    let findings: [ProgramFinding]
    let changes: [LibraryChange]
    let lastViewed: Date?
    let onGo: (ProgramSegment) -> Void

    private var isLive: Bool { research.isActive(programID: program.id) }

    /// Findings published since the user last opened this page.
    private var newFindings: [ProgramFinding] {
        guard let lastViewed else { return findings }
        return findings.filter { $0.createdAt > lastViewed }
    }

    /// Solution candidates filed or ruled on since the last visit. The only movement toward
    /// an answer that is a fact rather than an impression — a branch completing tasks is not.
    private var newCandidates: [SolutionCandidate] {
        guard let lastViewed else { return program.solutions }
        return program.solutions.filter { $0.createdAt > lastViewed }
    }

    /// Library changes are a diff of the whole last run rather than timestamped events, so
    /// they count as new only when the program itself was written since the visit.
    private var changesAreNew: Bool {
        guard let lastViewed else { return !changes.isEmpty }
        return !changes.isEmpty && program.updated > lastViewed
    }

    private var hasNews: Bool {
        !newFindings.isEmpty || !newCandidates.isEmpty || changesAreNew
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hasNews, lastViewed != nil { sinceCard }
                nowRunningCard
                // Above the routes and the findings: a claim under review is the most important
                // thing in a program, and a claim that failed is a fact about the problem.
                if !program.solutions.isEmpty { claimsCard }
                if !program.isVirtual, !status.routes.isEmpty { routesCard }
                if !findings.isEmpty { findingsCard }
                if !changes.isEmpty { changesCard }
                if !status.openObligations.isEmpty { obligationsCard }
                if program.reportPath != nil { reportCard }
                if !program.skippedCells.isEmpty { skippedCard }
            }
            .padding()
        }
    }

    // MARK: Cards

    private var sinceCard: some View {
        Card(title: "Since you last looked", systemImage: "sparkles", tint: .accentColor) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(newCandidates) { candidate in
                    Label(candidate.status == .accepted
                          ? "A solution claim on \(candidate.primaryItemID) was accepted"
                          : "A solution was claimed on \(candidate.primaryItemID) — \(candidate.status.displayName.lowercased())",
                          systemImage: candidate.status == .accepted
                          ? "checkmark.seal.fill" : "questionmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(candidate.status == .accepted ? Color.green
                                         : (candidate.status.isRejected ? Color.secondary : Color.orange))
                }
                ForEach(newFindings.prefix(4)) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: FindingStyle.icon(finding.kind))
                            .foregroundStyle(FindingStyle.color(finding.kind))
                        ItemNameText(name: finding.statement,
                                     macros: appState.store?.macroDictionary ?? [:],
                                     lineLimit: 2)
                            .font(.callout)
                    }
                }
                if newFindings.count > 4 {
                    Text("and \(newFindings.count - 4) more finding(s)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if changesAreNew {
                    Label("\(changes.count) change(s) to your theory library",
                          systemImage: "books.vertical")
                        .font(.callout)
                }
            }
        }
    }

    private var nowRunningCard: some View {
        Card(title: isLive && research.isRunning ? "Now running" : "Not running",
             systemImage: isLive && research.isRunning ? "play.circle.fill" : "pause.circle",
             tint: isLive && research.isRunning ? .green : .secondary,
             action: { onGo(.branches) }, actionLabel: "Branches") {
            VStack(alignment: .leading, spacing: 4) {
                if isLive, research.isRunning {
                    Text(research.currentActivity.isEmpty ? "Working…" : research.currentActivity)
                        .font(.callout)
                } else if let waiting = waitingBranch {
                    Label("\(waiting) is waiting on your answer", systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text(branchSummary).font(.callout).foregroundStyle(.secondary)
                }
                if let error = research.lastError, isLive {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
        }
    }

    private var waitingBranch: String? {
        guard isLive else { return nil }
        for branch in program.branches {
            if case .waitingForUser = research.state(of: branch.planID) {
                return branch.title
            }
        }
        return nil
    }

    private var branchSummary: String {
        let plans = appState.branchPlans(of: program)
        let done = plans.filter { $0.isFinished }.count
        return "\(done) of \(plans.count) branch(es) finished."
    }

    private var routesCard: some View {
        let live = status.routes.filter { !$0.status.isClosed }
        let dead = status.routes.filter { $0.status == .falsified }
        return Card(title: "Routes", systemImage: "arrow.triangle.branch", tint: .blue,
                    action: { onGo(.routes) },
                    actionLabel: "All \(status.routes.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(live.prefix(3)) { route in
                    VStack(alignment: .leading, spacing: 2) {
                        ItemNameText(name: route.mechanism,
                                     macros: appState.store?.macroDictionary ?? [:],
                                     lineLimit: 2)
                            .font(.callout)
                        if let next = route.nextTest {
                            Text("next: \(next)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if live.isEmpty {
                    Text("No live routes — every line of attack is closed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !dead.isEmpty {
                    Text("\(dead.count) ruled out")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Claims on the problem, live ones first. Two independent rulings decide a claim, so the
    /// card shows the chain rather than a single status — where a claim died is the useful part.
    private var claimsCard: some View {
        let ordered = program.solutions.sorted { lhs, rhs in
            if lhs.status.isRejected != rhs.status.isRejected { return !lhs.status.isRejected }
            return lhs.createdAt > rhs.createdAt
        }
        let live = ordered.filter { !$0.status.isRejected }.count
        return Card(title: "Solution claims", systemImage: "star.circle", tint: .orange,
                    action: { onGo(.evidence) }, actionLabel: "All \(ordered.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ordered.prefix(3)) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ClaimStyle.icon(candidate.status))
                            .foregroundStyle(ClaimStyle.color(candidate.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.primaryItemID)
                                .font(.callout).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(candidate.status.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(ClaimStyle.color(candidate.status))
                                ClaimChain(candidate: candidate)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if live == 0, !ordered.isEmpty {
                    Text("No claim is still standing. What each one failed on is on the claim itself.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var findingsCard: some View {
        // Unreviewed first: those are the ones asking for a verdict.
        let ordered = findings.sorted { lhs, rhs in
            if (lhs.verdict == nil) != (rhs.verdict == nil) { return lhs.verdict == nil }
            return lhs.createdAt > rhs.createdAt
        }
        let unreviewed = findings.filter { $0.verdict == nil }.count
        return Card(title: "Findings", systemImage: "sparkle.magnifyingglass", tint: .teal,
                    action: { onGo(.evidence) }, actionLabel: "All \(findings.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ordered.prefix(3)) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: FindingStyle.icon(finding.kind))
                            .foregroundStyle(FindingStyle.color(finding.kind))
                        VStack(alignment: .leading, spacing: 1) {
                            ItemNameText(name: finding.statement,
                                         macros: appState.store?.macroDictionary ?? [:],
                                         lineLimit: 2)
                                .font(.callout)
                            if finding.isConfirmed {
                                Text("confirmed").font(.caption2).foregroundStyle(.green)
                            } else if finding.isRejected {
                                Text("rejected — withheld from the other branches")
                                    .font(.caption2).foregroundStyle(.red)
                            }
                        }
                    }
                }
                if unreviewed > 0 {
                    Text("\(unreviewed) unreviewed — a branch's claim is evidence, not truth")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var changesCard: some View {
        let downgrades = changes.filter(\.isDowngrade)
        return Card(title: "Your theory library", systemImage: "books.vertical", tint: .indigo,
                    action: { onGo(.evidence) }, actionLabel: "All \(changes.count)") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(changes.count) item(s) created or changed by the last run.")
                    .font(.callout)
                if !downgrades.isEmpty {
                    Label("\(downgrades.count) trust downgrade(s) — usually a counterexample or a failed review",
                          systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var obligationsCard: some View {
        Card(title: "Open proof obligations", systemImage: "exclamationmark.triangle",
             tint: .orange) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(status.openObligations.count) item(s) presented as established rest on something that is not.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(status.openObligations.prefix(3)) { obligation in
                    Button {
                        appState.selectedItemID = obligation.itemID
                        appState.selection = .library
                    } label: {
                        Text("\(obligation.itemID) → \(obligation.unprovedDependencies.joined(separator: ", "))")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var reportCard: some View {
        Card(title: "Program report", systemImage: "doc.text", tint: .secondary) {
            VStack(alignment: .leading, spacing: 6) {
                if let path = program.reportPath, let store = appState.store,
                   let text = try? String(contentsOf: store.rootURL.appendingPathComponent(path),
                                          encoding: .utf8) {
                    RenderedMath(markdown: String(text.prefix(600)) + (text.count > 600 ? "…" : ""),
                                 id: "report-\(program.id)", maxHeight: 200)
                }
            }
        }
    }

    private var skippedCard: some View {
        Card(title: "Deliberately not tried", systemImage: "eye.slash", tint: .secondary) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(program.skippedCells.enumerated()), id: \.offset) { _, cell in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(cell.cell).font(.caption.weight(.medium))
                        ItemNameText(name: cell.why,
                                     macros: appState.store?.macroDictionary ?? [:],
                                     fontSize: NSFont.smallSystemFontSize, lineLimit: 3)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One dashboard card: a titled box whose header doubles as the way into its section.
private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var action: (() -> Void)?
    var actionLabel: String = "Open"
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if let action {
                    Button(action: action) {
                        HStack(spacing: 2) {
                            Text(actionLabel)
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
    }
}

/// Shared finding glyphs, so the overview card and the findings segment cannot drift.
enum FindingStyle {
    static func icon(_ kind: ProgramFinding.Kind) -> String {
        switch kind {
        case .counterexample: return "xmark.octagon.fill"
        case .candidateAnswer: return "target"
        case .proofOutcome: return "checkmark.seal"
        case .obstruction: return "hand.raised"
        case .reduction: return "arrow.triangle.merge"
        case .evidence: return "chart.bar"
        case .lensAbandoned: return "arrow.uturn.backward"
        }
    }

    static func color(_ kind: ProgramFinding.Kind) -> Color {
        switch kind {
        case .counterexample: return .red
        case .candidateAnswer: return .indigo
        case .proofOutcome: return .green
        case .obstruction: return .orange
        case .reduction: return .blue
        case .evidence: return .teal
        case .lensAbandoned: return .purple
        }
    }
}

// MARK: - Routes

/// The route registry: the program's durable negative knowledge, and the only place that
/// says what has already been ruled out and why. Cost per finding sits here too — a better
/// question than cost per answer, and the live diagnostic for a route burning budget.
struct RoutesSegment: View {
    let status: ProgramStatus
    let program: ResearchProgram

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if status.routes.isEmpty {
                    Text("No routes recorded yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(status.routes) { route in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            RouteStatusChip(status: route.status)
                            Text("generation \(route.generation)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            if route.tokensSpent > 0 {
                                Text("\(route.tokensSpent / 1000)k tokens · \(route.findings) finding(s)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .help("Cost per finding is the live diagnostic for a route that is spending without learning")
                            }
                        }
                        RenderedMath(markdown: route.mechanism, id: "route-\(route.id)")
                        if let obstruction = route.obstruction {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "hand.raised")
                                RenderedMath(markdown: obstruction, id: "route-obstruction-\(route.id)")
                            }
                            .font(.caption).foregroundStyle(.orange)
                        }
                        if let next = route.nextTest, !route.status.isClosed {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "arrow.right.circle")
                                RenderedMath(markdown: next, id: "route-next-\(route.id)")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }
}

private struct RouteStatusChip: View {
    let status: ResearchRoute.Status

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .proposed: return .gray
        case .active: return .green
        case .blocked: return .orange
        case .falsified: return .red
        case .merged: return .purple
        case .proved: return .green
        }
    }
}

// MARK: - Branches

struct BranchesSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController
    let onRequestDelete: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(appState.branchPlans(of: program), id: \.id) { plan in
                    BranchCard(program: program, plan: plan,
                               branch: program.branch(planID: plan.id),
                               research: research,
                               onRequestDelete: { onRequestDelete(plan.id) },
                               onOpenFully: {
                                   appState.researchPage = .branch(programID: program.id,
                                                                    planID: plan.id)
                               })
                    Divider()
                }
                HStack {
                    Text("Whoever authored the generation ranked it — the pass-1 planner for the first wave, the director for every later one. The first branch listed runs first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ModelTaskPicker(task: .researcher, compact: true)
                }
            }
            .padding()
        }
    }
}

// MARK: - Findings

struct FindingsSegment: View {
    let program: ResearchProgram
    let findings: [ProgramFinding]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if findings.isEmpty {
                    Text("No branch has published a finding yet. Only hard facts cross between branches — reasoning deliberately does not.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(findings) { finding in
                    FindingRow(program: program, finding: finding,
                               icon: FindingStyle.icon(finding.kind),
                               color: FindingStyle.color(finding.kind))
                    Divider()
                }
            }
            .padding()
        }
    }
}

// MARK: - Changes

struct ChangesSegment: View {
    @EnvironmentObject private var appState: AppState
    let changes: [LibraryChange]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if changes.isEmpty {
                    Text("This program has not changed your theory library.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(change))
                            .foregroundStyle(change.isDowngrade ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Button {
                                appState.selectedItemID = change.itemID
                                appState.selection = .library
                            } label: {
                                Text("\(change.itemID) — \(change.name)").font(.callout)
                            }
                            .buttonStyle(.link)
                            HStack(spacing: 6) {
                                Text(change.kind.displayName)
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let from = change.fromStatus, let to = change.toStatus {
                                    Text("\(from.displayName) → \(to.displayName)")
                                        .font(.caption2)
                                        .foregroundStyle(change.isDowngrade ? .orange : .secondary)
                                } else if let to = change.toStatus {
                                    StatusBadge(status: to)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }

    private func icon(_ change: LibraryChange) -> String {
        if change.isDowngrade { return "arrow.down.circle" }
        switch change.kind {
        case .created: return "plus.circle"
        case .statusChanged: return "arrow.up.circle"
        case .removed: return "minus.circle"
        case .revised: return "pencil.circle"
        }
    }
}

// MARK: - Log

/// The raw run log, demoted to its own segment. On a multi-hour unattended run this is
/// mostly noise — but it is the only place that shows what an agent is doing *right now*,
/// so it stays one click away rather than gone.
struct LogSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    @ObservedObject var research: ResearchController

    /// Which stream to watch. Everything is interleaved and unreadable above one concurrent
    /// branch, which is exactly when there is most to watch.
    @State private var channel = "__all__"
    @State private var showArchive = false

    private var text: String {
        channel == "__all__" ? research.log : research.log(forChannel: channel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picker
            Divider()
            if showArchive {
                TranscriptsList(programID: program.id)
            } else if research.isActive(programID: program.id) {
                if text.isEmpty {
                    Text("Nothing logged yet in this session.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(text)
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding()
                                .id("logEnd")
                        }
                        .onChange(of: research.log) { _, _ in
                            proxy.scrollTo("logEnd", anchor: .bottom)
                        }
                    }
                }
            } else {
                Text("The live log belongs to the running session. Start this program to watch its agents — or read the recorded transcripts above, which survive the run.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var picker: some View {
        HStack(spacing: 10) {
            Picker("", selection: $showArchive) {
                Text("Live").tag(false)
                Text("Recorded").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if !showArchive, !program.isVirtual {
                Picker("", selection: $channel) {
                    Text("Everything").tag("__all__")
                    Text("Director & judges").tag(ResearchController.programChannel)
                    ForEach(program.branches, id: \.planID) { branch in
                        Text(branch.title).tag(branch.planID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
    }
}

// MARK: - Branch page

/// One branch, alone, at full width — a plan with a dozen tasks plus a journal is not
/// readable in a shared column.
struct BranchPage: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let plan: PlanDocument

    @State private var confirmingDelete = false
    @State private var tab = Tab.plan

    /// A branch has more than a plan. Its transcripts are a *list*, not one document: a branch
    /// that compacts or replans has several legs, and which leg a piece of reasoning belongs to
    /// is part of reading it.
    private enum Tab: String, CaseIterable, Identifiable {
        case plan, journal, transcripts, knew

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plan: return "Plan"
            case .journal: return "Journal"
            case .transcripts: return "Transcripts"
            case .knew: return "What it knew"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    appState.researchPage = .program(id: program.id)
                } label: {
                    Label(program.displayName, systemImage: "chevron.left").lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help("Back to the whole program")
                Spacer()
                Button {
                    appState.showMemory(forBranch: plan.id)
                } label: {
                    Label("Branch memory", systemImage: "brain")
                }
                .help("Open this branch's research memory")
            }
            .padding()
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal).padding(.vertical, 6)
            Divider()
            body(for: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Delete this branch?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? appState.deleteBranch(planID: plan.id, from: program)
                appState.researchPage = .program(id: program.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the branch “\(program.branch(planID: plan.id)?.title ?? plan.id)”, its research memory, and any findings it published.")
        }
    }

    @ViewBuilder
    private func body(for tab: Tab) -> some View {
        switch tab {
        case .plan:
            ScrollView {
                BranchCard(program: program, plan: plan,
                           branch: program.branch(planID: plan.id),
                           research: appState.research,
                           startExpanded: true,
                           onRequestDelete: { confirmingDelete = true })
                    .padding()
            }
        case .journal:
            BranchJournal(plan: plan, record: appState.research.pendingRecord(for: plan.id))
        case .transcripts:
            TranscriptsList(programID: program.id, subjectID: plan.id)
        case .knew:
            BranchKnowledge(program: program, planID: plan.id)
        }
    }
}

/// What each task reported, and what it cost. The branch's own account of its run, which is also
/// what later tasks see of earlier ones once its context has been compacted.
private struct BranchJournal: View {
    let plan: PlanDocument
    let record: RunRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let record, !record.journal.isEmpty {
                    ForEach(record.journal, id: \.taskIndex) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Task \(entry.taskIndex)")
                                    .font(.callout.weight(.medium))
                                Text(entry.outcome)
                                    .font(.caption2)
                                    .foregroundStyle(entry.outcome == "completed" ? .green : .orange)
                                Spacer()
                                Text("\((entry.tokensIn + entry.tokensOut) / 1000)k")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(entry.endedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            RenderedMath(markdown: entry.summary, id: "journal-\(plan.id)-\(entry.taskIndex)")
                        }
                        Divider()
                    }
                } else {
                    Text("This branch has not reported on a task yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !plan.log.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Plan log").font(.caption.weight(.semibold))
                        ForEach(Array(plan.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding()
        }
    }
}

/// What this branch was told, and what was kept from it.
///
/// The question the routing model exists to answer, and the one nothing could answer before it:
/// a branch works from its own reasoning plus whatever crossed to it, so "what was it working
/// from" is not answerable from the branch alone.
private struct BranchKnowledge: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let planID: String

    private var received: [ProgramFinding] { program.findings(routedTo: planID) }

    private var withheld: [ProgramFinding] {
        program.findings.filter {
            $0.branchPlanID != planID && !$0.isRejected
                && program.routing(forFinding: $0.id)?.reaches(planID) != true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Reached this branch", findings: received, tint: .teal,
                        empty: "Nothing from a sibling reached this branch.")
                section("Kept from it", findings: withheld, tint: .orange,
                        empty: "Nothing was withheld from this branch.")
            }
            .padding()
        }
    }

    private func section(_ title: String, findings: [ProgramFinding],
                         tint: Color, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(tint)
            if findings.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    ItemNameText(name: finding.statement,
                                 macros: appState.store?.macroDictionary ?? [:],
                                 lineLimit: 3)
                        .font(.callout)
                    HStack(spacing: 6) {
                        Text(program.branch(planID: finding.branchPlanID)?.title
                             ?? finding.branchPlanID)
                            .font(.caption2).foregroundStyle(.secondary)
                        if let routing = program.routing(forFinding: finding.id) {
                            Text(routing.decision.displayName)
                                .font(.caption2)
                                .foregroundStyle(RoutingStyle.color(routing.decision))
                        } else {
                            Text("unrouted").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if let routing = program.routing(forFinding: finding.id),
                       !routing.rationale.isEmpty {
                        RenderedMath(markdown: routing.rationale, id: "knowledge-rationale-\(finding.id)")
                    }
                }
                Divider()
            }
        }
    }
}
