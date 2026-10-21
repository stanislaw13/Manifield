import SwiftUI
import ManifieldCore

/// Limits: every hard cap the user can move, grouped by the place that enforces it.
///
/// Grouped by place rather than by kind on purpose — "max tool iterations" means something
/// different in a chat turn (an investigation the user is watching) than in a research task
/// (an unattended leg of a branch), and a single number covering both would be wrong for one
/// of them. Each row says what running out actually does, because that is the only way to
/// choose a number.
struct SettingsLimitsPage: View {
    @State private var researchLimits = AppSettings.researchLimits

    @AppStorage(AppSettings.Limit.chatIterations.key)
    private var chatIterations = AppSettings.Limit.chatIterations.defaultValue
    @AppStorage(AppSettings.Limit.chatResponseTokens.key)
    private var chatResponseTokens = AppSettings.Limit.chatResponseTokens.defaultValue

    @AppStorage(AppSettings.Limit.researchTaskIterations.key)
    private var researchTaskIterations = AppSettings.Limit.researchTaskIterations.defaultValue
    @AppStorage(AppSettings.Limit.researchPlanRevisions.key)
    private var researchPlanRevisions = AppSettings.Limit.researchPlanRevisions.defaultValue
    @AppStorage(AppSettings.Limit.researchConversationTokens.key)
    private var researchConversationTokens = AppSettings.Limit.researchConversationTokens.defaultValue

    @AppStorage(AppSettings.Limit.importConcurrency.key)
    private var importConcurrency = AppSettings.Limit.importConcurrency.defaultValue
    @AppStorage(AppSettings.Limit.importResponseTokens.key)
    private var importResponseTokens = AppSettings.Limit.importResponseTokens.defaultValue
    @AppStorage(AppSettings.Limit.importWarnChunks.key)
    private var importWarnChunks = AppSettings.Limit.importWarnChunks.defaultValue
    @AppStorage(AppSettings.Limit.importWarnCharacters.key)
    private var importWarnCharacters = AppSettings.Limit.importWarnCharacters.defaultValue
    @AppStorage("suppressLargeImportWarning")
    private var suppressLargeImportWarning = false

    @AppStorage(AppSettings.Limit.pythonDefaultTimeout.key)
    private var pythonDefaultTimeout = AppSettings.Limit.pythonDefaultTimeout.defaultValue
    @AppStorage(AppSettings.Limit.pythonMaxTimeout.key)
    private var pythonMaxTimeout = AppSettings.Limit.pythonMaxTimeout.defaultValue

    var body: some View {
        Form {
            Section {
                LimitRow(
                    title: "Tool calls per turn",
                    caption: "How many times Prismo may call tools before one message ends. Reaching the cap ends the turn where it stands — the reply says so, and you can ask it to continue. 0 leaves the turn uncapped, which is what chat did before this setting: it stops when the model stops reaching for tools.",
                    spec: AppSettings.Limit.chatIterations,
                    value: $chatIterations,
                    specialValue: (0, "Unlimited"))
                LimitRow(
                    title: "Response tokens",
                    caption: "Output ceiling for one reply. A long proof written straight into chat is what runs into this. Providers with a thinking budget raise their own floor above it when reasoning needs the room.",
                    spec: AppSettings.Limit.chatResponseTokens,
                    value: $chatResponseTokens,
                    step: 1_024,
                    suffix: "tokens")
            } header: {
                SettingsSectionHeader("Chat", systemImage: "bubble.left.and.text.bubble.right")
            }

            Section {
                ResearchLimitsEditor(limits: $researchLimits)
                    .onChange(of: researchLimits) { _, value in AppSettings.researchLimits = value }
                LimitRow(
                    title: "Compact conversation at",
                    caption: "Estimated context size for compaction. The director and direct workers keep a strategic handoff and archive the full transcript. Compaction remains enabled in unlimited runs. New persistent conversations use a minimum of 8,000 tokens.",
                    spec: AppSettings.Limit.researchConversationTokens,
                    value: $researchConversationTokens,
                    step: 10_000,
                    suffix: "tokens",
                    specialValue: (0, "8,000 minimum for persistent research"))
            } header: {
                SettingsSectionHeader("Research", systemImage: "flask")
            }

            Section {
                LimitRow(
                    title: "Parallel chunk requests",
                    caption: "Chunks are independent model calls, so they can run at once — same prompts and model, just faster. Lower this if your provider rate-limits you.",
                    spec: AppSettings.Limit.importConcurrency,
                    value: $importConcurrency,
                    specialValue: (1, "Sequential"))
                LimitRow(
                    title: "Response tokens per chunk",
                    caption: "This one does more than cap cost. The Organizer restates most of what it reads, so the reply ceiling is what decides how large a chunk may be — raising it makes chunks bigger and fewer, lowering it makes them smaller and more numerous.",
                    spec: AppSettings.Limit.importResponseTokens,
                    value: $importResponseTokens,
                    step: 4_096,
                    suffix: "tokens")

                Toggle("Warn before a large import", isOn: Binding(
                    get: { !suppressLargeImportWarning },
                    set: { suppressLargeImportWarning = !$0 }))
                LimitRow(
                    title: "Warn at",
                    caption: "An import splitting into at least this many chunks asks before it starts spending.",
                    spec: AppSettings.Limit.importWarnChunks,
                    value: $importWarnChunks,
                    suffix: "chunks")
                    .disabled(suppressLargeImportWarning)
                LimitRow(
                    title: "…or at",
                    caption: "Same warning, on total size — whichever threshold a document trips first.",
                    spec: AppSettings.Limit.importWarnCharacters,
                    value: $importWarnCharacters,
                    step: 10_000,
                    suffix: "characters")
                    .disabled(suppressLargeImportWarning)
            } header: {
                SettingsSectionHeader("Organizer & import", systemImage: "tray.and.arrow.down")
            }

            Section {
                LimitRow(
                    title: "Default timeout",
                    caption: "What a script gets when the agent doesn't ask for a timeout of its own. Agents that estimate a longer runtime honestly are given headroom above their estimate instead.",
                    spec: AppSettings.Limit.pythonDefaultTimeout,
                    value: $pythonDefaultTimeout,
                    step: 30,
                    suffix: "seconds")
                    .onChange(of: pythonDefaultTimeout) { _, new in
                        // A ceiling under the default would quietly shorten every unasked-for
                        // run, so the ceiling follows the floor up rather than fighting it.
                        if pythonMaxTimeout < new { pythonMaxTimeout = new }
                    }
                LimitRow(
                    title: "Maximum timeout",
                    caption: "The most an agent may ask for. Longer requests are clamped to this and the script is killed there — the run still leaves a complete artifact, marked as timed out.",
                    spec: AppSettings.Limit.pythonMaxTimeout,
                    value: $pythonMaxTimeout,
                    step: 60,
                    suffix: "seconds")
                    .onChange(of: pythonMaxTimeout) { _, new in
                        if new < pythonDefaultTimeout { pythonDefaultTimeout = new }
                    }
                Text("Both numbers reach the agent's own tool description, so it plans its scripts against the limits you set here rather than against the old fixed ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Python sandbox", systemImage: "terminal")
            }

            Section {
                HStack {
                    Text("Restoring puts every limit on this page back to Manifield's default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        AppSettings.Limit.resetAll()
                        researchLimits = ResearchLimits()
                        AppSettings.researchLimits = researchLimits
                        UserDefaults.standard.removeObject(forKey: "suppressLargeImportWarning")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One numeric limit: a number you can type or step, and a line saying what running out of
/// it does. The caption is the point of the row — a cap whose consequence isn't stated is a
/// number the user has no way to choose.
private struct LimitRow: View {
    let title: String
    let caption: String
    let spec: LimitSpec
    @Binding var value: Int
    var step: Int = 1
    var suffix: String = ""
    /// One value that reads as a word instead of a number — 0 as "Unlimited", say.
    var specialValue: (value: Int, label: String)?

    /// The text beside the field: the special value's word when it is showing, else the unit.
    private var trailingLabel: String {
        if let special = specialValue, value == special.value { return special.label }
        return suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.callout)
                Spacer(minLength: 12)
                TextField("", value: $value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                    .labelsHidden()
                Text(trailingLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)
                Stepper("", value: $value, in: spec.range, step: step)
                    .labelsHidden()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        // The stepper respects the range on its own; a typed value has to be pulled back
        // into it here, or Settings would happily store a zero-token reply cap.
        .onChange(of: value) { _, new in
            let clamped = spec.clamped(new)
            if clamped != new { value = clamped }
        }
    }
}
