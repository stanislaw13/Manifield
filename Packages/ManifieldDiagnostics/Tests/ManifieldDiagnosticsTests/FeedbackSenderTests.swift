import XCTest
@testable import ManifieldDiagnostics

final class FeedbackReportTests: XCTestCase {

    private func report(snapshot: DiagnosticsSnapshot? = nil,
                        email: String? = nil,
                        logTail: String? = nil,
                        crashLog: String? = nil) -> FeedbackReport {
        FeedbackReport(kind: .bug,
                       message: "The graph view is blank after importing a paper.",
                       email: email,
                       snapshot: snapshot,
                       logTail: logTail,
                       crashLog: crashLog,
                       id: "a1b2c3d4e5f6",
                       createdAt: Date(timeIntervalSince1970: 1_789_732_800))
    }

    private func object(_ report: FeedbackReport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try report.jsonData()) as? [String: Any])
    }

    /// The one field that cannot be added later: builds already in testers' hands keep
    /// sending the shape they were compiled with.
    func testPayloadCarriesSchemaVersionAtTheTopLevel() throws {
        XCTAssertEqual(try object(report())["schemaVersion"] as? Int, 1)
        XCTAssertEqual(FeedbackReport.schemaVersion(of: try report().jsonData()), 1)
    }

    func testSchemaVersionIsPresentEvenOnTheLeanestReport() throws {
        let lean = FeedbackReport(kind: .other, message: "hi")
        XCTAssertEqual(try object(lean)["schemaVersion"] as? Int, 1)
    }

    func testOmittedAttachmentsAreAbsentRatherThanNull() throws {
        let keys = Set(try object(report()).keys)
        XCTAssertEqual(keys, ["schemaVersion", "id", "kind", "message", "createdAt"])
    }

    func testIncludedAttachmentsArePresent() throws {
        let snapshot = DiagnosticsSnapshot(appVersion: "0.1.0", buildNumber: "1",
                                           macOSVersion: "26.3", architecture: "arm64",
                                           isTranslocated: true, codexBinaryFound: true,
                                           codexPlanType: "pro", pythonEnvironmentReady: true,
                                           configuredProviders: ["anthropic"],
                                           capturedAt: Date(timeIntervalSince1970: 1_789_732_800))
        let full = try object(report(snapshot: snapshot, email: "ada@example.com",
                                     logTail: "2026-09-18T12:00:00.000Z INFO  [app] app.launched",
                                     crashLog: "Incident Identifier: 1"))
        XCTAssertEqual((full["snapshot"] as? [String: Any])?["isTranslocated"] as? Bool, true)
        XCTAssertEqual(full["email"] as? String, "ada@example.com")
        XCTAssertNotNil(full["logTail"])
        XCTAssertNotNil(full["crashLog"])
    }

    func testRoundTripsThroughJSON() throws {
        let original = report(email: "ada@example.com", logTail: "one\ntwo")
        let decoded = try FeedbackReport.decode(from: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testAnEmptyMessageIsNotSendable() {
        XCTAssertFalse(FeedbackReport(kind: .bug, message: "   \n ").isSendable)
        XCTAssertTrue(FeedbackReport(kind: .bug, message: "it broke").isSendable)
    }

    func testSuggestedFileNameSaysWhatAndWhen() {
        XCTAssertTrue(report().suggestedFileName.hasPrefix("manifield-bug-"))
        XCTAssertTrue(report().suggestedFileName.hasSuffix("-a1b2c3d4e5f6.json"))
    }

    /// A report id is short hex on purpose: the log's own secret redaction treats long
    /// opaque runs as possible keys, and a UUID-shaped reference would be unusable.
    func testReportIDSurvivesRedaction() {
        let id = FeedbackReport.newID()
        XCTAssertEqual(id.count, 12)
        XCTAssertEqual(Redactor.scrubIdentifier(id), id)
    }
}

final class FeedbackSenderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-feedback-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let report = FeedbackReport(kind: .bug, message: "Blank graph after import.")

    private func sender(status: Int, capture: (@Sendable (URLRequest) -> Void)? = nil) -> HTTPFeedbackSender {
        HTTPFeedbackSender(endpoint: FeedbackEndpoint.url) { request in
            capture?(request)
            let response = HTTPURLResponse(url: FeedbackEndpoint.url, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }

    // MARK: - HTTP

    func testSuccessfulSendReportsTheReference() async throws {
        let delivery = try await sender(status: 202).send(report)
        XCTAssertTrue(delivery.summary.contains(report.id))
        XCTAssertNil(delivery.fileURL)
    }

    func testPostsJSONWithSchemaVersionToTheConstantEndpoint() async throws {
        let box = RequestBox()
        _ = try await sender(status: 200, capture: { box.request = $0 }).send(report)
        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.url, URL(string: "https://feedback.manifield.net/report"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(FeedbackReport.schemaVersion(of: try XCTUnwrap(request.httpBody)), 1)
    }

    /// The state the alpha actually ships in: the Worker is not deployed, so the endpoint
    /// answers 404 and the fallback is the only path that works.
    func testUndeployedEndpointFailsWithAnActionableError() async throws {
        do {
            _ = try await sender(status: 404).send(report)
            XCTFail("a 404 must not read as success")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .server(status: 404))
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("404"), message)
        }
    }

    func testRateLimitingIsDistinguishedFromOtherFailures() async throws {
        do {
            _ = try await sender(status: 429).send(report)
            XCTFail("expected a failure")
        } catch let error as FeedbackError {
            XCTAssertEqual(error, .server(status: 429))
            XCTAssertTrue(try XCTUnwrap(error.errorDescription).contains("save the report to a file"))
        }
    }

    func testUnreachableHostIsReportedAsTransport() async throws {
        let sender = HTTPFeedbackSender(endpoint: FeedbackEndpoint.url) { _ in
            throw URLError(.cannotFindHost)
        }
        do {
            _ = try await sender.send(report)
            XCTFail("expected a failure")
        } catch let error as FeedbackError {
            guard case .transport = error else { return XCTFail("wrong case: \(error)") }
        }
    }

    // MARK: - The fallback

    /// The acceptance condition: with the endpoint unreachable, the report still ends up
    /// somewhere complete and readable. Nothing the tester wrote is lost.
    func testFileFallbackProducesACompleteReadableReport() async throws {
        let full = FeedbackReport(
            kind: .bug,
            message: "Blank graph after import.",
            email: "ada@example.com",
            snapshot: DiagnosticsSnapshot(appVersion: "0.1.0", buildNumber: "1",
                                          macOSVersion: "26.3", architecture: "arm64",
                                          isTranslocated: true, codexBinaryFound: false,
                                          codexPlanType: nil, pythonEnvironmentReady: false,
                                          configuredProviders: ["anthropic"],
                                          capturedAt: Date(timeIntervalSince1970: 1_789_732_800)),
            logTail: "2026-09-18T12:00:00.000Z INFO  [app] app.launched version=0.1.0")

        do {
            _ = try await HTTPFeedbackSender(endpoint: FeedbackEndpoint.url) { _ in
                throw URLError(.notConnectedToInternet)
            }.send(full)
            XCTFail("expected the send to fail")
        } catch {
            // …which is the point: what follows is what the UI does next.
        }

        let revealed = URLBox()
        let file = FileFeedbackSender(destination: .directory(directory),
                                      reveal: { revealed.url = $0 })
        let delivery = try await file.send(full)

        let url = try XCTUnwrap(delivery.fileURL)
        XCTAssertEqual(revealed.url, url, "the tester has to be shown where it went")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let written = try Data(contentsOf: url)
        let reloaded = try FeedbackReport.decode(from: written)
        XCTAssertEqual(reloaded, full, "the file must hold the whole report, not a summary")
        XCTAssertEqual(FeedbackReport.schemaVersion(of: written), 1)

        let text = try XCTUnwrap(String(data: written, encoding: .utf8))
        XCTAssertTrue(text.contains("\n"), "a report a tester may have to read by eye")
        XCTAssertTrue(text.contains("Blank graph after import."))
        XCTAssertTrue(text.contains("\"isTranslocated\" : true"))
    }

    func testFileSenderWritesExactlyWhereTheSavePanelSaid() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("chosen name.json")
        let delivery = try await FileFeedbackSender(destination: .file(target), reveal: { _ in })
            .send(report)
        XCTAssertEqual(delivery.fileURL, target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testFileSenderCreatesItsDirectory() async throws {
        let nested = directory.appendingPathComponent("a/b/reports")
        let delivery = try await FileFeedbackSender(destination: .directory(nested), reveal: { _ in })
            .send(report)
        XCTAssertEqual(delivery.fileURL?.deletingLastPathComponent().path, nested.path)
    }

    func testFileSenderSummaryDoesNotSpellOutTheHomeDirectory() async throws {
        let delivery = try await FileFeedbackSender(destination: .directory(directory), reveal: { _ in })
            .send(report)
        XCTAssertFalse(delivery.summary.contains(NSHomeDirectory()))
    }

    func testNeitherSenderAcceptsAnEmptyMessage() async throws {
        let empty = FeedbackReport(kind: .idea, message: "  ")
        for sender in [sender(status: 200) as FeedbackSender,
                       FileFeedbackSender(destination: .directory(directory), reveal: { _ in })] {
            do {
                _ = try await sender.send(empty)
                XCTFail("expected a refusal")
            } catch let error as FeedbackError {
                XCTAssertEqual(error, .emptyMessage)
            }
        }
    }

    func testDefaultFallbackDirectoryNeedsNoPermissionPrompt() {
        // ~/Library/Logs/… rather than Desktop or Documents, which are TCC-protected: a
        // permission prompt in the middle of a failed send is where reports get lost.
        let path = FileFeedbackSender.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("/Library/Logs/Manifield/reports"), path)
    }
}

/// Small boxes so a `@Sendable` closure can hand something back to the test.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var request: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
