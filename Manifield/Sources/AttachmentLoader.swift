import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Turns files picked in the composer into `ChatController.ComposerAttachment`s:
/// images are downscaled/re-encoded for the model, text formats are read directly,
/// PDFs get their text extracted. Runs synchronously — call off the main thread for
/// big files if it ever becomes noticeable.
enum AttachmentLoader {

    /// Longest edge sent to the model; larger photos are downscaled (matches what
    /// vision APIs resample to anyway, and keeps saved chats small).
    static let maxImageDimension: CGFloat = 1568
    /// Cap on extracted text per file (~45k tokens) so one attachment can't flood
    /// the context.
    static let maxDocumentCharacters = 180_000

    /// File types the picker offers. Text-ish types beyond the explicit list still work
    /// via the plain-text fallback.
    static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .png, .jpeg, .gif, .webP, .heic, .tiff, .bmp,
                               .plainText, .utf8PlainText, .text]
        for ext in ["md", "markdown", "tex", "py", "csv", "json", "toml", "yaml", "yml"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case emptyPDF(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Could not read “\(name)”."
            case .emptyPDF(let name): return "“\(name)” contains no extractable text (scanned PDF?)."
            case .unsupported(let name): return "“\(name)” is not a supported file type."
            }
        }
    }

    static func load(url: URL) throws -> ChatController.ComposerAttachment {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"].contains(ext) {
            return try loadImage(url: url, name: name)
        }
        if ext == "pdf" {
            return try loadPDF(url: url, name: name)
        }
        return try loadText(url: url, name: name)
    }

    // MARK: - Images

    private static func loadImage(url: URL, name: String) throws -> ChatController.ComposerAttachment {
        guard let image = NSImage(contentsOf: url) else { throw LoadError.unreadable(name) }
        return try attachment(image: image, name: name)
    }

    /// Builds an attachment directly from an in-memory image — used for pasted/dropped
    /// images that have no backing file (e.g. a clipboard screenshot). Shares the same
    /// downscale/re-encode pipeline as file loads.
    static func attachment(image: NSImage, name: String) throws -> ChatController.ComposerAttachment {
        guard let scaled = downscaled(image, maxDimension: maxImageDimension),
              let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { throw LoadError.unreadable(name) }

        // PNG keeps diagrams/screenshots crisp; JPEG keeps photos small. Heuristic:
        // try PNG first, fall back to JPEG when it comes out large.
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 2_000_000 {
            return ChatController.ComposerAttachment(
                name: name, kind: .image(mediaType: "image/png", base64: png.base64EncodedString()))
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw LoadError.unreadable(name)
        }
        return ChatController.ComposerAttachment(
            name: name, kind: .image(mediaType: "image/jpeg", base64: jpeg.base64EncodedString()))
    }

    private static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        // Work in pixel space: NSImage.size is in points and lies about Retina scans.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let longest = max(width, height)
        guard longest > maxDimension else {
            let result = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
            return result
        }
        let scale = maxDimension / longest
        let newSize = NSSize(width: floor(width * scale), height: floor(height * scale))
        let result = NSImage(size: newSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: NSSize(width: width, height: height))
            .draw(in: NSRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }

    // MARK: - Documents

    private static func loadPDF(url: URL, name: String) throws -> ChatController.ComposerAttachment {
        guard let document = PDFDocument(url: url) else { throw LoadError.unreadable(name) }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            pages.append("[page \(index + 1)]\n\(text)")
        }
        let joined = pages.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw LoadError.emptyPDF(name) }
        return ChatController.ComposerAttachment(name: name, kind: .document(text: capped(joined)))
    }

    private static func loadText(url: URL, name: String) throws -> ChatController.ComposerAttachment {
        let data = try? Data(contentsOf: url)
        guard let data else { throw LoadError.unreadable(name) }
        // Refuse obvious binaries (NUL bytes) instead of sending garbage to the model.
        guard !data.prefix(4096).contains(0) else { throw LoadError.unsupported(name) }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoadError.unreadable(name)
        }
        return ChatController.ComposerAttachment(name: name, kind: .document(text: capped(text)))
    }

    private static func capped(_ text: String) -> String {
        guard text.count > maxDocumentCharacters else { return text }
        return text.prefix(maxDocumentCharacters)
            + "\n\n[… truncated: file continues beyond \(maxDocumentCharacters) characters]"
    }

    // MARK: - Paste / drag-and-drop

    /// Reads composer attachments off a pasteboard (⌘V or a drop onto the composer).
    /// File URLs take priority — e.g. dragging from Finder or copying a file — and go
    /// through the same `load(url:)` path as the file picker, so PDFs/text files work
    /// via paste/drop too, not just images. Falls back to raw image data for content
    /// with no backing file, such as a clipboard screenshot or an image dragged out of
    /// a web page. Returns empty when the pasteboard holds neither, so callers can fall
    /// back to normal text paste/insertion.
    static func readFromPasteboard(_ pasteboard: NSPasteboard) -> (attachments: [ChatController.ComposerAttachment], errors: [String]) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            var attachments: [ChatController.ComposerAttachment] = []
            var errors: [String] = []
            for url in urls {
                do { attachments.append(try load(url: url)) }
                catch { errors.append(error.localizedDescription) }
            }
            return (attachments, errors)
        }
        if let image = NSImage(pasteboard: pasteboard) {
            do { return ([try attachment(image: image, name: pastedImageName())], []) }
            catch { return ([], [error.localizedDescription]) }
        }
        return ([], [])
    }

    private static func pastedImageName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Pasted image \(formatter.string(from: Date())).png"
    }
}
