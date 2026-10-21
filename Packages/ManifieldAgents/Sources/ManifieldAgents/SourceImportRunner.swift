import Foundation
import ManifieldCore

/// One event per chunk lifecycle step. Emitted from worker tasks — the receiver is
/// responsible for hopping to its own actor/queue.
public enum SourceImportEvent: Sendable {
    case chunkStarted(index: Int, title: String)
    /// Streamed response size so far (throttled to ~every 500 characters).
    case chunkProgress(index: Int, streamedChars: Int)
    case chunkFinished(index: Int, title: String, items: [TheoryItem], note: String?,
                       warnings: [String], duration: TimeInterval, responseChars: Int)
    /// A failed chunk is a warning, not an abort — the rest of the import continues.
    case chunkFailed(index: Int, title: String, message: String, duration: TimeInterval)
    /// A retryable provider error (rate limit, overload) is being waited out.
    case chunkRetrying(index: Int, title: String, attempt: Int, delay: TimeInterval, reason: String)
}

/// Runs the Organizer over a source's chunks with bounded parallelism. Chunks are
/// independent model calls, so a book that took an hour sequentially imports in a
/// fraction of that — same prompts, same model, same quality per chunk. The one
/// sequential nicety lost is the taken-ids list lagging behind in-flight chunks;
/// id collisions were always resolved after parsing anyway (the store renames).
///
/// Serves both import destinations: the source library (default prompts, items
/// forced to `source` status) and the open project (injected prompt builder,
/// items keep their proposed statuses for review).
public struct SourceImportRunner: Sendable {

    /// How parsed items are normalized before the chunkFinished event.
    public enum ItemPolicy: Sendable {
        /// Literature: statuses forced to `.source`, citation stamped.
        case sourceLibrary
        /// Project import: statuses kept (review decides), no citation stamp.
        case project
    }

    public typealias SystemPromptBuilder =
        @Sendable (_ takenIDs: [String], _ chunk: SourceImport.Chunk) -> String

    public let chunks: [SourceImport.Chunk]
    /// Original indices of the chunks to run; nil = all. Events always carry the
    /// ORIGINAL chunk index, so import records and order stamps stay stable when a
    /// resume or retry runs only a subset.
    public let indices: [Int]?
    public let citation: String?
    /// User's free-text import instructions, threaded into every chunk's prompt.
    public let instructions: String?
    /// Let the model replace synthetic part-N sections with heading-derived slugs.
    public let detectSections: Bool
    public let itemPolicy: ItemPolicy
    /// Overrides the default source-library prompt (used by the project import).
    public let makeSystemPrompt: SystemPromptBuilder?
    public let concurrency: Int
    public let maxTokens: Int
    let runner: AgentRunner
    /// Snapshot of ids already saved — read at each chunk's launch for the
    /// organizer's taken-ids prompt section.
    let currentIDs: @Sendable () async -> [String]
    /// Section slugs assigned so far (same lag caveat as taken ids); only read when
    /// `detectSections` is on.
    let currentSections: @Sendable () async -> [String]
    let onEvent: @Sendable (SourceImportEvent) -> Void

    public init(
        chunks: [SourceImport.Chunk],
        indices: [Int]? = nil,
        citation: String?,
        instructions: String? = nil,
        detectSections: Bool = false,
        itemPolicy: ItemPolicy = .sourceLibrary,
        makeSystemPrompt: SystemPromptBuilder? = nil,
        concurrency: Int,
        maxTokens: Int = 16_384,
        runner: AgentRunner,
        currentIDs: @escaping @Sendable () async -> [String],
        currentSections: @escaping @Sendable () async -> [String] = { [] },
        onEvent: @escaping @Sendable (SourceImportEvent) -> Void
    ) {
        self.chunks = chunks
        self.indices = indices
        self.citation = citation
        self.instructions = instructions
        self.detectSections = detectSections
        self.itemPolicy = itemPolicy
        self.makeSystemPrompt = makeSystemPrompt
        self.concurrency = max(1, concurrency)
        self.maxTokens = maxTokens
        self.runner = runner
        self.currentIDs = currentIDs
        self.currentSections = currentSections
        self.onEvent = onEvent
    }

    /// Returns when every targeted chunk has finished or failed; throws only on cancellation.
    public func run() async throws {
        let targets = indices ?? Array(chunks.indices)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextPosition = 0
            func launchNext() {
                let index = targets[nextPosition]
                nextPosition += 1
                group.addTask { try await process(index: index) }
            }
            for _ in 0..<min(concurrency, targets.count) { launchNext() }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if nextPosition < targets.count { launchNext() }
            }
        }
    }

    private func process(index: Int) async throws {
        let chunk = chunks[index]
        let started = Date()
        onEvent(.chunkStarted(index: index, title: chunk.title))
        do {
            let outcome = try await organize(chunk, index: index, depth: 0)
            let items: [TheoryItem]
            switch itemPolicy {
            case .sourceLibrary:
                items = SourceImport.normalize(
                    outcome.items, chunkSection: chunk.section, citation: citation, chunkIndex: index)
            case .project:
                items = SourceImport.normalizeForProject(
                    outcome.items, chunkSection: chunk.section, chunkIndex: index)
            }
            onEvent(.chunkFinished(
                index: index, title: chunk.title, items: items, note: outcome.note,
                warnings: outcome.warnings,
                duration: Date().timeIntervalSince(started),
                responseChars: outcome.responseChars))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Provider aborts surface as assorted URL errors when the run is torn
            // down — report them as cancellation, not a chunk failure.
            if Task.isCancelled { throw CancellationError() }
            onEvent(.chunkFailed(
                index: index, title: chunk.title,
                message: Self.describe(error, chunk: chunk),
                duration: Date().timeIntervalSince(started)))
        }
    }

    private struct ChunkOutcome {
        var items: [TheoryItem] = []
        var note: String?
        var warnings: [String] = []
        var responseChars = 0
    }

    /// How many times a chunk may be halved when the provider rejects it as too large
    /// for one request. Chunk sizes come from the model's budget, so this only fires on
    /// accounts whose per-minute limit is below their model's context window — but there
    /// it turns a dead chunk into a slightly slower one.
    private static let maxSubdivisions = 2

    private func organize(
        _ chunk: SourceImport.Chunk, index: Int, depth: Int
    ) async throws -> ChunkOutcome {
        let ids = await currentIDs()
        let sections = detectSections ? await currentSections() : []
        let systemPrompt = makeSystemPrompt?(ids, chunk)
            ?? Organizer.sourceSystemPrompt(
                existingIDs: ids,
                chunkSection: chunk.section,
                citation: citation,
                instructions: instructions,
                detectSections: detectSections,
                knownSections: sections,
                startsMidStructure: chunk.startsMidStructure,
                endsMidStructure: chunk.endsMidStructure)
        let config = AgentConfig(
            systemPrompt: SystemPrompt(systemPrompt),
            tools: [],
            maxTokens: maxTokens
        )
        do {
            let result = try await runWithRetries(config: config, chunk: chunk, index: index)
            do {
                let (parsed, note, warnings) = try Organizer.parseSourceChunk(from: result.finalText)
                return ChunkOutcome(items: parsed, note: note, warnings: warnings,
                                    responseChars: result.finalText.count)
            } catch let parseError as AgentError {
                // The model answered, but not in JSON we can read — a formatting slip,
                // not a content problem, and the whole chunk's items are hostage to it.
                // Say what was wrong and let it answer again before falling back to
                // splitting the chunk (which shortens the reply it has to get right).
                onEvent(.chunkRetrying(
                    index: index, title: chunk.title, attempt: 0, delay: 0,
                    reason: "reply was not valid JSON — asking again"))
                let retried = try await runWithRetries(
                    config: config, chunk: chunk, index: index,
                    correction: parseError.localizedDescription)
                let (parsed, note, warnings) = try Organizer.parseSourceChunk(from: retried.finalText)
                return ChunkOutcome(
                    items: parsed, note: note,
                    warnings: warnings + ["The first reply for this chunk was not valid JSON; the retry succeeded."],
                    responseChars: retried.finalText.count)
            }
        } catch let error as AgentError
            where depth < Self.maxSubdivisions
                && (Self.isOversizeRejection(error) || Self.isUnparseable(error)) {
            // Too big for one request: halve it along the same structural boundaries the
            // splitter uses and organize the halves in order. Their items concatenate, so
            // the chunk's document-order stamps stay contiguous.
            let halves = SourceImport.structuredSplit(chunk, max(chunk.text.count / 2, 2_000))
            guard halves.count > 1 else { throw error }
            onEvent(.chunkRetrying(
                index: index, title: chunk.title, attempt: depth + 1, delay: 0,
                reason: Self.isUnparseable(error)
                    ? "reply still unreadable — splitting into \(halves.count)"
                    : "too large for one request — splitting into \(halves.count)"))
            var merged = ChunkOutcome()
            var notes: [String] = []
            for half in halves {
                let outcome = try await organize(half, index: index, depth: depth + 1)
                merged.items += outcome.items
                merged.warnings += outcome.warnings
                merged.responseChars += outcome.responseChars
                if let note = outcome.note { notes.append(note) }
            }
            merged.note = notes.isEmpty ? nil : notes.joined(separator: "\n\n")
            return merged
        }
    }

    /// A provider saying the request itself is too big — as opposed to a rate limit that
    /// clears on its own. Retrying this unchanged always fails the same way.
    static func isOversizeRejection(_ error: AgentError) -> Bool {
        guard case .http(let status, let body) = error else { return false }
        return (status == 429 || status == 400 || status == 413) && isRequestTooLarge(body)
    }

    /// The model answered but the answer would not parse. Splitting the chunk is the last
    /// resort: a shorter chunk means a shorter reply, and a shorter reply is one the model
    /// is far more likely to get through without a formatting slip.
    static func isUnparseable(_ error: AgentError) -> Bool {
        if case .badResponse = error { return true }
        return false
    }

    /// One chunk's model call, retrying the errors that are worth retrying. Rate limits
    /// are the common failure of a parallel import — every chunk is a large request and
    /// several are in flight — and they clear on their own, so waiting beats reporting a
    /// failed chunk the user then has to retry by hand. The status is raised before any
    /// token is streamed, so a retry never duplicates output.
    private func runWithRetries(
        config: AgentConfig, chunk: SourceImport.Chunk, index: Int, correction: String? = nil
    ) async throws -> AgentTurnResult {
        var attempt = 0
        var message = Organizer.userMessage(source: chunk.text)
        if let correction {
            message = Organizer.correctedUserMessage(message, parseError: correction)
        }
        while true {
            let counter = StreamCounter()
            let onEvent = onEvent
            do {
                return try await runner.run(
                    config: config,
                    history: [.user(message)]
                ) { activity in
                    if case .textDelta(let delta) = activity {
                        if let milestone = counter.add(delta.count, notifyEvery: 500) {
                            onEvent(.chunkProgress(index: index, streamedChars: milestone))
                        }
                    }
                }
            } catch let error as AgentError {
                guard attempt < Self.maxRetries,
                      let delay = Self.retryDelay(for: error, attempt: attempt) else { throw error }
                attempt += 1
                onEvent(.chunkRetrying(index: index, title: chunk.title, attempt: attempt,
                                       delay: delay, reason: Self.shortReason(error)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    static let maxRetries = 3

    /// How long to wait before retrying, or nil for an error that retrying cannot fix.
    /// A 429 saying the *request* is too large is the second kind: the chunk exceeds
    /// what the account may send in one call, and it will exceed it again in a minute.
    static func retryDelay(for error: AgentError, attempt: Int) -> TimeInterval? {
        guard case .http(let status, let body) = error else { return nil }
        let backoff: TimeInterval = [5, 15, 40][min(attempt, 2)]
        switch status {
        case 429:
            return isRequestTooLarge(body) ? nil : backoff
        case 500, 502, 503, 504, 529:
            return backoff
        default:
            return nil
        }
    }

    static func isRequestTooLarge(_ body: String) -> Bool {
        let text = body.lowercased()
        return text.contains("request too large") || text.contains("too many tokens")
            || text.contains("maximum context length") || text.contains("context_length_exceeded")
    }

    private static func shortReason(_ error: AgentError) -> String {
        guard case .http(let status, _) = error else { return "provider error" }
        return status == 429 ? "rate limited" : "provider error \(status)"
    }

    /// Chunk failures reach the user as a wall of provider JSON. Where the cause is
    /// known and actionable, say what to do about it.
    static func describe(_ error: Error, chunk: SourceImport.Chunk) -> String {
        guard case AgentError.http(let status, let body) = error else {
            return error.localizedDescription
        }
        if isRequestTooLarge(body), status == 429 || status == 400 || status == 413 {
            return """
            \(error.localizedDescription)

            "\(chunk.title)" (\(chunk.text.count) characters) exceeds what one request may \
            carry on this account, and still did after being split \(Self.maxSubdivisions) \
            times — the account's per-minute token limit is well below the model's context \
            window. Import with a model or tier whose limits are higher.
            """
        }
        return error.localizedDescription
    }
}

/// Character counter shared with a streaming callback; lock-protected because the
/// callback is @Sendable (in practice each chunk streams from a single task).
final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Adds and returns the running total when it crosses a `notifyEvery` boundary,
    /// nil otherwise — callers use it to throttle progress events.
    func add(_ amount: Int, notifyEvery: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let before = value
        value += amount
        return before / notifyEvery != value / notifyEvery ? value : nil
    }
}
