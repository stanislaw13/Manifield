import Foundation
import PDFKit
import ManifieldCore
import ManifieldAgents

/// PDFKit lives in the app layer (ManifieldCore stays pure string processing), so every
/// path that turns a file on disk into something storable — the source importer, the
/// project importer, adding a file to a project — comes through here. Nothing in it
/// touches the main actor: reading a 400-page book takes seconds and belongs on a
/// background task.
enum PDFExtraction {

    /// What one file yielded: the agent-readable text (nil when nothing was extractable),
    /// plus the raw material the importers need to chunk it.
    struct Result: Sendable {
        /// Segmented text, one segment per page for PDFs / per section for LaTeX, with a
        /// table of contents where the file offered one.
        var fulltext: FullTextDocument?
        /// Cleaned page texts, in page order (PDFs only).
        var pages: [String] = []
        /// The PDF's bookmark outline, flattened — the input of the outline-aware splitter.
        var outline: [SourceImport.OutlineEntry]?
        /// The file's own text, for LaTeX (macro harvesting works on the whole source).
        var text: String?
        var pageCount: Int?
        var warnings: [String] = []

        var hasText: Bool { fulltext != nil }
    }

    /// Reads a PDF or text/LaTeX file. Throws only when the file cannot be opened at all —
    /// a PDF with no extractable text comes back with `fulltext == nil` and a warning, so
    /// callers that only want to store the file still can.
    static func read(url: URL) throws -> Result {
        if url.pathExtension.lowercased() == "pdf" {
            return try readPDF(url: url)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CoreError.io("Could not read '\(url.lastPathComponent)' as UTF-8 text.")
        }
        return readText(text)
    }

    static func readPDF(url: URL) throws -> Result {
        guard let pdf = PDFDocument(url: url) else {
            throw CoreError.io("Could not open '\(url.lastPathComponent)' as a PDF.")
        }
        let pages = PDFTextCleanup.clean(
            pages: (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" })
        var result = Result(pages: pages, pageCount: pdf.pageCount)
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            result.pages = []
            result.warnings.append("No extractable text — the file is stored for reading, but agents cannot search it. OCR it and add it again if you need that.")
            return result
        }
        result.fulltext = FullTextDocument(
            unit: .page,
            contents: outlineMarkdown(of: pdf),
            segments: pages.enumerated().map {
                .init(index: $0.offset + 1, title: "Page \($0.offset + 1)", text: $0.element)
            })
        result.outline = outlineEntries(of: pdf)
        return result
    }

    /// LaTeX/plain text: sections become the segments, so `read_document` addresses the
    /// same units the importer chunks on. Segmentation deliberately uses the default
    /// chunk size rather than the import model's budget — `fulltext.md` is written to
    /// disk and read back by agents for the life of the source, so which model happened
    /// to run the import must not change how it is addressed.
    static func readText(_ text: String) -> Result {
        var result = Result(text: text)
        let sections = SourceImport.splitLaTeX(text, maxChunkSize: SourceImport.defaultMaxChunkSize)
        guard !sections.isEmpty else { return result }
        result.fulltext = FullTextDocument(
            unit: .section,
            contents: sections.enumerated()
                .map { "- \($0.element.title) — segment \($0.offset + 1)" }
                .joined(separator: "\n"),
            segments: sections.enumerated().map {
                .init(index: $0.offset + 1, title: $0.element.title, text: $0.element.text)
            })
        return result
    }

    // MARK: - Outline

    /// Bookmarks flattened to two levels with resolved page indices.
    static func outlineEntries(of pdf: PDFDocument) -> [SourceImport.OutlineEntry]? {
        guard let root = pdf.outlineRoot else { return nil }
        var entries: [SourceImport.OutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            guard depth < 2, entries.count < 300 else { return }
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, let page = child.destination?.page {
                    let index = pdf.index(for: page)
                    if index != NSNotFound {
                        entries.append(.init(title: label, pageIndex: index, depth: depth))
                    }
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return entries.isEmpty ? nil : entries
    }

    /// The PDF's bookmark outline as a markdown list with page numbers — free navigation
    /// for agents (segment 0) and for overview generation.
    static func outlineMarkdown(of pdf: PDFDocument) -> String? {
        guard let root = pdf.outlineRoot else { return nil }
        var lines: [String] = []
        func walk(_ node: PDFOutline, depth: Int) {
            guard depth < 3, lines.count < 400 else { return }
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    var line = String(repeating: "  ", count: depth) + "- " + label
                    if let page = child.destination?.page {
                        let index = pdf.index(for: page)
                        if index != NSNotFound { line += " — p. \(index + 1)" }
                    }
                    lines.append(line)
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
