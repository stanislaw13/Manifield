import AppKit
import SwiftUI
import ManifieldAgents

/// The two halves of Settings: what the app is, and what the agents do.
///
/// Five flat rows read as five unrelated things. Split in two, the sidebar says something:
/// General and Profile are about this Mac and this person, the rest is about the machinery.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case app
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .agents: return "Agents"
        }
    }
}

/// Which page the Settings window is showing.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case profile
    case feedback
    case providers
    case roles
    case limits

    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .general, .profile, .feedback: return .app
        case .providers, .roles, .limits: return .agents
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .profile: return "Profile"
        case .feedback: return "Feedback"
        case .providers: return "AI Providers"
        case .roles: return "Roles"
        case .limits: return "Limits"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .profile: return "person.crop.circle"
        case .feedback: return "exclamationmark.bubble"
        case .providers: return "key"
        case .roles: return "person.2.badge.gearshape"
        case .limits: return "gauge.with.dots.needle.33percent"
        }
    }

    /// One line under the page title — what this page actually decides.
    var summary: String {
        switch self {
        case .general:
            return "Appearance and the Python environment agents compute in."
        case .profile:
            return "Who Prismo is writing for. Every agent reads this before it explains anything."
        case .feedback:
            return "Tell me what broke or what's missing. You see exactly what is sent before it is sent."
        case .providers:
            return "API keys, the Codex sign-in, and which provider and model everything falls back to."
        case .roles:
            return "Which model does which job, and how hard it thinks."
        case .limits:
            return "How far a run may go before the app stops it — grouped by where the cap applies."
        }
    }
}

/// The Settings window: a permanent sidebar and one page at a time.
///
/// Deliberately not a `NavigationSplitView` — that sidebar can be collapsed, and a settings
/// window whose only navigation has been hidden leaves the user with no way back to the other
/// pages. An `HStack` cannot be collapsed away. The sidebar is hand-built rather than a
/// `List(.sidebar)` for the same reason it looks calmer: no vibrancy, no full-width accent
/// bar, just a soft rounded selection that doesn't shout over the page beside it.
struct SettingsView: View {
    /// The window is fixed rather than resizable: every page is laid out to fit it, so there
    /// is no size the user could reach that shows more than this one does.
    private static let windowWidth: CGFloat = 1000
    private static let windowHeight: CGFloat = 700
    private static let sidebarWidth: CGFloat = 216
    /// Set once the window has been placed. Without it, "centre on open" would keep yanking
    /// the window back from wherever the user last dragged it. Versioned: the first
    /// implementation only centred horizontally, and anyone who had already opened Settings
    /// would otherwise keep that placement forever.
    private static let centeredKey = "settingsWindowCentered.v2"

    @AppStorage("settingsSection") private var section = SettingsSection.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            page
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .manifieldAppearance()
        .background(WindowReader { window in
            guard !UserDefaults.standard.bool(forKey: Self.centeredKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.centeredKey)
            // One runloop turn later: at the moment the view gains its window, SwiftUI has
            // not necessarily sized it yet, and centring a window that is still the wrong
            // size lands it off-centre.
            DispatchQueue.main.async { Self.center(window) }
        })
    }

    /// True centre, both axes.
    ///
    /// `NSWindow.center()` is not it: by long-standing AppKit convention it centres
    /// horizontally but places the window a third of the way down, which reads as "too high"
    /// for a window this large. Compute the origin from the screen's visible frame instead —
    /// visible, so the menu bar and Dock are excluded and the window is centred in the space
    /// it can actually occupy.
    private static func center(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(SettingsGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 3)
                    ForEach(SettingsSection.allCases.filter { $0.group == group }) { item in
                        SidebarRow(section: item, isSelected: section == item) {
                            section = item
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .frame(width: Self.sidebarWidth, alignment: .topLeading)
        // A hair darker than the page beside it. The grouped form already paints the window
        // background, so without this the divider is doing all the separating on its own.
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.primary.opacity(0.03)
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            switch section {
            case .general: SettingsGeneralPage()
            case .profile: SettingsProfilePage()
            case .feedback: SettingsFeedbackPage()
            case .providers: SettingsProvidersPage()
            case .roles: SettingsRolesPage()
            case .limits: SettingsLimitsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.opacity(0.13))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                Text(section.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }
}

/// One sidebar row. Soft neutral selection with an accent glyph, rather than the full-width
/// accent bar of a stock sidebar list — at this size the loud version reads as the most
/// important thing on screen, which it isn't.
private struct SidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.primary.opacity(0.09) }
        return isHovering ? Color.primary.opacity(0.045) : Color.clear
    }
}
