import Foundation
import ManifieldCore

struct MemoryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The research memory is the agent's own notebook — writes are direct (no proposal
/// flow), because it records the agent's working state, not mathematical truth. The
/// trust ladder never applies to it.
public enum MemoryTools {

    /// - Parameters:
    ///   - currentMemory: returns the current memory.md text (called per update).
    ///   - saveMemory: persists the new text; the app hops this to the main actor.
    public static func updateTool(
        currentMemory: @escaping @Sendable () async -> String,
        saveMemory: @escaping @Sendable (String) async throws -> Void
    ) -> AgentTool {
        UpdateMemoryTool(currentMemory: currentMemory, saveMemory: saveMemory)
    }
}

struct UpdateMemoryTool: AgentTool {
    let currentMemory: @Sendable () async -> String
    let saveMemory: @Sendable (String) async throws -> Void

    var spec: ToolSpec {
        let slugs = MemorySection.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return ToolSpec(
            name: "update_memory",
            description: "Replace one section of the project's research memory (memory.md). The memory persists across sessions and is read by every agent — keep it current: goal, status, active strategies, ELIMINATED strategies (always with why they failed), key insights, next steps. Cite theory items by id instead of restating them. The whole file is capped at \(MemoryDocument.maxLength) characters; compress instead of appending endlessly.",
            inputSchemaJSON: """
            {"type":"object","properties":{"section":{"type":"string","enum":[\(slugs)],"description":"Which section to replace"},"content":{"type":"string","description":"The section's complete new content (markdown; replaces the old content of that section)"}},"required":["section","content"]}
            """
        )
    }

    func execute(inputJSON: String) async throws -> String {
        let input = jsonObject(inputJSON)
        guard let sectionRaw = input["section"] as? String,
              let section = MemorySection(rawValue: sectionRaw) else {
            let valid = MemorySection.allCases.map(\.rawValue).joined(separator: ", ")
            throw MemoryError(message: "unknown section — use one of: \(valid)")
        }
        guard let content = input["content"] as? String else {
            throw MemoryError(message: "missing 'content'")
        }

        var document = MemoryDocument.parse(markdown: await currentMemory())
        document.sections[section] = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let serialized = document.serialized()

        if serialized.count > MemoryDocument.maxLength {
            throw MemoryError(message: """
            REJECTED — the memory would grow to \(serialized.count) characters \
            (cap: \(MemoryDocument.maxLength)). Compress before writing: merge stale \
            insights, shrink eliminated strategies to one line each (keep the WHY), \
            and cite theory item ids instead of restating their content. Then retry \
            update_memory with the shorter content.
            """)
        }

        try await saveMemory(serialized)
        return "Memory updated — section '\(section.heading)' replaced (\(serialized.count)/\(MemoryDocument.maxLength) chars used)."
    }
}
