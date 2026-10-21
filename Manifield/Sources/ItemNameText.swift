import SwiftUI
import SwiftMath
import ManifieldCore

/// Renders an item name that may contain inline `$...$` math as native text — the one
/// place all list rows get their names from, so the rendering strategy stays swappable.
/// Math segments go through MathExpansion (project macros) and SwiftMath; any segment
/// that fails to render falls back to its plain LaTeX source.
struct ItemNameText: View {
    let name: String
    /// Macro dictionary of the store that OWNS the item (a source's items need the
    /// source's macros, not the open project's).
    let macros: [String: String]
    var fontSize: CGFloat = NSFont.systemFontSize
    /// Set to 1 where the row must not change height — an outer `.lineLimit` cannot do it,
    /// since the limit applied closest to the text wins.
    var lineLimit: Int = 2

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        segments.reduce(Text("")) { $0 + $1 }
            .lineLimit(lineLimit)
    }

    private var segments: [Text] {
        MathTextCache.split(name).map { segment in
            guard segment.isMath else { return Text(segment.text) }
            let expanded = MathExpansion.expand(segment.text, macros: macros)
            if let image = MathTextCache.image(
                latex: expanded, fontSize: fontSize, dark: colorScheme == .dark) {
                return Text(Image(nsImage: image)).baselineOffset(-fontSize * 0.18)
            }
            return Text(segment.text)  // unrenderable math: show the LaTeX source
        }
    }
}

/// SwiftMath rendering with a process-wide image cache — lists redraw constantly and
/// typesetting is far more expensive than a dictionary hit.
enum MathTextCache {

    struct Segment {
        let isMath: Bool
        let text: String
    }

    /// Splits on unescaped `$` delimiters; an unbalanced `$` degrades the whole name
    /// to plain text rather than guessing.
    static func split(_ name: String) -> [Segment] {
        guard name.contains("$") else { return [Segment(isMath: false, text: name)] }
        var parts: [String] = [""]
        var escaped = false
        for char in name {
            if escaped {
                parts[parts.count - 1].append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                parts[parts.count - 1].append(char)
            } else if char == "$" {
                parts.append("")
            } else {
                parts[parts.count - 1].append(char)
            }
        }
        guard parts.count % 2 == 1 else { return [Segment(isMath: false, text: name)] }
        return parts.enumerated().compactMap { index, text in
            text.isEmpty ? nil : Segment(isMath: index % 2 == 1, text: text)
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(latex: String, fontSize: CGFloat, dark: Bool) -> NSImage? {
        let key = "\(latex)|\(fontSize)|\(dark)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let color: NSColor = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.13, alpha: 1)
        let renderer = MTMathImage(
            latex: latex, fontSize: fontSize, textColor: color, labelMode: .text)
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
