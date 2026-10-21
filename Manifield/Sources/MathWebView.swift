import SwiftUI
import WebKit

/// Owns one long-lived WKWebView loaded with a page from Resources/web (math/chat/graph).
/// JS calls made before the page finishes loading are queued and flushed on load.
/// Pages talk back through the `manifieldBridge` script message handler.
@MainActor
final class WebViewBox: NSObject, ObservableObject {

    let webView: WKWebView
    var onMessage: (([String: Any]) -> Void)?

    private var isLoaded = false
    private var pendingCalls: [String] = []

    init(page: String) {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Figure images reach the page through this scheme and no other — see FigureScheme.
        configuration.setURLSchemeHandler(FigureSchemeHandler(), forURLScheme: FigureScheme.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        controller.add(BridgeProxy(owner: self), name: "manifieldBridge")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        if let pageURL = Bundle.main.url(forResource: page, withExtension: "html", subdirectory: "web"),
           let webDir = Bundle.main.url(forResource: "web", withExtension: nil) {
            webView.loadFileURL(pageURL, allowingReadAccessTo: webDir)
        } else {
            assertionFailure("Missing bundled web page '\(page).html'")
        }
    }

    /// Calls a global JS function with the given arguments (JSON-encoded safely).
    func call(_ function: String, _ arguments: Any...) {
        let encoded = arguments.map { Self.jsLiteral($0) }.joined(separator: ", ")
        enqueue("\(function)(\(encoded));")
    }

    private func enqueue(_ js: String) {
        if isLoaded {
            webView.evaluateJavaScript(js) { _, error in
                if let error { NSLog("Manifield webview JS error: \(error.localizedDescription)") }
            }
        } else {
            pendingCalls.append(js)
        }
    }

    static func jsLiteral(_ value: Any) -> String {
        // Encode any value as a JSON fragment by wrapping in an array and unwrapping.
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    /// Breaks the retain cycle WKUserContentController ⟶ handler ⟶ box.
    private final class BridgeProxy: NSObject, WKScriptMessageHandler {
        weak var owner: WebViewBox?
        init(owner: WebViewBox) { self.owner = owner }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            MainActor.assumeIsolated {
                owner?.onMessage?(body)
            }
        }
    }
}

extension WebViewBox: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        for js in pendingCalls { enqueue(js) }
        pendingCalls.removeAll()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Keep the web views on their bundled pages; open external links in the browser.
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var box: WebViewBox

    func makeNSView(context: Context) -> WKWebView { box.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Renders markdown with LaTeX in the shared math page — the one view every "generated
/// content" field (a program's goal, a route's mechanism, a finding's statement, a
/// contract's rationale, a transcript's prose, …) should go through instead of a plain
/// `Text`, which neither expands macros nor typesets math at all.
///
/// A 600-character mathematical statement in a `Text` with `lineLimit(2)` is not
/// readable, and these are exactly the objects a mathematician most needs to read.
struct RenderedMath: View {
    @EnvironmentObject private var appState: AppState
    let markdown: String
    /// Changing this rebuilds the box, so selecting another entry cannot leave the previous
    /// one's content on screen while the new render is in flight.
    let id: String
    var minHeight: CGFloat = 18
    var maxHeight: CGFloat = 420
    /// Shows at most this much, faded at the bottom and without inner scrolling — for
    /// callers that offer their own "Show more". Nil shows up to `maxHeight`.
    var clipHeight: CGFloat? = nil
    /// The full rendered height, reported after every reflow, clip or not.
    var onContentHeight: ((CGFloat) -> Void)? = nil

    @StateObject private var box = WebViewBox(page: "math")
    @State private var contentHeight: CGFloat = 18

    var body: some View {
        WebViewRepresentable(box: box)
            .frame(height: min(max(contentHeight, minHeight), clipHeight ?? maxHeight))
            .onAppear {
                box.onMessage = { message in
                    guard message["type"] as? String == "contentHeight",
                          let height = message["height"] as? Double else { return }
                    contentHeight = CGFloat(height)
                    onContentHeight?(CGFloat(height))
                }
                box.call("setClip", Double(clipHeight ?? 0))
                render()
            }
            .onChange(of: id) { _, _ in render() }
            .onChange(of: markdown) { _, _ in render() }
            .onChange(of: clipHeight) { _, height in box.call("setClip", Double(height ?? 0)) }
    }

    private func render() {
        appState.syncMacros(box)
        box.call("setDocument", markdown)
    }
}

/// Long generated prose that should not take over a card: the first few lines, faded, with
/// "Show more" to read the rest in place. Short text shows whole with no control at all.
struct CollapsibleMath: View {
    let markdown: String
    let id: String
    var collapsedHeight: CGFloat = 110

    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0

    private var overflows: Bool { contentHeight > collapsedHeight + 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RenderedMath(markdown: markdown, id: id, maxHeight: .infinity,
                         clipHeight: overflows && !expanded ? collapsedHeight : nil,
                         onContentHeight: { contentHeight = $0 })
            if overflows {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(expanded ? "Show less" : "Show more",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }
        }
        .onChange(of: id) { _, _ in expanded = false }
    }
}
