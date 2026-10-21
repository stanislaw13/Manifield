import SwiftUI
import ManifieldCore

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppSettings.launchHoverAnimationEnabledKey) private var launchHoverAnimationEnabled = true

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                WelcomeLogo()
                    .frame(width: 88, height: 88)
                Text("Manifield")
                    .font(.largeTitle.weight(.semibold))
                Text("An AI workbench for mathematicians — organize your theory,\ncheck conjectures, and develop proofs with Prismo.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .anchorPreference(key: WelcomeContentBounds.self, value: .bounds) { [$0] }

            HStack(spacing: 12) {
                Button {
                    ProjectPanels.create(appState)
                } label: {
                    Label("New Project", systemImage: "plus")
                        .frame(width: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    ProjectPanels.open(appState)
                } label: {
                    Label("Open Project", systemImage: "folder")
                        .frame(width: 150)
                }
                .controlSize(.large)

                Button {
                    ProjectPanels.importPackage(appState)
                } label: {
                    Label("Import Package", systemImage: "shippingbox")
                        .frame(width: 150)
                }
                .controlSize(.large)
                .help("Import a shared .manifieldpack — a published theory or reference work")
            }
            .anchorPreference(key: WelcomeContentBounds.self, value: .bounds) { [$0] }

            if !appState.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(appState.recentProjects, id: \.path) { url in
                        Button {
                            appState.openProject(at: url)
                        } label: {
                            HStack {
                                Image(systemName: "books.vertical")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 340)
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .anchorPreference(key: WelcomeContentBounds.self, value: .bounds) { [$0] }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundPreferenceValue(WelcomeContentBounds.self) { anchors in
            GeometryReader { geometry in
                if launchHoverAnimationEnabled {
                    WelcomeMathTrail(exclusionRects: anchors.map { geometry[$0] })
                }
            }
            .accessibilityHidden(true)
        }
    }
}

private struct WelcomeContentBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}
