import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Full-text search over theory items, backed by SQLite FTS5.
/// The index is derived state — it can always be rebuilt from the `theory/` folder.
public final class SearchIndex: @unchecked Sendable {

    public struct Hit: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let snippet: String
    }

    public struct FulltextHit: Equatable, Sendable {
        public let segment: Int
        public let title: String
        public let snippet: String
    }

    /// A hit inside one of the project's stored documents (`documents/<slug>/fulltext.md`).
    public struct DocumentHit: Equatable, Sendable {
        public let document: String
        public let segment: Int
        public let title: String
        public let snippet: String
    }

    /// One searchable body of text. Language is a property of the corpus, not of the
    /// project: a Polish paper can sit next to an English one, and each has to be queried
    /// in its own words.
    public enum Corpus: Hashable, Sendable {
        case items
        case fulltext
        case document(String)
    }

    /// One index is shared by the UI, director, and concurrently running assignments.
    /// SQLite may serialize connection access, but the adjacent Swift cache does not;
    /// keep the whole index operation atomic so a rebuild cannot interleave with a search.
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    /// Detection is cheap but not free, and every search asks; the entry is dropped
    /// whenever the corpus behind it is rewritten.
    private var languageCache: [Corpus: LanguageDetection.Language?] = [:]

    public convenience init(at url: URL) throws {
        try self.init(path: url.path)
    }

    /// In-memory index (used by tests and as a fallback when the on-disk one is corrupt).
    /// The path is passed to SQLite verbatim: routed through `URL(fileURLWithPath:)` it
    /// resolved against the working directory and every "in-memory" index in the process
    /// ended up sharing one file literally named `:memory:` — including two projects'
    /// worth of items in a single table.
    public convenience init() throws {
        try self.init(path: ":memory:")
    }

    private init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw CoreError.sqlite(lastMessage())
        }
        try executeSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS items USING fts5(
                id UNINDEXED, name, type, tags, body, tokenize='unicode61'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS fulltext USING fts5(
                segment UNINDEXED, title, body, tokenize='unicode61'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
                doc UNINDEXED, segment UNINDEXED, title, body, tokenize='unicode61'
            );
            """)
    }

    deinit { sqlite3_close(db) }

    public func rebuild(items: [TheoryItem]) throws {
        try synchronized {
            invalidateLanguage(of: .items)
            try executeSQL("DELETE FROM items;")
            for item in items { try insert(item) }
        }
    }

    public func upsert(_ item: TheoryItem) throws {
        try synchronized {
            try remove(id: item.id)
            try insert(item)
        }
    }

    public func remove(id: String) throws {
        try synchronized {
            invalidateLanguage(of: .items)
            let sql = "DELETE FROM items WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CoreError.sqlite(lastMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(lastMessage()) }
        }
    }

    public func search(_ query: String, limit: Int = 12) throws -> [Hit] {
        try synchronized {
            let match = Self.ftsQuery(from: query)
            guard !match.isEmpty else { return [] }
            // `id` breaks ties, and it has to: `upsert` is a delete + insert, so an edited item
            // gets the table's highest rowid — and FTS5 orders equal ranks by rowid. Without a
            // stable tiebreak, saving an item (even a change to a field that isn't indexed at
            // all, like status) sent it to the very back of every tied result set and out of
            // the LIMIT window, so it vanished from the list you were looking at.
            let sql = """
                SELECT id, name, snippet(items, 4, '[', ']', ' … ', 14)
                FROM items WHERE items MATCH ? ORDER BY rank, id LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CoreError.sqlite(lastMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(Hit(
                    id: column(stmt, 0),
                    name: column(stmt, 1),
                    snippet: column(stmt, 2)
                ))
            }
            return hits
        }
    }

    // MARK: - Corpus language

    /// The language one indexed corpus is written in — nil when it holds too little prose
    /// to tell. FTS matching is literal, so this is the language a query has to be in:
    /// search surfaces pass it on to the agent rather than letting an English query come
    /// back empty from a Polish text.
    public func language(of corpus: Corpus) -> LanguageDetection.Language? {
        synchronized {
            if let cached = languageCache[corpus] { return cached }
            let detected = LanguageDetection.detect(sampleText(of: corpus))
            languageCache[corpus] = detected
            return detected
        }
    }

    private func invalidateLanguage(of corpus: Corpus) {
        languageCache.removeValue(forKey: corpus)
    }

    /// A handful of rows, skipping the first quarter of a paginated corpus: title pages,
    /// abstracts and copyright notices are routinely in a different language than the
    /// body they precede.
    private func sampleText(of corpus: Corpus) -> [String] {
        switch corpus {
        case .items:
            return sampleRows(
                sql: "SELECT substr(name || '. ' || body, 1, 2000) FROM items LIMIT 30;")
        case .fulltext:
            let offset = rowCount(sql: "SELECT count(*) FROM fulltext;") / 4
            return sampleRows(
                sql: "SELECT substr(body, 1, 3000) FROM fulltext LIMIT 8 OFFSET \(offset);")
        case .document(let slug):
            let offset = rowCount(sql: "SELECT count(*) FROM documents WHERE doc = ?;",
                                  bind: slug) / 4
            return sampleRows(
                sql: "SELECT substr(body, 1, 3000) FROM documents WHERE doc = ? LIMIT 8 OFFSET \(offset);",
                bind: slug)
        }
    }

    private func sampleRows(sql: String, bind: String? = nil) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let bind { sqlite3_bind_text(stmt, 1, bind, -1, SQLITE_TRANSIENT) }
        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(column(stmt, 0)) }
        return rows
    }

    private func rowCount(sql: String, bind: String? = nil) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let bind { sqlite3_bind_text(stmt, 1, bind, -1, SQLITE_TRANSIENT) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Full text (segments of fulltext.md)

    public func rebuildFulltext(segments: [FullTextDocument.Segment]) throws {
        try synchronized {
            invalidateLanguage(of: .fulltext)
            try executeSQL("DELETE FROM fulltext;")
            let sql = "INSERT INTO fulltext (segment, title, body) VALUES (?, ?, ?);"
            for segment in segments {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw CoreError.sqlite(lastMessage())
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int(stmt, 1, Int32(segment.index))
                sqlite3_bind_text(stmt, 2, segment.title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, segment.text, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(lastMessage()) }
            }
        }
    }

    public func searchFulltext(_ query: String, limit: Int = 8) throws -> [FulltextHit] {
        try synchronized {
            let match = Self.ftsQuery(from: query)
            guard !match.isEmpty else { return [] }
            let sql = """
                SELECT segment, title, snippet(fulltext, 2, '[', ']', ' … ', 18)
                FROM fulltext WHERE fulltext MATCH ? ORDER BY rank LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CoreError.sqlite(lastMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var hits: [FulltextHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(FulltextHit(
                    segment: Int(sqlite3_column_int(stmt, 0)),
                    title: column(stmt, 1),
                    snippet: column(stmt, 2)
                ))
            }
            return hits
        }
    }

    /// How many segments are indexed — 0 means the (derived) index needs a rebuild
    /// from fulltext.md.
    public func fulltextSegmentCount() -> Int {
        synchronized {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM fulltext;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: - Project documents (segments of documents/<slug>/fulltext.md)

    /// Replaces one document's segments. Documents are indexed side by side in a single
    /// table (namespaced by slug) so one query can search every file in the project.
    public func replaceDocument(slug: String, segments: [FullTextDocument.Segment]) throws {
        try synchronized {
            try removeDocument(slug: slug)
            let sql = "INSERT INTO documents (doc, segment, title, body) VALUES (?, ?, ?, ?);"
            for segment in segments {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw CoreError.sqlite(lastMessage())
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, slug, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(segment.index))
                sqlite3_bind_text(stmt, 3, segment.title, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, segment.text, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(lastMessage()) }
            }
        }
    }

    public func removeDocument(slug: String) throws {
        try synchronized {
            invalidateLanguage(of: .document(slug))
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM documents WHERE doc = ?;", -1, &stmt, nil) == SQLITE_OK else {
                throw CoreError.sqlite(lastMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, slug, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(lastMessage()) }
        }
    }

    /// Drops rows of documents that no longer exist on disk (deleted outside the app).
    public func pruneDocuments(keeping slugs: Set<String>) throws {
        try synchronized {
            for slug in indexedDocumentSlugs() where !slugs.contains(slug) {
                try removeDocument(slug: slug)
            }
        }
    }

    /// `document` restricts the search to one file; nil searches all of them.
    public func searchDocuments(_ query: String, document: String? = nil,
                                limit: Int = 8) throws -> [DocumentHit] {
        try synchronized {
            let match = Self.ftsQuery(from: query)
            guard !match.isEmpty else { return [] }
            let sql = """
                SELECT doc, segment, title, snippet(documents, 3, '[', ']', ' … ', 18)
                FROM documents WHERE documents MATCH ?\(document == nil ? "" : " AND doc = ?")
                ORDER BY rank LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CoreError.sqlite(lastMessage())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
            if let document {
                sqlite3_bind_text(stmt, 2, document, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(limit))
            } else {
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }

            var hits: [DocumentHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(DocumentHit(
                    document: column(stmt, 0),
                    segment: Int(sqlite3_column_int(stmt, 1)),
                    title: column(stmt, 2),
                    snippet: column(stmt, 3)
                ))
            }
            return hits
        }
    }

    /// Indexed segment count for one document — compared against its fulltext.md header
    /// to detect an index that needs rebuilding (a fresh clone, or an edited file).
    public func documentSegmentCount(document: String) -> Int {
        synchronized {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM documents WHERE doc = ?;",
                                     -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, document, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func indexedDocumentSlugs() -> [String] {
        synchronized {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT doc FROM documents;", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            var slugs: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { slugs.append(column(stmt, 0)) }
            return slugs
        }
    }

    /// Converts free text into a safe FTS5 MATCH expression: each token quoted, prefix-matched, ANDed.
    /// This prevents user/agent input from being parsed as FTS5 syntax.
    static func ftsQuery(from raw: String) -> String {
        let tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: - Internals

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func insert(_ item: TheoryItem) throws {
        let sql = "INSERT INTO items (id, name, type, tags, body) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CoreError.sqlite(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, item.type.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, item.tags.joined(separator: " "), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, item.body, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CoreError.sqlite(lastMessage()) }
    }

    private func executeSQL(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CoreError.sqlite(message)
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func lastMessage() -> String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}
