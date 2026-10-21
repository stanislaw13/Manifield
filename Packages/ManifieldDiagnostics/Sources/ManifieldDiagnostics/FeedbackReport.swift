import Foundation

/// What the tester is telling us. Drives nothing but routing and the default for whether
/// the log is attached — a bug wants the log, an idea rarely does.
public enum FeedbackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bug
    case idea
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bug: return "Bug"
        case .idea: return "Idea"
        case .other: return "Other"
        }
    }

    /// The log goes with a bug by default and nothing else. A bug report without the log is
    /// usually unactionable; an idea with 200 KB of log attached is noise the tester did not
    /// mean to send.
    public var attachesLogByDefault: Bool { self == .bug }
}

/// One report, exactly as it travels.
public struct FeedbackReport: Equatable, Sendable {

    /// The shape of the JSON below.
    ///
    /// Stamped into every payload because it cannot be added afterwards: a build handed to
    /// a tester in the alpha keeps sending the shape it was compiled with for as long as
    /// that copy exists, whatever the server later becomes. Without the version the server
    /// has to guess which format it is parsing; with it, an old build stays parseable
    /// forever. Bump it when a field changes meaning, not when one is added.
    public static let schemaVersion = 1

    public var kind: FeedbackKind
    public var message: String
    /// Optional, and only ever what the tester typed into the email field themselves. The
    /// app never fills this in from the Codex account or anywhere else.
    public var email: String?
    /// Absent when the tester turned "Include diagnostics" off. Optional on purpose: the
    /// consent rule says nothing leaves the machine that the tester did not agree to send,
    /// and a field that cannot be omitted is not something anyone can decline.
    public var snapshot: DiagnosticsSnapshot?
    public var logTail: String?
    public var crashLog: String?
    /// A short handle for this report, so a maintainer and a tester can refer to the same
    /// one. Not a UUID: the log's own redaction treats long opaque runs as possible keys.
    public var id: String
    public var createdAt: Date

    public init(kind: FeedbackKind,
                message: String,
                email: String? = nil,
                snapshot: DiagnosticsSnapshot? = nil,
                logTail: String? = nil,
                crashLog: String? = nil,
                id: String = FeedbackReport.newID(),
                createdAt: Date = Date()) {
        self.kind = kind
        self.message = message
        self.email = email
        self.snapshot = snapshot
        self.logTail = logTail
        self.crashLog = crashLog
        self.id = id
        self.createdAt = createdAt.truncatedToSecond
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    public var isSendable: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - JSON

    /// Hand-written rather than synthesised, for one reason: `schemaVersion` is a property
    /// of the payload, not of the value, and it must be encoded unconditionally and read
    /// back leniently. Synthesis gets one of those two wrong whichever way it is declared.
    public func jsonData() throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "id": id,
            "kind": kind.rawValue,
            "message": message,
            "createdAt": ISO8601DateFormatter().string(from: createdAt)
        ]
        if let email, !email.isEmpty { object["email"] = email }
        if let snapshot {
            object["snapshot"] = try JSONSerialization.jsonObject(with: snapshot.jsonData())
        }
        if let logTail, !logTail.isEmpty { object["logTail"] = logTail }
        if let crashLog, !crashLog.isEmpty { object["crashLog"] = crashLog }
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The payload as the tester sees it in the consent disclosure and as the file fallback
    /// writes it — the same bytes either way, so what they reviewed is what they sent.
    public func jsonString() throws -> String {
        String(data: try jsonData(), encoding: .utf8) ?? ""
    }

    public static func decode(from data: Data) throws -> FeedbackReport {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeedbackError.malformedReport
        }
        let snapshot: DiagnosticsSnapshot?
        if let raw = object["snapshot"] {
            snapshot = try DiagnosticsSnapshot.decoder()
                .decode(DiagnosticsSnapshot.self, from: JSONSerialization.data(withJSONObject: raw))
        } else {
            snapshot = nil
        }
        return FeedbackReport(
            kind: FeedbackKind(rawValue: object["kind"] as? String ?? "") ?? .other,
            message: object["message"] as? String ?? "",
            email: object["email"] as? String,
            snapshot: snapshot,
            logTail: object["logTail"] as? String,
            crashLog: object["crashLog"] as? String,
            id: object["id"] as? String ?? newID(),
            createdAt: (object["createdAt"] as? String)
                .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date())
    }

    /// The version stamped on a payload, without decoding the rest of it.
    public static func schemaVersion(of data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["schemaVersion"] as? Int
    }

    /// A filename that sorts by when it was written and says what it is.
    public var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "manifield-\(kind.rawValue)-\(formatter.string(from: createdAt))-\(id).json"
    }
}
