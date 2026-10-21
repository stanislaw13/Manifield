import Foundation
import ManifieldCore

/// The remedy for parallel chunk import's missing cross-chunk edges: walk the imported
/// items (no PDF involved), show the model the whole catalog plus one batch's full
/// statements, and collect additional depends_on edges. Every proposed edge is
/// validated — unknown targets, self-references, duplicates, and cycle-creating edges
/// are dropped with a warning.
public enum LinkPass {

    public struct Edit: Equatable, Sendable {
        public let itemID: String
        public let addDependsOn: [String]

        public init(itemID: String, addDependsOn: [String]) {
            self.itemID = itemID
            self.addDependsOn = addDependsOn
        }
    }

    /// Batches follow the document order (section grouping), so a batch's items share
    /// context and their likely dependencies sit in the catalog nearby.
    /// (groupedBySection preserves input order within groups, so sort first.)
    public static func batches(items: [TheoryItem], maxBatch: Int = 25) -> [[TheoryItem]] {
        let ordered = TheoryItem
            .groupedBySection(items.sorted(by: TheoryItem.documentOrder))
            .flatMap(\.items)
        guard !ordered.isEmpty else { return [] }
        return stride(from: 0, to: ordered.count, by: maxBatch).map {
            Array(ordered[$0..<min($0 + maxBatch, ordered.count)])
        }
    }

    /// One line per item across the WHOLE source — sent with every batch call.
    public static func catalogText(items: [TheoryItem]) -> String {
        items.map { "\($0.id) | \($0.type.rawValue) | \($0.section ?? "-") | \($0.name)" }
            .joined(separator: "\n")
    }

    public static func systemPrompt(items: [TheoryItem]) -> String {
        PromptLibrary.text("link_pass_system", ["CATALOG": catalogText(items: items)])
    }

    public static func userMessage(batch: [TheoryItem]) -> String {
        batch.map { item in
            var block = """
            ### \(item.id)
            existing depends_on: [\(item.dependsOn.joined(separator: ", "))]
            Statement:
            \(item.statement ?? item.body)
            """
            if let proof = item.proof, !proof.isEmpty {
                block += "\nProof (may be truncated):\n\(String(proof.prefix(1_500)))"
            }
            return block
        }.joined(separator: "\n\n")
    }

    public static func parse(_ response: String) throws -> [Edit] {
        guard let jsonText = Organizer.extractJSONArray(from: response),
              let array = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [[String: Any]] else {
            throw AgentError.badResponse("no JSON array found in link-pass response")
        }
        return array.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let deps = obj["add_depends_on"] as? [String], !deps.isEmpty else { return nil }
            return Edit(itemID: TheoryItem.sanitizeID(id), addDependsOn: deps)
        }
    }

    /// Applies validated edges through `store.save` (graph.json/FTS stay correct).
    /// NOT thread-safe — call on whatever context owns the store.
    public static func apply(_ edits: [Edit], store: ProjectStore) -> (added: Int, warnings: [String]) {
        var warnings: [String] = []
        var added = 0
        let validIDs = Set(store.items.map(\.id))

        for edit in edits {
            guard var item = store.item(id: edit.itemID) else {
                warnings.append("Link pass: unknown item '\(edit.itemID)' — skipped")
                continue
            }
            let original = item.dependsOn
            for dep in edit.addDependsOn {
                let depID = TheoryItem.sanitizeID(dep)
                guard depID != item.id else {
                    warnings.append("Link pass: '\(item.id)' cannot depend on itself — skipped")
                    continue
                }
                guard validIDs.contains(depID) else {
                    warnings.append("Link pass: '\(item.id)' → unknown '\(dep)' — skipped")
                    continue
                }
                guard !item.dependsOn.contains(depID) else { continue }
                item.dependsOn.append(depID)
                var projected = store.items
                if let idx = projected.firstIndex(where: { $0.id == item.id }) {
                    projected[idx] = item
                }
                if DependencyGraph(items: projected).findCycle() != nil {
                    item.dependsOn.removeLast()
                    warnings.append("Link pass: '\(item.id)' → '\(depID)' would create a cycle — skipped")
                    continue
                }
                added += 1
            }
            if item.dependsOn != original {
                do {
                    try store.save(item)
                } catch {
                    warnings.append("Link pass: could not save '\(item.id)' — \(error.localizedDescription)")
                    added -= item.dependsOn.count - original.count
                }
            }
        }
        return (added, warnings)
    }

    /// Rough cost preview for the confirmation UI.
    public static func estimate(items: [TheoryItem], maxBatch: Int = 25) -> (calls: Int, approxInputTokens: Int) {
        let allBatches = batches(items: items, maxBatch: maxBatch)
        let catalogChars = catalogText(items: items).count
        let statementChars = items.reduce(0) { $0 + ($1.statement ?? $1.body).count }
        let totalChars = allBatches.count * catalogChars + statementChars
        return (allBatches.count, totalChars / 4)
    }
}
