import AppKit
import PetCore
import PetSources

/// Small translucent slime with a chevron: hides bubbles for a while, or brings the pet and bubbles back early.
final class HideArrow: NSView {
    /// The blob's footprint used by the layout solver; the view adds room for shadow and jiggle.
    static let size = NSSize(width: 30, height: 30)
    static let margin: CGFloat = 12
    private let wobble = Slime.wobble("hide-arrow", count: 12, amount: 0.1)
    private var velocity = NSPoint.zero
    private(set) var redrawRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redrawRequests += 1 }; super.needsDisplay = newValue }
    }
    var tucked = false { didSet { if tucked != oldValue { needsDisplay = true } } }
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    var pulse: CGFloat = 0 { didSet { if pulse != oldValue && tucked && count > 0 { needsDisplay = true } } }
    var toward = NSPoint.zero { didSet { if toward != oldValue { needsDisplay = true } } }
    var goal = NSRect.zero
    var walls: [Wall] = [] { didSet { if walls != oldValue { needsDisplay = true } } }
    var onClick: ((HideArrow) -> Void)?
    /// Dragging the arrow carries the hidden pet with it; `delta` is the pointer's travel since mouse-down.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private var dragStart: NSPoint?
    private var dragged = false
    private(set) var isDragging = false

    private var bodyRect: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }
    private var blob: NSBezierPath {
        Slime.path(in: bodyRect, wobble: wobble, bulge: 1, velocity: velocity,
                   walls: walls.map { $0.local(to: self) })
    }

    override func draw(_ dirtyRect: NSRect) {
        let alert = tucked && count > 0
        // Translucent while idle; brighter and breathing when messages wait behind it.
        Slime.fill(blob, alpha: alert ? 0.8 + 0.2 * sin(pulse * 2) : 0.7)
        let body = bodyRect, center = NSPoint(x: body.midX, y: body.midY)
        // Points at the pet while bubbles are out ("tuck them in"), away from it while tucked ("pull them out").
        let aim = convert(toward, from: superview)
        let angle = atan2(aim.y - center.y, aim.x - center.x) + (tucked ? .pi : 0)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: -3, y: -5)); chevron.line(to: NSPoint(x: 3, y: 0)); chevron.line(to: NSPoint(x: -3, y: 5))
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byRadians: angle)
        chevron.transform(using: transform)
        NSColor(calibratedWhite: 0.35, alpha: 0.9).setStroke()
        chevron.lineWidth = 2.2; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
        chevron.stroke()
        if alert {
            let label = count > 99 ? "99+" : "\(count)"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
            let text = (label as NSString).size(withAttributes: attributes)
            let width = max(15, text.width + 6)
            // Inside the blob's own footprint, so a screen edge never cuts it off.
            let badge = NSRect(x: body.maxX - width + 2, y: body.maxY - 13, width: width, height: 15)
            NSColor(calibratedRed: 0.91, green: 0.3, blue: 0.35, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 7.5, yRadius: 7.5).fill()
            (label as NSString).draw(at: NSPoint(x: badge.midX - text.width / 2, y: badge.midY - text.height / 2), withAttributes: attributes)
        }
    }

    private var lastStepFrame = NSRect.zero
    func step(animated: Bool) {
        let target = goal.insetBy(dx: -Self.margin, dy: -Self.margin)
        let previousVelocity = velocity
        if !isDragging {
            let next: NSRect
            if !animated || frame == .zero { next = target; velocity = .zero }
            else { next = Slime.spring(frame, &velocity, toward: target) }
            if frame != next { frame = next }
        }
        if frame != lastStepFrame || velocity != previousVelocity { needsDisplay = true }
        lastStepFrame = frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && bodyRect.insetBy(dx: -4, dy: -4).contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; dragged = false; isDragging = true }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = NSEvent.mouseLocation, delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        if abs(delta.x) + abs(delta.y) > 4 { dragged = true }
        if dragged { onDrag?(delta) }
    }
    // Only a short click brings the pet back; a drag just moves it.
    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() } else { onClick?(self) }
        dragStart = nil; dragged = false; isDragging = false
    }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
}
