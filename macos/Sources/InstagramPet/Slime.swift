import AppKit
import PetCore
import PetSources

/// A side of the world a blob may not cross: points with dot(p - point, normal) > 0 are pushed back onto the line.
/// With a `zone` (a neighbour's ellipse bounds) only points inside that neighbour are pushed back, so
/// the flat face covers just the real contact, not a long cut across the blob.
struct Wall: Equatable {
    var point: NSPoint
    var normal: NSPoint
    var zone: NSRect? = nil
    func local(to view: NSView) -> Wall {
        Wall(point: view.convert(point, from: view.superview), normal: normal, zone: zone.map { view.convert($0, from: view.superview) })
    }
}

/// Soft white slime shared by message blobs and the hide arrow.
enum Slime {
    /// A stable lumpy outline per seed (FNV-1a), so blobs differ but never flicker. Only low-frequency
    /// lumps (2 and 3 per turn), so the outline stays soft with no spikes.
    static func wobble(_ seed: String, count: Int = 32, amount: CGFloat = 0.07) -> [CGFloat] {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let phase2 = CGFloat(hash & 0xffff) / 0xffff * 2 * .pi, phase3 = CGFloat((hash >> 16) & 0xffff) / 0xffff * 2 * .pi
        return (0..<count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            return amount * (0.6 * sin(2 * angle + phase2) + 0.4 * sin(3 * angle + phase3))
        }
    }

    /// Lumpy ellipse around `body`, stretched along `velocity` (jelly) and flattened against `walls` (local coordinates).
    static func path(in body: NSRect, wobble: [CGFloat], bulge: CGFloat, velocity: NSPoint, walls: [Wall]) -> NSBezierPath {
        let center = NSPoint(x: body.midX, y: body.midY)
        let a = body.width / 2 * bulge, b = body.height / 2 * bulge
        let speed = hypot(velocity.x, velocity.y)
        let ux = speed > 0.01 ? velocity.x / speed : 1, uy = speed > 0.01 ? velocity.y / speed : 0
        // Like the pet: the leading edge keeps up, the trailing edge lags behind and drags out.
        let drag = min(min(a, b) * 0.8, speed * 1.6)
        var points: [NSPoint] = wobble.indices.map { index in
            let angle = CGFloat(index) / CGFloat(wobble.count) * 2 * .pi
            let r = 1 + wobble[index]
            let dx = a * r * cos(angle), dy = b * r * sin(angle)
            let facing = (dx * ux + dy * uy) / max(1, hypot(dx, dy)) // 1 at the front, −1 at the back
            let behind = pow(max(0, (1 - facing) / 2), 1.5)
            return NSPoint(x: center.x + dx - ux * drag * behind, y: center.y + dy - uy * drag * behind)
        }
        func press(_ walls: [Wall]) {
            for wall in walls {
                for index in points.indices {
                    let p = points[index]
                    let depth = (p.x - wall.point.x) * wall.normal.x + (p.y - wall.point.y) * wall.normal.y
                    guard depth > 0 else { continue }
                    // Inside the neighbour: pressed fully flat. Fading out over its rim, so the flat face
                    // blends into the curve instead of leaving a notch next to an unpressed point.
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
        // Relax kinks: each point moves halfway to the midpoint of its neighbours (soft, slime-like rims).
        for _ in 0..<2 {
            let copy = points, n = copy.count
            points = copy.indices.map { i in
                let a = copy[(i + n - 1) % n], b = copy[(i + 1) % n], p = copy[i]
                return NSPoint(x: p.x * 0.5 + (a.x + b.x) * 0.25, y: p.y * 0.5 + (a.y + b.y) * 0.25)
            }
        }
        // Screen edges stay hard: nothing may be drawn past them.
        press(walls.filter { $0.zone == nil })
        // Closed Catmull-Rom spline through the points: soft, rounded slime edges.
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

    /// One tick of a damped spring toward `target`: lag, a small overshoot, then rest.
    static func spring(_ frame: NSRect, _ velocity: inout NSPoint, toward target: NSRect) -> NSRect {
        // Quick to follow, heavily damped: the edges lag and stretch, then settle with only a small overshoot.
        velocity = NSPoint(x: velocity.x * 0.62 + (target.minX - frame.minX) * 0.15, y: velocity.y * 0.62 + (target.minY - frame.minY) * 0.15)
        let next = NSRect(x: frame.minX + velocity.x, y: frame.minY + velocity.y,
                          width: frame.width + (target.width - frame.width) * 0.2, height: frame.height + (target.height - frame.height) * 0.2)
        let resting = abs(next.minX - target.minX) + abs(next.minY - target.minY) + abs(next.width - target.width) + abs(next.height - target.height) < 0.5
            && hypot(velocity.x, velocity.y) < 0.1
        if resting { velocity = .zero; return target }
        return next
    }
}
