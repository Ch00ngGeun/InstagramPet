import AppKit
import PetCore
import PetSources

// 말풍선과 숨기기 화살표가 함께 쓰는 슬라임 외곽선 그리기와 스프링 물리, 그리고 외곽선을 납작하게 누르는 Wall.

/// 슬라임이 넘을 수 없는 경계: dot(p - point, normal) > 0인 점은 선 위로 되밀린다.
/// `zone`(이웃 타원의 경계)이 있으면 그 이웃 안쪽의 점만 되밀어서,
/// 납작한 면이 슬라임을 길게 가로지르지 않고 실제로 맞닿은 곳만 덮는다.
struct Wall: Equatable {
    var point: NSPoint
    var normal: NSPoint
    var zone: NSRect? = nil
    func local(to view: NSView) -> Wall {
        Wall(point: view.convert(point, from: view.superview), normal: normal, zone: zone.map { view.convert($0, from: view.superview) })
    }
}

/// 메시지 슬라임과 숨기기 화살표가 함께 쓰는 부드러운 흰 슬라임.
enum Slime {
    /// 시드마다 고정된 울퉁불퉁한 외곽(FNV-1a)이라 슬라임마다 다르지만 깜빡이지 않는다. 낮은 주파수의
    /// 굴곡(한 바퀴에 2개와 3개)만 써서 뾰족한 곳 없이 부드럽다.
    static func wobble(_ seed: String, count: Int = 32, amount: CGFloat = 0.07) -> [CGFloat] {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let phase2 = CGFloat(hash & 0xffff) / 0xffff * 2 * .pi, phase3 = CGFloat((hash >> 16) & 0xffff) / 0xffff * 2 * .pi
        return (0..<count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            return amount * (0.6 * sin(2 * angle + phase2) + 0.4 * sin(3 * angle + phase3))
        }
    }

    /// `body` 둘레의 울퉁불퉁한 타원. `velocity` 방향으로 늘어나고(젤리) `walls`에 대고 납작해진다(로컬 좌표).
    static func path(in body: NSRect, wobble: [CGFloat], bulge: CGFloat, velocity: NSPoint, walls: [Wall]) -> NSBezierPath {
        let center = NSPoint(x: body.midX, y: body.midY)
        let a = body.width / 2 * bulge, b = body.height / 2 * bulge
        let speed = hypot(velocity.x, velocity.y)
        let ux = speed > 0.01 ? velocity.x / speed : 1, uy = speed > 0.01 ? velocity.y / speed : 0
        // 펫처럼: 앞쪽 가장자리는 따라붙고, 뒤쪽 가장자리는 뒤처져 끌려 나온다.
        let drag = min(min(a, b) * 0.8, speed * 1.6)
        var points: [NSPoint] = wobble.indices.map { index in
            let angle = CGFloat(index) / CGFloat(wobble.count) * 2 * .pi
            let r = 1 + wobble[index]
            let dx = a * r * cos(angle), dy = b * r * sin(angle)
            let facing = (dx * ux + dy * uy) / max(1, hypot(dx, dy)) // 앞쪽에서 1, 뒤쪽에서 −1
            let behind = pow(max(0, (1 - facing) / 2), 1.5)
            return NSPoint(x: center.x + dx - ux * drag * behind, y: center.y + dy - uy * drag * behind)
        }
        func press(_ walls: [Wall]) {
            for wall in walls {
                for index in points.indices {
                    let p = points[index]
                    let depth = (p.x - wall.point.x) * wall.normal.x + (p.y - wall.point.y) * wall.normal.y
                    guard depth > 0 else { continue }
                    // 이웃 안쪽: 완전히 납작하게 눌린다. 그 테두리를 넘어가며 점점 약해져서, 납작한 면이
                    // 눌리지 않은 점 옆에 홈을 남기지 않고 곡선으로 이어진다.
                    var weight: CGFloat = 1
                    if let zone = wall.zone {
                        let ex = (p.x - zone.midX) / (zone.width / 2), ey = (p.y - zone.midY) / (zone.height / 2)
                        weight = max(0, min(1, (1.6 - sqrt(ex * ex + ey * ey)) / 0.6))
                    }
                    points[index] = NSPoint(x: p.x - wall.normal.x * depth * weight, y: p.y - wall.normal.y * depth * weight)
                }
            }
        }
        press(walls)
        // 꺾임 풀기: 각 점을 이웃 두 점의 중점 쪽으로 절반 옮긴다(부드러운 슬라임 테두리).
        for _ in 0..<2 {
            let copy = points, n = copy.count
            points = copy.indices.map { i in
                let a = copy[(i + n - 1) % n], b = copy[(i + 1) % n], p = copy[i]
                return NSPoint(x: p.x * 0.5 + (a.x + b.x) * 0.25, y: p.y * 0.5 + (a.y + b.y) * 0.25)
            }
        }
        // 화면 가장자리는 단단하다: 그 밖으로는 아무것도 그리지 않는다.
        press(walls.filter { $0.zone == nil })
        // 점들을 지나는 닫힌 Catmull-Rom 스플라인: 둥글고 부드러운 슬라임 가장자리.
        let path = NSBezierPath(), n = points.count
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            path.curve(to: p2, controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.close()
        return path
    }

    static func fill(_ path: NSBezierPath, alpha: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.28 * alpha)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(calibratedWhite: 1, alpha: alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `target`을 향한 감쇠 스프링 한 틱: 뒤따라오다 살짝 지나친 뒤 멈춘다.
    static func spring(_ frame: NSRect, _ velocity: inout NSPoint, toward target: NSRect) -> NSRect {
        // 빠르게 따라가되 감쇠가 커서, 가장자리가 뒤처져 늘어났다가 조금만 지나친 뒤 자리 잡는다.
        velocity = NSPoint(x: velocity.x * 0.62 + (target.minX - frame.minX) * 0.15, y: velocity.y * 0.62 + (target.minY - frame.minY) * 0.15)
        let next = NSRect(x: frame.minX + velocity.x, y: frame.minY + velocity.y,
                          width: frame.width + (target.width - frame.width) * 0.2, height: frame.height + (target.height - frame.height) * 0.2)
        let resting = abs(next.minX - target.minX) + abs(next.minY - target.minY) + abs(next.width - target.width) + abs(next.height - target.height) < 0.5
            && hypot(velocity.x, velocity.y) < 0.1
        if resting { velocity = .zero; return target }
        return next
    }
}
