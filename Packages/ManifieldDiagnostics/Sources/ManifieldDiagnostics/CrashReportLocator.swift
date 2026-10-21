import Foundation

/// Finds the newest crash report macOS wrote for this app.
///
/// Opt-in, always. A crash report is a memory map of the process at the moment it died and
/// there is no honest way to promise what is or is not in it, so it is never attached
/// unless the tester ticks the box having been told what it is.
public struct CrashReportLocator: Sendable {

    /// Whether the folder can be read at all, and what to tell the tester if not.
    public enum Availability: Equatable, Sendable {
        /// Readable, with this many crash reports for this app in the window.
        case readable(matching: Int)
        /// The folder exists but macOS would not list it.
        case unreadable(reason: String)
        /// No such folder — the normal state on a Mac that has never crashed anything.
        case missing
    }

    /// `~/Library/Logs/DiagnosticReports/`.
    public let directory: URL
    /// Crash files are named `<process>-<date>.ips`.
    public let processPrefix: String
    /// How recent a report has to be to be worth offering.
    public let window: TimeInterval
    /// Crash reports run to hundreds of kilobytes of thread state; this keeps one from
    /// dwarfing everything else in the payload.
    public let maximumBytes: Int

    public init(directory: URL = CrashReportLocator.defaultDirectory,
                processPrefix: String = "Manifield",
                window: TimeInterval = 24 * 60 * 60,
                maximumBytes: Int = 200 * 1024) {
        self.directory = directory
        self.processPrefix = processPrefix
        self.window = window
        self.maximumBytes = maximumBytes
    }

    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    /// Probes the folder without reading any report.
    ///
    /// Hardened runtime does not gate file reads — it governs code signing, library
    /// validation and the debugging entitlements — and `~/Library/Logs/DiagnosticReports`
    /// is not one of the TCC-protected locations (Desktop, Documents, Downloads and the
    /// like), so a non-sandboxed Developer ID app reads it with no extra permission and no
    /// prompt. That was checked on this app, hardened and signed, rather than assumed. It
    /// is still probed at runtime and degraded gracefully: the folder is
    /// `drwxrwx--- <user>:_analyticsusers`, which is the user's to read today, and a report
    /// that fails because macOS changed its mind about that is a bad report.
    public func availability(now: Date = Date()) -> Availability {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: directory.path)
            return .readable(matching: matching(names: names, now: now).count)
        } catch {
            return .unreadable(reason: Redactor.scrub(error.localizedDescription, limit: 200))
        }
    }

    /// The newest report for this app inside the window, already capped and scrubbed.
    public func newestReport(now: Date = Date()) -> (url: URL, contents: String)? {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        guard let newest = matching(names: names, now: now)
            .max(by: { modified($0) < modified($1) }) else { return nil }
        guard let data = try? Data(contentsOf: newest) else { return nil }
        let text = String(data: data.prefix(maximumBytes), encoding: .utf8)
            ?? String(data: data.prefix(maximumBytes), encoding: .isoLatin1)
            ?? ""
        // The report is full of paths, and the first line of an .ips carries the crashing
        // process's full bundle path — which is under the tester's home directory.
        return (newest, Redactor.scrubMultiline(text, limit: maximumBytes))
    }

    private func matching(names: [String], now: Date) -> [URL] {
        names
            .filter { $0.hasPrefix(processPrefix) && $0.hasSuffix(".ips") }
            .map { directory.appendingPathComponent($0) }
            .filter { now.timeIntervalSince(modified($0)) <= window }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
    }
}
