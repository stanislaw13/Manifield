import Foundation
import CryptoKit
import ManifieldCore

/// Durable state of a chunked source import, persisted inside the source folder as
/// `sessions/import-run.json` after every chunk event (the RunRecord write-through
/// pattern). A quit or crashed app resumes the import from this record instead of
/// losing the run; a finished record with failed chunks drives the retry offer.
///
/// Chunk texts are NOT stored — the original document plus the deterministic chunker
/// re-derive them on resume, and `fingerprint` guards against either having changed.
public struct SourceImportRecord: Codable, Sendable {

    public enum Phase: String, Codable, Sendable {
        /// A record found in this state at launch means the app died mid-import —
        /// treat it as paused.
        case running
        case paused
        case finished
        case failed
    }

    public enum ChunkStatus: String, Codable, Sendable {
        case pending
        case done
        case failed
    }

    /// Only terminal transitions are persisted (pending → done/failed) — an in-flight
    /// chunk stays `pending`, so pausing never needs to unwind anything.
    public struct ChunkState: Codable, Sendable {
        public var index: Int
        public var title: String
        public var section: String
        public var status: ChunkStatus
        public var itemIDs: [String]
        public var note: String?
        public var warnings: [String]
        public var failureMessage: String?
        /// Project import with the review gate: nothing is saved to the store until
        /// the user confirms, so the proposed items live in the record — a quit app
        /// reopens straight into the review.
        public var proposedItems: [TheoryItem]?

        public init(index: Int, title: String, section: String) {
            self.index = index
            self.title = title
            self.section = section
            self.status = .pending
            self.itemIDs = []
            self.warnings = []
        }
    }

    public struct RequestSnapshot: Codable, Sendable {
        public var name: String
        public var authors: String
        public var citation: String
        public var license: String
        public var originalFileName: String
        public var convertToItems: Bool
        public var instructions: String?
        public var detectSections: Bool?
        public var linkPassRequested: Bool?
        /// Project import only: whether items wait in the review list before saving.
        public var reviewBeforeSaving: Bool?

        public init(name: String, authors: String, citation: String, license: String,
                    originalFileName: String, convertToItems: Bool,
                    instructions: String? = nil, detectSections: Bool? = nil,
                    linkPassRequested: Bool? = nil, reviewBeforeSaving: Bool? = nil) {
            self.name = name
            self.authors = authors
            self.citation = citation
            self.license = license
            self.originalFileName = originalFileName
            self.convertToItems = convertToItems
            self.instructions = instructions
            self.detectSections = detectSections
            self.linkPassRequested = linkPassRequested
            self.reviewBeforeSaving = reviewBeforeSaving
        }
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        /// Chunker identity + parameters; bump when the algorithm changes.
        public var chunker: String
        public var chunkCount: Int
        public var chunkTextSHA256: String

        public init(chunker: String, chunkCount: Int, chunkTextSHA256: String) {
            self.chunker = chunker
            self.chunkCount = chunkCount
            self.chunkTextSHA256 = chunkTextSHA256
        }

        public static func hash(of chunks: [SourceImport.Chunk]) -> String {
            var hasher = SHA256()
            for chunk in chunks {
                hasher.update(data: Data(chunk.text.utf8))
                hasher.update(data: Data([0]))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    public var version: Int
    public var phase: Phase
    public var createdAt: Date
    public var updatedAt: Date
    public var request: RequestSnapshot
    public var fingerprint: Fingerprint
    public var chunks: [ChunkState]
    /// Run-level warnings (extraction issues, overview failure) — chunk-level ones
    /// live on their chunk.
    public var warnings: [String]
    public var overviewDone: Bool
    /// Set once the requested deep-link pass has run (optional for old records).
    public var linkPassDone: Bool?

    public init(request: RequestSnapshot, fingerprint: Fingerprint,
                chunks: [SourceImport.Chunk], warnings: [String] = []) {
        self.version = 1
        self.phase = .running
        self.createdAt = Date()
        self.updatedAt = Date()
        self.request = request
        self.fingerprint = fingerprint
        self.chunks = chunks.enumerated().map {
            ChunkState(index: $0.offset, title: $0.element.title, section: $0.element.section)
        }
        self.warnings = warnings
        self.overviewDone = false
    }

    // MARK: Queries

    public var pendingIndices: [Int] { chunks.filter { $0.status == .pending }.map(\.index) }
    public var failedIndices: [Int] { chunks.filter { $0.status == .failed }.map(\.index) }
    public var doneCount: Int { chunks.filter { $0.status == .done }.count }
    /// Ids of every item saved so far, in chunk order — seeds the taken-ids prompt on resume.
    public var allItemIDs: [String] {
        chunks.sorted { $0.index < $1.index }.flatMap(\.itemIDs)
    }
    public var chunkNotes: [(index: Int, title: String, note: String)] {
        chunks.sorted { $0.index < $1.index }
            .compactMap { chunk in chunk.note.map { (chunk.index, chunk.title, $0) } }
    }
    public var isResumable: Bool {
        phase == .running || phase == .paused
    }
    public var hasRetryableFailures: Bool {
        phase == .finished && !failedIndices.isEmpty
    }

    // MARK: Persistence

    /// Source-library imports; project imports use `theorySessionName` in the
    /// project's own sessions folder.
    public static let sessionName = "import-run"
    public static let theorySessionName = "theory-import-run"

    public func save(to store: ProjectStore, named name: String = Self.sessionName) {
        var record = self
        record.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? store.saveSession(named: name, json: data)
        }
    }

    public static func load(from store: ProjectStore, named name: String = sessionName) -> SourceImportRecord? {
        store.loadSession(named: name).flatMap(decode)
    }

    /// Reads a record straight off disk — the discovery scan must not pay the cost of
    /// opening every library source as a full ProjectStore.
    public static func load(atSourceFolder url: URL, named name: String = sessionName) -> SourceImportRecord? {
        let file = url.appendingPathComponent("sessions/\(name).json")
        return (try? Data(contentsOf: file)).flatMap(decode)
    }

    public static func delete(atSourceFolder url: URL, named name: String = sessionName) {
        try? FileManager.default.removeItem(
            at: url.appendingPathComponent("sessions/\(name).json"))
    }

    private static func decode(_ data: Data) -> SourceImportRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SourceImportRecord.self, from: data)
    }
}
