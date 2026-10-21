import XCTest
import AppKit
import SwiftUI
@testable import Manifield

/// Renders the feedback form offscreen to PNG, at both the sizes it is actually shown at:
/// the Help menu's own window, and the Settings page's content area. Opt-in the same way
/// `ResearchUISnapshotTests` is — set MANIFIELD_SNAPSHOT_DIR or the test skips.
///
/// One view serves both doors, and "it fits in a window" and "it fits in a settings page"
/// are different claims. This is how they get checked without screen-recording permission.
final class FeedbackUISnapshotTests: XCTestCase {

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MANIFIELD_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set MANIFIELD_SNAPSHOT_DIR to render the feedback form.")
        }
        outputDirectory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    @MainActor
    func testRenderFeedbackForm() async throws {
        // The Help → "Report a Bug…" window, as ManifieldApp sizes it.
        try await render("feedback-1-bug-window", FeedbackView(kind: .bug),
                         size: NSSize(width: 640, height: 760))
        // Settings › Feedback: the page area left over beside the 216pt sidebar.
        try await render("feedback-2-idea-settings", SettingsFeedbackPage(),
                         size: NSSize(width: 784, height: 640))
    }

    @MainActor
    private func render<V: View>(_ name: String, _ view: V, size: NSSize) async throws {
        let root = view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 900_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
