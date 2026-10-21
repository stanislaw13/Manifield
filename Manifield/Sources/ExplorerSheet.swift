import SwiftUI
import ManifieldCore
import ManifieldAgents

/// Runs the Explorer agent: it studies the library and proposes NEW candidate theory
/// (conjectures, occasionally definitions) in a user-given direction — or open-ended.
/// Candidates arrive as ordinary proposals, so nothing is written without confirmation.
struct ExplorerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case setup
        case running
        case done(newProposals: Int)
        case failed(String)
    }

    @State private var phase: Phase = .setup
    @State private var direction = ""
    @State private var candidateCount = 3
    @State private var log = ""
    @State private var runTask: Task<Void, Never>?
    @State private var inThinking = false
    @State private var proposalsBefore = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore new directions").font(.title3.weight(.semibold))
                    Text("Prismo proposes candidate conjectures extending your theory — numerically pre-screened where feasible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRunning ? "Cancel" : "Close") {
                    runTask?.cancel()
                    dismiss()
                }
            }
            .padding()
            Divider()
            content.padding()
        }
        .frame(width: 680, height: 480)
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .setup:
            Form {
                TextField("Direction (optional — empty = open-ended)",
                          text: $direction, axis: .vertical)
                    .lineLimit(2...4)
                Text("Example: “strengthen the doubling lemma”, “analogues over finite fields”, “what breaks without the connectivity hypothesis”.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Candidates to propose: \(candidateCount)", value: $candidateCount, in: 1...8)
                LabeledContent("Model") {
                    ModelTaskPicker(task: .explorer)
                }
                Text("Each candidate is checked on small cases with Python where feasible and delivered as a proposal — you accept or reject every one.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Explore") { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)

        case .running:
            VStack(spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Exploring…").foregroundStyle(.secondary)
                    Spacer()
                    if appState.pendingProposals.count > proposalsBefore {
                        Text("\(appState.pendingProposals.count - proposalsBefore) candidate(s) so far")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                logView
            }

        case .done(let newProposals):
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: newProposals > 0 ? "sparkles" : "moon.zzz")
                        .foregroundStyle(newProposals > 0 ? .yellow : .secondary)
                    Text(newProposals > 0
                         ? "\(newProposals) candidate(s) proposed."
                         : "No candidates were proposed — see the log for the Explorer's reasoning.")
                }
                logView
                HStack {
                    if newProposals > 0 {
                        Button("Review Proposals") {
                            appState.showProposalsSheet = true
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Explore Again") { phase = .setup }
                    Button("Close") { dismiss() }
                }
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button("Try Again") { phase = .setup }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "The Explorer's activity streams here." : log)
                    .font(.caption.monospaced())
                    .foregroundStyle(log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
                    .id("logEnd")
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: log) { _, _ in
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }

    private func start() {
        phase = .running
        log = ""
        proposalsBefore = appState.pendingProposals.count
        let message = Explorer.userMessage(direction: direction)
        let count = candidateCount
        runTask = Task {
            do {
                let (runner, config) = try appState.makeExplorerConfig(candidateCount: count)
                _ = try await runner.run(
                    config: config,
                    history: [.user(message)]
                ) { activity in
                    DispatchQueue.main.async { handle(activity) }
                }
                phase = .done(newProposals: appState.pendingProposals.count - proposalsBefore)
            } catch is CancellationError {
                phase = .setup
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ activity: AgentActivity) {
        switch activity {
        case .thinkingDelta(let delta):
            if !inThinking { inThinking = true; appendLog("\n┄┄ thinking ┄┄\n") }
            appendLog(delta)
        case .textDelta(let delta):
            closeThinking()
            appendLog(delta)
        case .toolStarted(let name, let summary):
            closeThinking()
            appendLog("\n→ \(name) \(summary)\n")
        case .toolFinished(let name, _, let isError):
            if isError { appendLog("✕ \(name) failed\n") }
        case .usage, .usageDetails:
            break
        case .iterationLimitReached:
            appendLog("\n⚠︎ iteration limit reached\n")
        }
    }

    private func closeThinking() {
        guard inThinking else { return }
        inThinking = false
        appendLog("\n┄┄ end thinking ┄┄\n")
    }

    private func appendLog(_ text: String) {
        log = String((log + text).suffix(16_000))
    }
}
