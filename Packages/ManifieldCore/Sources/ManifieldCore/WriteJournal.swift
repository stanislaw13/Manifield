import Foundation

/// One agent write to the library, with enough state to show a diff and to undo it.
///
/// Records are grouped by `turnID` — every write an agent makes while answering a single
/// message shares one turn — because that is the unit the user thinks in ("undo what it
/// just did") and the unit the change summary presents.
public struct TheoryWrite: Codable, Identifiable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case create
        case update
    }

    public let id: UUID
    public let turnID: UUID
    public let itemID: String
    public let itemName: String
    public let itemType: ItemType
    public let action: Action
    /// Complete item file before the write; nil for a create. This is what a revert restores.
    public let before: String?
    /// Complete item file after the write.
    public let after: String
    public let at: Date

    public init(
        id: UUID = UUID(),
        turnID: UUID,
        itemID: String,
        itemName: String,
        itemType: ItemType,
        action: Action,
        before: String?,
        after: String,
        at: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.itemID = itemID
        self.itemName = itemName
        self.itemType = itemType
        self.action = action
        self.before = before
        self.after = after
        self.at = at
    }
}

/// The project's rolling record of agent writes. Capped, because it is a safety net and a
/// summary source rather than an archive — the item files themselves are the history.
public struct WriteJournal: Codable, Sendable {
    public static let maxWrites = 400

    public private(set) var writes: [TheoryWrite]

    public init(writes: [TheoryWrite] = []) {
        self.writes = writes
    }

    public mutating func record(_ write: TheoryWrite) {
        writes.append(write)
        if writes.count > Self.maxWrites {
            writes.removeFirst(writes.count - Self.maxWrites)
        }
    }

    /// Writes from one turn, oldest first.
    public func writes(inTurn turnID: UUID) -> [TheoryWrite] {
        writes.filter { $0.turnID == turnID }
    }

    /// Turn ids newest-first, each with its writes in the order they were made.
    public var turns: [(turnID: UUID, writes: [TheoryWrite])] {
        var order: [UUID] = []
        var grouped: [UUID: [TheoryWrite]] = [:]
        for write in writes {
            if grouped[write.turnID] == nil { order.append(write.turnID) }
            grouped[write.turnID, default: []].append(write)
        }
        return order.reversed().map { ($0, grouped[$0] ?? []) }
    }

    /// Drops a turn's records once it has been reverted, so the journal never offers to
    /// undo the same turn twice.
    public mutating func forget(turnID: UUID) {
        writes.removeAll { $0.turnID == turnID }
    }

    /// The steps that undo a turn, in the order they must be applied: newest write first,
    /// so an item written twice in one turn lands back on its oldest recorded state.
    public func revertPlan(turnID: UUID) -> [RevertStep] {
        writes(inTurn: turnID).reversed().map { write in
            if let before = write.before {
                return .restore(itemID: write.itemID, markdown: before)
            }
            return .delete(itemID: write.itemID)
        }
    }

    public enum RevertStep: Equatable, Sendable {
        case restore(itemID: String, markdown: String)
        case delete(itemID: String)
    }
}

extension WriteJournal {
    /// One-line summaries of a turn's writes, grouped the way the change summary reads them:
    /// "Created 3 definitions and 5 theorems", "Edited 2 theory items".
    public static func summary(for writes: [TheoryWrite]) -> String {
        let created = writes.filter { $0.action == .create }
        let updated = writes.filter { $0.action == .update }
        var parts: [String] = []
        if !created.isEmpty { parts.append("Created \(phrase(created))") }
        if !updated.isEmpty { parts.append("Edited \(phrase(updated))") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }

    /// What reverting a turn will do to the folder, spelled out — it deletes files, and
    /// "Revert" on its own does not say so. Reads as the object of a sentence:
    /// "This will <phrase>."
    ///
    /// Counted by item rather than by write: two writes to one item are still one file
    /// to put back, and `revertPlan` walks them newest-first to land on its pre-turn state.
    public static func revertPhrase(for writes: [TheoryWrite]) -> String {
        let (created, updated) = revertCounts(for: writes)
        var parts: [String] = []
        if created > 0 { parts.append("delete \(created) new item\(created == 1 ? "" : "s")") }
        if updated > 0 {
            parts.append(updated == 1
                         ? "restore 1 item to its previous contents"
                         : "restore \(updated) items to their previous contents")
        }
        return parts.isEmpty ? "undo this turn's writes" : parts.joined(separator: " and ")
    }

    /// The note left in the transcript in place of a card once its turn has been undone.
    public static func revertedLabel(for writes: [TheoryWrite]) -> String {
        let (created, updated) = revertCounts(for: writes)
        var parts: [String] = []
        if created > 0 { parts.append("\(created) deleted") }
        if updated > 0 { parts.append("\(updated) restored") }
        return parts.isEmpty ? "Reverted" : "Reverted — " + parts.joined(separator: ", ")
    }

    /// Items the turn brought into existence, and items it only edited. An item created
    /// and then edited in the same turn is counted as created: reverting deletes it.
    private static func revertCounts(for writes: [TheoryWrite]) -> (created: Int, updated: Int) {
        let created = Set(writes.filter { $0.action == .create }.map(\.itemID))
        let updated = Set(writes.filter { $0.action == .update }.map(\.itemID))
            .subtracting(created)
        return (created.count, updated.count)
    }

    /// "3 definitions and 5 theorems" when the types are few, "8 theory items" when they
    /// are many — a breakdown stops being readable past a couple of kinds.
    private static func phrase(_ writes: [TheoryWrite]) -> String {
        let counts = Dictionary(grouping: writes, by: \.itemType)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.type.rawValue < $1.type.rawValue }
        guard counts.count <= 2 else {
            return "\(writes.count) theory item\(writes.count == 1 ? "" : "s")"
        }
        let phrases = counts.map { entry -> String in
            let name = entry.type.displayName.lowercased()
            return "\(entry.count) \(name)\(entry.count == 1 ? "" : "s")"
        }
        return phrases.joined(separator: " and ")
    }
}
