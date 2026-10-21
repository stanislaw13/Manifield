import XCTest
@testable import ManifieldDiagnostics

/// A clock the test drives. `DiagnosticsLog` takes its `now` as a closure precisely so
/// rotation — which is about days and sizes, not about waiting — can be tested in
/// milliseconds.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); date = newValue; lock.unlock() }
    }

    func advanceDays(_ count: Int) {
        now = now.addingTimeInterval(Double(count) * 86_400)
    }
}

final class DiagnosticsLogTests: XCTestCase {

    private var directory: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifield-diagnostics-tests-\(UUID().uuidString)")
        // 2026-09-18T12:00:00Z, fixed so the file names in the assertions are the file
        // names on disk whatever timezone the machine is in.
        clock = Clock(Date(timeIntervalSince1970: 1_789_732_800))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(retentionDays: Int = 7,
                         maximumTotalBytes: Int = 10 * 1024 * 1024,
                         maximumFileBytes: Int = 4 * 1024 * 1024) -> DiagnosticsLog {
        let clock = self.clock!
        return DiagnosticsLog(
            configuration: .init(directory: directory,
                                 retentionDays: retentionDays,
                                 maximumTotalBytes: maximumTotalBytes,
                                 maximumFileBytes: maximumFileBytes,
                                 minimumLevel: .debug,
                                 mirrorsToSystemLog: false),
            now: { clock.now })
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Writing

    func testWritesOneLinePerEventWithFieldsInOrder() throws {
        let log = makeLog()
        log.info("run.started", category: .run, [
            ("program", .id("9F86D081-884C-7D65-9A25-8A1C2E4F3B77")),
            ("branches", .count(3)),
            ("mode", .symbol("auto"))
        ])
        log.flush()

        let lines = contents(of: log.currentFileURL()).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let line = String(lines[0])
        XCTAssertTrue(line.contains("[run] run.started"), line)
        XCTAssertTrue(line.contains("program=9F86D081-884C-7D65-9A25-8A1C2E4F3B77"), line)
        XCTAssertTrue(line.contains("branches=3"), line)
        XCTAssertTrue(line.contains("mode=auto"), line)
        XCTAssertTrue(line.hasPrefix("2026-09-18T12:00:00.000Z INFO "), line)
    }

    func testMinimumLevelDropsQuieterLines() throws {
        let log = DiagnosticsLog(
            configuration: .init(directory: directory, minimumLevel: .notice, mirrorsToSystemLog: false),
            now: { [clock] in clock!.now })
        log.debug("a.debug", category: .app)
        log.info("a.info", category: .app)
        log.notice("a.notice", category: .app)
        log.flush()

        let text = contents(of: log.currentFileURL())
        XCTAssertFalse(text.contains("a.debug"))
        XCTAssertFalse(text.contains("a.info"))
        XCTAssertTrue(text.contains("a.notice"))
    }

    /// Concurrency is the whole reason for the serial queue: agent runs log from several
    /// tasks at once, and two half-lines spliced together would be unreadable.
    func testConcurrentWritesProduceWholeLines() throws {
        let log = makeLog()
        let group = DispatchGroup()
        for index in 0..<200 {
            DispatchQueue.global().async(group: group) {
                log.info("run.event", category: .run, [("n", .count(index))])
            }
        }
        group.wait()
        log.flush()

        let lines = contents(of: log.currentFileURL()).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        for line in lines {
            XCTAssertTrue(line.contains("[run] run.event n="), String(line))
        }
    }

    func testAppendsRatherThanTruncatingAcrossWriters() throws {
        let first = makeLog()
        first.info("app.launched", category: .app)
        first.flush()

        let second = makeLog()
        second.info("app.relaunched", category: .app)
        second.flush()

        let text = contents(of: second.currentFileURL())
        XCTAssertTrue(text.contains("app.launched"))
        XCTAssertTrue(text.contains("app.relaunched"))
    }

    // MARK: - Redaction, end to end

    /// The rule as a test: nothing that resembles research, a key or an address may reach
    /// the file, whichever value case a call site chose.
    func testNothingSensitiveReachesTheFile() throws {
        let log = makeLog()
        let statement = "Theorem 3.2: every finite Blaschke product of degree n is n-to-one"
        let key = "sk-ant-api03-QQQQWWWWEEEERRRRTTTTYYYYUUUUIIII"

        log.info("item.saved", category: .project, [("item", .id(statement))])
        log.info("provider.configured", category: .app, [("provider", .symbol(statement))])
        log.info("project.opened", category: .project,
                 [("project", .handle("/Users/ada/Documents/\(statement)"))])
        log.error("run.failed", category: .run,
                  [("error", .errorDescription("401 from provider using \(key) for ada@example.com"))])
        log.flush()

        let text = contents(of: log.currentFileURL())
        XCTAssertFalse(text.contains("Blaschke"), text)
        XCTAssertFalse(text.contains("Theorem 3.2:"), text)
        XCTAssertFalse(text.contains(key), text)
        XCTAssertFalse(text.contains("ada@example.com"), text)
        XCTAssertTrue(text.contains("<redacted:key>"), text)
        XCTAssertTrue(text.contains("<redacted:email>"), text)
    }

    func testEveryRecordIsExactlyOneLine() throws {
        let log = makeLog()
        log.error("run.failed", category: .run,
                  [("error", .errorDescription("first line\nsecond line\nthird line"))])
        log.flush()
        XCTAssertEqual(contents(of: log.currentFileURL()).split(separator: "\n").count, 1)
    }

    /// A `.path` value is documented as app-controlled only, so a real one — the shared
    /// venv `PythonRuntime` builds under Application Support — should survive whole, not
    /// just lose its home prefix.
    func testLoggedPathsLoseTheHomeDirectory() throws {
        let log = makeLog()
        log.info("python.located", category: .python,
                 [("interpreter", .path(NSHomeDirectory() + "/Library/Application Support/Manifield/pyenv/bin/python3"))])
        log.flush()
        let text = contents(of: log.currentFileURL())
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertTrue(text.contains("~/Library/Application Support/Manifield/pyenv/bin/python3"), text)
    }

    /// The other side of the same case: a `.path` value that (by mistake, or by whatever
    /// route) turns out to be under a folder the app does not own must not survive just
    /// because it went through `.path` rather than `.errorDescription`.
    func testLoggedPathsUnderAnUnownedFolderAreRedactedWholesale() throws {
        let log = makeLog()
        log.info("python.located", category: .python,
                 [("interpreter", .path(NSHomeDirectory() + "/Documents/Manifield/My Secret Theorem/venv"))])
        log.flush()
        let text = contents(of: log.currentFileURL())
        XCTAssertFalse(text.contains("My Secret Theorem"))
        XCTAssertTrue(text.contains("<redacted:path>"), text)
    }

    // MARK: - Rotation

    func testRollsToANewFileEachDay() throws {
        let log = makeLog()
        log.info("app.launched", category: .app)
        log.flush()
        clock.advanceDays(1)
        log.info("app.launched", category: .app)
        log.flush()

        let names = log.files().map(\.lastPathComponent)
        XCTAssertEqual(names, ["manifield-2026-09-18.log", "manifield-2026-09-19.log"])
    }

    func testKeepsSevenDaysAndDropsOlder() throws {
        let log = makeLog(retentionDays: 7)
        for _ in 0..<12 {
            log.info("app.tick", category: .app)
            log.flush()
            clock.advanceDays(1)
        }
        // One more write so the prune runs with the last day as "today".
        log.info("app.tick", category: .app)
        log.flush()

        let names = log.files().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 8, "\(names)")           // today plus seven days back
        XCTAssertEqual(names.first, "manifield-2026-09-23.log")
        XCTAssertEqual(names.last, "manifield-2026-09-30.log")
    }

    func testTotalSizeCapEvictsOldestFirst() throws {
        // 4 KB of ceiling, 1 KB per file: every write of a padded line rolls the part, so
        // the directory is forced past the cap in a handful of lines.
        let log = makeLog(retentionDays: 365, maximumTotalBytes: 4 * 1024, maximumFileBytes: 1024)
        for index in 0..<40 {
            log.info("run.event", category: .run, [("n", .count(index)), ("pad", .id(String(repeating: "a", count: 60)))])
            log.flush()
        }
        let total = log.files().reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(total, 4 * 1024 + 1024, "directory grew past its cap: \(total)")
        XCTAssertFalse(log.files().isEmpty)
        // The newest part survives; the oldest went first.
        XCTAssertTrue(contents(of: log.currentFileURL()).contains("n=39"))
    }

    func testOneDayRollsIntoNumberedPartsWhenItGrows() throws {
        let log = makeLog(maximumTotalBytes: 10 * 1024 * 1024, maximumFileBytes: 512)
        for index in 0..<20 {
            log.info("run.event", category: .run, [("n", .count(index)), ("pad", .id(String(repeating: "b", count: 60)))])
        }
        log.flush()
        let names = log.files().map(\.lastPathComponent)
        XCTAssertTrue(names.contains("manifield-2026-09-18.log"), "\(names)")
        XCTAssertTrue(names.contains("manifield-2026-09-18.2.log"), "\(names)")
    }

    // MARK: - Tail

    func testTailIsCappedAndStartsOnALineBoundary() throws {
        let log = makeLog()
        for index in 0..<500 {
            log.info("run.event", category: .run, [("n", .count(index))])
        }
        log.flush()

        let tail = log.tail(maximumBytes: 2_000)
        XCTAssertLessThanOrEqual(tail.utf8.count, 2_000)
        XCTAssertTrue(tail.hasPrefix("2026-09-18T"), String(tail.prefix(40)))
        XCTAssertTrue(tail.contains("n=499"))
        XCTAssertFalse(tail.contains("n=0 "))
    }

    func testTailSpansFilesOldestFirst() throws {
        let log = makeLog()
        log.info("day.one", category: .app)
        log.flush()
        clock.advanceDays(1)
        log.info("day.two", category: .app)
        log.flush()

        let tail = log.tail(maximumBytes: DiagnosticsLog.defaultTailBytes)
        let one = try XCTUnwrap(tail.range(of: "day.one"))
        let two = try XCTUnwrap(tail.range(of: "day.two"))
        XCTAssertTrue(one.lowerBound < two.lowerBound, "tail is out of order")
    }

    func testTailOfAnEmptyDirectoryIsEmpty() {
        XCTAssertEqual(makeLog().tail(), "")
    }
}
