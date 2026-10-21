import AppKit
import CoreText
import SwiftUI

/// A single drawing surface: cursor updates never invalidate the SwiftUI welcome content.
struct WelcomeMathTrail: NSViewRepresentable {
    var exclusionRects: [CGRect]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WelcomeMathTrailView {
        WelcomeMathTrailView()
    }

    func updateNSView(_ view: WelcomeMathTrailView, context: Context) {
        view.exclusionRects = exclusionRects
        view.isDark = colorScheme == .dark
        view.motionEnabled = !reduceMotion
    }

    static func dismantleNSView(_ view: WelcomeMathTrailView, coordinator: ()) {
        view.clear()
    }
}

final class WelcomeMathTrailView: NSView {
    var exclusionRects: [CGRect] = []
    var isDark = false
    var motionEnabled = true {
        didSet { if !motionEnabled { clear() } }
    }

    private struct Glyph {
        let line: CTLine
        let width: CGFloat
    }

    private struct Particle {
        let origin: CGPoint
        let tangent: CGVector
        let birth: TimeInterval
        let lifetime: Double
        let phase: Double
        let spread: Double
        let glyph: Int
        let tint: Int
    }

    private static let symbols = ["α", "β", "γ", "δ", "ε", "θ", "λ", "μ", "π", "ρ", "σ", "φ", "ψ", "ω",
                                  "∇", "∂", "∫", "∑", "∞", "≈", "⊂", "∈", "ℝ", "ℂ", "∀", "∃"]
    private static let equations = ["eⁱπ + 1 = 0", "∇·F = 0", "∂² = 0", "f : M → ℝ", "∫ ω", "Σ aₙ", "δS = 0"]
    // Shape text once, including font fallback for mathematical characters.
    private let glyphs: [Glyph] = (symbols + equations).map { text in
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "TimesNewRomanPS-ItalicMT", size: 16) ?? NSFont.systemFont(ofSize: 16),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return Glyph(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
    private let lightColors = [
        NSColor(red: 0.30, green: 0.39, blue: 0.65, alpha: 1).cgColor,
        NSColor(red: 0.44, green: 0.36, blue: 0.62, alpha: 1).cgColor,
        NSColor(red: 0.43, green: 0.44, blue: 0.59, alpha: 1).cgColor
    ]
    private let darkColors = [
        NSColor(red: 0.62, green: 0.71, blue: 0.94, alpha: 1).cgColor,
        NSColor(red: 0.77, green: 0.66, blue: 0.93, alpha: 1).cgColor,
        NSColor(red: 0.72, green: 0.73, blue: 0.88, alpha: 1).cgColor
    ]
    private var particles: [Particle] = []
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var previousPoint: CGPoint?
    private var distanceToNext: CGFloat = 0
    private var sequence = 0
    private var drawingTime: TimeInterval = 0
    private static let spacing: CGFloat = 9
    private static let capacity = 240

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        particles.reserveCapacity(Self.capacity)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clear()
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        guard canAnimate else { return }
        sample(convert(event.locationInWindow, from: nil), at: CACurrentMediaTime())
        startTimerIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        previousPoint = nil
        distanceToNext = 0
    }

    private var canAnimate: Bool {
        motionEnabled && window?.isKeyWindow == true && NSApp.isActive
            && window?.attachedSheet == nil && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !particles.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard canAnimate else { clear(); return }
        drawingTime = CACurrentMediaTime()
        particles.removeAll { drawingTime - $0.birth >= $0.lifetime }
        needsDisplay = true
        if particles.isEmpty {
            timer?.invalidate()
            timer = nil
            previousPoint = nil
            distanceToNext = 0
        }
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        particles.removeAll(keepingCapacity: true)
        previousPoint = nil
        distanceToNext = 0
        needsDisplay = true
    }

    private func sample(_ point: CGPoint, at time: TimeInterval) {
        guard bounds.contains(point), !exclusionRects.contains(where: { $0.insetBy(dx: -12, dy: -12).contains(point) }) else {
            previousPoint = nil
            distanceToNext = 0
            return
        }
        guard let previous = previousPoint else {
            previousPoint = point
            return
        }
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let distance = hypot(dx, dy)
        guard distance > 0.1 else { return }
        previousPoint = point
        // Re-entry / pointer jumps must not paint a line across the whole window.
        guard distance < 240 else { distanceToNext = 0; return }
        let tangent = CGVector(dx: dx / distance, dy: dy / distance)
        var offset = distanceToNext
        while offset <= distance {
            let center = CGPoint(x: previous.x + tangent.dx * offset, y: previous.y + tangent.dy * offset)
            emit(at: center, tangent: tangent, time: time)
            offset += Self.spacing
        }
        distanceToNext = offset - distance
        drawingTime = time
    }

    private func emit(at center: CGPoint, tangent: CGVector, time: TimeInterval) {
        // Three loosely braided strands form a soft, irregular silhouette.
        for lane in -1...1 {
            sequence += 1
            let phase = Double(sequence) * 2.3999632297 // Golden angle: no visible repeating pattern.
            let spread = Double(lane) * (17 + 7 * sin(phase * 0.37)) + 5 * sin(phase)
            let origin = CGPoint(x: center.x - tangent.dy * spread,
                                 y: center.y + tangent.dx * spread)
            let equation = sequence % 29 == 0
            let glyph = equation ? Self.symbols.count + (sequence / 29) % Self.equations.count
                : (sequence * 7) % Self.symbols.count
            particles.append(Particle(origin: origin, tangent: tangent, birth: time,
                                      lifetime: 1.25 + 0.45 * (0.5 + 0.5 * sin(phase)),
                                      phase: phase, spread: spread, glyph: glyph, tint: sequence % 3))
        }
        if particles.count > Self.capacity {
            particles.removeFirst(particles.count - Self.capacity)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = isDark ? darkColors : lightColors
        for particle in particles {
            let age = max(0, drawingTime - particle.birth)
            let progress = age / particle.lifetime
            guard progress < 1 else { continue }
            let drift = (sin(particle.phase + age * 2) - sin(particle.phase)) * 11
                + particle.spread * age * 0.22
            let point = CGPoint(x: particle.origin.x - particle.tangent.dx * age * 8 - particle.tangent.dy * drift,
                                y: particle.origin.y - particle.tangent.dy * age * 8 + particle.tangent.dx * drift)
            let glyph = glyphs[particle.glyph]
            let scale = 0.78 + 0.22 * sin(particle.phase) * sin(particle.phase)
            let glyphRect = CGRect(x: point.x - glyph.width * scale / 2, y: point.y - 11,
                                   width: glyph.width * scale, height: 22)
            // Keep the entire glyph away from foreground content, feathering its approach.
            var clearance: CGFloat = 1
            for rect in exclusionRects {
                let dx = max(rect.minX - glyphRect.maxX, glyphRect.minX - rect.maxX, 0)
                let dy = max(rect.minY - glyphRect.maxY, glyphRect.minY - rect.maxY, 0)
                clearance = min(clearance, max(0, min(1, (hypot(dx, dy) - 8) / 24)))
            }
            let fadeIn = min(1, age / 0.09)
            let opacity = fadeIn * pow(1 - progress, 1.7) * (isDark ? 0.62 : 0.46) * clearance
            guard opacity > 0.008, glyphRect.intersects(dirtyRect) else { continue }
            context.saveGState()
            context.setAlpha(opacity)
            context.setFillColor(palette[particle.tint])
            context.translateBy(x: point.x, y: point.y)
            context.scaleBy(x: scale, y: -scale)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -glyph.width / 2, y: -5)
            CTLineDraw(glyph.line, context)
            context.restoreGState()
        }
    }
}
