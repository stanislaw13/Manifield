import SwiftUI
import ManifieldCore
import ManifieldAgents

/// How this program came to be defined: the retained prompt, the frozen goal item, independent
/// first attempts, and the portfolio those produced.
///
/// One segment rather than a Pilots tab. The pilots alone are thin — four turns that ran once,
/// before anything else — but the four stages together are a single story, and it is the story
/// a mathematician checks first: *did it understand the question, and did it decide what would
/// count before it started looking?* Everything here is frozen once the run begins.
struct OriginSegment: View {
    @EnvironmentObject private var appState: AppState
    let program: ResearchProgram

    @State private var turns: [AgentTurnSummary] = []
    @State private var reading: AgentTurnSummary?

    /// The front half's turns, in the order they ran.
    private var frontHalf: [AgentTurnSummary] {
        let roles: Set<AgentTurnRecord.Role> = [
            .goalFormalization,
            .statementAudit, .contractDraft, .recognition, .pilotSelect, .pilot, .portfolio,
            .portfolioAudit, .branchPlan, .challengeMathReview, .challengeScopeReview
        ]
        return turns.filter { roles.contains($0.role) }
    }

    private var pilots: [AgentTurnSummary] { turns.filter { $0.role == .pilot } }
    private var audit: AgentTurnSummary? { turns.first { $0.role == .statementAudit } }
    private var goalTurn: AgentTurnSummary? { turns.first { $0.role == .goalFormalization } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if frontHalf.isEmpty && program.contract == nil {
                    empty
                } else {
                    requestCard
                    goalCard
                    if let audit { auditCard(audit) }
                    pilotsCard
                    portfolioCard
                }
            }
            .padding()
        }
        .onAppear(perform: load)
        .sheet(item: $reading) { summary in
            TranscriptReader(programID: program.id, summary: summary,
                             onDone: { reading = nil })
        }
    }

    private var requestCard: some View {
        OriginCard(title: "Original user request", systemImage: "text.quote", tint: .secondary) {
            RenderedMath(markdown: program.originalRequest, id: "request-\(program.id)")
            Text("Retained verbatim for history and diagnostics. Research agents work from the frozen goal item below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var goalCard: some View {
        let revision = program.activeTargetRevision
        return OriginCard(
            title: "Frozen research goal",
            systemImage: "scope", tint: .green,
            onOpen: goalTurn.map { summary in { reading = summary } }
        ) {
            VStack(alignment: .leading, spacing: 7) {
                if let id = revision.libraryItemID {
                    ItemNameText(name: revision.libraryItemName ?? id,
                                 macros: appState.store?.macroDictionary ?? [:],
                                 fontSize: NSFont.systemFontSize + 2, lineLimit: 2)
                        .font(.headline)
                    Text("\(id) · revision \(revision.id)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                RenderedMath(markdown: revision.statement.isEmpty ? revision.requestText : revision.statement,
                             id: "goal-\(revision.id)")
                Label(revision.isReviewed
                      ? "Interpretation confirmed during goal review"
                      : "Automatic interpretation; not user-confirmed",
                      systemImage: revision.isReviewed ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(revision.isReviewed ? Color.green : Color.orange)
            }
        }
    }

    private func load() {
        guard let store = appState.store, !program.isVirtual else { return }
        turns = store.turnSummaries(programID: program.id)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded for this program's planning.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Programs planned before transcripts were kept have no record of their statement audit, their pilots or their portfolio pass — those turns ran and were discarded.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func auditCard(_ summary: AgentTurnSummary) -> some View {
        OriginCard(title: "How the statement was read", systemImage: "text.magnifyingglass",
                   tint: .purple, onOpen: { reading = summary }) {
            RenderedMath(markdown: summary.outcome, id: "audit-\(summary.id)")
            Text("Interpretation only — no attempt at the problem, and deliberately no literature search. Reaching for a nearby paper while deciding how to read the question biases the reading toward that paper's terminology before the contract is frozen.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pilotsCard: some View {
        OriginCard(title: "Independent first attempts", systemImage: "sparkles", tint: .teal) {
            VStack(alignment: .leading, spacing: 8) {
                if pilots.isEmpty {
                    Text(program.pilotsEnabled
                         ? "No pilots were recorded for this program."
                         : "Pilots were disabled when this program was planned.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Each ran in isolation and saw none of the others, so agreement between them is weak evidence and disagreement is worth looking at. Nothing here was reviewed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(pilots) { pilot in
                        Button { reading = pilot } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(pilot.title).font(.callout.weight(.medium))
                                    Spacer()
                                    Text("\(pilot.tokensUsed / 1000)k")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(pilot.outcome)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private var portfolioCard: some View {
        OriginCard(title: "The portfolio", systemImage: "arrow.triangle.branch", tint: .blue,
                   onOpen: turns.first { $0.role == .portfolio }.map { s in { reading = s } }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(program.branches, id: \.planID) { branch in
                    HStack(spacing: 6) {
                        if branch.challengesLeadingAnswer {
                            ChallengerChip(challengesLeadingAnswer: true, compact: true)
                        }
                        ItemNameText(name: branch.title,
                                     macros: appState.store?.macroDictionary ?? [:], lineLimit: 1)
                            .font(.callout)
                        Spacer()
                        if let priority = branch.priority {
                            Text("#\(priority + 1)")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !program.skippedCells.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deliberately not tried").font(.caption.weight(.medium))
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
                    .padding(.top, 2)
                }
            }
        }
    }
}

private struct OriginCard<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var onOpen: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if let onOpen {
                    Button(action: onOpen) {
                        HStack(spacing: 2) {
                            Text("Transcript")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
    }
}

// MARK: - Transcript list

/// Every turn a program ran, grouped by what produced it.
///
/// This is where "show me the full reasoning" is answered. It is deliberately not a single
/// scrolling log: a multi-hour run across four branches produces one, and it is unreadable
/// exactly when there is most to read. Each turn is its own document instead.
struct TranscriptsList: View {
    @EnvironmentObject private var appState: AppState
    let programID: String
    /// When set, only this branch's turns — the branch page's own tab.
    var subjectID: String?

    @State private var turns: [AgentTurnSummary] = []
    @State private var reading: AgentTurnSummary?
    @State private var byteSize = 0

    private var shown: [AgentTurnSummary] {
        guard let subjectID else { return turns }
        return turns.filter { $0.subjectID == subjectID }
    }

    /// Judging turns apart from working turns. Their thin context is a design decision, and a
    /// reader who does not know that reads the absent memory and taste as a bug.
    private var grouped: [(title: String, turns: [AgentTurnSummary])] {
        let work = shown.filter { !$0.role.judges }
        let judged = shown.filter { $0.role.judges }
        return [("Work", work), ("Judgements", judged)].filter { !$0.turns.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                empty
            } else {
                List {
                    ForEach(grouped, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.turns) { turn in
                                Button { reading = turn } label: { row(turn) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .sheet(item: $reading) { summary in
            TranscriptReader(programID: programID, summary: summary,
                             onDone: { reading = nil })
        }
    }

    private func load() {
        guard let store = appState.store else { return }
        turns = store.turnSummaries(programID: programID)
        byteSize = store.turnsByteSize(programID: programID)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No transcripts recorded.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Runs from before transcripts were kept have none — their reasoning was discarded as they went. Anything that runs from now on is written down.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private func row(_ turn: AgentTurnSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: TranscriptStyle.icon(turn.role))
                .foregroundStyle(turn.role.judges ? Color.purple : Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(turn.title).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(turn.role.displayName).font(.caption2).foregroundStyle(.secondary)
                    Text(turn.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                    if turn.tokensUsed > 0 {
                        Text("\(turn.tokensUsed / 1000)k")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if turn.endedByCompaction {
                        Text("compacted here")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("The branch's context was dropped at this point and it continued behind its journal digest. The transcript was kept.")
                    }
                }
                if !turn.outcome.isEmpty {
                    Text(turn.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Text("\(turns.count) turn(s) · \(byteSize / 1_000_000 > 0 ? "\(byteSize / 1_000_000) MB" : "\(byteSize / 1000) KB") on disk")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Delete transcripts…", role: .destructive) {
                try? appState.store?.purgeTurns(programID: programID)
                load()
            }
            .controlSize(.small)
            .help("Throws away this program's reasoning. Its findings, claims and theory items are untouched.")
        }
        .padding(.horizontal).padding(.vertical, 6)
    }
}

enum TranscriptStyle {
    static func icon(_ role: AgentTurnRecord.Role) -> String {
        switch role {
        case .goalFormalization: return "scope"
        case .statementAudit: return "text.magnifyingglass"
        case .contractDraft: return "checkmark.seal"
        case .recognition: return "eye"
        case .pilotSelect, .pilot: return "sparkles"
        case .portfolio: return "arrow.triangle.branch"
        case .portfolioAudit: return "checkmark.shield"
        case .branchPlan, .replan: return "list.bullet.clipboard"
        case .branchLeg: return "flask"
        case .review, .assemblyReview: return "checkmark.shield"
        case .findingAdjudication, .contractAdjudication,
             .challengeMathReview, .challengeScopeReview: return "scalemass"
        case .routing: return "arrow.triangle.branch"
        case .directorVerdict: return "person.crop.square.filled.and.at.rectangle"
        case .synthesis: return "doc.text"
        case .other: return "bubble.left"
        }
    }
}

// MARK: - Reader

/// One turn, as a document.
///
/// Not a chat and not raw log text. Thinking collapses to a preview, tool calls become
/// expandable cards, and prose reads as prose — because the point of keeping a transcript is
/// that somebody can follow the reasoning afterwards, which a wall of interleaved JSON defeats.
struct TranscriptReader: View {
    @EnvironmentObject private var appState: AppState
    let programID: String
    let summary: AgentTurnSummary
    let onDone: () -> Void

    @State private var record: AgentTurnRecord?
    @State private var showThinking = false
    @State private var showToolResults = true
    @State private var showSystemPrompt = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            if let record {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if showSystemPrompt {
                            systemPromptBlock(record.systemPrompt)
                        }
                        ForEach(Array(blocks(of: record).enumerated()), id: \.offset) { offset, block in
                            TranscriptBlockView(block: block,
                                                showThinking: showThinking,
                                                showToolResults: showToolResults,
                                                blockID: "\(summary.id)-\(offset)")
                        }
                    }
                    .padding()
                }
            } else {
                Text("Could not read this transcript.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            record = appState.store?.loadTurn(programID: programID, fileName: summary.fileName)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.headline).lineLimit(2)
                HStack(spacing: 8) {
                    Text(summary.role.displayName).font(.caption).foregroundStyle(.secondary)
                    Text(summary.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    if let model = summary.model {
                        Text(model).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("\(summary.tokensIn / 1000)k in · \(summary.tokensOut / 1000)k out")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !summary.outcome.isEmpty {
                    RenderedMath(markdown: summary.outcome, id: "reader-outcome-\(summary.id)")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                Button("Ask about this in chat") { askInChat() }
                    .controlSize(.small)
                    .help("Opens a normal chat with this transcript attached — you are talking to the assistant about a document, not to the agent that produced it")
            }
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Thinking", isOn: $showThinking).toggleStyle(.checkbox)
            Toggle("Tool results", isOn: $showToolResults).toggleStyle(.checkbox)
            Toggle("System prompt", isOn: $showSystemPrompt).toggleStyle(.checkbox)
            if summary.role.judges {
                Label("A judging turn — thin context by design: no memory, no taste, sometimes no tools.",
                      systemImage: "scalemass")
                    .font(.caption2).foregroundStyle(.purple)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func systemPromptBlock(_ text: String) -> some View {
        DisclosureGroup {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text("System prompt (\(text.count) characters)")
                .font(.caption.weight(.medium))
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private func blocks(of record: AgentTurnRecord) -> [(role: MessageRole, block: ContentBlock)] {
        record.messages.flatMap { message in
            message.blocks.map { (message.role, $0) }
        }
    }

    /// The answer to "who would I be writing to?" — the chat assistant, about an attachment.
    /// No new agent, no replay of the researcher, no ambiguity.
    private func askInChat() {
        guard let record else { return }
        var parts = ["# \(summary.title)",
                     "Agent role: \(summary.role.displayName)",
                     "Outcome: \(summary.outcome)"]
        for message in record.messages {
            var lines = ["## \(message.role == .user ? "Input" : "Agent")"]
            for block in message.blocks {
                switch block {
                case .text(let text): lines.append(text)
                case .thinking(let text, _): lines.append("*(thinking)* \(text)")
                case .toolUse(_, let name, let json): lines.append("→ `\(name)` \(json)")
                case .toolResult(_, let content, let isError):
                    lines.append("\(isError ? "✕" : "✓") result: \(content)")
                default: break
                }
            }
            parts.append(lines.joined(separator: "\n\n"))
        }
        appState.chat.newChat()
        appState.chat.pendingAttachments.append(ChatController.ComposerAttachment(
            name: "\(summary.role.rawValue)-\(summary.id.prefix(8)).md",
            kind: .document(text: parts.joined(separator: "\n\n"))))
        appState.chat.draft = "This is the transcript of a \(summary.role.displayName.lowercased()) turn. "
        appState.selection = .chat
        onDone()
    }
}

/// One block of a transcript, rendered for the kind of thing it is.
private struct TranscriptBlockView: View {
    let block: (role: MessageRole, block: ContentBlock)
    let showThinking: Bool
    let showToolResults: Bool
    let blockID: String

    @State private var expanded = false

    var body: some View {
        switch block.block {
        case .text(let text):
            VStack(alignment: .leading, spacing: 3) {
                Text(block.role == .user ? "INPUT" : "AGENT")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
                RenderedMath(markdown: text, id: "block-text-\(blockID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .thinking(let text, _):
            if showThinking {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(text)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                } label: {
                    Text("thinking — \(text.prefix(90))…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(8)
                .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

        case .toolUse(_, let name, let json):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver").font(.caption2)
                    Text(name).font(.caption.monospaced().weight(.semibold))
                }
                .foregroundStyle(.blue)
                Text(json)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

        case .toolResult(_, let content, let isError):
            if showToolResults {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(content)
                        .font(.caption2.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                } label: {
                    Text("\(isError ? "✕ failed" : "✓ result") — \(content.prefix(90))…")
                        .font(.caption2.monospaced())
                        .foregroundStyle(isError ? .red : .secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }

        case .document(let name, _):
            Label(name, systemImage: "doc").font(.caption).foregroundStyle(.secondary)

        case .image, .redactedThinking, .reasoningItem:
            EmptyView()
        }
    }
}
