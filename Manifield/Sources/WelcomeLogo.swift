import AppKit
import SwiftUI

/// Render the artwork at its final backing-pixel size instead of asking the GPU
/// to minify a padded 1024px texture and its separate mask on every frame.
struct WelcomeLogo: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = WelcomeLogoRaster.image(displayScale: displayScale) {
            Image(decorative: image, scale: displayScale)
                .interpolation(.high)
        }
    }
}

@MainActor
private enum WelcomeLogoRaster {
    private static var cache: [Int: CGImage] = [:]
    private static let size: CGFloat = 88
    // Tight bounds of the original mark, with a little room for its edge pixels.
    private static let artworkBounds = CGRect(x: 184, y: 230, width: 684, height: 526)

    static func image(displayScale: CGFloat) -> CGImage? {
        let pixels = max(1, Int((size * displayScale).rounded()))
        if let image = cache[pixels] { return image }
        guard let source = NSImage(named: "AppLogo")?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Supersample the mask and shading together, then downsample once. This
        // gives thin curved edges proper coverage at both 1x and 2x display scale.
        let samplePixels = pixels * 4
        guard let drawing = CGContext(data: nil, width: samplePixels, height: samplePixels,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawing.interpolationQuality = .high
        drawing.setShouldAntialias(true)
        let factor = CGFloat(samplePixels) / artworkBounds.width
        let artworkBottom = 1024 - artworkBounds.maxY
        let verticalPadding = (CGFloat(samplePixels) - artworkBounds.height * factor) / 2
        drawing.translateBy(x: -artworkBounds.minX * factor,
                            y: verticalPadding - artworkBottom * factor)
        drawing.scaleBy(x: factor, y: factor)
        // SwiftUI paths use top-left coordinates; Core Graphics images use bottom-left.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1024)
        let outline = WelcomeLogoOutline().path(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let mask = outline.cgPath.copy(using: &flip) else { return nil }
        drawing.addPath(mask)
        drawing.clip()
        drawing.draw(source, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))

        guard let sampled = drawing.makeImage(),
              let output = CGContext(data: nil, width: pixels, height: pixels,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        output.interpolationQuality = .high
        output.draw(sampled, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = output.makeImage() else { return nil }
        cache[pixels] = image
        return image
    }
}

/// The original artwork has a black backdrop. A vector outline preserves its
/// shading while removing the backdrop and shadow without a noisy raster cutout.
private struct WelcomeLogoOutline: Shape {
    func path(in rect: CGRect) -> Path {
        // Points follow the original 1024px artwork. Smooth cubic segments avoid
        // both pixel stair-stepping and dark fringes from its former backdrop.
        let outline: [CGPoint] = [
            .init(x: 262, y: 378), .init(x: 310, y: 383), .init(x: 358, y: 385),
            .init(x: 406, y: 380), .init(x: 454, y: 367), .init(x: 502, y: 345),
            .init(x: 550, y: 318), .init(x: 598, y: 286), .init(x: 646, y: 255),
            .init(x: 670, y: 242), .init(x: 690, y: 235), .init(x: 704, y: 236),
            .init(x: 718, y: 241), .init(x: 742, y: 264), .init(x: 766, y: 300),
            .init(x: 790, y: 344), .init(x: 814, y: 397), .init(x: 838, y: 463),
            .init(x: 853, y: 523), .init(x: 861, y: 571), .init(x: 863, y: 604),
            .init(x: 862, y: 634), .init(x: 857, y: 666), .init(x: 848, y: 698),
            .init(x: 828, y: 730), .init(x: 807, y: 745), .init(x: 790, y: 750),
            .init(x: 766, y: 749), .init(x: 742, y: 744), .init(x: 694, y: 726),
            .init(x: 646, y: 705), .init(x: 598, y: 684), .init(x: 550, y: 668),
            .init(x: 502, y: 687), .init(x: 454, y: 704), .init(x: 406, y: 717),
            .init(x: 358, y: 725), .init(x: 310, y: 727), .init(x: 286, y: 727),
            .init(x: 262, y: 723), .init(x: 246, y: 713), .init(x: 230, y: 698),
            .init(x: 220, y: 682), .init(x: 212, y: 666), .init(x: 206, y: 650),
            .init(x: 201, y: 634), .init(x: 194, y: 602), .init(x: 190, y: 570),
            .init(x: 189, y: 538), .init(x: 191, y: 506), .init(x: 195, y: 474),
            .init(x: 203, y: 442), .init(x: 218, y: 410), .init(x: 239, y: 387)
        ]
        var path = Path()
        path.move(to: outline[0])
        for index in outline.indices {
            let previous = outline[(index + outline.count - 1) % outline.count]
            let start = outline[index]
            let end = outline[(index + 1) % outline.count]
            let next = outline[(index + 2) % outline.count]
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + (end.x - previous.x) / 6,
                                            y: start.y + (end.y - previous.y) / 6),
                          control2: CGPoint(x: end.x - (next.x - start.x) / 6,
                                            y: end.y - (next.y - start.y) / 6))
        }
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 1024, y: rect.height / 1024)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

