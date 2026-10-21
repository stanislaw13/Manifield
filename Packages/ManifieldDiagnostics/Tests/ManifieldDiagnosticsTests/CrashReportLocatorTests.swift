import XCTest
@testable import ManifieldDiagnostics

final class CrashReportLocatorTests: XCTestCase {

    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_789_732_800)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-crash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func write(_ name: String, contents: String = "Incident Identifier: 1\n",
                       hoursAgo: Double = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-hoursAgo * 3600)], ofItemAtPath: url.path)
        return url
    }

    private func locator() -> CrashReportLocator {
        CrashReportLocator(directory: directory, processPrefix: "Manifield")
    }

    func testMissingDirectoryIsReportedNotTreatedAsAFailure() {
        let absent = CrashReportLocator(directory: directory.appendingPathComponent("nope"))
        XCTAssertEqual(absent.availability(now: now), .missing)
        XCTAssertNil(absent.newestReport(now: now))
    }

    func testReadableDirectoryCountsOnlyThisAppsRecentReports() throws {
        try write("Manifield-2026-09-18-120000.ips", hoursAgo: 2)
        try write("Manifield-2026-09-10-120000.ips", hoursAgo: 200)      // outside the window
        try write("NotificationCenter-2026-09-18-120000.ips", hoursAgo: 1) // another process
        try write("Manifield-notes.txt", hoursAgo: 1)                     // not a crash report
        XCTAssertEqual(locator().availability(now: now), .readable(matching: 1))
    }

    func testPicksTheNewestReport() throws {
        try write("Manifield-2026-09-18-010000.ips", contents: "older\n", hoursAgo: 6)
        let newest = try write("Manifield-2026-09-18-110000.ips", contents: "newest\n", hoursAgo: 1)
        let found = try XCTUnwrap(locator().newestReport(now: now))
        XCTAssertEqual(found.url, newest)
        XCTAssertTrue(found.contents.contains("newest"))
    }

    func testStaleReportsAreNotOffered() throws {
        try write("Manifield-2026-09-15-120000.ips", hoursAgo: 48)
        XCTAssertNil(locator().newestReport(now: now))
        XCTAssertEqual(locator().availability(now: now), .readable(matching: 0))
    }

    /// An .ips names the crashing bundle's full path on its first lines, which is under the
    /// tester's home directory — and so is their user name. `Downloads` is not one of the
    /// app's own fixed locations, so the path is redacted wholesale rather than merely
    /// losing its home prefix: a user free to put `Manifield.app` in `~/Downloads` is
    /// equally free to put it inside a folder named after their research.
    func testContentsAreScrubbedOfHomePathsAndAddresses() throws {
        try write("Manifield-2026-09-18-120000.ips", contents: """
        {"app_name":"Manifield","path":"\(NSHomeDirectory())/Downloads/Manifield.app"}
        signed-in as ada@example.com with sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH
        """)
        let found = try XCTUnwrap(locator().newestReport(now: now))
        XCTAssertFalse(found.contents.contains(NSHomeDirectory()))
        XCTAssertFalse(found.contents.contains("Downloads"))
        XCTAssertTrue(found.contents.contains("<redacted:path>"), found.contents)
        XCTAssertFalse(found.contents.contains("ada@example.com"))
        XCTAssertFalse(found.contents.contains("sk-ant-api03"))
    }

    /// The app's own fixed locations are the exception: a crash report that mentions the
    /// Codex environment or the app's own logs must still say exactly where.
    func testAppOwnedPathsSurviveInCrashReports() throws {
        let home = NSHomeDirectory()
        try write("Manifield-2026-09-18-120000.ips", contents: """
        CODEX_HOME=\(home)/Library/Application Support/Manifield/codex-home
        codex candidate: \(home)/.codex/bin/codex
        """)
        let found = try XCTUnwrap(locator().newestReport(now: now))
        XCTAssertTrue(found.contents.contains("~/Library/Application Support/Manifield/codex-home"), found.contents)
        XCTAssertTrue(found.contents.contains("~/.codex/bin/codex"), found.contents)
        XCTAssertFalse(found.contents.contains("<redacted:path>"), found.contents)
    }

    /// Crash reports run to hundreds of kilobytes of thread state; one must not crowd out
    /// everything else in the payload.
    func testContentsAreCapped() throws {
        try write("Manifield-2026-09-18-120000.ips",
                  contents: String(repeating: "thread state\n", count: 20_000))
        let locator = CrashReportLocator(directory: directory, maximumBytes: 4_096)
        let found = try XCTUnwrap(locator.newestReport(now: now))
        XCTAssertLessThanOrEqual(found.contents.count, 4_097)
    }

    /// Multi-line on purpose: a crash report is only readable as many lines, unlike a log
    /// record, so this text keeps its newlines while everything in the log loses them.
    func testContentsKeepTheirLineBreaks() throws {
        try write("Manifield-2026-09-18-120000.ips", contents: "one\ntwo\nthree\n")
        let found = try XCTUnwrap(locator().newestReport(now: now))
        XCTAssertTrue(found.contents.contains("\n"))
    }
}
