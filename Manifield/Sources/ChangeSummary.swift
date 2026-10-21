import Foundation
import ManifieldCore

/// Builds what the chat web view renders as a turn's change summary: the collapsed
/// headline, one row per write, and each row's block-level diff.
///
/// Everything is computed up front rather than fetched when a row is expanded. An item
/// file is a few kilobytes and a turn touches a handful of them, so a bridge round-trip
/// per expansion would cost more than it saves — and the journal is already in memory.
enum ChangeSummary {

    /// `writes` must be one turn's records, oldest first (`WriteJournal.writes(inTurn:)`).
    static func payload(turnID: UUID, writes: [TheoryWrite]) -> [String: Any] {
        // A turn may write the same item twice; those rows are numbered so the second
        // reads as a further step rather than as a duplicate row.
        var total: [String: Int] = [:]
        for write in writes { total[write.itemID, default: 0] += 1 }
        var seen: [String: Int] = [:]

        let rows: [[String: Any]] = writes.map { write in
            seen[write.itemID, default: 0] += 1
            let count = total[write.itemID] ?? 1
            return [
                "writeID": write.id.uuidString,
                "itemID": write.itemID,
                "name": write.itemName,
                "type": write.itemType.displayName,
                "action": write.action.rawValue,
                "step": count > 1 ? "\(seen[write.itemID] ?? 1) of \(count)" : "",
                "blocks": blocks(before: write.before, after: write.after)
            ]
        }

        return [
            "turnID": turnID.uuidString,
            "summary": WriteJournal.summary(for: writes),
            "revertHint": "Undo this turn: " + WriteJournal.revertPhrase(for: writes),
            "items": rows
        ]
    }

    private static func blocks(before: String?, after: String) -> [[String: Any]] {
        BlockDiff.compare(before: before, after: after).map { change in
            var entry: [String: Any] = [
                "kind": change.kind.rawValue,
                // Frontmatter is a record, not prose: it is shown as `key: value` and
                // rendered inline, never run through the markdown parser.
                "field": change.blockKind == .field,
                "label": change.label ?? "",
                "before": change.before?.text ?? "",
                "after": change.after?.text ?? ""
            ]
            if change.kind == .changed, let old = change.before, let new = change.after {
                let runs = BlockDiff.words(before: old.text, after: new.text)
                entry["wordsBefore"] = runs.before.map { ["k": $0.kind.rawValue, "t": $0.text] }
                entry["wordsAfter"] = runs.after.map { ["k": $0.kind.rawValue, "t": $0.text] }
            }
            return entry
        }
    }
}
