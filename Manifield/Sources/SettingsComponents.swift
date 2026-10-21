import AppKit
import SwiftUI

/// A settings section header: an accent-tinted glyph and the title.
///
/// The icon is not decoration. A settings page is a wall of similar-looking rows, and the
/// glyph is what lets you find "the Python one" without reading every heading on the way
/// down.
struct SettingsSectionHeader: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            Text(title)
        }
    }
}

/// Hands back the `NSWindow` hosting this view once it has one. SwiftUI has no first-class
/// way to ask, and the Settings scene needs its window for the one thing SwiftUI does not
/// place well on its own: opening centred.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReadingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// `viewDidMoveToWindow` rather than a dispatch-async guess: it is the moment the window
    /// actually exists, however long the scene took to get there.
    private final class WindowReadingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
