import AppKit
import SwiftUI
import ManifieldDiagnostics
import UniformTypeIdentifiers

/// The feedback form. One view, two doors: Help → "Report a Bug…" opens it in its own
/// window on `.bug`, and Settings → Feedback shows the same view inside the settings page.
///
/// The governing rule is consent. Everything that would travel is on screen before
/// anything travels: the diagnostics disclosure shows the exact JSON bytes that will be
/// POSTed, the log has its own toggle and a button to open the file in Finder, and the
/// crash report — the one attachment nobody can fully vouch for the contents of — is off
/// unless the tester turns it on. Nothing is sent until Send is pressed.
struct FeedbackView: View {

    /// What the entry point opened it for. The picker can change it afterwards; this is
    /// only where it starts.
    let initialKind: FeedbackKind

    init(kind: FeedbackKind = .bug) {
        self.initialKind = kind
        _kind = State(initialValue: kind)
        _includeLog = State(initialValue: kind.attachesLogByDefault)
    }

    @State private var kind: FeedbackKind
    @State private var message = ""
    @State private var email = AppSettings.feedbackEmail
    @State private var includeDiagnostics = true
    @State private var includeLog: Bool
    @State private var includeCrashLog = false
    @State private var showingPayload = false

    @State private var state: SendState = .composing
    /// Kept after a failure so Save to File and Copy give back exactly what Send tried to
    /// send — not a freshly built report with a different timestamp and id.
    @State private var lastAttempt: FeedbackReport?
    @State private var crashAvailability: CrashReportLocator.Availability = .missing

    private enum SendState: Equatable {
        case composing
        case sending
        case sent(String)
        case failed(String)
    }

    private var canSend: Bool {
        state != .sending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            aboutSection
            attachmentsSection
            sendSection
        }
        .formStyle(.grouped)
        .onAppear { crashAvailability = CrashReportLocator().availability() }
        .onChange(of: kind) { _, newKind in
            // Only while the tester has not touched it: the default follows the kind, and
            // overriding a deliberate choice because they switched Bug→Idea would be rude.
            if state == .composing, lastAttempt == nil {
                includeLog = newKind.attachesLogByDefault
            }
        }
    }

    // MARK: - What happened

    private var aboutSection: some View {
        Section {
            Picker("This is a", selection: $kind) {
                ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(placeholder)
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Write as much or as little as you like. Nothing from your project is included — not item text, statements, proofs, prompts or model output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Email (optional)", text: $email, prompt: Text("Only if you'd like a reply"))
                .onChange(of: email) { _, newValue in AppSettings.feedbackEmail = newValue }
        } header: {
            SettingsSectionHeader(heading, systemImage: kind == .bug ? "ladybug" : "text.bubble")
        }
    }

    /// Follows the picker. "What happened" over a form someone opened to suggest a feature
    /// is the kind of small wrongness that makes an app feel like it wasn't expecting you —
    /// and the Settings page opens on Idea.
    private var heading: String {
        switch kind {
        case .bug: return "What happened"
        case .idea: return "Your idea"
        case .other: return "What's on your mind"
        }
    }

    private var placeholder: String {
        switch kind {
        case .bug: return "What did you do, what did you expect, and what happened instead?"
        case .idea: return "What would you like Manifield to do?"
        case .other: return "Anything you'd like to tell me."
        }
    }

    // MARK: - What goes with it

    private var attachmentsSection: some View {
        Section {
            Toggle(isOn: $includeDiagnostics) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include diagnostics")
                    Text("App version and build, macOS version, architecture, and whether Codex and the Python environment were found. No keys, no paths, no project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            DisclosureGroup("Show exactly what will be sent", isExpanded: $showingPayload) {
                payloadPreview
            }
            .font(.callout)

            Toggle(isOn: $includeLog) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include recent log")
                    Text("The last \(DiagnosticsLog.defaultTailBytes / 1024) KB of Manifield's own log: event names, ids, counts and errors. You can read the whole file yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Button("Show Log File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.log.currentFileURL()])
            }

            crashLogRow
        } header: {
            SettingsSectionHeader("What goes with it", systemImage: "paperclip")
        }
    }

    @ViewBuilder private var crashLogRow: some View {
        switch crashAvailability {
        case .readable(let matching) where matching > 0:
            Toggle(isOn: $includeCrashLog) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include the crash report macOS wrote")
                    Text("Manifield crashed in the last 24 hours. A crash report is a dump of the program's state when it died — home paths and addresses are removed, but it is off unless you turn it on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        case .unreadable(let reason):
            // Degrade, don't fail: the report still sends, minus the one attachment macOS
            // would not hand over.
            Label("macOS would not let Manifield read the crash-report folder (\(reason)). Everything else still sends; you can attach the report yourself from Console › Crash Reports.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .readable, .missing:
            EmptyView()
        }
    }

    private var payloadPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            let preview = previewText()
            ScrollView {
                Text(preview.text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text(preview.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// The preview is the payload — the same bytes `HTTPFeedbackSender` will POST and the
    /// same bytes the file fallback writes, not a description of them.
    ///
    /// Only the *rendering* is bounded: a 200 KB log tail in one `Text` makes the window
    /// crawl. When that bites, the preview says so and says how many bytes it is holding
    /// back, and the log file itself is one button away — so nothing is hidden, only
    /// deferred to a place that can show it properly.
    private func previewText() -> (text: String, footnote: String) {
        let report = composeReport()
        guard let json = try? report.jsonString() else {
            return ("(could not render the report)", "")
        }
        let bytes = json.utf8.count
        let limit = 40 * 1024
        guard bytes > limit else {
            return (json, "\(bytes) bytes — this is the whole request body, exactly as it will be sent.")
        }
        let shown = String(json.prefix(limit))
        return (shown + "\n…",
                "Showing the first \(limit / 1024) KB of \(bytes / 1024) KB. The rest is the attached log — open the log file above to read all of it.")
    }

    // MARK: - Sending

    private var sendSection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                if state == .sending { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }

            switch state {
            case .composing, .sending:
                EmptyView()
            case .sent(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 10) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your report hasn't been lost. Save it to a file or copy it and paste it into a GitHub issue — or leave this open and press Send again later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Save to File…") { saveToFile() }
                        Button("Copy to Clipboard") { copyToClipboard() }
                    }
                }
            }
        } header: {
            SettingsSectionHeader("Send", systemImage: "paperplane")
        } footer: {
            Text("Goes to \(FeedbackEndpoint.url.host ?? "the feedback service"). Nothing leaves this Mac until you press Send. From there it is forwarded into a private Discord channel only I read, where it stays until I delete it — ask and I'll delete yours.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func composeReport() -> FeedbackReport {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedbackReport(
            kind: kind,
            message: message,
            email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            snapshot: includeDiagnostics ? Diagnostics.snapshot() : nil,
            logTail: includeLog ? Diagnostics.log.tail() : nil,
            crashLog: includeCrashLog ? CrashReportLocator().newestReport()?.contents : nil)
    }

    private func send() {
        let report = composeReport()
        lastAttempt = report
        state = .sending
        Diagnostics.log.info("feedback.send.started", category: .feedback, [
            ("report", .id(report.id)),
            ("kind", .symbol(report.kind.rawValue)),
            ("diagnostics", .flag(report.snapshot != nil)),
            ("log", .flag(report.logTail != nil)),
            ("crash", .flag(report.crashLog != nil))
        ])
        Task {
            do {
                let delivery = try await HTTPFeedbackSender().send(report)
                await MainActor.run {
                    state = .sent(delivery.summary)
                    message = ""
                    lastAttempt = nil
                    includeCrashLog = false
                }
                Diagnostics.log.info("feedback.send.succeeded", category: .feedback,
                                     [("report", .id(report.id))])
            } catch {
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                }
                Diagnostics.log.failure("feedback.send.failed", category: .feedback, error: error,
                                        [("report", .id(report.id))])
            }
        }
    }

    /// The report the tester tried to send, or — if they changed their mind about an
    /// attachment after the failure — the one on screen now.
    private func reportForFallback() -> FeedbackReport { lastAttempt ?? composeReport() }

    private func saveToFile() {
        let report = reportForFallback()
        let panel = NSSavePanel()
        panel.message = "Save this report so you can send it by hand."
        panel.nameFieldStringValue = report.suggestedFileName
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let delivery = try await FileFeedbackSender(destination: .file(url)).send(report)
                await MainActor.run { state = .sent(delivery.summary) }
                Diagnostics.log.info("feedback.saved", category: .feedback, [("report", .id(report.id))])
            } catch {
                await MainActor.run { state = .failed(error.localizedDescription) }
            }
        }
    }

    private func copyToClipboard() {
        guard let json = try? reportForFallback().jsonString() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        state = .sent("Copied. Paste it into an email — it is the whole report.")
    }
}
