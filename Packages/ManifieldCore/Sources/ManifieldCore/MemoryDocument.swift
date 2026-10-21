import Foundation

/// The fixed sections of a project's research memory (memory.md).
public enum MemorySection: String, CaseIterable, Sendable, Codable {
    case goal
    case currentStatus = "current-status"
    case activeStrategies = "active-strategies"
    case eliminatedStrategies = "eliminated-strategies"
    case keyInsights = "key-insights"
    case nextSteps = "next-steps"

    public var heading: String {
        switch self {
        case .goal: return "Goal"
        case .currentStatus: return "Current Status"
        case .activeStrategies: return "Active Strategies"
        case .eliminatedStrategies: return "Eliminated Strategies"
        case .keyInsights: return "Key Insights"
        case .nextSteps: return "Next Steps"
        }
    }

    static func match(heading: String) -> MemorySection? {
        let normalized = heading.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.heading.lowercased() == normalized }
    }
}

/// The project's persistent research memory: goals, status, strategies tried and
/// eliminated (with why), insights, next steps. It holds only what the theory library
/// can't — agents cite item ids instead of restating content. Stored as memory.md at
/// the project root, human-editable, injected whole into agent contexts.
public struct MemoryDocument: Equatable, Sendable {

    /// Hard cap (~3k tokens). update_memory rejects oversize updates with an
    /// instruction to compress, so the model self-prunes instead of growing forever.
    public static let maxLength = 12_000

    public var sections: [MemorySection: String]
    /// Preamble or unknown-heading content a human added — preserved on round-trip.
    public var extra: String

    public init(sections: [MemorySection: String] = [:], extra: String = "") {
        self.sections = sections
        self.extra = extra
    }

    public var isEmpty: Bool {
        extra.isEmpty && sections.values.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Lenient parse: `## <heading>` lines open sections; recognized headings map to
    /// their section, everything else (preamble, unknown headings, comments) lands in
    /// `extra` verbatim. An optional YAML frontmatter block is skipped.
    public static func parse(markdown: String) -> MemoryDocument {
        let (_, body) = Frontmatter.split(document: markdown)
        var sections: [MemorySection: String] = [:]
        var extraLines: [String] = []
        var current: MemorySection?
        var buffer: [String] = []

        func flush() {
            guard let section = current else { return }
            let text = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections[section] = text
            buffer = []
        }

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if let section = MemorySection.match(heading: String(trimmed.dropFirst(3))) {
                    flush()
                    current = section
                    continue
                }
                // Unknown heading: close the current section, collect as extra.
                flush()
                current = nil
            }
            if current != nil {
                buffer.append(line)
            } else {
                extraLines.append(line)
            }
        }
        flush()

        return MemoryDocument(
            sections: sections,
            extra: extraLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Canonical serialization: every known section (empty ones included, so the file
    /// stays self-documenting), extra content preserved at the end.
    public func serialized() -> String {
        var parts: [String] = []
        for section in MemorySection.allCases {
            let body = sections[section]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            parts.append(body.isEmpty ? "## \(section.heading)" : "## \(section.heading)\n\(body)")
        }
        if !extra.isEmpty {
            parts.append(extra)
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Compact rendering for system prompts: only non-empty sections, or an explicit
    /// "empty" marker so the model knows the memory exists but has nothing yet.
    public var promptRendering: String {
        var parts: [String] = []
        for section in MemorySection.allCases {
            guard let body = sections[section]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { continue }
            parts.append("## \(section.heading)\n\(body)")
        }
        if !extra.isEmpty { parts.append(extra) }
        return parts.isEmpty ? "(the research memory is empty — nothing recorded yet)"
                             : parts.joined(separator: "\n\n")
    }

    /// Starter file content for new projects.
    public static func stub() -> String {
        """
        <!-- Research memory: the project's working state — goals, strategies (tried and
             eliminated, with why), insights, next steps. Agents read it every turn and
             keep it updated; you can edit it freely. Cite theory items by id instead of
             restating them. -->

        """ + MemoryDocument().serialized()
    }
}
