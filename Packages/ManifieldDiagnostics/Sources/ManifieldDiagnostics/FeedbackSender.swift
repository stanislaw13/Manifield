import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum FeedbackError: LocalizedError, Equatable {
    case emptyMessage
    /// The endpoint answered, but not with success. Carries the status because a 404 (the
    /// Worker is not deployed yet) and a 429 (you are sending too fast) call for different
    /// things from the tester.
    case server(status: Int)
    case transport(String)
    case malformedReport
    case couldNotWriteFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyMessage:
            return "Write a few words about what happened before sending."
        case .server(let status) where status == 404:
            return "The feedback service isn’t answering at that address yet (404)."
        case .server(let status) where status == 429:
            return "The feedback service is rate-limiting this connection (429). Try again in a few minutes, or save the report to a file."
        case .server(let status):
            return "The feedback service returned an error (HTTP \(status))."
        case .transport(let detail):
            return "Could not reach the feedback service: \(detail)"
        case .malformedReport:
            return "That file isn’t a Manifield feedback report."
        case .couldNotWriteFile(let detail):
            return "Could not write the report: \(detail)"
        }
    }
}

/// What happened to a report, in terms the UI can show.
public struct FeedbackDelivery: Equatable, Sendable {
    /// One sentence for the success state.
    public var summary: String
    /// Set when the report ended up on disk, so the UI can offer to show it.
    public var fileURL: URL?

    public init(summary: String, fileURL: URL? = nil) {
        self.summary = summary
        self.fileURL = fileURL
    }
}

/// Somewhere a report can go.
///
/// Two implementations, and both are first-class. There is no retry queue: a report held
/// for later is a report the tester thinks they sent, and the alpha's endpoint will 404
/// until the Worker is deployed. Failure is a normal outcome here, and the answer to it is
/// to put the report somewhere the tester can see and send by hand — which is why the file
/// sender is a `FeedbackSender` too, not a rescue path bolted onto the UI.
public protocol FeedbackSender: Sendable {
    func send(_ report: FeedbackReport) async throws -> FeedbackDelivery
}

/// POSTs the report as JSON to `FeedbackEndpoint.url`.
public struct HTTPFeedbackSender: FeedbackSender {

    /// Injected so the failure path — the one that has to work on day one — can be tested
    /// without a network or a deployed Worker.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let endpoint: URL
    public let timeout: TimeInterval
    private let transport: Transport

    public init(endpoint: URL = FeedbackEndpoint.url,
                timeout: TimeInterval = 20,
                transport: Transport? = nil) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.transport = transport ?? { request in
            // Ephemeral: no cookie store, no URL cache, nothing about a report persisted by
            // the loading system after it has gone.
            let session = URLSession(configuration: .ephemeral)
            return try await session.data(for: request)
        }
    }

    public func send(_ report: FeedbackReport) async throws -> FeedbackDelivery {
        guard report.isSendable else { throw FeedbackError.emptyMessage }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(FeedbackEndpoint.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try report.jsonData()

        let response: URLResponse
        do {
            (_, response) = try await transport(request)
        } catch {
            throw FeedbackError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.transport("unexpected response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedbackError.server(status: http.statusCode)
        }
        return FeedbackDelivery(summary: "Sent. Thank you — reference \(report.id).")
    }
}

/// Writes the report to a file and shows it in Finder.
public struct FileFeedbackSender: FeedbackSender {

    public enum Destination: Sendable {
        /// Write into this folder under the report's own suggested name.
        case directory(URL)
        /// Write exactly here — what the Save panel hands back.
        case file(URL)
    }

    public let destination: Destination
    private let reveal: @Sendable (URL) -> Void

    public init(destination: Destination = .directory(FileFeedbackSender.defaultDirectory),
                reveal: (@Sendable (URL) -> Void)? = nil) {
        self.destination = destination
        self.reveal = reveal ?? { url in
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            #endif
        }
    }

    /// `~/Library/Logs/Manifield/reports/`, beside the logs.
    ///
    /// Not the Desktop, and not Documents: those are TCC-protected, so the one-click
    /// fallback would raise a permission prompt at precisely the moment the tester is
    /// already dealing with a failure. The app's own Logs folder needs no permission, and
    /// Finder opens it just as happily.
    public static var defaultDirectory: URL {
        DiagnosticsLog.Configuration.defaultDirectory.appendingPathComponent("reports", isDirectory: true)
    }

    public func send(_ report: FeedbackReport) async throws -> FeedbackDelivery {
        guard report.isSendable else { throw FeedbackError.emptyMessage }
        let url: URL
        switch destination {
        case .directory(let directory):
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw FeedbackError.couldNotWriteFile(error.localizedDescription)
            }
            url = directory.appendingPathComponent(report.suggestedFileName)
        case .file(let fileURL):
            url = fileURL
        }
        do {
            try report.jsonData().write(to: url, options: .atomic)
        } catch {
            throw FeedbackError.couldNotWriteFile(error.localizedDescription)
        }
        reveal(url)
        return FeedbackDelivery(summary: "Saved to \(Redactor.abbreviatingHome(url.path)).", fileURL: url)
    }
}
