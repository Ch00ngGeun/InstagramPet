import AppKit
import PetCore
import PetSources

/// One soft white slime blob with a thin source-coloured rim. It flattens at a screen edge or neighbour,
/// and stretches and jiggles when it moves. Idle blobs stay still.
final class BubbleView: NSView {
    static let font = NSFont.systemFont(ofSize: 14)
    static let timeFont = NSFont.systemFont(ofSize: 10)
    /// Slime shapes (wrap width, line limit): natural, wider and flatter, narrower and taller. Text always fits.
    static let shapes: [(wrap: CGFloat, lines: Int)] = [(150, 4), (210, 3), (110, 6)]
    static let pad: CGFloat = 24
    // Text sits in the ellipse's inscribed box, which is 1/sqrt(2) of the ellipse.
    static let inscribe: CGFloat = 1.42
    /// `margin`: drawing room around the body for the bulge, stretch and soft shadow.
    /// `tailRoom` < 0: neighbours' bodies overlap by 2×6pt and flatten against each other, sticking together.
    /// The text box is the ellipse's inscribed box, so this flattening never reaches the text.
    static let margin: CGFloat = 70, tailRoom: CGFloat = -6
    /// The drawn blob bulges past its body, so a blob resting against an edge or neighbour flattens there.
    static let bulge: CGFloat = 1.07
    private static let clock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "a h:mm"; return f }()
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private(set) var event: PetEvent?
    private var wobble: [CGFloat] = Array(repeating: 0, count: 32)
    private var velocity = NSPoint.zero
    // Count invalidation requests, including offscreen views whose AppKit dirty flag is cleared immediately.
    private(set) var redrawRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redrawRequests += 1 }; super.needsDisplay = newValue }
    }
    var onClick: ((PetEvent) -> Void)?
    /// Solver output: the footprint rect (body + tailRoom) in superview coordinates, and the shape.
    var goal = NSRect.zero
    var shape = 0 { didSet { messageField.maximumNumberOfLines = Self.shapes[shape].lines; needsLayout = true } }
    /// Screen edges and neighbours, in superview coordinates.
    var walls: [Wall] = [] { didSet { if walls != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        messageField.font = Self.font
        messageField.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        messageField.maximumNumberOfLines = Self.shapes[0].lines
        messageField.lineBreakMode = .byWordWrapping
        messageField.alignment = .center
        messageField.cell?.wraps = true
        messageField.cell?.usesSingleLineMode = false
        timeField.font = Self.timeFont
        timeField.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        timeField.alignment = .center
        [messageField, timeField].forEach { $0.isSelectable = false; addSubview($0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Rendering is intentionally bounded. The entire event never enters a log.
    static func message(_ event: PetEvent) -> String { String(event.text.prefix(360)) }
    static func time(_ event: PetEvent) -> String { PetEvent.date(event.observedAt).map { clock.string(from: $0) } ?? "" }

    static func bodySize(for event: PetEvent, shape: Int) -> NSSize {
        let (wrap, lines) = shapes[shape]
        // Labels pad their text by a few points, so measure narrower than the field will be.
        let text = (message(event) as NSString).boundingRect(with: NSSize(width: wrap - 8, height: 2000), options: [.usesLineFragmentOrigin], attributes: [.font: font]).size
        let time = (time(event) as NSString).size(withAttributes: [.font: timeFont])
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let width = min(wrap, max(48, ceil(text.width) + 8, ceil(time.width) + 4))
        let height = min(ceil(text.height), line * CGFloat(lines)) + 4 + 16
        return NSSize(width: width * inscribe + pad, height: height * inscribe + pad / 2)
    }
    static func footprint(for event: PetEvent, shape: Int) -> NSSize {
        let body = bodySize(for: event, shape: shape)
        return NSSize(width: body.width + 2 * tailRoom, height: body.height + 2 * tailRoom)
    }

    private var bodyRect: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    var blob: NSBezierPath {
        Slime.path(in: bodyRect, wobble: wobble, bulge: Self.bulge, velocity: velocity,
                   walls: walls.map { $0.local(to: self) })
    }

    private static let sourceColours: [PetSource: [NSColor]] = [
        .instagram: [NSColor(calibratedRed: 0.96, green: 0.36, blue: 0.29, alpha: 1),
                     NSColor(calibratedRed: 0.93, green: 0.24, blue: 0.55, alpha: 1),
                     NSColor(calibratedRed: 0.64, green: 0.30, blue: 0.85, alpha: 1)],
        .kakao: [NSColor(calibratedRed: 254.0 / 255, green: 229.0 / 255, blue: 0, alpha: 1)],
        .messages: [NSColor(calibratedRed: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255, alpha: 1)]
    ]

    /// AppKit's CGPath property requires macOS 14; keep this renderer compatible with macOS 13.
    private static func outline(_ path: NSBezierPath) -> CGPath {
        if #available(macOS 14.0, *) { return path.cgPath }
        let result = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &points) {
            case .moveTo: result.move(to: points[0])
            case .lineTo: result.addLine(to: points[0])
            case .curveTo: result.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: result.closeSubpath()
            default: break // quadratic elements are available only on macOS 14+ above
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = blob
        Slime.fill(path)
        guard let source = event?.source, let colours = Self.sourceColours[source] else { return }
        NSGraphicsContext.saveGraphicsState()
        let tint = colours[colours.count / 2]
        let glow = NSShadow()
        glow.shadowColor = tint.withAlphaComponent(0.44)
        glow.shadowBlurRadius = 7
        glow.shadowOffset = .zero
        glow.set()
        tint.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1.25
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Clip the gradient to the rim so the message surface remains white.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(Self.outline(path))
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        let gradientColours = colours.count == 1 ? [colours[0], colours[0]] : colours
        NSGradient(colors: gradientColours)?.draw(in: path.bounds.insetBy(dx: -2, dy: -2), angle: 35)
        context.restoreGState()
    }

    override func layout() {
        super.layout()
        let body = bodyRect
        let width = (body.width - Self.pad) / Self.inscribe, height = (body.height - Self.pad / 2) / Self.inscribe
        let box = NSRect(x: body.midX - width / 2, y: body.midY - height / 2, width: width, height: height)
        timeField.frame = NSRect(x: box.minX - 10, y: box.minY, width: box.width + 20, height: 13)
        messageField.frame = NSRect(x: box.minX, y: box.minY + 16, width: box.width, height: box.height - 16)
    }

    func show(_ event: PetEvent) {
        self.event = event
        wobble = Slime.wobble(event.identity)
        messageField.stringValue = Self.message(event)
        timeField.stringValue = Self.time(event)
        let destination = event.source == .instagram ? "Google Chrome" : event.source.title
        setAccessibilityLabel("\(event.source.title), \(timeField.stringValue): \(messageField.stringValue)")
        setAccessibilityHelp("\(event.source.title) message. Click to open \(destination). Right-click to hide bubbles for a while.")
        toolTip = "\(event.source.title) · Open in \(destination) · Right-click to hide for a while"
        needsLayout = true; needsDisplay = true
    }

    /// The footprint where the blob is right now (equal to `goal` at rest).
    var footprintNow: NSRect { frame.insetBy(dx: Self.margin - Self.tailRoom, dy: Self.margin - Self.tailRoom) }

    /// A collision push: moves now and feeds the jelly, so a shoved blob squashes and wobbles.
    func shove(_ push: NSPoint) {
        // Subpixel round-off at flush contacts must not keep a resting spring and redraws alive.
        guard max(abs(push.x), abs(push.y)) > 0.0001 else { return }
        frame = frame.offsetBy(dx: push.x, dy: push.y)
        velocity = NSPoint(x: velocity.x + push.x * 0.5, y: velocity.y + push.y * 0.5)
        needsDisplay = true
    }

    /// A damped spring toward the solver's goal: it lags (satellite), overshoots a little and settles (jelly).
    func step(animated: Bool) {
        let target = goal.insetBy(dx: Self.tailRoom - Self.margin, dy: Self.tailRoom - Self.margin)
        let previousFrame = frame, previousVelocity = velocity, previousAlpha = alphaValue
        if !animated || frame == .zero {
            if frame != target { frame = target }
            velocity = .zero
            if alphaValue != 1 { alphaValue = 1 }
        } else {
            let next = Slime.spring(frame, &velocity, toward: target)
            if next != frame { frame = next }
            if alphaValue < 1 { alphaValue = min(1, alphaValue + 0.15) }
        }
        if frame.size != previousFrame.size { needsLayout = true }
        if frame != previousFrame || velocity != previousVelocity || alphaValue != previousAlpha { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return blob.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseUp(with event: NSEvent) { if let shown = self.event { onClick?(shown) } }
    override func menu(for event: NSEvent) -> NSMenu? { (superview as? BubbleField)?.contextMenu }
    override func accessibilityPerformPress() -> Bool { if let shown = event { onClick?(shown) }; return true }
}
