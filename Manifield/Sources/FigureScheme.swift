import Foundation
import WebKit
import ManifieldCore

/// Serves figure images to the bundled web views under a scheme of our own.
///
/// The pages load from the app bundle with read access scoped to `Resources/web`, so a
/// `file://` URL into the user's project is (correctly) refused, and inlining every image
/// as a data: URL would push megabytes through `evaluateJavaScript` on every re-render.
/// A custom scheme fixes both — but the real reason for it is that it keeps *resolution*
/// in Swift: `manifield-figure://<item-id>` is the only image source render.js allows,
/// and this handler answers it only for figures of the open project. Markdown coming out
/// of a model therefore has no way to make the page fetch anything.
enum FigureScheme {

    static let scheme = "manifield-figure"

    /// The URL that renders `item`'s image. Ids are already lowercase kebab-case
    /// (`TheoryItem.sanitizeID`), so they need no escaping to sit in a host component.
    static func url(forItemID id: String) -> URL? {
        URL(string: "\(scheme)://\(id)")
    }

    static func itemID(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == scheme else { return nil }
        let raw = url.host ?? url.path.split(separator: "/").first.map(String.init) ?? ""
        let id = raw.removingPercentEncoding ?? raw
        return id.isEmpty ? nil : id
    }
}

/// Resolves figure ids against whichever project is open. Set by `AppState` on open and
/// cleared on close; weak, so it can never be the reason a closed project's store lives on.
@MainActor
final class FigureResolver {
    static let shared = FigureResolver()
    weak var store: ProjectStore?

    /// Images of figures that are proposed but not yet accepted, keyed by item id. A
    /// review has to show the picture it is asking the user to approve, and until they
    /// say yes that picture is still in the sandbox run folder — nothing has been copied
    /// into `figures/`. Kept in step with `AppState.pendingProposals`.
    var pendingImages: [String: URL] = [:]

    private init() {}

    /// The image file for a figure item, or nil if the id is unknown, is not a figure, or
    /// its `image` does not name a real file inside `figures/`.
    func imageURL(forItemID id: String) -> URL? {
        if let store, let item = store.item(id: id), item.isFigure,
           let stored = store.figureImageURL(for: item) {
            return stored
        }
        return pendingImages[id]
    }
}

final class FigureSchemeHandler: NSObject, WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url,
                  let id = FigureScheme.itemID(from: url),
                  let fileURL = FigureResolver.shared.imageURL(forItemID: id),
                  let mime = FigureAsset.mimeType(forExtension: fileURL.pathExtension),
                  let data = try? Data(contentsOf: fileURL) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            // no-store, because the id survives a "replace image": without it the web
            // view would keep showing the picture the figure used to have.
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(data.count)",
                    "Cache-Control": "no-store"
                ])
            guard let response else {
                task.didFailWithError(URLError(.badServerResponse))
                return
            }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
