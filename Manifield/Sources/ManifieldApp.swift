import SwiftUI
import UniformTypeIdentifiers
import ManifieldCore
import ManifieldAgents
import ManifieldDiagnostics

@main
struct ManifieldApp: App {
    @StateObject private var appState = AppState()
    // Touching the singleton here is what starts Sparkle at launch.
    @StateObject private var updater = AppUpdater.shared

    init() {
        // Before the first window draws. The per-window modifier keeps it applied as the
        // user changes it; without this there is a flash of the system appearance at launch.
        AppSettings.appearance.apply()
        // First line of every session: which build this is, and whether macOS is running it
        // from a translocated path. Everything later in the log is read against it.
        Diagnostics.recordLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 620)
                .manifieldAppearance()
        }
        .commands {
            // Directly under "About Manifield", where macOS apps put this. The Help menu
            // is deliberately left alone.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { ProjectPanels.create(appState) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { ProjectPanels.open(appState) }
                    .keyboardShortcut("o")
                Button("Close Project") { appState.closeProject() }
                    .disabled(appState.store == nil)
                Divider()
                Button("Import Package…") { ProjectPanels.importPackage(appState) }
                Button("Export as Package…") { ProjectPanels.exportPackage(appState) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(appState.store == nil)
            }

            // The Help menu is ours; the app menu belongs to the updater. `replacing`
            // rather than `after`, because the stock "Manifield Help" item opens a help
            // book this app does not ship.
            CommandGroup(replacing: .help) {
                ReportABugCommand()
            }
        }

        // Secondary project windows ("Open as Project" on a source). Keyed by folder
        // URL, so opening the same source twice fronts the existing window.
        WindowGroup("Project", id: "project-window", for: URL.self) { $url in
            if let url {
                ProjectWindowRoot(url: url)
            }
        }

        // The Help menu's door into the feedback form. A `Window` rather than a sheet on
        // the project window: a bug report is often about the window you are looking at,
        // and a modal over it hides the thing being described.
        Window("Report a Bug", id: FeedbackWindow.id) {
            FeedbackView(kind: .bug)
                .frame(width: 640, height: 760)
                .manifieldAppearance()
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        Settings {
            // SettingsView sizes and themes itself — it is the one window whose appearance
            // has to react while the user is changing that very setting.
            SettingsView()
                .environmentObject(appState)
        }
        // Centred on first open, then wherever the user leaves it. `contentSize` keeps the
        // window at exactly the size SettingsView asks for instead of letting AppKit pick.
        .defaultPosition(.center)
        .windowResizability(.contentSize)
    }
}

/// The feedback window's scene id, in one place so the menu command and the scene cannot
/// drift apart.
enum FeedbackWindow {
    static let id = "feedback-window"
}

/// A menu item that needs the environment, which `.commands` cannot reach directly — but a
/// command group's content is a `View`, so a view that holds `openWindow` can live there.
private struct ReportABugCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Report a Bug…") {
            openWindow(id: FeedbackWindow.id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// A window with its own independent AppState — AppState is self-contained, so two
/// windows showing two projects never fight over selection, chat, or watchers.
struct ProjectWindowRoot: View {
    let url: URL
    @StateObject private var windowState: AppState

    init(url: URL) {
        self.url = url
        _windowState = StateObject(wrappedValue: {
            let state = AppState()
            state.openProject(at: url)
            return state
        }())
    }

    var body: some View {
        RootView()
            .environmentObject(windowState)
            .frame(minWidth: 980, minHeight: 620)
            .manifieldAppearance()
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.store == nil {
                WelcomeView()
            } else {
                MainView()
            }
        }
        .alert(appState.openAccessDenial == nil
               ? "Something went wrong" : "Manifield needs access to this folder",
               isPresented: Binding(
            get: { appState.openError != nil },
            set: { if !$0 { appState.openError = nil } }
        )) {
            // The second button exists only for a permission failure: re-choosing the
            // folder is what grants access, and it would be no help — and actively
            // misleading — for a missing folder or a corrupt project.json.
            if let denied = appState.openAccessDenial {
                Button("Choose Folder…") { ProjectPanels.grantAccess(to: denied, appState) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(appState.openError ?? "")
        }
        .onAppear {
            // Prompts ship as markdown resources; a broken bundle must fail loudly
            // at launch, never silently mid-agent-run.
            let problems = PromptLibrary.validateAll()
            if !problems.isEmpty {
                appState.openError = "Prompt templates failed validation:\n\n"
                    + problems.joined(separator: "\n")
            }
            // Dev/automation hook: `Manifield -openProject /path` skips the welcome screen.
            if appState.store == nil,
               let path = UserDefaults.standard.string(forKey: "openProject"), !path.isEmpty {
                appState.openProject(at: URL(fileURLWithPath: path))
            }
        }
    }
}

/// NSOpenPanel/NSSavePanel flows for creating and opening project folders.
@MainActor
enum ProjectPanels {

    static func open(_ appState: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Manifield project folder (it contains project.json)."
        panel.prompt = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.openProject(at: url)
    }

    /// The way out of a permission failure, offered by the open-error alert.
    ///
    /// The same panel as `open(_:)`, already pointed at the folder that was refused:
    /// choosing it hands the app a per-path grant through Powerbox, independent of the
    /// Documents TCC grant that is missing, and the retry then goes through the one route
    /// that is known to work. See `ProjectAccess`.
    static func grantAccess(to url: URL, _ appState: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.message = "Choose \"\(url.lastPathComponent)\" to give Manifield access to it."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let granted = panel.url else { return }
        appState.openProject(at: granted)
    }

    static func create(_ appState: AppState) {
        let panel = NSSavePanel()
        panel.message = "Choose a name and location for the new project folder."
        panel.nameFieldStringValue = "My Theory"
        panel.prompt = "Create Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.createProject(at: url)
    }

    static var packType: UTType {
        UTType(filenameExtension: ProjectPackage.fileExtension) ?? .zip
    }

    /// Shares the open project as a single `.manifieldpack` file (derived/personal state stripped).
    static func exportPackage(_ appState: AppState) {
        guard let store = appState.store else { return }
        let panel = NSSavePanel()
        panel.message = "Export '\(store.meta.name)' as a shareable Manifield package."
        panel.nameFieldStringValue = "\(store.meta.name).\(ProjectPackage.fileExtension)"
        panel.allowedContentTypes = [packType]
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectPackage.export(projectAt: store.rootURL, to: url)
        } catch {
            appState.openError = error.localizedDescription
        }
    }

    /// Imports a `.manifieldpack` into a new project folder and opens it.
    static func importPackage(_ appState: AppState) {
        let open = NSOpenPanel()
        open.message = "Choose a Manifield package (.\(ProjectPackage.fileExtension)) to import."
        open.allowedContentTypes = [packType]
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let packURL = open.url else { return }

        let save = NSSavePanel()
        save.message = "Choose a name and location for the imported project folder."
        save.nameFieldStringValue = packURL.deletingPathExtension().lastPathComponent
        save.prompt = "Import"
        guard save.runModal() == .OK, let destination = save.url else { return }
        do {
            try ProjectPackage.importPackage(at: packURL, to: destination)
            appState.openProject(at: destination)
        } catch {
            appState.openError = error.localizedDescription
        }
    }
}
