import SwiftUI
import ManifieldCore
import ManifieldAgents

/// One thing the program produced, in the order a reader wants them.
///
/// Claims, findings and library changes share a list because they are the same kind of object
/// to a reader: something the program asserted, with whatever ruling it has attracted. Splitting
/// them across tabs separates "we found a counterexample" from "we claim this settles it", which
/// is exactly the pair you want side by side.
enum EvidenceEntry: Identifiable, Equatable {
    case challenge(ProblemChallenge)
    case claim(SolutionCandidate)
    case finding(ProgramFinding)
    case change(LibraryChange)

    var id: String {
        switch self {
        case .challenge(let challenge): return "challenge:\(challenge.id)"
        case .claim(let candidate): return "claim:\(candidate.id)"
        case .finding(let finding): return "finding:\(finding.id)"
        case .change(let change): return "change:\(change.id)"
        }
    }

    /// Newest first within a section — a program is read from what just happened backwards.
    var timestamp: Date {
        switch self {
        case .challenge(let challenge): return challenge.createdAt
        case .claim(let candidate): return candidate.createdAt
        case .finding(let finding): return finding.createdAt
        case .change(let change): return change.at ?? .distantPast
        }
    }
}

// MARK: - Segment

/// Which kind of evidence the list shows. Held by the program page when it has one, so a
/// count on the Overview can open this tab already narrowed to what was clicked.
enum EvidenceFilter: String, CaseIterable, Identifiable {
    case all, challenges, claims, findings, changes
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .challenges: return "Challenges"
        case .claims: return "Claims"
        case .findings: return "Findings"
        case .changes: return "Library"
        }
    }
}

struct EvidenceSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram
    let findings: [ProgramFinding]
    let changes: [LibraryChange]
    /// Owned by the page when it wants to steer this tab from elsewhere; local otherwise.
    var selection: Binding<String?>? = nil
    var filter: Binding<EvidenceFilter>? = nil
    var navigation = ResearchNavigation()

    @State private var localSelection: String?
    @State private var localFilter: EvidenceFilter = .all

    private var selectionBinding: Binding<String?> { selection ?? $localSelection }
    private var activeFilter: EvidenceFilter { filter?.wrappedValue ?? localFilter }

    private func setFilter(_ value: EvidenceFilter) {
        if let filter { filter.wrappedValue = value } else { localFilter = value }
    }

    private func shows(_ kind: EvidenceFilter) -> Bool { activeFilter == .all || activeFilter == kind }

    private func count(_ kind: EvidenceFilter) -> Int {
        switch kind {
        case .all: return program.challenges.count + claims.count + findings.count + changes.count
        case .challenges: return program.challenges.count
        case .claims: return claims.count
        case .findings: return findings.count
        case .changes: return changes.count
        }
    }

    private var claims: [SolutionCandidate] {
        program.solutions.sorted { $0.createdAt > $1.createdAt }
    }

    private var sortedChallenges: [ProblemChallenge] {
        program.challenges.sorted { $0.createdAt > $1.createdAt }
    }

    private var sortedFindings: [ProgramFinding] {
        findings.sorted { $0.createdAt > $1.createdAt }
    }

    /// Attributed first and newest first; the run-diff entries, which have no moment, fall to
    /// the end rather than pretending to a position in the timeline.
    private var sortedChanges: [LibraryChange] {
        changes.sorted { lhs, rhs in
            if lhs.isAttributed != rhs.isAttributed { return lhs.isAttributed }
            return (lhs.at ?? .distantPast) > (rhs.at ?? .distantPast)
        }
    }

    /// In the list's section order, so the fallback selection is the first row shown.
    private var entries: [EvidenceEntry] {
        (shows(.challenges) ? sortedChallenges.map(EvidenceEntry.challenge) : [])
            + (shows(.claims) ? claims.map(EvidenceEntry.claim) : [])
            + (shows(.findings) ? sortedFindings.map(EvidenceEntry.finding) : [])
            + (shows(.changes) ? sortedChanges.map(EvidenceEntry.change) : [])
    }

    private var selected: EvidenceEntry? {
        entries.first { $0.id == selectionBinding.wrappedValue } ?? entries.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if count(.all) > 0 {
                    filterBar
                    Divider()
                }
                list
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
            detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EvidenceFilter.allCases.filter { $0 == .all || $0 == activeFilter || count($0) > 0 }) { kind in
                    let active = kind == activeFilter
                    Button { setFilter(kind) } label: {
                        HStack(spacing: 4) {
                            Text(kind.label)
                            Text("\(count(kind))").monospacedDigit().opacity(0.65)
                        }
                        .font(.caption.weight(active ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var list: some View {
        if count(.all) == 0 {
            ContentUnavailableView {
                Label("Nothing filed yet", systemImage: "tray")
            } description: {
                Text(program.execution != nil
                     ? "Problem challenges, solution claims and findings from workers land here. Challenges and claims count only after independent review."
                     : "Branches publish findings into a pool; the director decides who receives each one. A finding nobody has routed reaches nobody — silence is the default, not broadcast.")
            }
            .frame(maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView("Nothing of this kind yet", systemImage: "line.3.horizontal.decrease.circle")
                .frame(maxHeight: .infinity)
        } else {
            List(selection: selectionBinding) {
                if shows(.challenges) && !sortedChallenges.isEmpty {
                    Section("Problem challenges") {
                        ForEach(sortedChallenges) { challenge in
                            ChallengeRow(challenge: challenge, program: program)
                                .tag(EvidenceEntry.challenge(challenge).id)
                        }
                    }
                }
                if shows(.claims) && !claims.isEmpty {
                    Section("Solution claims") {
                        ForEach(claims) { candidate in
                            ClaimRow(candidate: candidate, program: program)
                                .tag(EvidenceEntry.claim(candidate).id)
                        }
                    }
                }
                if shows(.findings) && !sortedFindings.isEmpty {
                    Section("Findings") {
                        ForEach(sortedFindings) { finding in
                            FindingListRow(finding: finding, program: program)
                                .tag(EvidenceEntry.finding(finding).id)
                        }
                    }
                }
                if shows(.changes) && !sortedChanges.isEmpty {
                    Section("Library changes") {
                        ForEach(sortedChanges) { change in
                            ChangeRow(change: change, program: program)
                                .tag(EvidenceEntry.change(change).id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .challenge(let challenge):
            ChallengeDetail(challenge: challenge, program: program, navigation: navigation).id(challenge.id)
        case .claim(let candidate):
            ClaimDetail(candidate: candidate, program: program, navigation: navigation).id(candidate.id)
        case .finding(let finding):
            FindingDetail(finding: finding, program: program, navigation: navigation).id(finding.id)
        case .change(let change):
            ChangeDetail(change: change, program: program, navigation: navigation).id(change.id)
        case nil:
            Text("Select something to read it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Rows

private struct ChallengeRow: View {
    @EnvironmentObject private var appState: AppState
    let challenge: ProblemChallenge
    let program: ResearchProgram

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ChallengeStyle.icon(challenge.status))
                .foregroundStyle(ChallengeStyle.color(challenge.status))
            VStack(alignment: .leading, spacing: 2) {
                ItemNameText(name: ResearchText.headline(challenge.description),
                             macros: appState.store?.macroDictionary ?? [:], lineLimit: 2)
                    .font(.callout)
                    .strikethrough(challenge.status.isRejected)
                HStack(spacing: 5) {
                    Text(ChallengeStyle.label(challenge.status))
                        .foregroundStyle(ChallengeStyle.color(challenge.status))
                    Text("·")
                    Text(program.workTitle(for: challenge.branchPlanID)).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ClaimRow: View {
    @EnvironmentObject private var appState: AppState
    let candidate: SolutionCandidate
    let program: ResearchProgram

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ClaimStyle.icon(candidate.status))
                .foregroundStyle(ClaimStyle.color(candidate.status))
            VStack(alignment: .leading, spacing: 1) {
                ItemNameText(name: appState.store?.item(id: candidate.primaryItemID)?.name ?? candidate.primaryItemID,
                             macros: appState.store?.macroDictionary ?? [:], lineLimit: 1)
                    .font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    Text(candidate.status.displayName)
                        .font(.caption2).foregroundStyle(ClaimStyle.color(candidate.status))
                    if !candidate.effectiveCompletionIDs.isEmpty {
                        Text(candidate.effectiveCompletionIDs.joined(separator: ", "))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct FindingListRow: View {
    @EnvironmentObject private var appState: AppState
    let finding: ProgramFinding
    let program: ResearchProgram

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: FindingStyle.icon(finding.kind))
                .foregroundStyle(FindingStyle.color(finding.kind))
            VStack(alignment: .leading, spacing: 1) {
                // One sentence: the full statement is what the detail pane is for, and a list
                // row that grows to four lines stops being scannable.
                ItemNameText(name: ResearchText.headline(finding.statement),
                             macros: appState.store?.macroDictionary ?? [:], lineLimit: 2)
                    .font(.callout)
                    .strikethrough(finding.isRejected)
                    .foregroundStyle(finding.isRejected ? .secondary : .primary)
                HStack(spacing: 5) {
                    Text(finding.kind.displayName)
                        .font(.caption2).foregroundStyle(FindingStyle.color(finding.kind))
                    let routing = RoutingStyle.summary(for: finding, in: program)
                    if !routing.isEmpty {
                        Text(routing)
                            .font(.caption2)
                            .foregroundStyle(RoutingStyle.color(for: finding, in: program))
                    } else {
                        Text(program.workTitle(for: finding.branchPlanID))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ChangeRow: View {
    let change: LibraryChange
    let program: ResearchProgram

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ChangeStyle.icon(change))
                .foregroundStyle(change.isDowngrade ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name).font(.callout).lineLimit(1)
                HStack(spacing: 5) {
                    Text(change.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                    if let planID = change.branchPlanID {
                        Text(program.workTitle(for: planID))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("branch unknown").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Claim detail

/// A solution claim and the two independent rulings it had to survive.
///
/// The rulings are shown as a chain rather than a status, because the order is the mechanism:
/// contract adjudication is cheap and runs first, and only a candidate that would answer the
/// right question if its mathematics held is worth pausing a branch and paying for review.
private struct ClaimDetail: View {
    @EnvironmentObject private var appState: AppState
    let candidate: SolutionCandidate
    let program: ResearchProgram
    var navigation = ResearchNavigation()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                RenderedMath(markdown: candidate.argument, id: "claim-\(candidate.id)", minHeight: 60, maxHeight: .infinity)
                citedItems
                contractRuling
                reviewRuling
                provenance
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .researchScrollGutter()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ClaimStyle.icon(candidate.status))
                    .foregroundStyle(ClaimStyle.color(candidate.status))
                Text(candidate.status.displayName)
                    .font(.headline).foregroundStyle(ClaimStyle.color(candidate.status))
                Spacer()
            }
            Text("A branch claims \(candidate.primaryItemID) answers the question. A claim settles nothing by itself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var citedItems: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Rests on")
            ForEach(candidate.citedItemIDs, id: \.self) { id in
                Button {
                    appState.selectedItemID = id
                    appState.selection = .library
                } label: {
                    HStack(spacing: 6) {
                        Text(id).font(.caption.monospaced())
                        if id == candidate.primaryItemID {
                            Text("primary").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var contractRuling: some View {
        if let ruling = candidate.contractRuling {
            RulingPanel(
                id: "contract-ruling-\(candidate.id)",
                title: "Does it answer the question?",
                accepted: ruling.accepted,
                note: ruling.note
            ) {
                if !ruling.satisfiedCompletionIDs.isEmpty {
                    Text("Satisfies \(ruling.satisfiedCompletionIDs.joined(separator: ", "))")
                        .font(.caption.weight(.medium))
                }
                // The adjudicator rules for itself; the claimant's guess is not binding, and
                // when the two differ that disagreement is a fact about the result worth
                // seeing rather than something to flatten.
                if let claimed = candidate.claimedCompletionIDs, !claimed.isEmpty,
                   Set(claimed.map { $0.lowercased() })
                    != Set(ruling.satisfiedCompletionIDs.map { $0.lowercased() }) {
                    Text("The branch claimed \(claimed.joined(separator: ", ")) — the adjudicator ruled otherwise.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            PendingPanel(text: "Not yet checked against the contract.")
        }
    }

    @ViewBuilder
    private var reviewRuling: some View {
        if let ruling = candidate.reviewRuling {
            RulingPanel(
                id: "review-ruling-\(candidate.id)",
                title: "Is the mathematics right?",
                accepted: ruling.accepted,
                note: ruling.note
            ) {
                if !ruling.itemsReviewed.isEmpty {
                    Text("Items reviewed: \(ruling.itemsReviewed.joined(separator: ", "))")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Deliberately its own block. Item reviews certify the parts and say nothing
                // about whether they combine — the parts can each be right while the join
                // applies one outside its hypotheses — so the assembly verdict is never folded
                // into the item list.
                if !ruling.assemblyNote.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel("The assembled argument")
                        RenderedMath(markdown: ruling.assemblyNote, id: "assembly-\(candidate.id)")
                    }
                    .padding(.top, 4)
                }
            }
        } else if candidate.contractRuling?.accepted == true {
            PendingPanel(text: "Contract-complete; the mathematics is being reviewed.")
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel("Filed by")
            WorkLink(id: candidate.branchPlanID, program: program, navigation: navigation)
            Text(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Finding detail

/// A finding, its full statement, and — the part nothing used to show — who was told about it.
private struct FindingDetail: View {
    @EnvironmentObject private var appState: AppState
    let finding: ProgramFinding
    let program: ResearchProgram
    var navigation = ResearchNavigation()

    @State private var note = ""
    @State private var writingNote = false
    @State private var error: String?

    private var routing: FindingRouting? { program.routing(forFinding: finding.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                RenderedMath(markdown: finding.statement, id: "finding-\(finding.id)", minHeight: 40, maxHeight: .infinity)
                facts
                routingPanel
                verdictControls
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .researchScrollGutter()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: FindingStyle.icon(finding.kind))
                .foregroundStyle(FindingStyle.color(finding.kind))
            Text(finding.kind.displayName)
                .font(.headline).foregroundStyle(FindingStyle.color(finding.kind))
            Spacer()
            switch finding.verdict {
            case .confirmed:
                Label("confirmed", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            case .rejected:
                Label("rejected", systemImage: "nosign")
                    .font(.caption).foregroundStyle(.red)
            case nil:
                Text("unreviewed").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                SectionLabel("Published by")
                WorkLink(id: finding.branchPlanID, program: program, navigation: navigation)
            }
            if !finding.itemIDs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Items")
                    ForEach(finding.itemIDs, id: \.self) { id in
                        Button {
                            appState.selectedItemID = id
                            appState.selection = .library
                        } label: {
                            Text(id).font(.caption.monospaced())
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if let path = finding.artifactPath {
                LabelledRow("Artifact", path, monospaced: true)
            }
            LabelledRow("Published",
                        finding.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let note = finding.verdictNote, !note.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("Ruling note")
                    RenderedMath(markdown: note, id: "verdict-note-\(finding.id)")
                }
            }
        }
    }

    /// The single most interesting thing the routing model records, and the reason it exists:
    /// a finding that reaches nobody is a decision, not an accident.
    @ViewBuilder
    private var routingPanel: some View {
        if let routing {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: RoutingStyle.icon(routing.decision))
                            .foregroundStyle(RoutingStyle.color(routing.decision))
                        Text(routing.decision.displayName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(RoutingStyle.color(routing.decision))
                        Spacer()
                        Text(routing.decidedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(recipientLine)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if !routing.rationale.isEmpty {
                        RenderedMath(markdown: routing.rationale, id: "routing-rationale-\(finding.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Who was told").font(.caption.weight(.semibold))
            }
        } else if !program.isVirtual && program.execution == nil {
            // Persistent programs have no routing records: the director forwards evidence
            // explicitly with continue_work, so "not routed" would be false there.
            GroupBox {
                Text("Not routed yet — this finding is in the pool and reaches nobody until the director decides.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Who was told").font(.caption.weight(.semibold))
            }
        }
    }

    private var recipientLine: String {
        guard let routing else { return "" }
        switch routing.decision {
        case .global:
            return "Every branch but the one that published it."
        case .sendNow:
            let names = routing.recipientPlanIDs.map {
                program.branch(planID: $0)?.title ?? $0
            }
            return names.isEmpty ? "No recipients were named." : names.joined(separator: ", ")
        case .hold:
            return "Held. Real, but kept back — disclosing it now would cost more than it gives."
        case .doNotSend:
            return "Branch-local. It stays searchable here and is never injected into a branch."
        }
    }

    @ViewBuilder
    private var verdictControls: some View {
        if !program.isVirtual {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if finding.verdict == nil {
                    if writingNote {
                        TextField("Why? (optional — confirmations pass this to the other branches)",
                                  text: $note)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Confirm") { rule(.confirmed) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Reject", role: .destructive) { rule(.rejected) }
                                .controlSize(.small)
                            Button("Cancel") { writingNote = false }.controlSize(.small)
                        }
                    } else {
                        Button("Review this finding…") { note = ""; writingNote = true }
                            .controlSize(.small)
                            .help("Confirm it (siblings may rely on it) or reject it (siblings stop seeing it)")
                    }
                } else {
                    Button("Return to unreviewed") { rule(nil) }
                        .controlSize(.small)
                }
            }
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

// MARK: - Change detail

private struct ChangeDetail: View {
    @EnvironmentObject private var appState: AppState
    let change: LibraryChange
    let program: ResearchProgram
    var navigation = ResearchNavigation()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: ChangeStyle.icon(change))
                        .foregroundStyle(change.isDowngrade ? .orange : .secondary)
                    Text(change.kind.displayName).font(.headline)
                    Spacer()
                }

                Button {
                    appState.selectedItemID = change.itemID
                    appState.selection = .library
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.name).font(.callout)
                        Text(change.itemID).font(.caption.monospaced())
                    }
                }
                .buttonStyle(.link)

                if let from = change.fromStatus, let to = change.toStatus {
                    HStack(spacing: 6) {
                        StatusBadge(status: from)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        StatusBadge(status: to)
                        if change.isDowngrade {
                            Text("trust went down — usually a counterexample or a failed review")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else if let to = change.toStatus {
                    StatusBadge(status: to)
                }

                provenance
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .researchScrollGutter()
    }

    /// The point of attributing changes at all. When the run genuinely does not know who made a
    /// change it says so, rather than picking a branch.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Made by")
            if let planID = change.branchPlanID {
                WorkLink(id: planID, program: program, navigation: navigation)
                HStack(spacing: 8) {
                    if let index = change.taskIndex {
                        Text("task \(index)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let at = change.at {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Caught by the whole-run comparison, which cannot say which branch made it or when. Changes that arrive outside a task — a proposal accepted mid-run, evidence attached by hand — land here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Challenge detail

/// A claim that the goal itself is defective, and the two independent reviews it must pass.
/// The scope ruling's disposition is the part that decides what happens to the program, so
/// it is stated in words rather than as an enum's raw value.
private struct ChallengeDetail: View {
    @EnvironmentObject private var appState: AppState
    let challenge: ProblemChallenge
    let program: ResearchProgram
    var navigation = ResearchNavigation()

    private var revisionLabel: String {
        guard let index = program.targetRevisions.firstIndex(where: { $0.id == challenge.targetRevisionID }) else {
            return "goal revision \(ResearchIDText.short(challenge.targetRevisionID))"
        }
        return challenge.targetRevisionID == program.activeTargetRevisionID
            ? "goal revision \(index + 1), the current goal" : "goal revision \(index + 1)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                RenderedMath(markdown: challenge.description, id: "challenge-\(challenge.id)",
                             minHeight: 40, maxHeight: .infinity)
                disposition
                if let ruling = challenge.mathematicalRuling {
                    RulingPanel(id: "challenge-math-\(challenge.id)", title: "Is the mathematics right?",
                                accepted: ruling.accepted, note: ruling.note) { EmptyView() }
                } else if !challenge.status.isRejected {
                    PendingPanel(text: "Waiting for the mathematical review.")
                }
                if let ruling = challenge.scopeRuling {
                    RulingPanel(id: "challenge-scope-\(challenge.id)", title: "Does it defeat the goal as asked?",
                                accepted: ruling.accepted, note: ruling.note) { EmptyView() }
                } else if challenge.mathematicalRuling?.accepted == true {
                    PendingPanel(text: "The mathematics was accepted; waiting for the scope review.")
                }
                if let governance = challenge.governance {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            RenderedMath(markdown: governance.rationale, id: "challenge-governance-\(challenge.id)",
                                         maxHeight: .infinity)
                            if governance.applyRevision {
                                Label("Adopted a corrected goal", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Director's decision").font(.caption.weight(.semibold))
                    }
                }
                if let replacement = challenge.proposedReplacementRequest, !replacement.isEmpty {
                    GroupBox {
                        RenderedMath(markdown: replacement, id: "challenge-correction-\(challenge.id)", maxHeight: .infinity)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text("Proposed correction").font(.caption.weight(.semibold))
                    }
                }
                if !challenge.evidenceItemIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Cites")
                        FlowLayout(spacing: 6) {
                            ForEach(challenge.evidenceItemIDs, id: \.self) {
                                ReferenceChip(id: $0, program: program, navigation: navigation)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Filed by")
                    WorkLink(id: challenge.branchPlanID, program: program, navigation: navigation)
                    Text("Against \(revisionLabel)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .researchScrollGutter()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ChallengeStyle.icon(challenge.status))
                    .foregroundStyle(ChallengeStyle.color(challenge.status))
                Text("Problem challenge · \(ChallengeStyle.label(challenge.status))")
                    .font(.headline).foregroundStyle(ChallengeStyle.color(challenge.status))
                Spacer()
                Text(challenge.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("A worker claims the goal as stated is defective. It counts only once a mathematical review and a scope review both accept it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var disposition: some View {
        if let value = challenge.scopeRuling?.targetDisposition {
            let style = ChallengeStyle.disposition(value)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.icon).font(.title3).foregroundStyle(style.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.label).font(.callout.weight(.semibold))
                    Text(style.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.color.opacity(0.09)))
        }
    }
}

// MARK: - Shared pieces

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }
}

private struct LabelledRow: View {
    let label: String
    let value: String
    var monospaced = false

    init(_ label: String, _ value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(label)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RulingPanel<Extra: View>: View {
    let id: String
    let title: String
    let accepted: Bool
    let note: String
    @ViewBuilder let extra: Extra

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(accepted ? Color.green : Color.red)
                    Text(accepted ? "Accepted" : "Rejected")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(accepted ? Color.green : Color.red)
                    Spacer()
                }
                if !note.isEmpty {
                    RenderedMath(markdown: note, id: id, maxHeight: .infinity)
                }
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.caption.weight(.semibold))
        }
    }
}

private struct PendingPanel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Styles

enum ChallengeStyle {
    static func label(_ status: ProblemChallenge.Status) -> String {
        switch status {
        case .filed: return "Filed"
        case .mathematicalReview: return "Mathematics under review"
        case .mathematicalRejected: return "Rejected on the mathematics"
        case .scopeReview: return "Scope under review"
        case .scopeRejected: return "Rejected on scope"
        case .accepted: return "Accepted"
        case .governed: return "Accepted · governed"
        }
    }

    static func icon(_ status: ProblemChallenge.Status) -> String {
        switch status {
        case .filed: return "exclamationmark.bubble"
        case .mathematicalReview, .scopeReview: return "clock.badge.questionmark"
        case .mathematicalRejected, .scopeRejected: return "xmark.circle"
        case .accepted: return "checkmark.seal.fill"
        case .governed: return "checkmark.seal"
        }
    }

    static func color(_ status: ProblemChallenge.Status) -> Color {
        switch status {
        case .filed, .mathematicalReview, .scopeReview: return .orange
        case .mathematicalRejected, .scopeRejected: return .secondary
        case .accepted, .governed: return .green
        }
    }

    static func disposition(_ value: ProblemChallenge.ReviewRuling.TargetDisposition)
        -> (label: String, detail: String, icon: String, color: Color) {
        switch value {
        case .fullInvalidity:
            return ("Invalidates the whole goal",
                    "No part of the goal survives as stated, so the director may resolve the program as invalid.",
                    "xmark.octagon.fill", .red)
        case .partialInvalidity:
            return ("Invalidates part of the goal",
                    "Unaffected obligations stay open; the director decides explicitly which work continues.",
                    "circle.lefthalf.filled", .orange)
        case .needsClarification:
            return ("Needs clarification",
                    "The intended statement is ambiguous; the director should ask before relying on either reading.",
                    "questionmark.circle.fill", .yellow)
        }
    }
}

enum ClaimStyle {
    static func icon(_ status: SolutionCandidate.Status) -> String {
        switch status {
        case .filed: return "star"
        case .contractChecking, .underReview: return "clock.badge.questionmark"
        case .contractRejected, .reviewRejected: return "xmark.circle"
        case .accepted: return "checkmark.seal.fill"
        }
    }

    static func color(_ status: SolutionCandidate.Status) -> Color {
        switch status {
        case .filed, .contractChecking, .underReview: return .orange
        case .contractRejected, .reviewRejected: return .secondary
        case .accepted: return .green
        }
    }
}

enum ChangeStyle {
    static func icon(_ change: LibraryChange) -> String {
        if change.isDowngrade { return "arrow.down.circle" }
        switch change.kind {
        case .created: return "plus.circle"
        case .statusChanged: return "arrow.up.circle"
        case .removed: return "minus.circle"
        case .revised: return "pencil.circle"
        }
    }
}

enum RoutingStyle {
    static func icon(_ decision: FindingRouting.Decision) -> String {
        switch decision {
        case .sendNow: return "arrow.right.circle.fill"
        case .global: return "dot.radiowaves.left.and.right"
        case .hold: return "pause.circle.fill"
        case .doNotSend: return "nosign"
        }
    }

    static func color(_ decision: FindingRouting.Decision) -> Color {
        switch decision {
        case .sendNow, .global: return .teal
        case .hold: return .orange
        case .doNotSend: return .secondary
        }
    }

    /// The one-line routing state for a list row.
    static func summary(for finding: ProgramFinding, in program: ResearchProgram) -> String {
        guard let routing = program.routing(forFinding: finding.id) else {
            return program.isVirtual || program.execution != nil ? "" : "unrouted"
        }
        switch routing.decision {
        case .global: return "all branches"
        case .sendNow:
            let count = routing.recipientPlanIDs.count
            return count == 1
                ? (program.branch(planID: routing.recipientPlanIDs[0])?.title ?? "1 branch")
                : "\(count) branches"
        case .hold: return "held"
        case .doNotSend: return "not sent"
        }
    }

    static func color(for finding: ProgramFinding, in program: ResearchProgram) -> Color {
        guard let routing = program.routing(forFinding: finding.id) else { return .orange }
        return color(routing.decision)
    }
}
