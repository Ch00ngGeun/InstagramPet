import AppKit
import PetCore
import PetSources

/// 얇은 소스 색 테두리를 두른 부드러운 흰 슬라임 하나. 화면 가장자리나 이웃에 닿으면 납작해지고,
/// 움직일 때 늘어나며 출렁인다. 가만히 있는 슬라임은 움직이지 않는다.
final class BubbleView: NSView {
    static let font = NSFont.systemFont(ofSize: 14)
    static let timeFont = NSFont.systemFont(ofSize: 10)
    /// 슬라임 모양(줄바꿈 폭, 최대 줄 수): 기본, 넓고 납작한 모양, 좁고 높은 모양. 글자는 늘 들어간다.
    static let shapes: [(wrap: CGFloat, lines: Int)] = [(150, 4), (210, 3), (110, 6)]
    static let pad: CGFloat = 24
    // 글자는 타원에 내접하는 상자 안에 놓이며, 그 상자는 타원의 1/sqrt(2)다.
    static let inscribe: CGFloat = 1.42
    /// `margin`: 몸 둘레에 부풀음·늘어남·부드러운 그림자를 그릴 여유.
    /// `tailRoom` < 0: 이웃의 몸이 2×6pt 겹치며 서로 납작하게 붙는다.
    /// 글상자는 타원의 내접 상자라서 이렇게 납작해져도 글자까지 닿지 않는다.
    static let margin: CGFloat = 70, tailRoom: CGFloat = -6
    /// 그려지는 슬라임은 몸보다 부풀어 있어서, 가장자리나 이웃에 기대면 그쪽이 납작해진다.
    static let bulge: CGFloat = 1.07
    private static let clock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "a h:mm"; return f }()
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private(set) var event: PetEvent?
    private var wobble: [CGFloat] = Array(repeating: 0, count: 32)
    private var velocity = NSPoint.zero
    // 다시 그리기 요청 횟수를 센다. AppKit이 표시를 바로 지우는 화면 밖 뷰도 포함한다.
    private(set) var redrawRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redrawRequests += 1 }; super.needsDisplay = newValue }
    }
    var onClick: ((PetEvent) -> Void)?
    /// 배치 계산 결과: 상위 뷰 좌표의 footprint 사각형(몸 + tailRoom)과 모양.
    var goal = NSRect.zero
    var shape = 0 { didSet { messageField.maximumNumberOfLines = Self.shapes[shape].lines; needsLayout = true } }
    /// 상위 뷰 좌표의 화면 가장자리와 이웃 벽.
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

    // 표시 길이는 일부러 제한한다. 이벤트 전체가 로그에 남는 일은 없다.
    static func message(_ event: PetEvent) -> String { String(event.text.prefix(360)) }
    static func time(_ event: PetEvent) -> String { PetEvent.date(event.observedAt).map { clock.string(from: $0) } ?? "" }

    static func bodySize(for event: PetEvent, shape: Int) -> NSSize {
        let (wrap, lines) = shapes[shape]
        // 라벨은 글자 둘레에 몇 pt 여백을 두므로, 실제 칸보다 좁게 잰다.
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

    /// AppKit의 cgPath 속성은 macOS 14부터라서, 이 렌더러는 macOS 13과도 호환되게 둔다.
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
            default: break // quadratic 요소는 macOS 14 이상에서만 나오며, 그 경우는 위에서 처리했다
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

        // 그라데이션을 테두리에만 잘라 넣어 메시지 면은 흰색으로 남긴다.
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

    /// 지금 슬라임이 있는 footprint(멈춰 있으면 `goal`과 같다).
    var footprintNow: NSRect { frame.insetBy(dx: Self.margin - Self.tailRoom, dy: Self.margin - Self.tailRoom) }

    /// 충돌로 밀기: 바로 옮기고 출렁임에도 반영해서, 밀린 슬라임이 찌그러지며 흔들린다.
    func shove(_ push: NSPoint) {
        // 딱 붙은 접촉에서 생기는 1pt 미만 반올림 오차가 멈춘 스프링과 다시 그리기를 계속 살려 두면 안 된다.
        guard max(abs(push.x), abs(push.y)) > 0.0001 else { return }
        frame = frame.offsetBy(dx: push.x, dy: push.y)
        velocity = NSPoint(x: velocity.x + push.x * 0.5, y: velocity.y + push.y * 0.5)
        needsDisplay = true
    }

    /// 배치 목표를 향한 감쇠 스프링: 뒤따라오다(위성) 살짝 지나쳤다가 멈춘다(젤리).
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
