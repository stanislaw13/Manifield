import AppKit
import Foundation
import ManifieldAgents
import ManifieldDiagnostics
import SwiftUI

/// Live status of Manifield's private Codex session — signed-in account, plan type, and plan-
/// limit usage — shared between Settings (which drives sign-in/out) and anywhere else that wants
/// to show how close a Codex-backed run is to its plan limit.
@MainActor
final class CodexAccountStatus: ObservableObject {
    static let shared = CodexAccountStatus()

    @Published private(set) var isChecking = false
    @Published private(set) var email: String?
    @Published private(set) var planType: String?
    @Published private(set) var usedPercent: Double?
    @Published private(set) var resetsAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var compatibilityStatus: String?
    @Published private(set) var isSigningIn = false

    var isSignedIn: Bool { email != nil }
    var binaryPath: String? {
        CodexBinaryLocator().locate(override: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
    }

    private var pollTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var observedServer: ObjectIdentifier?

    private init() {}

    func refresh() {
        guard let binaryPath else {
            lastError = "codex binary not found"
            email = nil
            return
        }
        isChecking = true
        let server = CodexEnvironment.sharedServer(binaryPath: binaryPath)
        observe(server)
        Task {
            do {
                let capabilities = try await CodexEnvironment.capabilities(binaryPath: binaryPath)
                if let issue = capabilities.incompatibilityDescription {
                    self.compatibilityStatus = "Incompatible: \(issue)"
                    self.lastError = self.compatibilityStatus
                    self.email = nil
                    self.planType = nil
                } else {
                    self.compatibilityStatus = "Compatible app-server protocol"
                    await self.load(from: server)
                }
            } catch {
                self.compatibilityStatus = "Compatibility check failed: \(error.localizedDescription)"
                self.lastError = self.compatibilityStatus
            }
            self.isChecking = false
        }
    }

    private func load(from server: CodexServer) async {
        let wasSignedIn = isSignedIn
        let previousPlan = planType
        do {
            let account = try await server.accountInfo()
            email = account["account"]?["email"]?.stringValue
            planType = account["account"]?["planType"]?.stringValue
            lastError = nil
        } catch {
            email = nil
            planType = nil
            lastError = error.localizedDescription
        }
        noteStateChange(wasSignedIn: wasSignedIn, previousPlan: previousPlan)
        guard isSignedIn else {
            usedPercent = nil
            resetsAt = nil
            return
        }
        // Best-effort: a rate-limit fetch failing shouldn't blank out the account info that
        // already loaded successfully above.
        if let limits = try? await server.rateLimits(),
           let snapshot = limits["rateLimits"]?.objectValue {
            applyRateLimits(snapshot)
        }
    }

    private func applyRateLimits(_ snapshot: [String: JSONValue]) {
        guard let primary = snapshot["primary"]?.objectValue else { return }
        // Rolling notifications are sparse. Missing fields retain the latest snapshot value;
        // the generated protocol explicitly says nullable metadata does not clear prior state.
        if let value = primary["usedPercent"]?.doubleValue { usedPercent = value }
        if let value = primary["resetsAt"]?.intValue {
            resetsAt = Date(timeIntervalSince1970: Double(value))
        }
    }

    private func observe(_ server: CodexServer) {
        let identity = ObjectIdentifier(server)
        guard observedServer != identity else { return }
        observedServer = identity
        notificationTask?.cancel()
        notificationTask = Task {
            let events = await server.accountEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .rateLimitsUpdated(let snapshot):
                    self.applyRateLimits(snapshot)
                case .accountUpdated, .loginCompleted:
                    await self.load(from: server)
                }
            }
        }
    }

    /// Opens the ChatGPT sign-in page, then waits for the generated protocol's
    /// `account/login/completed` notification. No stale account polling loop is involved.
    func signIn() {
        guard let binaryPath else {
            lastError = "codex binary not found"
            return
        }
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        Diagnostics.log.info("codex.signin.started", category: .codex)
        let server = CodexEnvironment.sharedServer(binaryPath: binaryPath)
        observe(server)
        pollTask?.cancel()
        pollTask = Task {
            var loginID: String?
            do {
                try await CodexEnvironment.requireCompatible(binaryPath: binaryPath)
                // Subscribe before account/login/start so an unusually fast completion cannot
                // race past the client between the response and stream creation.
                let loginEvents = await server.accountEvents()
                let started = try await server.startLogin()
                loginID = started.loginID
                let authURLString = started.authURL
                guard let authURL = URL(string: authURLString) else {
                    throw AgentError.codexUnavailable("sign-in returned an invalid URL")
                }
                NSWorkspace.shared.open(authURL)

                let completion = try await withThrowingTaskGroup(of: CodexAccountEvent.self) { group in
                    group.addTask {
                        for await event in loginEvents {
                            if case .loginCompleted(let eventLoginID, _, _) = event,
                               eventLoginID == nil || eventLoginID == started.loginID {
                                return event
                            }
                        }
                        throw CancellationError()
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 300_000_000_000)
                        throw AgentError.codexUnavailable("Sign-in timed out — try again.")
                    }
                    let event = try await group.next()!
                    group.cancelAll()
                    return event
                }
                guard case .loginCompleted(_, let success, let message) = completion else {
                    throw AgentError.codexUnavailable("sign-in ended without a completion result")
                }
                guard success else {
                    throw AgentError.codexUnavailable(message ?? "ChatGPT sign-in failed")
                }
                await self.load(from: server)
            } catch {
                if let loginID { await server.cancelLogin(loginID: loginID) }
                if !Task.isCancelled {
                    self.lastError = error.localizedDescription
                    Diagnostics.log.failure("codex.signin.failed", category: .codex, error: error)
                }
            }
            self.isSigningIn = false
        }
    }

    /// Logs a change in the Codex session, and nothing when nothing changed.
    ///
    /// The *fact* of being signed in, and the plan behind it, explain most "why did my run
    /// stop" reports. The account's email address explains nothing and is the tester's own
    /// identity, so it never appears here — `.flag`, not `.id`. `Diagnostics` keeps the
    /// plan type so a report can name it without waking the codex subprocess.
    private func noteStateChange(wasSignedIn: Bool, previousPlan: String?) {
        Diagnostics.lastKnownCodexPlanType = planType
        guard wasSignedIn != isSignedIn || previousPlan != planType else { return }
        Diagnostics.log.info("codex.account.changed", category: .codex, [
            ("signedIn", .flag(isSignedIn)),
            ("plan", .symbol(planType ?? "none"))
        ])
    }

    func cancelSignIn() {
        pollTask?.cancel()
        isSigningIn = false
    }

    func signOut() {
        guard let binaryPath else { return }
        let server = CodexEnvironment.sharedServer(binaryPath: binaryPath)
        Task {
            let wasSignedIn = self.isSignedIn
            let previousPlan = self.planType
            await server.logout()
            self.email = nil
            self.planType = nil
            self.usedPercent = nil
            self.resetsAt = nil
            self.noteStateChange(wasSignedIn: wasSignedIn, previousPlan: previousPlan)
        }
    }
}

/// Settings' "Codex (ChatGPT account)" section: binary location, sign-in/out, and a plan-usage
/// readout. Split out from `SettingsView` because it owns a fair amount of its own state
/// (the path override field) independent of Settings' other sections.
struct CodexAccountSection: View {
    @ObservedObject private var status = CodexAccountStatus.shared
    @State private var codexPath = AppSettings.codexPath

    var body: some View {
        if let binaryPath = status.binaryPath {
            LabeledContent("Binary") {
                Text(binaryPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Label("codex binary not found — install the ChatGPT app, or locate it below.",
                  systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            TextField("Codex binary (optional override)", text: $codexPath, prompt: Text("Auto-detect"))
                .font(.body.monospaced())
                .onChange(of: codexPath) { _, newValue in
                    AppSettings.codexPath = newValue
                    status.refresh()
                }
            Button("Locate…") { locate() }
        }

        if status.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking app-server compatibility…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let compatibility = status.compatibilityStatus {
            if compatibility.hasPrefix("Compatible") {
                Label(compatibility, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(compatibility, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        if status.isSignedIn {
            LabeledContent("Account") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(status.email ?? "").font(.callout)
                    if let planType = status.planType {
                        Text(planType.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let usedPercent = status.usedPercent {
                LabeledContent("Plan usage") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: usedPercent, total: 100).frame(width: 140)
                        if let resetsAt = status.resetsAt {
                            Text("Resets \(resetsAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Button("Sign Out") { status.signOut() }
        } else if status.isSigningIn {
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in in your browser…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { status.cancelSignIn() }
            }
        } else {
            Button("Sign In with ChatGPT") { status.signIn() }
                .disabled(status.binaryPath == nil)
        }

        if let error = status.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text("Codex runs as a separate session — signing in here is independent of ChatGPT.app or the Codex CLI, and draws on your ChatGPT plan's included usage instead of API billing.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Label(CodexSecurityPolicy.settingsDescription, systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the codex binary."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexPath = url.path
        AppSettings.codexPath = url.path
        status.refresh()
    }
}

/// Compact plan-usage readout for the Research program header — invisible unless the user is
/// actually signed in to Codex, since it has nothing relevant to say otherwise. Deliberately
/// global rather than per-branch: the ChatGPT plan's rate limit is one account-wide window, not
/// something a single branch or program consumes in isolation.
struct CodexPlanUsageIndicator: View {
    @ObservedObject private var status = CodexAccountStatus.shared

    var body: some View {
        if status.isSignedIn, let usedPercent = status.usedPercent {
            HStack(spacing: 6) {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "person.crop.circle.badge.clock")
                    .foregroundStyle(.secondary)
                ProgressView(value: usedPercent, total: 100)
                    .controlSize(.small)
                    .frame(maxWidth: 100)
                Text("\(Int(usedPercent))% of Codex plan")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help(status.resetsAt.map { "Resets \($0.formatted(.relative(presentation: .named)))" } ?? "")
        }
    }
}
