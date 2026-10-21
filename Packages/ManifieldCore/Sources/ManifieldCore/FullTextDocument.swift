import Foundation

/// The agent-readable full text of an imported source (`fulltext.md`): the original
/// document converted to plain markdown and split into addressable segments — one per
/// PDF page, or one per chapter/section for LaTeX. Whole documents exceed model
/// context, so agents never receive this file wholesale; they search its FTS index and
/// read narrow segment ranges. The file stays human-readable markdown on purpose.
///
///     <!-- manifield:fulltext v1 | unit: page | segments: 412 -->
///
///     <!-- manifield:contents -->
///     - Chapter 1. Preliminaries — p. 9
///
///     <!-- manifield:segment 1 | Page 1 -->
///     …text…
public struct FullTextDocument: Equatable, Sendable {

    public static let fileName = "fulltext.md"

    /// What one segment corresponds to in the original document.
    public enum Unit: String, Sendable, Equatable {
        case page
        case section

        var plural: String {
            switch self {
            case .page: return "pages"
            case .section: return "sections"
            }
        }
    }

    public struct Segment: Equatable, Sendable {
        /// 1-based address used by agent tools (`read_fulltext`). For PDFs this is the
        /// page number, so it matches the in-app PDF viewer and printed citations.
        public let index: Int
        public let title: String
        public let text: String

        public init(index: Int, title: String, text: String) {
            self.index = index
            self.title = title
            self.text = text
        }
    }

    /// Cheap summary parsed from the header line alone — briefings need "412 pages"
    /// without loading a multi-megabyte file.
    public struct Info: Equatable, Sendable {
        public let unit: Unit
        public let segmentCount: Int

        public init(unit: Unit, segmentCount: Int) {
            self.unit = unit
            self.segmentCount = segmentCount
        }

        /// e.g. "412 pages" / "1 section".
        public var unitLabel: String {
            segmentCount == 1 ? "1 \(unit.rawValue)" : "\(segmentCount) \(unit.plural)"
        }
    }

    public var unit: Unit
    /// Table of contents in markdown (from the PDF outline or the import's chunk
    /// titles). Agents read it as "segment 0" to decide where to look.
    public var contents: String?
    public var segments: [Segment]

    public init(unit: Unit, contents: String? = nil, segments: [Segment]) {
        self.unit = unit
        self.contents = contents
        self.segments = segments
    }

    public var info: Info { Info(unit: unit, segmentCount: segments.count) }

    /// Segments whose declared index falls in `range`, in file order.
    public func segments(in range: ClosedRange<Int>) -> [Segment] {
        segments.filter { range.contains($0.index) }
    }

    // MARK: - Serialization

    public func serialized() -> String {
        var out = "<!-- manifield:fulltext v1 | unit: \(unit.rawValue) | segments: \(segments.count) -->\n"
        if let contents, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\n<!-- manifield:contents -->\n\(Self.escapeMarkers(in: contents))\n"
        }
        for segment in segments {
            out += "\n<!-- manifield:segment \(segment.index) | \(Self.sanitizeTitle(segment.title)) -->\n"
            out += Self.escapeMarkers(in: segment.text) + "\n"
        }
        return out
    }

    public static func parse(markdown: String) throws -> FullTextDocument {
        guard let headerLine = markdown.split(separator: "\n", omittingEmptySubsequences: true).first,
              let info = parseHeader(String(headerLine)) else {
            throw CoreError.io("\(fileName) is missing its 'manifield:fulltext' header line — regenerate it by re-importing the source.")
        }

        let ns = markdown as NSString
        let matches = segmentMarkerRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))

        // The contents block sits between its marker and the first segment.
        var contents: String? = nil
        if let contentsRange = markdown.range(of: "<!-- manifield:contents -->") {
            let start = markdown.distance(from: markdown.startIndex, to: contentsRange.upperBound)
            let end = matches.first?.range.location ?? ns.length
            if end > start {
                let block = ns.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                contents = block.isEmpty ? nil : block
            }
        }

        var segments: [Segment] = []
        for (i, match) in matches.enumerated() {
            let index = Int(ns.substring(with: match.range(at: 1))) ?? (i + 1)
            let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(Segment(index: index, title: title, text: body))
        }
        return FullTextDocument(unit: info.unit, contents: contents, segments: segments)
    }

    /// Reads only the header line of the file — constant-time regardless of size.
    public static func quickInfo(at url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256),
              let head = String(data: data, encoding: .utf8) else { return nil }
        guard let firstLine = head.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        return parseHeader(String(firstLine))
    }

    // MARK: - Internals

    private static let segmentMarkerRegex = try! NSRegularExpression(
        pattern: #"<!-- manifield:segment (\d+) \| ([^>\n]*) -->"#)

    private static func parseHeader(_ line: String) -> Info? {
        let pattern = #"<!-- manifield:fulltext v1 \| unit: (\w+) \| segments: (\d+) -->"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let unit = Unit(rawValue: ns.substring(with: match.range(at: 1))),
              let count = Int(ns.substring(with: match.range(at: 2))) else { return nil }
        return Info(unit: unit, segmentCount: count)
    }

    /// Titles live inside the marker comment — they must not close or fake it.
    private static func sanitizeTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "—")
            .replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Document text that happens to contain our marker syntax must not be parsed as
    /// structure on the way back in.
    private static func escapeMarkers(in text: String) -> String {
        text.replacingOccurrences(of: "<!-- manifield:", with: "<!-- manifield\u{2010}")
    }
}
