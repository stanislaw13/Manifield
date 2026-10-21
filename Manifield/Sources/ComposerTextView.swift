import SwiftUI
import AppKit

/// The chat input: a plain NSTextView with chat keybindings — ⏎ sends, ⇧⏎ / ⌥⏎ insert
/// a newline (SwiftUI's TextField(axis: .vertical) can't distinguish those). Reports its
/// laid-out height so the composer grows with content up to a cap, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onHeightChange: (CGFloat) -> Void
    /// Fires when the user pastes or drops images/files onto the composer instead of
    /// plain text — attachments to stage, plus any per-item load errors to surface.
    var onAttachments: ([ChatController.ComposerAttachment], [String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = KeyCatchingTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none

        context.coordinator.textView = textView
        textView.coordinator = context.coordinator
        // Focus the composer as soon as it lands in a window.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.reportHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func reportHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            parent.onHeightChange(used + textView.textContainerInset.height * 2)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                parent.onSubmit()
                return true
            }
            return false
        }
    }

    /// Intercepts paste and drag-and-drop so images/files become composer attachments
    /// instead of garbled text (or, for drag, whatever AppKit's default text-view drop
    /// handling would otherwise do). Anything that isn't a recognized image/file — plain
    /// copied text, a dragged text selection — falls through to the normal behavior.
    final class KeyCatchingTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func paste(_ sender: Any?) {
            let (attachments, errors) = AttachmentLoader.readFromPasteboard(.general)
            guard !attachments.isEmpty || !errors.isEmpty else {
                super.paste(sender)
                return
            }
            coordinator?.parent.onAttachments(attachments, errors)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let (attachments, errors) = AttachmentLoader.readFromPasteboard(sender.draggingPasteboard)
            guard !attachments.isEmpty || !errors.isEmpty else {
                return super.performDragOperation(sender)
            }
            coordinator?.parent.onAttachments(attachments, errors)
            return true
        }
    }
}
