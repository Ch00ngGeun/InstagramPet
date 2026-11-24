import AppKit
import PetCore
import PetSources

final class CatView: NSView {
    /// Fixed sprite height, so the view can be larger than the sprite and leave room for the jelly lean.
    static let spriteHeight: CGFloat = 338
    /// Enough transparent room for the wall bulge and the body's simultaneous drag trail.
    static let room: CGFloat = 172
    static let size = NSSize(width: 480, height: spriteHeight + 2 * room)
    var phase: CGFloat = 0
    var excited = false
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var petMenu: NSMenu?
    private var dragStart: NSPoint?
    private var initialOrigin: NSPoint?
    private var dragged = false
    private(set) var isDragging = false
    // Jelly drag: only the area around the grabbed spot is moved, by up to 15% of the height, in the drag
    // direction. Pulled away from the body it stretches; pushed into the body it squashes (head held and
    // moved down, feet held and moved up, bag held and moved left, …). The far side keeps its shape.
    private var grab: CGFloat = 0, grabSide: CGFloat = 0 // grabbed height 0 (feet)…1 (head), side −1…1
    private var lag = NSPoint.zero
    static let maxTrail: CGFloat = 0.15
    /// How far the pet is pressed into each screen edge (left, right, bottom, top), and its spring.
    private var squash: [CGFloat] = [0, 0, 0, 0], squashVelocity: [CGFloat] = [0, 0, 0, 0], pressTarget: [CGFloat] = [0, 0, 0, 0]
    /// Visible screen area in view coordinates; the squashed body never spreads past it.
    var area: NSRect?
    /// Called while dragging with the window origin the pointer asks for; the owner clamps it and sets the press.
    var onDragTo: ((NSPoint) -> Void)?
    // Bundled cutout character, or one the user added; missing only when run outside the .app bundle.
    var sprite = Bundle.main.image(forResource: "pet") { didSet { opaqueRows = Self.rows(of: sprite); needsDisplay = true } }
    /// Bottom-to-top alpha spans, cached per sprite; transparent pixels do not count as wall contact.
    private lazy var opaqueRows = Self.rows(of: sprite)
    private static func rows(of sprite: NSImage?) -> [(CGFloat, CGFloat)] {
        guard let image = sprite?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let bitmap = NSBitmapImageRep(cgImage: image), width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        return (0..<height).map { row in
            var left = width, right = 0
            for x in 0..<width where (bitmap.colorAt(x: x, y: height - row - 1)?.alphaComponent ?? 0) > 0 {
                left = min(left, x); right = max(right, x + 1)
            }
            return left < right ? (CGFloat(left) / CGFloat(width), CGFloat(right) / CGFloat(width)) : (0, 1)
        }
    }
    private let pink = NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.52, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Instagram Pet")
        setAccessibilityHelp("Drag to move. Click to show or dismiss the latest message. Right-click for controls.")
        toolTip = "Drag me · Click for latest message · Right-click for controls"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The character's drawn area, used so transparent space stays click-through.
    var spriteRect: NSRect {
        guard let size = sprite?.size, size.height > 0 else { return bounds }
        let height = min(Self.spriteHeight, bounds.height), width = height * size.width / size.height
        return NSRect(x: bounds.midX - width / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// Pressed into walls by these depths; 0 lets the body spring back (with a bounce).
    func press(left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat, immediately: Bool = false) {
        let size = spriteRect.size
        pressTarget = [min(left, size.width * 0.8), min(right, size.width * 0.8), min(bottom, size.height * 0.8), min(top, size.height * 0.8)]
        if immediately { squash = pressTarget; squashVelocity = [0, 0, 0, 0] }
    }
    /// The body's real outline right now (view coordinates): flattened against walls, with its bulge.
    /// Bubbles orbit and collide with this, so they close in on a squashed pet instead of leaving a gap.
    var bodyRect: NSRect {
        strips(in: spriteRect).reduce(NSRect.null) { $0.union($1.destination) }
    }

    var isSquashed: Bool { squash.contains { abs($0) > 0.3 } || pressTarget.contains { $0 > 0 } }

    /// Feed the window's movement since the last tick (points per tick).
    func shake(by motion: NSPoint) {
        for i in 0..<4 {
            squashVelocity[i] = squashVelocity[i] * 0.55 + (pressTarget[i] - squash[i]) * 0.3
            squash[i] = max(-3, squash[i] + squashVelocity[i]) // only a slight rebound past round when released
            if abs(squash[i] - pressTarget[i]) + abs(squashVelocity[i]) < 0.05 { squash[i] = pressTarget[i]; squashVelocity[i] = 0 }
        }
    }

    /// The pointer's offset from where the body is (the body follows a little behind): the grabbed area is
    /// moved by exactly this much, so it stays under the cursor and squashes or stretches 1:1 with the mouse.
    func setPull(_ offset: NSPoint) {
        lag = offset
        needsDisplay = true
    }

    /// Where the pet is held (0 feet … 1 head); set on mouse-down, also used by previews.
    func hold(at height: CGFloat, side: CGFloat = 0) { grab = max(0, min(1, height)); grabSide = max(-1, min(1, side)) }

    /// How much a spot (x: 0 left … 1 right, t: 0 feet … 1 head) moves with the grabbed area:
    /// 1 at the grabbed spot, fading smoothly to 0 about a hand's length away.
    private func pull(x: CGFloat, t: CGFloat) -> CGFloat {
        let sprite = spriteRect.size, sigma: CGFloat = 60
        let dx = (x - (grabSide + 1) / 2) * sprite.width, dy = (t - grab) * sprite.height
        return exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bob = isSquashed || isDragging ? 0 : sin(phase) * (excited ? 4 : 1.5)
        let rect = spriteRect.offsetBy(dx: 0, dy: bob)
        NSGraphicsContext.saveGraphicsState()
        if let sprite { drawSquashed(sprite, in: rect) }
        if excited {
            let heart: NSString = "♥"
            // Rides on the real (possibly squashed) head, not where the head would be unsquashed.
            let body = bodyRect.offsetBy(dx: 0, dy: rect.minY - spriteRect.minY)
            heart.draw(at: NSPoint(x: min(body.maxX - 4, bounds.maxX - 24), y: body.maxY - 34 + sin(phase) * 3), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: pink])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    struct Strip {
        /// Normalized source rectangle, shared with the render and geometry checks.
        let source: NSRect
        let destination: NSRect
    }

    private func opaqueSpan(from t0: CGFloat, to t1: CGFloat) -> (CGFloat, CGFloat) {
        guard !opaqueRows.isEmpty else { return (0, 1) }
        // Include neighbouring source pixels sampled by image interpolation.
        let first = max(0, Int(t0 * CGFloat(opaqueRows.count)) - 1)
        let last = min(opaqueRows.count, Int(ceil(t1 * CGFloat(opaqueRows.count))) + 1)
        return opaqueRows[first..<last].reduce((1, 0)) { (min($0.0, $1.0), max($0.1, $1.1)) }
    }

    /// Shared, ordered strip boundaries: a deep squeeze cannot fold or discard any image rows.
    func strips(in rect: NSRect) -> [Strip] {
        let l = squash[0], r = squash[1], b = squash[2], t = squash[3]
        guard isSquashed || abs(lag.x) + abs(lag.y) > 0.3 else {
            return [Strip(source: NSRect(x: 0, y: 0, width: 1, height: 1), destination: rect)]
        }
        let squeezeX = l + r, squeezeY = b + t
        let width = max(rect.width * 0.2, rect.width - squeezeX), height = max(rect.height * 0.2, rect.height - squeezeY)
        let minX = l >= r ? rect.minX : rect.maxX - width
        let minY = b >= t ? rect.minY : rect.maxY - height
        let n = max(48, Int(height / 2)), column = (grabSide + 1) / 2
        let weights = (0...n).map { pull(x: column, t: CGFloat($0) / CGFloat(n)) }
        // Preserve the free drag's 1:1 pull. Only limit an impossible compression that would
        // reverse neighbouring rows; every strip retains at least a tenth of its base height.
        var verticalPull: CGFloat = 1
        for i in 0..<n {
            let change = lag.y * (weights[i + 1] - weights[i])
            if change < 0 { verticalPull = min(verticalPull, 0.9 * height / CGFloat(n) / -change) }
        }
        var edges = (0...n).map { minY + height * CGFloat($0) / CGFloat(n) + lag.y * verticalPull * weights[$0] }
        if let area {
            // The wall belongs to the screen, even while the panel is still following the mouse.
            let shift: CGFloat
            if pressTarget[2] > 0 && pressTarget[2] >= pressTarget[3] { shift = area.minY - edges[0] }
            else if pressTarget[3] > 0 { shift = area.maxY - edges[n] }
            else { shift = max(0, area.minY - edges[0]) - max(0, edges[n] - area.maxY) }
            edges = edges.map { $0 + shift }
        }
        var ends: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
        var horizontalPull: CGFloat = 1
        for i in 0..<n {
            let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n), tm = (t0 + t1) / 2
            let swell = squeezeX * 0.55 * sin(.pi * tm)
            let nearWall = b >= t ? 1 - tm : tm
            let spread = squeezeY * 0.4 * pow(sin(.pi / 2 * (0.25 + 0.75 * nearWall)), 2)
            var x0 = minX - spread - (r > l ? swell : 0), x1 = minX + width + spread + (l >= r && l > 0 ? swell : 0)
            if l > 0 && r > 0 { x0 = minX - swell / 2 - spread; x1 = minX + width + swell / 2 + spread }
            let dx0 = lag.x * pull(x: 0, t: tm), dx1 = lag.x * pull(x: 1, t: tm)
            if dx1 < dx0 { horizontalPull = min(horizontalPull, 0.9 * (x1 - x0) / (dx0 - dx1)) }
            ends.append((x0, x1, dx0, dx1))
        }
        let unclamped: [Strip] = (0..<n).map { i in
            let end = ends[i], x0 = end.0 + horizontalPull * end.2, x1 = end.1 + horizontalPull * end.3
            let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n), span = opaqueSpan(from: t0, to: t1)
            return Strip(source: NSRect(x: span.0, y: t0, width: span.1 - span.0, height: t1 - t0),
                         destination: NSRect(x: x0 + span.0 * (x1 - x0), y: edges[i],
                                             width: (span.1 - span.0) * (x1 - x0), height: edges[i + 1] - edges[i]))
        }
        let left = unclamped.map { $0.destination.minX }.min() ?? minX
        let right = unclamped.map { $0.destination.maxX }.max() ?? minX + width
        var shiftX: CGFloat = 0
        if let area {
            if pressTarget[0] > 0 && pressTarget[0] >= pressTarget[1] { shiftX = area.minX - left }
            else if pressTarget[1] > 0 { shiftX = area.maxX - right }
            else { shiftX = max(0, area.minX - left) - max(0, right - area.maxX) }
        }
        return unclamped.map { strip in
            Strip(source: strip.source, destination: strip.destination.offsetBy(dx: shiftX, dy: 0))
        }
    }

    /// Keep the agreed horizontal-strip renderer; the same geometry also places the bubbles.
    private func drawSquashed(_ sprite: NSImage, in rect: NSRect) {
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        for strip in strips(in: rect) {
            // Crop with a shared destination clip, not separate tiny source images: resampling
            // each source crop independently introduces transparent horizontal seams.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
            NSBezierPath(rect: strip.destination).addClip()
            let fullHeight = strip.destination.height / strip.source.height
            let fullWidth = strip.destination.width / strip.source.width
            let full = NSRect(x: strip.destination.minX - strip.source.minX * fullWidth,
                              y: strip.destination.minY - strip.source.minY * fullHeight,
                              width: fullWidth, height: fullHeight)
            sprite.draw(in: full, from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        let point = convert(event.locationInWindow, from: nil), sprite = spriteRect
        grab = max(0, min(1, (point.y - sprite.minY) / sprite.height))
        grabSide = max(-1, min(1, (point.x - sprite.midX) / (sprite.width / 2)))
        isDragging = true
        dragStart = NSEvent.mouseLocation
        initialOrigin = window?.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = initialOrigin else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - start.x, dy = point.y - start.y
        if abs(dx) + abs(dy) > 4 { dragged = true }
        guard dragged else { return }
        let next = NSPoint(x: origin.x + dx, y: origin.y + dy)
        if let onDragTo { onDragTo(next) } else { window?.setFrameOrigin(next) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        NSCursor.openHand.set()
        isDragging = false
        dragStart = nil; initialOrigin = nil
    }
    override func menu(for event: NSEvent) -> NSMenu? { petMenu }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
