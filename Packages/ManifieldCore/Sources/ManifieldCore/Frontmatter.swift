import Foundation

/// Parses and serializes the constrained YAML frontmatter used by theory item files.
///
/// Supported syntax (a deliberate subset of YAML — files are written by the app itself):
///   key: scalar value
///   key: "quoted value"
///   key: [a, b, c]
///   key:
///     - a
///     - b
public enum Frontmatter {

    public static func split(document: String) -> (frontmatter: String?, body: String) {
        let normalized = document.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") || normalized == "---" else {
            return (nil, normalized)
        }
        let afterOpen = String(normalized.dropFirst(4))
        guard let closeRange = afterOpen.range(of: "\n---") else {
            return (nil, normalized)
        }
        let fm = String(afterOpen[..<closeRange.lowerBound])
        var body = String(afterOpen[closeRange.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (fm, body)
    }

    public static func parseFields(_ text: String) -> [String: [String]] {
        var fields: [String: [String]] = [:]
        var currentListKey: String? = nil

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("- "), let key = currentListKey {
                fields[key, default: []].append(unquote(String(line.dropFirst(2))))
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip trailing YAML comment on unquoted scalars: `status: tested   # note`
            if !value.hasPrefix("\""), let hash = value.range(of: " #") {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            if value.isEmpty {
                currentListKey = key
                fields[key] = fields[key] ?? []
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                currentListKey = nil
                let inner = String(value.dropFirst().dropLast())
                let parts = inner.split(separator: ",").map {
                    unquote($0.trimmingCharacters(in: .whitespaces))
                }.filter { !$0.isEmpty }
                fields[key] = parts
            } else {
                currentListKey = nil
                fields[key] = [unquote(value)]
            }
        }
        return fields
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.replacingOccurrences(of: "\\\"", with: "\"")
    }

    static func quoteIfNeeded(_ s: String) -> String {
        let needsQuote = s.isEmpty
            || s.contains(":") || s.contains("#") || s.contains("[") || s.contains("]")
            || s.contains("\"") || s.hasPrefix("- ") || s != s.trimmingCharacters(in: .whitespaces)
        guard needsQuote else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension TheoryItem {

    /// Parses a theory item file (frontmatter + markdown body).
    public static func parse(markdown: String, fallbackID: String? = nil) throws -> TheoryItem {
        let (fm, body) = Frontmatter.split(document: markdown)
        guard let fm else {
            throw CoreError.invalidFrontmatter("missing '---' frontmatter block")
        }
        let fields = Frontmatter.parseFields(fm)

        guard let id = fields["id"]?.first ?? fallbackID, !id.isEmpty else {
            throw CoreError.invalidFrontmatter("missing 'id'")
        }
        guard let typeRaw = fields["type"]?.first, let type = ItemType(rawValue: typeRaw) else {
            throw CoreError.invalidFrontmatter("missing or unknown 'type' in item '\(id)'")
        }
        let name = fields["name"]?.first ?? id
        let status: ItemStatus
        if let statusRaw = fields["status"]?.first {
            guard let parsed = ItemStatus(rawValue: statusRaw) else {
                throw CoreError.invalidFrontmatter("unknown 'status' '\(statusRaw)' in item '\(id)'")
            }
            status = parsed
        } else {
            status = TheoryItem.defaultStatus(for: type)
        }

        return TheoryItem(
            id: id,
            type: type,
            name: name,
            status: status,
            dependsOn: fields["depends_on"] ?? [],
            resolves: fields["resolves"] ?? [],
            tags: fields["tags"] ?? [],
            source: fields["source"]?.first,
            section: TheoryItem.sanitizeSection(fields["section"]?.first),
            order: fields["order"]?.first.flatMap(Int.init),
            // Asset paths are dropped unless they name a file inside `figures/`. This is
            // the parser agent-written frontmatter goes through (`write_theory_item`),
            // so it is where a `../../.ssh/id_rsa` has to die.
            image: FigureAsset.sanitizedPath(fields["image"]?.first),
            generator: FigureAsset.sanitizedPath(fields["generator"]?.first),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Serializes the item back to frontmatter + body markdown.
    public func serialized() -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(Frontmatter.quoteIfNeeded(id))")
        lines.append("type: \(type.rawValue)")
        lines.append("name: \(Frontmatter.quoteIfNeeded(name))")
        lines.append("status: \(status.rawValue)")
        lines.append("depends_on: [\(dependsOn.map(Frontmatter.quoteIfNeeded).joined(separator: ", "))]")
        lines.append("resolves: [\(resolves.map(Frontmatter.quoteIfNeeded).joined(separator: ", "))]")
        lines.append("tags: [\(tags.map(Frontmatter.quoteIfNeeded).joined(separator: ", "))]")
        if let source, !source.isEmpty {
            lines.append("source: \(Frontmatter.quoteIfNeeded(source))")
        }
        if let section, !section.isEmpty {
            lines.append("section: \(Frontmatter.quoteIfNeeded(section))")
        }
        if let order {
            lines.append("order: \(order)")
        }
        if let image, !image.isEmpty {
            lines.append("image: \(Frontmatter.quoteIfNeeded(image))")
        }
        if let generator, !generator.isEmpty {
            lines.append("generator: \(Frontmatter.quoteIfNeeded(generator))")
        }
        lines.append("---")
        lines.append(body)
        return lines.joined(separator: "\n") + "\n"
    }
}
