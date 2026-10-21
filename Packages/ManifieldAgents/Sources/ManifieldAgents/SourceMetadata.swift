import Foundation
import ManifieldCore

/// One small model call filling in name/authors/citation the user left on "Auto" —
/// fed the document's opening and closing text, never the whole file.
public enum SourceMetadata {

    public struct Extracted: Equatable, Sendable {
        public let name: String?
        public let authors: [String]
        public let citation: String?

        public init(name: String?, authors: [String], citation: String?) {
            self.name = name
            self.authors = authors
            self.citation = citation
        }
    }

    public static func extract(
        runner: AgentRunner,
        head: String,
        tail: String,
        fileName: String,
        instructions: String? = nil
    ) async throws -> Extracted {
        let config = AgentConfig(
            systemPrompt: SystemPrompt(PromptLibrary.text("organizer_metadata")),
            tools: [],
            maxTokens: 400
        )
        var message = "File name: \(fileName)\n\nOpening pages:\n\(head)"
        if !tail.isEmpty { message += "\n\nClosing pages:\n\(tail)" }
        if let instructions, !instructions.trimmingCharacters(in: .whitespaces).isEmpty {
            message += "\n\nUser notes that may affect the metadata:\n\(instructions)"
        }
        let result = try await runner.run(
            config: config,
            history: [.user(message)]
        )
        return try parse(result.finalText)
    }

    /// Tolerates prose/fences around the JSON object; empty strings collapse to nil.
    public static func parse(_ response: String) throws -> Extracted {
        guard let json = extractJSONObject(from: response),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw AgentError.badResponse("no JSON object found in metadata response")
        }
        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let citation = (obj["citation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = (obj["authors"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Extracted(
            name: (name?.isEmpty ?? true) ? nil : name,
            authors: authors,
            citation: (citation?.isEmpty ?? true) ? nil : citation)
    }

    /// First top-level `{…}` in the text, respecting strings and escapes.
    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                switch char {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
