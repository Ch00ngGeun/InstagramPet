import AppKit
import PetCore
import PetSources

// 펫 캐릭터 뷰: 스프라이트를 가로 띠로 나눠 그리고, 잡아 끌면 젤리처럼 늘어나며 화면 가장자리에 눌리면 찌그러진다.

final class CatView: NSView {
    /// 고정된 스프라이트 높이. 뷰가 스프라이트보다 커서 젤리처럼 기울 여유가 생긴다.
    static let spriteHeight: CGFloat = 338
    /// 벽에 눌린 부풀음과 그와 동시에 생기는 몸의 끌림 자국을 담을 만큼의 투명한 여유.
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
    // 젤리 끌기: 잡은 곳 주변만 끄는 방향으로 높이의 최대 15%까지 옮겨진다. 몸에서 멀어지게 당기면
    // 늘어나고, 몸 쪽으로 밀면 찌그러진다(머리를 잡고 아래로, 발을 잡고 위로, 가방을 잡고 왼쪽으로 …).
    // 반대쪽은 모양을 그대로 유지한다.
    private var grab: CGFloat = 0, grabSide: CGFloat = 0 // 잡은 높이 0(발)…1(머리), 좌우 −1…1
    private var lag = NSPoint.zero
    static let maxTrail: CGFloat = 0.15
    /// 펫이 각 화면 가장자리(왼쪽, 오른쪽, 아래, 위)에 눌린 깊이와 그 스프링.
    private var squash: [CGFloat] = [0, 0, 0, 0], squashVelocity: [CGFloat] = [0, 0, 0, 0], pressTarget: [CGFloat] = [0, 0, 0, 0]
    /// 뷰 좌표의 보이는 화면 영역. 찌그러진 몸은 이 밖으로 퍼지지 않는다.
    var area: NSRect?
    /// 끄는 동안 포인터가 원하는 창 원점을 넘겨받는다. 소유자가 이를 제한하고 눌림을 정한다.
    var onDragTo: ((NSPoint) -> Void)?
    // 번들에 든 오려낸 캐릭터, 또는 사용자가 추가한 캐릭터. .app 번들 밖에서 실행할 때만 없다.
    var sprite = Bundle.main.image(forResource: "pet") { didSet { opaqueRows = Self.rows(of: sprite); needsDisplay = true } }
    /// 아래에서 위로 줄마다 불투명한 가로 구간. 스프라이트마다 캐시하며, 투명 픽셀은 벽 접촉으로 치지 않는다.
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

    /// 캐릭터가 그려지는 영역. 투명한 곳은 클릭이 아래로 통과하게 하는 데 쓴다.
    var spriteRect: NSRect {
        guard let size = sprite?.size, size.height > 0 else { return bounds }
        let height = min(Self.spriteHeight, bounds.height), width = height * size.width / size.height
        return NSRect(x: bounds.midX - width / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// 이 깊이만큼 벽에 눌린다. 0이면 몸이 (통통 튀며) 원래대로 돌아온다.
    func press(left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat, immediately: Bool = false) {
        let size = spriteRect.size
        pressTarget = [min(left, size.width * 0.8), min(right, size.width * 0.8), min(bottom, size.height * 0.8), min(top, size.height * 0.8)]
        if immediately { squash = pressTarget; squashVelocity = [0, 0, 0, 0] }
    }
    /// 지금 몸의 실제 외곽(뷰 좌표): 벽에 납작해진 모양과 부풀음을 포함한다.
    /// 말풍선은 이것을 기준으로 둘러서고 부딪치므로, 찌그러진 펫 옆에도 틈 없이 다가온다.
    var bodyRect: NSRect {
        strips(in: spriteRect).reduce(NSRect.null) { $0.union($1.destination) }
    }

    var isSquashed: Bool { squash.contains { abs($0) > 0.3 } || pressTarget.contains { $0 > 0 } }

    /// 지난 틱 이후 창이 움직인 양(틱당 pt)을 넣어 준다.
    func shake(by motion: NSPoint) {
        for i in 0..<4 {
            squashVelocity[i] = squashVelocity[i] * 0.55 + (pressTarget[i] - squash[i]) * 0.3
            squash[i] = max(-3, squash[i] + squashVelocity[i]) // 놓았을 때 원래 모양을 아주 조금만 지나쳐 튕긴다
            if abs(squash[i] - pressTarget[i]) + abs(squashVelocity[i]) < 0.05 { squash[i] = pressTarget[i]; squashVelocity[i] = 0 }
        }
    }

    /// 몸(조금 늦게 따라옴)에서 포인터까지의 거리: 잡은 부분이 정확히 이만큼 옮겨져
    /// 커서 아래에 머무르고, 마우스와 1:1로 찌그러지거나 늘어난다.
    func setPull(_ offset: NSPoint) {
        lag = offset
        needsDisplay = true
    }

    /// 펫을 잡은 높이(0 발 … 1 머리). 마우스를 누를 때 정하며, 미리보기와 점검에서도 쓴다.
    func hold(at height: CGFloat, side: CGFloat = 0) { grab = max(0, min(1, height)); grabSide = max(-1, min(1, side)) }

    /// 한 지점(x: 0 왼쪽 … 1 오른쪽, t: 0 발 … 1 머리)이 잡은 부분과 함께 움직이는 정도:
    /// 잡은 지점에서 1, 손 한 뼘쯤 떨어지면 부드럽게 0이 된다.
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
            // 찌그러지지 않았을 때의 머리 자리가 아니라, 실제(찌그러졌을 수 있는) 머리 위에 얹힌다.
            let body = bodyRect.offsetBy(dx: 0, dy: rect.minY - spriteRect.minY)
            heart.draw(at: NSPoint(x: min(body.maxX - 4, bounds.maxX - 24), y: body.maxY - 34 + sin(phase) * 3), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: pink])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    struct Strip {
        /// 정규화된 원본 사각형. 렌더링과 기하 점검이 함께 쓴다.
        let source: NSRect
        let destination: NSRect
    }

    private func opaqueSpan(from t0: CGFloat, to t1: CGFloat) -> (CGFloat, CGFloat) {
        guard !opaqueRows.isEmpty else { return (0, 1) }
        // 이미지 보간이 샘플링하는 이웃 원본 픽셀까지 포함한다.
        let first = max(0, Int(t0 * CGFloat(opaqueRows.count)) - 1)
        let last = min(opaqueRows.count, Int(ceil(t1 * CGFloat(opaqueRows.count))) + 1)
        return opaqueRows[first..<last].reduce((1, 0)) { (min($0.0, $1.0), max($0.1, $1.1)) }
    }

    /// 공유되는 순서 있는 띠 경계: 깊게 눌러도 이미지 줄이 접히거나 사라지지 않는다.
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
        // 자유롭게 끌 때의 1:1 당김은 유지한다. 이웃 줄의 순서를 뒤집을 만큼 불가능한 압축만
        // 제한하며, 모든 띠는 원래 높이의 10분의 1 이상을 유지한다.
        var verticalPull: CGFloat = 1
        for i in 0..<n {
            let change = lag.y * (weights[i + 1] - weights[i])
            if change < 0 { verticalPull = min(verticalPull, 0.9 * height / CGFloat(n) / -change) }
        }
        var edges = (0...n).map { minY + height * CGFloat($0) / CGFloat(n) + lag.y * verticalPull * weights[$0] }
        if let area {
            // 패널이 아직 마우스를 따라가는 중이어도 벽은 화면에 속한다.
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

    /// 합의한 가로 띠 렌더러를 유지한다. 같은 기하로 말풍선 자리도 정한다.
    private func drawSquashed(_ sprite: NSImage, in rect: NSRect) {
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        for strip in strips(in: rect) {
            // 작은 원본 이미지를 따로 잘라 쓰지 않고 공유된 대상 클립으로 잘라 그린다. 원본 조각마다
            // 따로 리샘플링하면 투명한 가로 이음매가 생긴다.
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
