import Foundation
import ManifieldAgents
import ManifieldDiagnostics
import ManifieldSandbox

/// The app's one handle on the log.
///
/// A shorthand rather than a wrapper: call sites write
/// `Diagnostics.log.info("project.opened", category: .project, […])`, and the API they are
/// calling is the package's, with its redaction rules intact. Nothing here relaxes them.
enum Diagnostics {
    static var log: DiagnosticsLog { .shared }

    /// Called once, before the first window. Writes the line that says which build this is
    /// — the first thing worth knowing about any report that follows.
    static func recordLaunch() {
        let snapshot = DiagnosticsSnapshot.current(supplied())
        log.info("app.launched", category: .app, [
            ("version", .symbol(snapshot.appVersion)),
            ("build", .symbol(snapshot.buildNumber)),
            ("macos", .symbol(shortSystemVersion())),
            ("arch", .symbol(snapshot.architecture)),
            ("translocated", .flag(snapshot.isTranslocated)),
            ("codex", .flag(snapshot.codexBinaryFound)),
            ("python", .flag(snapshot.pythonEnvironmentReady)),
            ("providers", .count(snapshot.configuredProviders.count))
        ])
        // Loud, and at `error`: a translocated app is a working app with broken resource
        // loading and broken subprocess spawning, which surfaces later as half a dozen
        // unrelated-looking failures. Saying it once, at the top of the log, is what turns
        // those into one sentence of diagnosis.
        if snapshot.isTranslocated {
            log.error("app.translocated", category: .app, [
                ("hint", .symbol("move-to-Applications-and-reopen"))
            ])
        }
        recordCrashReportAccess()
    }

    /// Whether macOS let this build list `~/Library/Logs/DiagnosticReports`.
    ///
    /// Recorded at launch rather than only when the feedback form is open, so the answer is
    /// in the log of every session — including the one where the tester says "it offered to
    /// attach a crash report and then didn't". Hardened runtime does not gate file reads and
    /// that folder is not TCC-protected, so this is expected to succeed; it is logged
    /// because "expected" is not "verified on the tester's Mac".
    private static func recordCrashReportAccess() {
        switch CrashReportLocator().availability() {
        case .readable(let matching):
            // Listing a folder and reading a file in it are separate permissions. The .ips
            // files are `-rw------- <user>`, so both hold — but only the second one decides
            // whether the attachment the UI offers can actually be produced, so both are
            // recorded rather than inferred from each other.
            log.info("crashreports.readable", category: .app, [
                ("recent", .count(matching)),
                ("newestReadable", .flag(matching == 0 ? true : CrashReportLocator().newestReport() != nil))
            ])
        case .unreadable(let reason):
            log.notice("crashreports.unreadable", category: .app,
                       [("reason", .errorDescription(reason))])
        case .missing:
            log.info("crashreports.absent", category: .app)
        }
    }

    /// Everything only the app can answer about this installation.
    ///
    /// Provider *names* for providers with a key in the Keychain — never the keys, and the
    /// value is never read here, only tested for existence.
    static func supplied() -> DiagnosticsSnapshot.AppSupplied {
        let configured = ProviderKind.allCases
            .filter { $0.usesAPIKey && !(Keychain.apiKey(for: $0) ?? "").isEmpty }
            .map(\.rawValue)
        let codexPath = CodexBinaryLocator()
            .locate(override: AppSettings.codexPath.isEmpty ? nil : AppSettings.codexPath)
        let python = PythonRuntime(interpreterOverride: AppSettings.pythonPath.isEmpty
                                   ? nil : AppSettings.pythonPath)
        return .init(codexBinaryFound: codexPath != nil,
                     codexPlanType: lastKnownCodexPlanType,
                     pythonEnvironmentReady: python.isReady,
                     configuredProviders: configured)
    }

    /// A full snapshot of this machine, for a report.
    static func snapshot() -> DiagnosticsSnapshot { .current(supplied()) }

    /// The Codex plan type as of the last status refresh.
    ///
    /// Cached rather than fetched: reading it live means an await on a subprocess, and
    /// building a snapshot has to be instant — the consent disclosure shows it while the
    /// tester is typing. `CodexAccountStatus` writes it here whenever it learns one.
    private static let planTypeKey = "diagnostics.codexPlanType"

    static var lastKnownCodexPlanType: String? {
        get { UserDefaults.standard.string(forKey: planTypeKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: planTypeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: planTypeKey)
            }
        }
    }

    /// "26.3.0" rather than "Version 26.3.0 (Build 25D60)" — the long form is in the
    /// snapshot, and a log line wants the short one.
    private static func shortSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
