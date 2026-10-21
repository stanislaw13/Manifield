import Foundation
import os

/// How much a line matters. Maps one-to-one onto `os.Logger`'s levels so the same call
/// lands in Console.app at the severity it deserves.
public enum DiagnosticsLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case notice
    case error

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .notice: return "NOTE "
        case .error: return "ERROR"
        }
    }

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Which part of the app a line came from. A struct with static members rather than an
/// enum so ManifieldCore, ManifieldAgents and ManifieldSandbox can each declare their own
/// without editing this file when they adopt the logger.
public struct DiagnosticsCategory: Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = Redactor.scrubIdentifier(name, limit: 24)
    }

    public static let app = DiagnosticsCategory("app")
    public static let project = DiagnosticsCategory("project")
    public static let codex = DiagnosticsCategory("codex")
    public static let run = DiagnosticsCategory("run")
    public static let python = DiagnosticsCategory("python")
    public static let feedback = DiagnosticsCategory("feedback")
}

/// The only kinds of thing a log line may carry.
///
/// This enum *is* the redaction rule. There is no `.text` case and no way to add one at a
/// call site, so item text, statements, proofs, prompts, model output and file contents
/// have no route into the log — not because every call site remembers not to log them, but
/// because the function will not accept them. What each case does accept is scrubbed again
/// by `Redactor` on the way to disk.
public enum DiagnosticsValue: Sendable, Equatable {
    /// A number of things. The count of items in a project, of branches in a run.
    case count(Int)
    /// A size in bytes, rendered with a unit.
    case bytes(Int)
    /// An elapsed time in seconds.
    case seconds(Double)
    case flag(Bool)
    /// An identifier: a UUID, a slug, a plan or program id. Reduced to identifier
    /// characters, so prose handed here by mistake arrives as underscores.
    case id(String)
    /// A word from a fixed vocabulary — a state name, a provider name, a run mode.
    case symbol(String)
    /// A path the *app* controls (its own log directory, the codex binary). Never a
    /// project path: those are named by the user and say what they are working on — use
    /// `.handle` for those.
    case path(String)
    /// A short opaque stand-in for a string too revealing to log, stable across a session
    /// so two lines about the same project can still be tied together.
    case handle(String)
    /// `error.localizedDescription`, and nothing else. Scrubbed hardest of all.
    case errorDescription(String)

    /// What this value looks like in a log line — already redacted.
    var rendered: String {
        switch self {
        case .count(let value): return String(value)
        case .bytes(let value): return "\(value)B"
        case .seconds(let value): return String(format: "%.2fs", value)
        case .flag(let value): return value ? "true" : "false"
        case .id(let value): return quoteIfNeeded(Redactor.scrubIdentifier(value))
        case .symbol(let value): return quoteIfNeeded(Redactor.scrubIdentifier(value, limit: 48))
        case .path(let value): return quoteIfNeeded(Redactor.scrub(value, limit: 240))
        case .handle(let value): return Redactor.handle(value)
        case .errorDescription(let value): return quoteIfNeeded(Redactor.scrub(value, limit: 400))
        }
    }

    private func quoteIfNeeded(_ text: String) -> String {
        guard text.isEmpty || text.contains(" ") || text.contains("\"") || text.contains("=") else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}

/// One `key=value` pair. Keys are `StaticString` for the same reason event names are:
/// a literal cannot be assembled out of a proof.
public typealias DiagnosticsFields = [(StaticString, DiagnosticsValue)]

/// Append-only log writer for `~/Library/Logs/Manifield/`.
///
/// The app is not sandboxed (see the README's security notes), so this needs no entitlement — the
/// user can open the folder in Finder, read the file in Console, or delete it, which is
/// the point: a log the tester cannot inspect is a log they have to take on trust.
///
/// Thread-safe by confinement: every write is funnelled onto one serial queue, so lines
/// never interleave no matter which actor or thread called. Callers are never blocked
/// waiting for the disk.
public final class DiagnosticsLog: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Where the files live. Defaults to `~/Library/Logs/Manifield/`.
        public var directory: URL
        /// Days of history to keep.
        public var retentionDays: Int
        /// Ceiling on everything in the directory together.
        public var maximumTotalBytes: Int
        /// Ceiling on one file, after which the day rolls to a numbered part. Without it a
        /// single runaway day could hold the whole budget and evict every other day.
        public var maximumFileBytes: Int
        /// Lines below this are dropped before they reach the disk.
        public var minimumLevel: DiagnosticsLevel
        /// Whether to mirror to `os.Logger` (and so to Console.app).
        public var mirrorsToSystemLog: Bool
        public var subsystem: String

        public init(directory: URL = Configuration.defaultDirectory,
                    retentionDays: Int = 7,
                    maximumTotalBytes: Int = 10 * 1024 * 1024,
                    maximumFileBytes: Int = 4 * 1024 * 1024,
                    minimumLevel: DiagnosticsLevel = .info,
                    mirrorsToSystemLog: Bool = true,
                    subsystem: String = "com.manifield.app") {
            self.directory = directory
            self.retentionDays = retentionDays
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumFileBytes = maximumFileBytes
            self.minimumLevel = minimumLevel
            self.mirrorsToSystemLog = mirrorsToSystemLog
            self.subsystem = subsystem
        }

        public static var defaultDirectory: URL {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return library.appendingPathComponent("Logs/Manifield", isDirectory: true)
        }
    }

    public static let shared = DiagnosticsLog()

    public let configuration: Configuration
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date

    /// Guarded by `queue`.
    private var handle: FileHandle?
    private var openFileURL: URL?
    private var openFileBytes: Int = 0
    private var loggers: [String: Logger] = [:]

    public init(configuration: Configuration = Configuration(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
        self.queue = DispatchQueue(label: "com.manifield.diagnostics.log")
    }

    deinit { try? handle?.close() }

    public var directoryURL: URL { configuration.directory }

    // MARK: - Writing

    public func debug(_ event: StaticString, category: DiagnosticsCategory, _ fields: DiagnosticsFields = []) {
        log(.debug, event, category: category, fields)
    }

    public func info(_ event: StaticString, category: DiagnosticsCategory, _ fields: DiagnosticsFields = []) {
        log(.info, event, category: category, fields)
    }

    public func notice(_ event: StaticString, category: DiagnosticsCategory, _ fields: DiagnosticsFields = []) {
        log(.notice, event, category: category, fields)
    }

    public func error(_ event: StaticString, category: DiagnosticsCategory, _ fields: DiagnosticsFields = []) {
        log(.error, event, category: category, fields)
    }

    /// The common shape of a failure line: whatever the call site knows, plus the error.
    public func failure(_ event: StaticString, category: DiagnosticsCategory,
                        error: Error, _ fields: DiagnosticsFields = []) {
        log(.error, event, category: category, fields + [("error", .errorDescription(error.localizedDescription))])
    }

    public func log(_ level: DiagnosticsLevel, _ event: StaticString,
                    category: DiagnosticsCategory, _ fields: DiagnosticsFields = []) {
        guard level >= configuration.minimumLevel else { return }
        let timestamp = now()
        // Rendering (and therefore redacting) happens here, on the caller's thread, so the
        // unredacted value never outlives the call — nothing sensitive is captured into a
        // closure that sits on a queue.
        let rendered = Self.render(level: level, timestamp: timestamp, event: event,
                                   category: category, fields: fields)
        queue.async { [weak self] in
            self?.append(rendered, level: level, category: category, at: timestamp)
        }
    }

    /// Blocks until everything queued so far is on disk. For the moments where that
    /// matters: attaching the log to a report, and quitting.
    public func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    static func render(level: DiagnosticsLevel, timestamp: Date, event: StaticString,
                       category: DiagnosticsCategory, fields: DiagnosticsFields) -> String {
        var line = "\(Self.timestampFormatter.string(from: timestamp)) \(level.label) [\(category.name)] \(event)"
        for (key, value) in fields {
            line += " \(key)=\(value.rendered)"
        }
        // Belt and braces: `event` and the keys are literals and the values are rendered
        // through `Redactor`, so there should be nothing left to flatten. If a newline ever
        // does get through, one record must still mean one line.
        return Redactor.singleLine(line)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private func append(_ line: String, level: DiagnosticsLevel,
                        category: DiagnosticsCategory, at timestamp: Date) {
        mirror(line, level: level, category: category)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        prepareFile(for: timestamp, incoming: data.count)
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            openFileBytes += data.count
        } catch {
            // A log that throws is worse than a log that misses a line. Drop the handle so
            // the next write reopens; there is nowhere useful to report this to.
            try? handle.close()
            self.handle = nil
            openFileURL = nil
        }
    }

    private func mirror(_ line: String, level: DiagnosticsLevel, category: DiagnosticsCategory) {
        guard configuration.mirrorsToSystemLog else { return }
        let logger = loggers[category.name] ?? {
            let new = Logger(subsystem: configuration.subsystem, category: category.name)
            loggers[category.name] = new
            return new
        }()
        // `.public`: the line has already been through `Redactor`, and a log that renders
        // as `<private>` in Console is no help to anyone diagnosing a tester's machine.
        switch level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }

    // MARK: - Files and rotation

    static func fileName(for day: String, part: Int) -> String {
        part <= 1 ? "manifield-\(day).log" : "manifield-\(day).\(part).log"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Makes sure `handle` points at the file this line belongs in, rolling the day over
    /// and the part number up as needed. Called on `queue`.
    private func prepareFile(for timestamp: Date, incoming: Int) {
        let day = Self.dayFormatter.string(from: timestamp)
        let expectedPrefix = "manifield-\(day)"
        let needsNewDay = openFileURL.map { !$0.lastPathComponent.hasPrefix(expectedPrefix) } ?? true
        let needsNewPart = openFileBytes + incoming > configuration.maximumFileBytes

        if handle != nil && !needsNewDay && !needsNewPart { return }

        try? handle?.close()
        handle = nil

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: configuration.directory, withIntermediateDirectories: true)

        var part = 1
        var url = configuration.directory.appendingPathComponent(Self.fileName(for: day, part: part))
        // Pick up where a previous launch left off on the same day, and step past any part
        // that is already full.
        while fileSize(of: url) + incoming > configuration.maximumFileBytes {
            part += 1
            url = configuration.directory.appendingPathComponent(Self.fileName(for: day, part: part))
        }

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        // Append-only: seek to the end rather than truncating, so a crash mid-session and
        // a second window never cost anyone the earlier half of the day.
        let end = (try? opened.seekToEnd()) ?? 0
        handle = opened
        openFileURL = url
        openFileBytes = Int(end)

        pruneOldFiles(currentDay: day, keeping: url)
    }

    private func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    /// Enforces both caps: seven days of history, and a ceiling on the directory as a
    /// whole. Old days go first; if that is not enough, the oldest surviving files go too,
    /// never the one being written.
    private func pruneOldFiles(currentDay: String, keeping current: URL) {
        let fileManager = FileManager.default
        let logs = Self.orderedNames(in: configuration.directory)

        // Retention is counted in whole UTC days from today, not in elapsed hours: the
        // files are named by day, and "keep 7 days" is a statement about those names.
        let cutoff = Calendar.current.date(byAdding: .day, value: -configuration.retentionDays,
                                           to: Self.dayFormatter.date(from: currentDay) ?? now())
        var survivors: [String] = []
        for name in logs {
            let url = configuration.directory.appendingPathComponent(name)
            if url == current { survivors.append(name); continue }
            if let cutoff, let day = Self.day(from: name), day < cutoff {
                try? fileManager.removeItem(at: url)
            } else {
                survivors.append(name)
            }
        }

        var total = survivors.reduce(0) { $0 + fileSize(of: configuration.directory.appendingPathComponent($1)) }
        for name in survivors where total > configuration.maximumTotalBytes {
            let url = configuration.directory.appendingPathComponent(name)
            guard url != current else { continue }
            let size = fileSize(of: url)
            try? fileManager.removeItem(at: url)
            total -= size
        }
    }

    /// The day a log file name encodes, or nil if it is not one of ours.
    static func day(from fileName: String) -> Date? {
        guard let key = sortKey(for: fileName) else { return nil }
        return dayFormatter.date(from: key.day)
    }

    /// Chronological order for a file name, or nil if it is not one of ours.
    ///
    /// The part number has to be compared as a number: sorted as text,
    /// `manifield-2026-09-18.10.log` lands *before* `…2.log`, which would have the tail
    /// read the wrong file and the size cap evict the wrong one.
    static func sortKey(for fileName: String) -> (day: String, part: Int)? {
        guard fileName.hasPrefix("manifield-"), fileName.hasSuffix(".log") else { return nil }
        let stem = fileName.dropFirst("manifield-".count).dropLast(".log".count)
        let day = String(stem.prefix(10))
        guard day.count == 10 else { return nil }
        let rest = stem.dropFirst(10)
        if rest.isEmpty { return (day, 1) }
        guard rest.hasPrefix("."), let part = Int(rest.dropFirst()) else { return nil }
        return (day, part)
    }

    /// Every log file in the directory, oldest first.
    static func orderedNames(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name in sortKey(for: name).map { (name: name, key: $0) } }
            .sorted { ($0.key.day, $0.key.part) < ($1.key.day, $1.key.part) }
            .map(\.name)
    }

    // MARK: - Reading

    /// Every log file, oldest first.
    public func files() -> [URL] {
        Self.orderedNames(in: configuration.directory)
            .map { configuration.directory.appendingPathComponent($0) }
    }

    /// The file currently being written, for "Reveal in Finder".
    public func currentFileURL() -> URL {
        let day = Self.dayFormatter.string(from: now())
        return files().last(where: { $0.lastPathComponent.hasPrefix("manifield-\(day)") })
            ?? configuration.directory.appendingPathComponent(Self.fileName(for: day, part: 1))
    }

    /// The end of the log, at most `maximumBytes` of it, newest files last.
    ///
    /// Cut on a line boundary: a report that opens mid-line reads like corruption, and the
    /// first thing anyone does with a tail is look at where it starts.
    public func tail(maximumBytes: Int = DiagnosticsLog.defaultTailBytes) -> String {
        flush()
        var chunks: [String] = []
        var remaining = maximumBytes
        for url in files().reversed() {
            guard remaining > 0 else { break }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let slice = data.count > remaining ? data.suffix(remaining) : data
            guard var text = String(data: Data(slice), encoding: .utf8)
                    ?? String(data: Data(slice), encoding: .isoLatin1) else { continue }
            if slice.count < data.count, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            remaining -= slice.count
            chunks.append(text)
        }
        return chunks.reversed().joined()
    }

    /// ~200 KB: enough to hold a long session, small enough that a report still travels as
    /// one ordinary HTTP request.
    public static let defaultTailBytes = 200 * 1024
}
