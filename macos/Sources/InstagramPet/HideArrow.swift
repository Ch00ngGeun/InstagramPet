import AppKit
import PetCore
import PetSources

/// 꺾쇠 표시가 있는 작은 반투명 슬라임: 말풍선을 잠시 숨기거나, 펫과 말풍선을 일찍 다시 불러온다.
final class HideArrow: NSView {
    /// 배치 계산에 쓰는 슬라임 몸 크기. 뷰는 그림자와 흔들림을 위한 여유를 더한다.
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
    /// 화살표를 끌면 숨은 펫도 함께 옮겨진다. `delta`는 마우스를 누른 뒤 포인터가 움직인 거리다.
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
        // 평소엔 반투명, 뒤에 메시지가 기다리면 더 밝아지고 숨 쉬듯 깜빡인다.
        Slime.fill(blob, alpha: alert ? 0.8 + 0.2 * sin(pulse * 2) : 0.7)
        let body = bodyRect, center = NSPoint(x: body.midX, y: body.midY)
        // 말풍선이 나와 있으면 펫 쪽을 가리키고(“집어넣기”), 집어넣은 동안엔 반대쪽을 가리킨다(“꺼내기”).
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
            // 슬라임 자신의 몸 안에 둬서 화면 가장자리에 잘리지 않게 한다.
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
    // 짧은 클릭만 펫을 다시 불러온다. 끌기는 옮기기만 한다.
    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() } else { onClick?(self) }
        dragStart = nil; dragged = false; isDragging = false
    }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
}
