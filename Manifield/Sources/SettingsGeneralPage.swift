import SwiftUI
import ManifieldSandbox

/// General: how the app looks, and the Python environment agents compute in.
///
/// The Python setup lives here rather than under Limits or Providers because it is a
/// property of this Mac, not of a run or a provider — installing it once is what makes
/// `run_python` work everywhere in the app.
struct SettingsGeneralPage: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppearancePreference.system
    @AppStorage(AppSettings.launchHoverAnimationEnabledKey) private var launchHoverAnimationEnabled = true
    @ObservedObject private var updater = AppUpdater.shared

    @State private var pythonPath = AppSettings.pythonPath
    @State private var pythonReady = PythonRuntime().isReady
    @State private var settingUp = false
    @State private var setupLog = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ForEach(AppearancePreference.allCases) { option in
                        ThemeSwatch(preference: option, isSelected: appearance == option) {
                            appearance = option
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                Text("“System” follows macOS, which is what Manifield did before this setting existed. Light and dark pin every window — including the proof and graph views, which render through a web view and follow the same choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $launchHoverAnimationEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch-screen hover animation")
                        Text("Show a trail of mathematical symbols behind the pointer on the launch screen. Respects macOS Reduce Motion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                SettingsSectionHeader("Appearance", systemImage: "paintpalette")
            }

            Section {
                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatically check for updates")
                        Text("Manifield is in alpha and fixes land often, so this is on by default. Turn it off to check only when you choose Manifield › Check for Updates…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } header: {
                SettingsSectionHeader("Updates", systemImage: "arrow.down.circle")
            }

            Section {
                LabeledContent("Status") {
                    if pythonReady {
                        Label("Ready — \(PythonRuntime.packages.joined(separator: ", ")) installed",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not set up", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Python interpreter (optional override)", text: $pythonPath,
                          prompt: Text(runtime.findSystemPython() ?? "python3 not found"))
                    .font(.body.monospaced())
                    .onChange(of: pythonPath) { _, newValue in
                        AppSettings.pythonPath = newValue
                    }
                HStack {
                    Button(pythonReady ? "Rebuild Environment" : "Set Up Environment") {
                        runSetup()
                    }
                    .disabled(settingUp)
                    if settingUp { ProgressView().controlSize(.small) }
                }
                if !setupLog.isEmpty {
                    ScrollView {
                        Text(setupLog)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 150)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Agent scripts run with no network access, writes confined to the run folder, and a hard timeout. Every run is saved to the project's artifacts/ folder. The timeouts themselves are under Limits › Python sandbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader("Python environment (conjecture checking)",
                                      systemImage: "terminal")
            }
        }
        .formStyle(.grouped)
    }

    private var runtime: PythonRuntime {
        PythonRuntime(interpreterOverride: pythonPath.isEmpty ? nil : pythonPath)
    }

    private func runSetup() {
        settingUp = true
        setupLog = ""
        let runtime = self.runtime
        Task {
            do {
                try await runtime.setUp { line in
                    DispatchQueue.main.async {
                        setupLog += line + "\n"
                        setupLog = String(setupLog.suffix(4000))
                    }
                }
            } catch {
                await MainActor.run { setupLog += "ERROR: \(error.localizedDescription)\n" }
            }
            await MainActor.run {
                settingUp = false
                pythonReady = runtime.isReady
            }
        }
    }
}

/// One theme choice, shown as a miniature of the app in that theme.
///
/// A three-way segmented control makes you read the words "Light" and "Dark" and then imagine
/// the result. A picture of the result skips that step, and it is how macOS itself asks this
/// question — including the half-and-half swatch that says what "System" means without a
/// sentence of explanation.
private struct ThemeSwatch: View {
    let preference: AppearancePreference
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 124, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor
                                          : Color.primary.opacity(isHovering ? 0.28 : 0.15),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                    .shadow(color: .black.opacity(isSelected ? 0.14 : 0.06),
                            radius: isSelected ? 5 : 2, y: 1)

                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
                    Text(preference.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(preference.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        switch preference {
        case .light:
            MiniWindow(dark: false)
        case .dark:
            MiniWindow(dark: true)
        case .system:
            // Light underneath, dark masked to the right half — the standard "Auto" swatch.
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    }
            }
        }
    }
}

/// A miniature of a Manifield window — sidebar, title, a couple of lines of theory — drawn
/// in fixed colours rather than semantic ones, because the whole point is to show a theme
/// that is *not* the one currently in effect.
private struct MiniWindow: View {
    let dark: Bool

    private var canvas: Color { dark ? Color(white: 0.14) : Color(white: 0.99) }
    private var sidebar: Color { dark ? Color(white: 0.19) : Color(white: 0.93) }
    private var faint: Color { dark ? Color(white: 0.42) : Color(white: 0.75) }
    private var strong: Color { dark ? Color(white: 0.88) : Color(white: 0.32) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule().fill(faint).frame(width: 20, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(width: 38, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(sidebar)

            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(strong).frame(width: 44, height: 5)
                Capsule().fill(faint).frame(width: 62, height: 3)
                Capsule().fill(faint).frame(width: 54, height: 3)
                Capsule().fill(faint).frame(width: 40, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(canvas)
        }
    }
}
