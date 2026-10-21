import Foundation
import ManifieldCore

/// Progress accounting for a chunked source import. Pure value math — the UI layer
/// feeds it runner events and reads fractions, counts, and an ETA.
///
/// A chunk's completion cannot be observed directly (one model call is opaque), so the
/// in-flight fraction is estimated from characters streamed so far against the rolling
/// average response size of completed chunks, and the ETA from average chunk wall time
/// spread over the concurrency level.
public struct ImportProgress: Equatable, Sendable {

    /// Assumed response size before any chunk has finished (chars). Organizer chunk
    /// responses are JSON arrays of items — a few thousand characters in practice.
    public static let defaultResponseChars = 6_000
    /// An in-flight estimate never claims more than this — only completion is 100%.
    public static let inFlightCap = 0.92

    public let totalChunks: Int
    public let concurrency: Int
    public private(set) var completedChunks = 0
    public private(set) var failedChunks = 0
    /// Streamed character counts of chunks currently in flight, by chunk index.
    public private(set) var inFlight: [Int: Int] = [:]
    /// Item tally of everything imported so far, by type.
    public private(set) var itemCounts: [ItemType: Int] = [:]
    private var completedResponseChars: [Int] = []
    private var completedDurations: [TimeInterval] = []

    public init(totalChunks: Int, concurrency: Int) {
        self.totalChunks = max(totalChunks, 1)
        self.concurrency = max(concurrency, 1)
    }

    // MARK: - Event feed

    public mutating func chunkStarted(index: Int) {
        inFlight[index] = 0
    }

    public mutating func chunkProgress(index: Int, streamedChars: Int) {
        inFlight[index] = streamedChars
    }

    public mutating func chunkFinished(
        index: Int, items: [TheoryItem], duration: TimeInterval, responseChars: Int
    ) {
        inFlight[index] = nil
        completedChunks += 1
        completedDurations.append(max(duration, 0.1))
        completedResponseChars.append(max(responseChars, 1))
        for item in items {
            itemCounts[item.type, default: 0] += 1
        }
    }

    public mutating func chunkFailed(index: Int, duration: TimeInterval) {
        inFlight[index] = nil
        completedChunks += 1
        failedChunks += 1
        completedDurations.append(max(duration, 0.1))
    }

    // MARK: - Readouts

    public var itemsTotal: Int { itemCounts.values.reduce(0, +) }

    /// Expected response size for a running chunk, from the rolling average.
    var expectedResponseChars: Double {
        guard !completedResponseChars.isEmpty else { return Double(Self.defaultResponseChars) }
        return Double(completedResponseChars.reduce(0, +)) / Double(completedResponseChars.count)
    }

    /// Estimated completion of one in-flight chunk (0...inFlightCap).
    public func fraction(ofInFlight index: Int) -> Double {
        guard let streamed = inFlight[index] else { return 0 }
        return min(Double(streamed) / max(expectedResponseChars, 1), Self.inFlightCap)
    }

    /// Whole-import fraction (0...1): completed chunks plus in-flight estimates.
    public var overallFraction: Double {
        let running = inFlight.keys.reduce(0.0) { $0 + fraction(ofInFlight: $1) }
        return min((Double(completedChunks) + running) / Double(totalChunks), 1)
    }

    /// Seconds until done, estimated once at least one chunk has finished: average
    /// chunk wall time × outstanding work ÷ effective parallelism.
    public var etaSeconds: TimeInterval? {
        guard !completedDurations.isEmpty, completedChunks < totalChunks else { return nil }
        let average = completedDurations.reduce(0, +) / Double(completedDurations.count)
        let running = inFlight.keys.reduce(0.0) { $0 + fraction(ofInFlight: $1) }
        let outstanding = Double(totalChunks - completedChunks) - running
        let workers = Double(min(concurrency, max(totalChunks - completedChunks, 1)))
        return max(average * outstanding / workers, 0)
    }

    /// "3 min" / "40 s" — coarse on purpose; this is an estimate, not a countdown.
    public static func formatETA(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(max(Int(seconds.rounded()), 5)) s"
                     : "\(Int((seconds / 60).rounded())) min"
    }

    /// "4 definitions · 2 theorems · 1 lemma" in canonical type order.
    public var itemCountSummary: String {
        let parts = ItemType.allCases.compactMap { type -> String? in
            guard let count = itemCounts[type], count > 0 else { return nil }
            let name = type.displayName.lowercased()
            return "\(count) \(count == 1 ? name : name + "s")"
        }
        return parts.joined(separator: " · ")
    }
}
