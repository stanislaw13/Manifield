import AppKit
import SwiftUI
import ManifieldAgents
import ManifieldCore
import ManifieldSandbox

/// One user-adjustable numeric limit: where it lives in UserDefaults, what it is when the
/// user has never touched it, and the range outside which the app will not run it.
///
/// The range is enforced on read as well as on write. A value typed straight into defaults,
/// or left behind by an older build with a wider range, therefore still cannot put a run
/// somewhere it can't come back from — a zero-iteration researcher or a one-token reply are
/// failures the user would read as the model being broken.
struct LimitSpec: Sendable {
    let key: String
    let defaultValue: Int
    let range: ClosedRange<Int>

    var value: Int {
        get {
            // `integer(forKey:)` cannot tell "never set" from "set to 0", and 0 is a
            // meaningful value for some of these — so ask whether the key exists first.
            guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
            return clamped(UserDefaults.standard.integer(forKey: key))
        }
        nonmutating set { UserDefaults.standard.set(clamped(newValue), forKey: key) }
    }

    func clamped(_ raw: Int) -> Int { min(max(raw, range.lowerBound), range.upperBound) }

    /// Back to the built-in default. Removes the key rather than writing the default in,
    /// so a later change to that default still reaches users who never chose their own.
    func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

extension AppSettings {
    static let researchLimitsKey = "research.execution.limits.v1"
    static var researchLimits: ResearchLimits {
        get {
            guard let data = UserDefaults.standard.data(forKey: researchLimitsKey),
                  let limits = try? JSONDecoder().decode(ResearchLimits.self, from: data) else {
                return ResearchLimits(toolCalls: .bounded(Limit.researchTaskIterations.value),
                    planRevisions: .bounded(Limit.researchPlanRevisions.value))
            }
            return limits
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: researchLimitsKey) }
    }

    /// Every hard cap the user can move, grouped by the place that enforces it — which is
    /// also how Settings › Limits lays them out. A limit only belongs here if some code
    /// path actually reads it; a knob that changes nothing is worse than no knob.
    enum Limit {

        // MARK: Chat

        /// Provider round-trips one chat turn may take (each tool batch costs one).
        /// 0 means no cap, which is what chat did before this was configurable — a long
        /// investigation stops when the model stops calling tools, not on a counter.
        static let chatIterations = LimitSpec(
            key: "limit.chat.iterations", defaultValue: 0, range: 0...500)

        /// Output-token ceiling per chat reply. Thinking-capable providers raise their own
        /// floor above this when a reasoning budget needs the room.
        static let chatResponseTokens = LimitSpec(
            key: "limit.chat.responseTokens", defaultValue: 8_192, range: 1_024...200_000)

        // MARK: Research

        /// Provider round-trips one research task may take before the branch gives up on it.
        static let researchTaskIterations = LimitSpec(
            key: "limit.research.taskIterations", defaultValue: 24, range: 1...300)

        /// How many times a branch may rewrite its remaining tasks. Past this it is
        /// thrashing, and failing has to stay cheaper than another rewrite. 0 disables
        /// replanning entirely.
        static let researchPlanRevisions = LimitSpec(
            key: "limit.research.planRevisions", defaultValue: 3, range: 0...20)

        /// Estimated conversation size at which a branch compacts: the transcript is dropped
        /// and the next task starts fresh behind the journal digest. **0 disables the
        /// carried conversation altogether** — a fresh context per task.
        static let researchConversationTokens = LimitSpec(
            key: "limit.research.conversationTokens", defaultValue: 120_000, range: 0...2_000_000)

        // MARK: Organizer / Import

        /// Chunks are independent model calls, so they can run in parallel. Lower this if
        /// the provider rate-limits.
        static let importConcurrency = LimitSpec(
            key: "importConcurrency", defaultValue: 3, range: 1...8)

        /// Output-token ceiling per chunk. This one is not only a cost knob: the Organizer
        /// restates most of what it reads, so the reply ceiling is what decides how large a
        /// chunk may be (see `ImportBudget`). Raising it makes chunks bigger, not just
        /// safer against truncation.
        static let importResponseTokens = LimitSpec(
            key: "limit.import.responseTokens", defaultValue: 16_384, range: 4_096...200_000)

        /// Chunk count at or above which an import asks before spending.
        static let importWarnChunks = LimitSpec(
            key: "limit.import.warnChunks", defaultValue: 10, range: 1...1_000)

        /// Total characters at or above which an import asks before spending.
        static let importWarnCharacters = LimitSpec(
            key: "limit.import.warnCharacters", defaultValue: 200_000, range: 10_000...20_000_000)

        // MARK: Python sandbox

        /// Wall-clock seconds a script gets when the agent doesn't ask for a timeout.
        static let pythonDefaultTimeout = LimitSpec(
            key: "limit.python.defaultTimeout", defaultValue: 120, range: 5...3_600)

        /// The most the agent may ask for. Requests above this are clamped down to it.
        static let pythonMaxTimeout = LimitSpec(
            key: "limit.python.maxTimeout", defaultValue: 600, range: 5...7_200)

        /// Every limit, in the order Settings shows them — the list "Restore Defaults" walks.
        static let all: [LimitSpec] = [
            chatIterations, chatResponseTokens,
            researchTaskIterations, researchPlanRevisions, researchConversationTokens,
            importConcurrency, importResponseTokens, importWarnChunks, importWarnCharacters,
            pythonDefaultTimeout, pythonMaxTimeout,
        ]

        static func resetAll() { all.forEach { $0.reset() } }
    }

    // MARK: Derived values the runtime asks for

    /// Chat's per-turn cap in the form `AgentConfig` understands: the user's 0 ("no cap")
    /// becomes the sentinel, everything else passes through.
    static var chatMaxIterations: Int {
        let configured = Limit.chatIterations.value
        return configured == 0 ? AgentConfig.unlimitedIterations : configured
    }

    static var pythonSandboxLimits: PythonSandbox.Limits {
        PythonSandbox.Limits(
            defaultTimeout: TimeInterval(Limit.pythonDefaultTimeout.value),
            maxTimeout: TimeInterval(Limit.pythonMaxTimeout.value))
    }
}

// MARK: - Appearance

/// The app's light/dark choice. `system` is the default and is exactly what Manifield did
/// before this setting existed: follow macOS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil hands the decision back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor func apply() {
        NSApplication.shared.appearance = nsAppearance
    }
}

extension AppSettings {
    static let appearanceKey = "appearance"
    static let launchHoverAnimationEnabledKey = "launchHoverAnimationEnabled"

    static var appearance: AppearancePreference {
        get {
            AppearancePreference(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "")
                ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }
}

/// Drives the app's appearance from the stored preference.
///
/// `NSApplication.appearance`, deliberately, and **not** SwiftUI's `preferredColorScheme`:
/// that modifier overrides one window at a time, and passing it nil for "System" does not
/// cleanly undo what AppKit already applied — going Dark → System left windows half
/// repainted, SwiftUI content light while the toolbar and the NSView-backed regions stayed
/// dark. Setting it on the application covers every window, sheet, panel, toolbar and web
/// view at once, and nil there genuinely means "follow macOS again".
private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppearancePreference.system

    func body(content: Content) -> some View {
        content
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}

extension View {
    /// Safe to put on more than one window root — the effect is app-wide and idempotent,
    /// so whichever window is on screen keeps the preference applied.
    func manifieldAppearance() -> some View { modifier(AppearanceModifier()) }
}
