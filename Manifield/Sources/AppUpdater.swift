import Foundation
import OSLog
import Sparkle

/// Quiet diagnostics for the update path.
///
/// `os.Logger` rather than the `NSLog` used elsewhere in the app: NSLog output from this
/// bundle does not reach the unified log at all (verified — a test line logged from here
/// never appeared in `log show`), and a failure nobody can read is not a logged failure.
/// Read it with:
///
///     log show --last 10m --predicate 'subsystem == "com.manifield.app"'
private let updateLog = Logger(subsystem: "com.manifield.app", category: "updates")

/// The app's one Sparkle updater.
///
/// Sparkle wants a single updater per process, started once and kept alive for the whole
/// run. SwiftUI rebuilds `App` and `Scene` values freely, so the controller lives here as a
/// singleton rather than in a property of `ManifieldApp` that could be torn down and
/// recreated underneath a running update.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// Whether "Check for Updates…" should be clickable. Sparkle turns this off while a
    /// check is already in flight or an update is waiting to install, so the menu item
    /// tracks it instead of letting a second check stack on the first.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's own preference so the Settings toggle has something to bind to.
    ///
    /// Sparkle keeps the real value in UserDefaults. `SUEnableAutomaticChecks` in
    /// Info.plist supplies the default for anyone who has never touched the toggle — it is
    /// what makes automatic checks on-by-default *and* suppresses Sparkle's first-launch
    /// "check for updates automatically?" prompt. Writing here overrides it per user.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates
            else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        // startingUpdater: true schedules the first background check. With no user driver
        // delegate Sparkle uses its standard UI, which only reports errors for checks the
        // user asked for.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: delegate,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// The user asked, from the menu. Sparkle shows its own progress and error UI for this
    /// path — unlike a background check, silence here would look like nothing happened.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// Sparkle delegate that exists only to keep a failed background check quiet.
///
/// The feed is unreachable whenever the user is offline — and, until the first appcast is
/// published, always. Sparkle already suppresses error dialogs for scheduled checks; this
/// records the reason in the log so a genuinely broken feed is still diagnosable.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard let error else { return }
        updateLog.error("Update check finished without a result: \(error.localizedDescription, privacy: .public)")
    }
}
