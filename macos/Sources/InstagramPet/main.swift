import AppKit
import PetCore
import PetSources

// The application deliberately has no network client. Local sources join Chrome's private queue.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// "Gravity" placement: newest first, each item takes the free spot nearest its orbit slot around the pet,
/// fully inside the visible area and clear of the visible pet and of items already placed.
/// When a slot is off-screen the item slides to the closest spot on-screen, so items huddle where the pet hides.
enum Orbit {
    static let gap: CGFloat = 28, margin: CGFloat = 0, step: CGFloat = 8

    /// While the pet is on screen, bubbles sit on an arc fanned toward its roomiest side, in time order:
    /// read left → right on an arc above or below the pet, top → bottom on an arc to a side; near a corner the
    /// whole arc slides inward. Only once the pet is tucked away past the screen edge do they huddle round,
    /// flush in that corner. Index 0 is the newest bubble.
    static let bubbleCount = 12
    /// Up to four per app (KakaoTalk, Instagram, Messages); one app's burst never pushes out another app's bubbles.
    static let perSource = 4
    /// The inner arc keeps the original five-slot spacing; older bubbles continue on an outer arc.
    static let innerArc = 5

    /// `events` oldest first; keeps the newest `perSource` of each source, still oldest first.
    static func capped(_ events: [PetEvent]) -> [PetEvent] {
        var counts: [PetSource: Int] = [:]
        let kept = events.reversed().filter { event in
            counts[event.source, default: 0] += 1
            return counts[event.source]! <= perSource
        }
        return Array(kept.reversed().suffix(bubbleCount))
    }

    /// Where the tucked-away pet's corner is, or nil while the pet is (mostly) on screen.
    static func tuckCorner(pet: NSRect, area: NSRect) -> NSPoint? {
        let shown = pet.intersection(area)
        guard shown.width * shown.height < pet.width * pet.height * 0.3 else { return nil }
        return NSPoint(x: pet.midX < area.midX ? area.minX : area.maxX, y: pet.midY < area.midY ? area.minY : area.maxY)
    }

    /// The arc's facing (radians): below the feet near the top edge (top corners included), out to the side
    /// along the middle of a side edge, and above the head everywhere else (bottom corners included).
    static func facing(pet: NSRect, area: NSRect) -> CGFloat {
        let above = area.maxY - pet.maxY, below = pet.minY - area.minY
        let left = pet.minX - area.minX, right = area.maxX - pet.maxX
        if above < 170 { return -.pi / 2 }
        if (left < 180 || right < 180) && below >= 120 { return right >= left ? 0 : .pi }
        return .pi / 2
    }

    static func arcGoal(_ slot: Int, size: NSSize, pet: NSRect, facing: CGFloat) -> NSPoint {
        let spread: CGFloat = 95 * .pi / 180, step = 2 * spread / CGFloat(innerArc - 1)
        // Time runs left → right on a mostly horizontal arc and top → bottom on a mostly vertical one:
        // the newest end is the right-hand end, or the lower end.
        let ends = [facing - spread, facing + spread]
        let horizontal = abs(sin(facing)) >= abs(cos(facing)) - 0.01
        let newest = horizontal ? ends.max { cos($0) < cos($1) }! : ends.min { sin($0) < sin($1) }!
        let angle = newest + (newest == ends[0] ? step : -step) * CGFloat(slot)
        let c = cos(angle), s = sin(angle)
        let up = sin(facing) > 0.9, down = sin(facing) < -0.9
        // Anchor near the end of the body the arc wraps (head above, feet below, upper body otherwise).
        let anchor = NSPoint(x: pet.midX, y: up ? pet.maxY - pet.height * 0.18 : down ? pet.minY + pet.height * 0.18 : pet.minY + pet.height * 0.55)
        let radiusY = up || down ? pet.height * 0.18 + gap : pet.height * 0.42 + gap
        let reach = hypot(c * (pet.width / 2 + gap), s * radiusY) + abs(c) * size.width / 2 + abs(s) * size.height / 2
        return NSPoint(x: anchor.x + c * reach, y: anchor.y + s * reach)
    }

    /// Set while the pet is tucked away behind its arrow: the arrow's spot. Bubbles then line up flush along
    /// the screen edge the arrow is on — a row along the top or bottom (left → right), a column along a
    /// side (top → bottom) — centred on the arrow, or huddle round in a corner.
    static var tuckAnchor: NSPoint?

    /// The arrow's rect while tucked: flush on the screen edge (or corner) nearest the anchor.
    static func tuckArrowRect(anchor: NSPoint, area: NSRect) -> NSRect {
        let w = HideArrow.size.width, h = HideArrow.size.height
        return NSRect(x: min(max(anchor.x - w / 2, area.minX), area.maxX - w), y: min(max(anchor.y - h / 2, area.minY), area.maxY - h), width: w, height: h)
    }

    /// The nearest edge point for an anchor anywhere on screen: where a dropped arrow settles.
    static func snapToEdge(_ p: NSPoint, area: NSRect) -> NSPoint {
        let d = [p.x - area.minX, area.maxX - p.x, p.y - area.minY, area.maxY - p.y]
        let hw = HideArrow.size.width / 2, hh = HideArrow.size.height / 2
        var q = NSPoint(x: min(max(p.x, area.minX + hw), area.maxX - hw), y: min(max(p.y, area.minY + hh), area.maxY - hh))
        switch d.firstIndex(of: d.min()!)! {
        case 0: q.x = area.minX + hw
        case 1: q.x = area.maxX - hw
        case 2: q.y = area.minY + hh
        default: q.y = area.maxY - hh
        }
        return q
    }

    /// Tucked layout (no searching, so it always follows the arrow exactly). Bubbles touch each other and the
    /// screen edge, start right beside the arrow and run toward the middle of the edge: a row along the top or
    /// bottom read left → right, a column along a side read top → bottom; in a corner, rows of three stacked
    /// out of the corner. Returns rects newest first.
    static func tuckedRects(_ sizes: [NSSize], anchor: NSPoint, area: NSRect) -> [NSRect] {
        guard !sizes.isEmpty else { return [] }
        let arrow = tuckArrowRect(anchor: anchor, area: area)
        let oldest = Array(sizes.reversed())
        let dl = arrow.minX - area.minX, dr = area.maxX - arrow.maxX, db = arrow.minY - area.minY, dt = area.maxY - arrow.maxY
        let corner: CGFloat = 90
        var rects: [NSRect] = []
        if min(dl, dr) < corner && min(db, dt) < corner {
            let right = dr < dl, top = dt < db
            let rows = stride(from: 0, to: oldest.count, by: 3).map { Array(oldest[$0..<min($0 + 3, oldest.count)]) }
            // Rows read top → bottom, oldest first: at the top the oldest row is the edge row, at the bottom
            // the newest row is.
            var rowRects: [[NSRect]] = [], placed: [NSRect] = []
            for row in (top ? rows : rows.reversed()) {
                let total = row.reduce(0) { $0 + $1.width }
                // Leave the arrow its own spot in the corner on the edge row.
                let inset = rowRects.isEmpty ? arrow.width : 0
                var x = right ? area.maxX - inset - total : area.minX + inset
                var cells: [NSRect] = []
                for size in row {
                    let cell = settle(x: x, size: size, top: top, on: placed, area: area)
                    cells.append(cell); placed.append(cell)
                    x += size.width
                }
                if top { rowRects.append(cells) } else { rowRects.insert(cells, at: 0) }
            }
            rects = rowRects.flatMap { $0 }
        } else if min(db, dt) <= min(dl, dr) {
            let top = dt < db
            // Too many for one row: wrap into further rows, oldest row on the top edge, newest row on the bottom edge.
            var placed: [NSRect] = []
            // Rows never cover the arrow: wrap to the roomier side of it.
            let lines = wrap(oldest, limit: max(arrow.minX - area.minX, area.maxX - arrow.maxX)) { $0.width }
            // Every row starts from the same spot beside the arrow, so wrapped rows stack flush on each other.
            let widest = lines.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0
            var start = arrow.midX < area.midX ? arrow.maxX : arrow.minX - widest
            if start + widest > area.maxX { start = arrow.minX - widest }
            if start < area.minX { start = arrow.maxX }
            start = min(max(start, area.minX), area.maxX - widest)
            let towardRight = start >= arrow.maxX - 1
            for line in top ? lines : lines.reversed() {
                let total = line.reduce(0) { $0 + $1.width }
                // Run from beside the arrow toward the middle.
                var x = towardRight ? start : start + widest - total
                var cells: [NSRect] = []
                for size in line {
                    let cell = settle(x: x, size: size, top: top, on: placed, area: area)
                    cells.append(cell); placed.append(cell)
                    x += size.width
                }
                if top { rects += cells } else { rects.insert(contentsOf: cells, at: 0) }
            }
        } else {
            let right = dr < dl
            // Too many for one column: wrap into further columns stepping in from the edge.
            var x = right ? area.maxX : area.minX
            for line in wrap(oldest, limit: max(arrow.minY - area.minY, area.maxY - arrow.maxY), { $0.height }) {
                let total = line.reduce(0) { $0 + $1.height }, width = line.map(\.width).max() ?? 0
                var top = arrow.midY > area.midY ? arrow.minY : arrow.maxY + total
                if top - total < area.minY { top = arrow.maxY + total }
                if top > area.maxY { top = arrow.minY }
                top = min(max(top, area.minY + total), area.maxY)
                for size in line {
                    // Slide in from the edge until resting against the column already there (no ragged gap).
                    let beside = rects.filter { min($0.maxY, top) - max($0.minY, top - size.height) > 1 }
                    let cx = right ? (beside.map(\.minX).min() ?? area.maxX) - size.width : beside.map(\.maxX).max() ?? area.minX
                    rects.append(NSRect(x: cx, y: top - size.height, width: size.width, height: size.height))
                    top -= size.height
                }
                x += right ? -width : width
            }
        }
        return rects.reversed()
    }

    /// More than five: an arc can't hold them in readable order, so they form a block beside the pet on its
    /// roomiest side — rows of three read left → right, oldest row at the top. Returns centres newest first.
    static func blockGoals(_ sizes: [NSSize], pet: NSRect, area: NSRect) -> [NSPoint] {
        let oldest = Array(sizes.reversed())
        let rows = stride(from: 0, to: oldest.count, by: 3).map { Array(oldest[$0..<min($0 + 3, oldest.count)]) }
        let widths = rows.map { $0.reduce(0) { $0 + $1.width } }, heights = rows.map { $0.map(\.height).max() ?? 0 }
        let w = widths.max() ?? 0, h = heights.reduce(0, +)
        let shown = pet.intersection(area).isEmpty ? pet : pet.intersection(area)
        let body = shown.insetBy(dx: -gap / 2 - 1, dy: -gap / 2 - 1)
        let midY = shown.midY + shown.height * 0.15
        // (block origin, alignment of short rows toward the pet: -1 left, 0 centre, 1 right, room on that side)
        let sides: [(NSPoint, Int, CGFloat)] = [
            (NSPoint(x: body.maxX, y: midY - h / 2), -1, area.maxX - body.maxX - w),
            (NSPoint(x: body.minX - w, y: midY - h / 2), 1, body.minX - area.minX - w),
            (NSPoint(x: shown.midX - w / 2, y: body.maxY), 0, area.maxY - body.maxY - h),
            (NSPoint(x: shown.midX - w / 2, y: body.minY - h), 0, body.minY - area.minY - h)
        ]
        func clamped(_ o: NSPoint) -> NSRect {
            NSRect(x: min(max(o.x, area.minX), area.maxX - w), y: min(max(o.y, area.minY), area.maxY - h), width: w, height: h)
        }
        let fitting = sides.filter { !clamped($0.0).intersects(body) }
        let (origin, align, _) = (fitting.isEmpty ? sides : fitting).max { $0.2 < $1.2 }!
        let block = clamped(origin)
        // Each bubble hangs from the one above it (no row-height gaps).
        var placed: [NSRect] = []
        for (index, row) in rows.enumerated() {
            var x = align < 0 ? block.minX : align > 0 ? block.maxX - widths[index] : block.midX - widths[index] / 2
            for size in row {
                placed.append(settle(x: x, size: size, top: true, on: placed, area: block))
                x += size.width
            }
        }
        return placed.map { NSPoint(x: $0.midX, y: $0.midY) }.reversed()
    }

    /// Drops a bubble straight toward the edge (down onto the bottom, up against the top) until it rests on
    /// whatever is already stacked under it, so uneven heights leave no gaps.
    static func settle(x: CGFloat, size: NSSize, top: Bool, on placed: [NSRect], area: NSRect) -> NSRect {
        let under = placed.filter { min($0.maxX, x + size.width) - max($0.minX, x) > 1 }
        let y = top ? (under.map(\.minY).min() ?? area.maxY) - size.height : under.map(\.maxY).max() ?? area.minY
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Greedy line breaking, order kept: as many as fit within `limit` per line.
    static func wrap(_ sizes: [NSSize], limit: CGFloat, _ length: (NSSize) -> CGFloat) -> [[NSSize]] {
        var lines: [[NSSize]] = [], used: CGFloat = 0
        for size in sizes {
            if lines.isEmpty || used + length(size) > limit { lines.append([]); used = 0 }
            lines[lines.count - 1].append(size); used += length(size)
        }
        // Same number of lines, but evenly filled (12 → 6 + 6 rather than 8 + 4) when that still fits.
        let per = (sizes.count + lines.count - 1) / max(1, lines.count)
        let even = stride(from: 0, to: sizes.count, by: max(1, per)).map { Array(sizes[$0..<min($0 + per, sizes.count)]) }
        return even.count == lines.count && even.allSatisfy({ $0.reduce(0) { $0 + length($1) } <= limit }) ? even : lines
    }

    /// Centres for bubbles of these sizes (newest first).
    static func lineGoals(_ sizes: [NSSize], pet: NSRect, area: NSRect) -> [NSPoint] {
        guard !sizes.isEmpty else { return [] }
        if let corner = tuckCorner(pet: pet, area: area) { return Array(repeating: corner, count: sizes.count) }
        if sizes.count > innerArc { return blockGoals(sizes, pet: pet, area: area) }
        let facing = facing(pet: pet, area: area)
        var goals = sizes.enumerated().map { arcGoal($0.offset, size: $0.element, pet: pet, facing: facing) }
        // Near a corner part of the arc would fall off screen: slide the whole arc inward, keeping its order.
        let rects = zip(goals, sizes).map { NSRect(x: $0.x - $1.width / 2, y: $0.y - $1.height / 2, width: $1.width, height: $1.height) }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        var shift = NSPoint.zero
        if union.width <= area.width { shift.x = max(0, area.minX - union.minX) + min(0, area.maxX - union.maxX) }
        if union.height <= area.height { shift.y = max(0, area.minY - union.minY) + min(0, area.maxY - union.maxY) }
        goals = goals.map { NSPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
        return goals
    }

    /// The small hide arrow's spot, by the head.
    static func target(_ slot: Int, size: NSSize, pet: NSRect) -> NSPoint {
        NSPoint(x: pet.maxX + size.width / 2, y: pet.maxY - size.height)
    }

    /// `options[i]` are the sizes item i may take (natural first); returns each item's rect and chosen option.
    static func place(_ options: [[NSSize]], slots: [Int], pet: NSRect, area: NSRect, obstacles: [NSRect] = []) -> [(rect: NSRect, shape: Int)] {
        let visible = pet.intersection(area)
        let body = visible.isEmpty ? NSRect.zero : visible.insetBy(dx: -gap / 2, dy: -gap / 2)
        let core = visible.isEmpty ? NSPoint(x: pet.midX, y: pet.midY) : NSPoint(x: visible.midX, y: visible.midY)
        var placed = obstacles, result: [(rect: NSRect, shape: Int)] = []
        if let anchor = tuckAnchor {
            if slots.allSatisfy({ $0 < bubbleCount }) { return tuckedRects(options.map { $0[0] }, anchor: anchor, area: area).map { ($0, 0) } }
            return options.map { _ in (tuckArrowRect(anchor: anchor, area: area), 0) }
        }
        let line = slots.allSatisfy({ $0 < bubbleCount }) ? lineGoals(options.map { $0[0] }, pet: pet, area: area) : []
        // The block is already non-overlapping and in reading order: use it as is.
        if options.count > innerArc && line.count == options.count && tuckCorner(pet: pet, area: area) == nil {
            return zip(line, options).map { goal, sizes in
                (NSRect(x: goal.x - sizes[0].width / 2, y: goal.y - sizes[0].height / 2, width: sizes[0].width, height: sizes[0].height), 0)
            }
        }
        // Each item clings to the one placed just before it (the next newer message), so even when crowded
        // into a corner the bubbles form a chain in time order instead of filling gaps at random.
        func gapTo(_ rect: NSRect) -> CGFloat {
            guard let other = result.last?.rect else { return 0 }
            return hypot(max(0, other.minX - rect.maxX, rect.minX - other.maxX), max(0, other.minY - rect.maxY, rect.minY - other.maxY))
        }
        for (index, sizes) in options.enumerated() {
            var best: (rect: NSRect, shape: Int, cost: CGFloat)?
            for (shape, size) in sizes.enumerated() {
                let goal = index < line.count ? line[index] : target(slots[index], size: size, pet: pet)
                let inner = area.insetBy(dx: margin + size.width / 2, dy: margin + size.height / 2)
                guard inner.width >= 0, inner.height >= 0 else { continue }
                // Grid anchored at the clamped goal, so an unobstructed item lands exactly on its slot.
                let gx = min(max(goal.x, inner.minX), inner.maxX), gy = min(max(goal.y, inner.minY), inner.maxY)
                let x0 = gx - ((gx - inner.minX) / step).rounded(.down) * step
                let y0 = gy - ((gy - inner.minY) / step).rounded(.down) * step
                for y in stride(from: y0, through: inner.maxY, by: step) {
                    for x in stride(from: x0, through: inner.maxX, by: step) {
                        let rect = NSRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
                        if rect.intersects(body) || placed.contains(where: { $0.intersects(rect) }) { continue }
                        // Pull toward the slot, toward the pet (satellite) and toward blobs already placed, so a crowd
                        // sticks together instead of leaving gaps. Squashed shapes cost extra.
                        let cost = hypot(x - goal.x, y - goal.y) + 0.5 * hypot(x - core.x, y - core.y) + 2.5 * gapTo(rect) + CGFloat(shape) * 30
                        if best == nil || cost < best!.cost { best = (rect, shape, cost) }
                    }
                }
            }
            let chosen: (rect: NSRect, shape: Int)
            if let best { chosen = (best.rect, best.shape) } else {
                // No free spot (tiny screen): stay on-screen even if overlapping.
                let size = sizes[0], goal = index < line.count ? line[index] : target(slots[index], size: size, pet: pet)
                chosen = (NSRect(x: min(max(goal.x - size.width / 2, area.minX), area.maxX - size.width),
                                 y: min(max(goal.y - size.height / 2, area.minY), area.maxY - size.height),
                                 width: size.width, height: size.height), 0)
            }
            placed.append(chosen.rect); result.append(chosen)
        }
        return result
    }
}

/// A side of the world a blob may not cross: points with dot(p - point, normal) > 0 are pushed back onto the line.
/// With a `zone` (a neighbour's ellipse bounds) only points inside that neighbour are pushed back, so
/// the flat face covers just the real contact, not a long cut across the blob.
struct Wall {
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
    var onClick: ((PetEvent) -> Void)?
    /// Solver output: the footprint rect (body + tailRoom) in superview coordinates, and the shape.
    var goal = NSRect.zero
    var shape = 0 { didSet { messageField.maximumNumberOfLines = Self.shapes[shape].lines; needsLayout = true } }
    /// Screen edges and neighbours, in superview coordinates.
    var walls: [Wall] = []

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

    private var blob: NSBezierPath {
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
        guard push.x != 0 || push.y != 0 else { return }
        frame = frame.offsetBy(dx: push.x, dy: push.y)
        velocity = NSPoint(x: velocity.x + push.x * 0.5, y: velocity.y + push.y * 0.5)
        needsDisplay = true
    }

    /// A damped spring toward the solver's goal: it lags (satellite), overshoots a little and settles (jelly).
    func step(animated: Bool) {
        let target = goal.insetBy(dx: Self.tailRoom - Self.margin, dy: Self.tailRoom - Self.margin)
        if !animated || frame == .zero {
            frame = target; velocity = .zero; alphaValue = 1; needsDisplay = true; return
        }
        let next = Slime.spring(frame, &velocity, toward: target)
        if next != frame {
            if next.size != frame.size { needsLayout = true }
            frame = next
        }
        needsDisplay = true
        if alphaValue < 1 { alphaValue = min(1, alphaValue + 0.15) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return blob.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseUp(with event: NSEvent) { if let shown = self.event { onClick?(shown) } }
    override func menu(for event: NSEvent) -> NSMenu? { (superview as? BubbleField)?.contextMenu }
    override func accessibilityPerformPress() -> Bool { if let shown = event { onClick?(shown) }; return true }
}

/// Up to five bubbles orbiting the pet: newest on the right, then above the head, left, lower right, lower left.
final class BubbleField: NSView {
    private var views: [String: BubbleView] = [:]
    private var order: [PetEvent] = []
    private var solvedKey = ""
    private(set) var footprints: [NSRect] = []
    var onClick: ((PetEvent) -> Void)?
    var contextMenu: NSMenu?

    /// `events` is oldest first; the last one is the current message.
    func show(_ events: [PetEvent]) {
        order = Orbit.capped(events)
        let ids = Set(order.map(\.identity))
        for (id, view) in views where !ids.contains(id) { view.removeFromSuperview(); views[id] = nil }
        for event in order where views[event.identity] == nil {
            let view = BubbleView(frame: .zero)
            view.alphaValue = 0
            view.onClick = { [weak self] in self?.onClick?($0) }
            view.show(event)
            addSubview(view); views[event.identity] = view
        }
        solvedKey = ""
        isHidden = false
    }

    /// Re-solve only when the pet, the screen or the messages change; spring every tick.
    func update(pet: NSRect, area: NSRect, animated: Bool) {
        let key = "\(pet.integral)|\(area)|\(order.map(\.identity))|\(String(describing: Orbit.tuckAnchor))"
        if key != solvedKey {
            solvedKey = key
            let newest = Array(order.reversed())
            let options = newest.map { event in BubbleView.shapes.indices.map { BubbleView.footprint(for: event, shape: $0) } }
            let spots = Orbit.place(options, slots: Array(newest.indices), pet: pet, area: area)
            footprints = spots.map(\.rect)
            for (event, spot) in zip(newest, spots) {
                guard let view = views[event.identity] else { continue }
                view.goal = spot.rect
                if view.shape != spot.shape { view.shape = spot.shape }
            }
        }
        // Walls: the screen edges, and between neighbours a line where their bodies would meet.
        let edges = [Wall(point: NSPoint(x: area.minX, y: 0), normal: NSPoint(x: -1, y: 0)), Wall(point: NSPoint(x: area.maxX, y: 0), normal: NSPoint(x: 1, y: 0)),
                     Wall(point: NSPoint(x: 0, y: area.minY), normal: NSPoint(x: 0, y: -1)), Wall(point: NSPoint(x: 0, y: area.maxY), normal: NSPoint(x: 0, y: 1))]
        let all = Array(views.values)
        for view in all { view.step(animated: animated) }
        // Solid bodies: a fast pet shoves bubbles along instead of passing through, and bubbles shove each other.
        if animated {
            let solid = pet.insetBy(dx: 10, dy: 6)
            for _ in 0..<3 {
                for view in all { if let push = Self.separation(view.footprintNow, from: solid) { view.shove(push) } }
                for (i, a) in all.enumerated() {
                    for b in all[(i + 1)...] {
                        guard let push = Self.separation(a.footprintNow, from: b.footprintNow) else { continue }
                        a.shove(NSPoint(x: push.x / 2, y: push.y / 2)); b.shove(NSPoint(x: -push.x / 2, y: -push.y / 2))
                    }
                }
                for view in all {
                    let f = view.footprintNow
                    view.shove(NSPoint(x: max(0, area.minX - f.minX) + min(0, area.maxX - f.maxX), y: max(0, area.minY - f.minY) + min(0, area.maxY - f.maxY)))
                }
            }
        }
        for view in all {
            var walls = edges
            let mine = view.footprintNow, c = NSPoint(x: mine.midX, y: mine.midY)
            for other in all where other !== view {
                let theirs = other.footprintNow
                // Contact faces are always straight and axis-aligned (vertical between side-by-side bubbles,
                // horizontal between stacked ones), midway between the two edges, even when the neighbours are
                // offset or differ in size: a slanted face made the outlines ripple and leave ragged gaps.
                let overlapX = min(mine.maxX, theirs.maxX) - max(mine.minX, theirs.minX)
                let overlapY = min(mine.maxY, theirs.maxY) - max(mine.minY, theirs.minY)
                let gapX = max(theirs.minX - mine.maxX, mine.minX - theirs.maxX), gapY = max(theirs.minY - mine.maxY, mine.minY - theirs.maxY)
                guard max(gapX, gapY) < 24, max(overlapX, overlapY) > 8 else { continue }
                let n: NSPoint, point: NSPoint
                if overlapY >= overlapX {
                    let right = theirs.midX > c.x
                    n = NSPoint(x: right ? 1 : -1, y: 0)
                    point = NSPoint(x: right ? (mine.maxX + theirs.minX) / 2 : (mine.minX + theirs.maxX) / 2, y: c.y)
                } else {
                    let up = theirs.midY > c.y
                    n = NSPoint(x: 0, y: up ? 1 : -1)
                    point = NSPoint(x: c.x, y: up ? (mine.maxY + theirs.minY) / 2 : (mine.minY + theirs.maxY) / 2)
                }
                // The neighbour's drawn ellipse: body (footprint minus tailRoom) grown by the bulge.
                let body = theirs.insetBy(dx: BubbleView.tailRoom, dy: BubbleView.tailRoom)
                let zone = body.insetBy(dx: -body.width * (BubbleView.bulge - 1) / 2, dy: -body.height * (BubbleView.bulge - 1) / 2)
                walls.append(Wall(point: point, normal: n, zone: zone))
            }
            // The pet is a wall too: a stretched or squashed blob flattens against it instead of overlapping it.
            let solid = pet.insetBy(dx: 10, dy: 6)
            let gapX = max(solid.minX - mine.maxX, mine.minX - solid.maxX), gapY = max(solid.minY - mine.maxY, mine.minY - solid.maxY)
            let zone = solid.insetBy(dx: -solid.width * 0.25, dy: -solid.height * 0.25)
            if max(gapX, gapY) < 80 {
                if gapX >= gapY {
                    walls.append(c.x > solid.midX ? Wall(point: NSPoint(x: solid.maxX, y: 0), normal: NSPoint(x: -1, y: 0), zone: zone)
                                                  : Wall(point: NSPoint(x: solid.minX, y: 0), normal: NSPoint(x: 1, y: 0), zone: zone))
                } else {
                    walls.append(c.y > solid.midY ? Wall(point: NSPoint(x: 0, y: solid.maxY), normal: NSPoint(x: 0, y: -1), zone: zone)
                                                  : Wall(point: NSPoint(x: 0, y: solid.minY), normal: NSPoint(x: 0, y: 1), zone: zone))
                }
            }
            view.walls = walls
        }
    }

    /// Smallest move that takes `a` out of `b`, or nil when they don't overlap.
    static func separation(_ a: NSRect, from b: NSRect) -> NSPoint? {
        guard a.intersects(b) else { return nil }
        let options = [NSPoint(x: b.minX - a.maxX, y: 0), NSPoint(x: b.maxX - a.minX, y: 0), NSPoint(x: 0, y: b.minY - a.maxY), NSPoint(x: 0, y: b.maxY - a.minY)]
        return options.min { abs($0.x) + abs($0.y) < abs($1.x) + abs($1.y) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return subviews.lazy.compactMap { $0.hitTest(local) }.first
    }
}

/// Small translucent slime with a chevron: hides bubbles for a while, or brings the pet and bubbles back early.
final class HideArrow: NSView {
    /// The blob's footprint used by the layout solver; the view adds room for shadow and jiggle.
    static let size = NSSize(width: 30, height: 30)
    static let margin: CGFloat = 12
    private let wobble = Slime.wobble("hide-arrow", count: 12, amount: 0.1)
    private var velocity = NSPoint.zero
    var tucked = false
    var count = 0
    var pulse: CGFloat = 0
    var toward = NSPoint.zero
    var goal = NSRect.zero
    var walls: [Wall] = []
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

    func step(animated: Bool) {
        let target = goal.insetBy(dx: -Self.margin, dy: -Self.margin)
        if isDragging { needsDisplay = true; return }
        if !animated || frame == .zero { frame = target; velocity = .zero }
        else { frame = Slime.spring(frame, &velocity, toward: target) }
        needsDisplay = true
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
    // Bundled cutout character; missing only when run outside the .app bundle.
    private let sprite = Bundle.main.image(forResource: "pet")
    /// Bottom-to-top alpha spans, cached once; transparent pixels do not count as wall contact.
    private lazy var opaqueRows: [(CGFloat, CGFloat)] = {
        guard let image = sprite?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let bitmap = NSBitmapImageRep(cgImage: image), width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        return (0..<height).map { row in
            var left = width, right = 0
            for x in 0..<width where (bitmap.colorAt(x: x, y: height - row - 1)?.alphaComponent ?? 0) > 0 {
                left = min(left, x); right = max(right, x + 1)
            }
            return left < right ? (CGFloat(left) / CGFloat(width), CGFloat(right) / CGFloat(width)) : (0, 1)
        }
    }()
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

final class PetController: NSObject, NSApplicationDelegate {
    /// Hiding is always temporary: the girlfriend always deserves attention again.
    static let hideMinutes = [10, 20, 30, 40, 50, 60]
    /// The pet always stays fully on screen; pressed into an edge it squashes, and only a corner hides it.
    static let keepVisible: CGFloat = .infinity
    /// Pressed this deep into both walls of a corner at release: the pet tucks away behind its arrow.
    static let cornerPress: CGFloat = 30
    private let paths = PetPaths()
    private var sourceConfig = SourcesConfig()
    private var settingsWindow: SourcesSettingsWindowController?
    private var settingsOpening = false
    private var sourceConfigError: String?
    private var localReaders: [LocalSourceReader] = [] // accessed only on the serial I/O queue after launch
    private var lastSourcesPoll = Date.distantPast
    private var sourceStatuses: [PetSource: SourceStatus] = [:]
    private var kakaoAccessibilityStatus = SourceStatus.disabled
    private var kakaoNotificationStatus = SourceStatus.disabled
    private struct ReaderStatuses {
        var sources: [PetSource: SourceStatus] = [:]
        var accessibility = SourceStatus.disabled
        var notifications = SourceStatus.disabled
    }
    private var sourceStatusItems: [PetSource: NSMenuItem] = [:]
    private var permissionNotices = Set<PetSource>()
    private var queue: EventQueue!
    private var panel: PetPanel!       // the character
    private var overlay: PetPanel!     // screen-sized, click-through layer for bubbles and the arrow
    private var bubble: BubbleField!
    private var arrow: HideArrow!
    private var cat: CatView!
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var showNowItem: NSMenuItem!
    private var animationTimer: Timer?
    private var pollTimer: Timer?
    private var pending: [PetEvent] = []
    private var current: PetEvent?
    private var recent: [PetEvent] = [] // the (up to four) messages shown before `current`
    private var readMarks: [ConversationKey: Date] = [:]
    private var knownIDs = Set<String>()
    private var knownOrder: [String] = []
    private var queueGeneration = 0
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pollInFlight = false
    private var hidePetUntil: Date?
    private var hideBubblesUntil: Date?
    private var isHidden: Bool { hidePetUntil != nil }
    /// Dragged off the edge: the pet is tucked away behind its arrow, but bubbles keep coming (they gather at
    /// that edge). It pops back out after an hour at most — nothing hides indefinitely.
    private var tuckedUntil: Date?
    private var isTucked: Bool { tuckedUntil != nil }
    static let tuckMinutes = 60
    private var paused: Bool { hideBubblesUntil != nil }
    private var arrowKey = ""
    private var lastCatOrigin = NSPoint.zero
    private var tuckArrowCenter: NSPoint?
    private var petTarget: NSPoint?
    private var petDragArea: NSRect?
    private var overPet = false
    private var lastPress: (left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat) = (0, 0, 0, 0)
    private var arrowDragStart: (panel: NSPoint, arrow: NSPoint)?
    private var lastError: String?
    private let io = DispatchQueue(label: "com.instagrampet.queue", qos: .userInitiated)
    private var smokeReport: URL?
    private var smokeFinishing = false
    private var smokeBurstCount: Int?
    private var smokeBurstSamples: [[Double]] = []
    private var smokeNotificationMode = false
    private var previewMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-settings"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkSettings(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-pet-geometry"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkPetGeometry(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--measure-live-ax") {
            previewMode = true
            measureLiveAccessibility()
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-source-reads"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkSourceReads(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-scenarios"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            renderScenarios(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > flag + 1 {
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            if CommandLine.arguments.contains("--start-hidden") { // checks that a new message ends a timed hide
                hidePetUntil = Date().addingTimeInterval(600); hideBubblesUntil = Date().addingTimeInterval(600)
            }
            if CommandLine.arguments.contains("--start-tucked") { // a message must bring back bubbles, not the pet
                tuckedUntil = Date().addingTimeInterval(600); hideBubblesUntil = Date().addingTimeInterval(600)
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-burst-latency"), CommandLine.arguments.count > flag + 2 {
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            smokeBurstCount = max(1, min(100, Int(CommandLine.arguments[flag + 2]) ?? 5))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-notification-latency"), CommandLine.arguments.count > flag + 2 {
            guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil else {
                previewMode = true; NSApplication.shared.terminate(nil); return
            }
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            smokeBurstCount = max(1, min(100, Int(CommandLine.arguments[flag + 2]) ?? 5))
            smokeNotificationMode = true
        }
        queue = EventQueue(paths: paths)
        do { try paths.prepare() }
        catch { lastError = "Cannot open private queue" }
        if smokeReport == nil {
            do { sourceConfig = try SourcesConfig.load(paths: paths) }
            catch { sourceConfigError = "Sources configuration unavailable · check sources.json" }
            localReaders = [makeContactReaders(.messages, config: sourceConfig), makeContactReaders(.kakao, config: sourceConfig)]
        } else if smokeNotificationMode {
            localReaders = [KakaoNotificationReader(name: "Fixture Friend", databaseURL: paths.root.appendingPathComponent("notification-fixture.db"))]
        }
        buildPanel()
        buildMenu()
        if smokeReport == nil { overlay.orderFrontRegardless(); panel.orderFrontRegardless() }
        else { statusItem.isVisible = false }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkHideExpiry()
            if !self.isHidden && !self.isTucked {
                self.cat.phase += 0.12
                if self.paused { self.cat.excited = !self.pending.isEmpty } // messages wait behind the pause
                self.followPet(step: 0.3)
                let origin = self.panel.frame.origin
                self.cat.shake(by: NSPoint(x: origin.x - self.lastCatOrigin.x, y: origin.y - self.lastCatOrigin.y))
                self.updatePetArea()
                self.lastCatOrigin = origin
                self.cat.needsDisplay = true
            }
            self.layoutOverlay(animated: true)
            self.updateClickThrough()
        }
        // The pet never takes focus, so let this background app show the open hand over it.
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updateClickThrough() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateClickThrough(); return event
        }
        updateClickThrough()
        pollTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pollTimer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        poll()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if smokeReport != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishSmokeTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if smokeReport == nil, !previewMode { persistPosition() }
        animationTimer?.invalidate(); pollTimer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    private func makePanel(_ frame: NSRect) -> PetPanel {
        let result = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.title = "Instagram Pet"
        result.level = .floating
        result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        result.backgroundColor = .clear
        result.isOpaque = false
        result.hasShadow = false
        result.hidesOnDeactivate = false
        result.isReleasedWhenClosed = false
        result.animationBehavior = .none
        result.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        return result
    }

    private func buildPanel() {
        // Wider than the sprite: room for the jelly lean and squash.
        let size = CatView.size
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel = makePanel(NSRect(origin: NSPoint(x: visible.maxX - size.width - 22, y: visible.minY + 18), size: size))
        panel.level = .statusBar // above the menu bar, so the pet can press flat against the very top edge
        cat = CatView(frame: NSRect(origin: .zero, size: size))
        cat.onClick = { [weak self] in self?.toggleLatest() }
        cat.onMoved = { [weak self] in self?.droppedPet() }
        cat.onDragTo = { [weak self] in self?.dragPet(to: $0) }
        panel.contentView?.addSubview(cat)
        overlay = makePanel(NSScreen.main?.frame ?? visible)
        overlay.level = .statusBar // above the menu bar and Dock, so bubbles can sit flush in a corner
        overlay.ignoresMouseEvents = true
        bubble = BubbleField(frame: overlay.contentView!.bounds)
        bubble.autoresizingMask = [.width, .height]
        bubble.isHidden = true
        bubble.onClick = { [weak self] in self?.openConversation($0) }
        bubble.contextMenu = hideMenu(action: #selector(hideBubblesFor(_:)))
        arrow = HideArrow(frame: .zero)
        arrow.isHidden = true
        arrow.onClick = { [weak self] in self?.arrowClicked($0) }
        arrow.onDrag = { [weak self] in self?.dragArrow($0) }
        arrow.onDragEnd = { [weak self] in self?.arrowDropped() }
        overlay.contentView?.addSubview(bubble)
        overlay.contentView?.addSubview(arrow)
        // Saved as the sprite's own origin, so panel size changes never move the pet.
        let sprite = cat.spriteRect
        if let saved = UserDefaults.standard.array(forKey: "pet.sprite.origin") as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0] - sprite.minX, y: saved[1] - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.cat.origin") as? [Double], old.count == 2 {
            // Previous build: a 200pt panel, sprite at (32.6, 4).
            panel.setFrameOrigin(NSPoint(x: old[0] + 32.6 - sprite.minX, y: old[1] + 4 - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.position") as? [Double], old.count == 2 {
            // v1: a 340pt panel, sprite at (190.6, 9).
            panel.setFrameOrigin(NSPoint(x: old[0] + 190.6 - sprite.minX, y: old[1] + 9 - sprite.minY))
        }
        clampPosition()
        lastCatOrigin = panel.frame.origin
    }

    private func item(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func hideMenu(action: Selector) -> NSMenu {
        let menu = NSMenu()
        for minutes in Self.hideMinutes {
            let entry = item(minutes == 60 ? "1시간" : "\(minutes)분", action: action)
            entry.tag = minutes
            menu.addItem(entry)
        }
        return menu
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Instagram Pet controls")
        statusItem.button?.toolTip = "Instagram Pet · Instagram / KakaoTalk / Messages"
        let menu = NSMenu()
        menu.addItem(item("Instagram Pet · MVP"))
        statusLine = item("Waiting for Chrome observations"); menu.addItem(statusLine)
        for source in [PetSource.messages, .kakao] {
            let line = item("\(source.title): disabled")
            sourceStatusItems[source] = line
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let bubbles = item("말풍선 잠깐 숨기기"); bubbles.submenu = hideMenu(action: #selector(hideBubblesFor(_:))); menu.addItem(bubbles)
        let pet = item("펫 잠깐 숨기기"); pet.submenu = hideMenu(action: #selector(hidePetFor(_:))); menu.addItem(pet)
        showNowItem = item("지금 다시 보이기", action: #selector(showNow)); menu.addItem(showNowItem)
        menu.addItem(item("Show Latest Message", action: #selector(showLatest)))
        menu.addItem(item("Show Demo Bubble", action: #selector(showDemo)))
        menu.addItem(item("Clear Waiting Messages", action: #selector(clearMessages)))
        menu.addItem(.separator())
        menu.addItem(item("설정…", action: #selector(openSettings), key: ","))
        menu.addItem(item("Open Instagram Inbox", action: #selector(openInbox)))
        menu.addItem(item("Open Local Data Folder", action: #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Instagram Pet", action: #selector(quit), key: "q"))
        menu.autoenablesItems = false
        statusItem.menu = menu
        cat.petMenu = menu
        updateStatus()
    }

    private func remaining(_ until: Date?) -> String {
        guard let until else { return "" }
        return "\(max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up))))분 후 다시 표시"
    }

    @objc private func openSettings() {
        if let settingsWindow, settingsWindow.window?.isVisible == true { settingsWindow.show(); return }
        guard !settingsOpening else { return }
        settingsOpening = true
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try SourcesConfig.load(paths: self.paths) }
            DispatchQueue.main.async {
                self.settingsOpening = false
                switch result {
                case .failure:
                    self.lastError = "설정 파일을 읽을 수 없습니다 · 로컬 데이터 폴더 확인"
                    self.updateStatus()
                case .success(let config):
                    let controller = SourcesSettingsWindowController(config: config)
                    controller.onSave = { [weak self] value, completion in self?.saveSettings(value, completion: completion) }
                    self.settingsWindow = controller
                    controller.show()
                }
            }
        }
    }

    /// Called on the main thread. The I/O queue serializes file replacement and reader changes with polls.
    private func saveSettings(_ value: SourcesConfig, completion: @escaping (Result<Void, SettingsFormError>) -> Void) {
        let previous = sourceConfig
        queueGeneration += 1 // Ignore a poll snapshot captured with the old selection.
        io.async { [weak self] in
            guard let self else { return }
            do {
                let config = try value.validated()
                try config.save(paths: self.paths)
                let changed = Self.changedSources(from: previous, to: config)
                self.localReaders = self.localReaders.map { reader in
                    guard changed.contains(reader.source) else { return reader }
                    return self.makeContactReaders(reader.source, config: config, reusing: reader as? ContactReaders)
                }
                self.lastSourcesPoll = .distantPast
                // Receipts and per-conversation read marks survive a selection change.
                // If cleanup cannot run now, the display boundary rejects obsolete queued selections later.
                if let waiting = try? self.queue?.pending() {
                    for event in waiting where changed.contains(event.source) && !Self.acceptsEvent(event, config: config) {
                        try? self.queue?.consume(event)
                    }
                }
                DispatchQueue.main.async {
                    self.applySettings(config, changed: changed)
                    completion(.success(()))
                    if !self.previewMode { self.poll() }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(SettingsFormError(message: "설정을 저장하지 못했습니다. 로컬 데이터 폴더의 소유권·권한과 입력을 확인해 주세요.")))
                }
            }
        }
    }

    private func makeContactReaders(_ source: PetSource, config: SourcesConfig, reusing previous: ContactReaders? = nil) -> ContactReaders {
        if source == .messages {
            return ContactReaders(source: source, identifiers: config.messageHandles, reusing: previous) { MessagesReader(handle: $0) }
        }
        return ContactReaders(source: source, identifiers: config.kakaoNames, reusing: previous) { KakaoCombinedReader(name: $0, fallbackGrace: 0.5) }
    }

    private static func changedSources(from previous: SourcesConfig, to config: SourcesConfig) -> Set<PetSource> {
        var changed = Set<PetSource>()
        if previous.instagram != config.instagram { changed.insert(.instagram) }
        if previous.messages != config.messages { changed.insert(.messages) }
        if previous.kakao != config.kakao { changed.insert(.kakao) }
        return changed
    }

    private func applySettings(_ config: SourcesConfig, changed: Set<PetSource>) {
        sourceConfig = config; sourceConfigError = nil; lastError = nil
        pending.removeAll { changed.contains($0.source) && !Self.acceptsEvent($0, config: config) }
        recent.removeAll { changed.contains($0.source) && !Self.acceptsEvent($0, config: config) }
        if let event = current, changed.contains(event.source), !Self.acceptsEvent(event, config: config) { current = recent.popLast() }
        let shown = recent + [current].compactMap { $0 }
        if shown.isEmpty { bubble.isHidden = true; cat.excited = false }
        else if !bubble.isHidden { bubble.show(shown) }
        for source in changed {
            permissionNotices.remove(source)
            if source == .messages { sourceStatuses[source] = config.messages == nil ? .disabled : .idle }
            if source == .kakao {
                sourceStatuses[source] = config.kakao == nil ? .disabled : .idle
                kakaoAccessibilityStatus = config.kakao == nil ? .disabled : .idle
                kakaoNotificationStatus = config.kakao == nil ? .disabled : .idle
            }
        }
        updateStatus()
    }

    private static func acceptsEvent(_ event: PetEvent, config: SourcesConfig) -> Bool {
        if event.kind == "test" { return true }
        switch event.source {
        case .instagram:
            guard config.instagram != nil else { return true } // Legacy extension-managed selection.
            guard let url = URL(string: event.threadUrl) else { return false }
            let path = url.path.split(separator: "/").map(String.init)
            return config.instagramSelections.contains { $0.username == event.sender && path == ["direct", "t", $0.threadId] }
        case .messages:
            return config.messageHandles.contains { ConversationKey.local(.messages, identifier: $0) == event.conversation }
        case .kakao:
            return config.kakaoNames.contains { ConversationKey.local(.kakao, identifier: $0) == event.conversation }
        }
    }

    private func updateStatus() {
        if let lastError { statusLine.title = lastError }
        else if let sourceConfigError { statusLine.title = sourceConfigError }
        else if isTucked { statusLine.title = "펫 가장자리에 숨김 · \(remaining(tuckedUntil))" }
        else if isHidden { statusLine.title = "펫 숨김 · \(remaining(hidePetUntil)) · \(pending.count) waiting" }
        else if paused { statusLine.title = "말풍선 숨김 · \(remaining(hideBubblesUntil)) · \(pending.count) waiting" }
        else if !pending.isEmpty { statusLine.title = "\(pending.count) message(s) waiting" }
        else { statusLine.title = "Ready · Instagram은 대화 탭을 열어 두세요" }
        showNowItem.isEnabled = isHidden || paused || isTucked
        for (source, line) in sourceStatusItems {
            let detail: String
            switch sourceStatuses[source] ?? .disabled {
            case .disabled: detail = "꺼짐 · sources.json 확인"
            case .idle: detail = "대기 · 앱/목록 창 확인"
            case .observing: detail = "관측 중"
            case .permissionRequired: detail = source == .messages ? "전체 디스크 접근 필요" : "손쉬운 사용 권한 필요"
            case .unavailable: detail = source == .messages ? "DB/스키마 확인 필요" : "목록 구조 인식 불가"
            }
            var sourceDetail = detail
            if source == .kakao, sourceStatuses[source] == .observing {
                if kakaoAccessibilityStatus == .observing && kakaoNotificationStatus == .observing { sourceDetail = "관측 중 · 알림 + 목록" }
                else if kakaoAccessibilityStatus == .permissionRequired { sourceDetail = "알림 관측 중 · 읽음 연동에 손쉬운 사용 권한 필요" }
                else if kakaoNotificationStatus == .permissionRequired { sourceDetail = "목록 관측 중 · 개별 알림에 전체 디스크 접근 필요" }
                else if kakaoAccessibilityStatus != .observing { sourceDetail = "알림 관측 중 · 읽음 연동은 목록 창 확인" }
                else { sourceDetail = "목록 관측 중" }
            }
            line.title = "\(source.title): \(sourceDetail)"
        }
    }

    /// Off the main thread. Reader outboxes are acknowledged only after durable queue acceptance.
    private func pollLocalSources() throws -> ReaderStatuses? {
        let now = Date()
        guard now.timeIntervalSince(lastSourcesPoll) >= 0.45 else { return nil }
        lastSourcesPoll = now
        let waiting = try queue.pending()
        var statuses = ReaderStatuses()
        for reader in localReaders {
            reader.restorePending(waiting)
            let batch = reader.poll(now: now)
            statuses.sources[reader.source] = batch.status
            if let kakao = reader as? KakaoCombinedReader {
                statuses.accessibility = kakao.accessibilityStatus
                statuses.notifications = kakao.notificationStatus
            } else if let kakao = reader as? ContactReaders, reader.source == .kakao {
                statuses.accessibility = kakao.accessibilityStatus
                statuses.notifications = kakao.notificationStatus
            }
            for (key, at) in batch.reads { try queue.markRead(key, at: at) }
            let marks = try queue.reads()
            var accepted = Set<String>()
            for event in batch.events {
                let expired = PetEvent.date(event.observedAt).map { now.timeIntervalSince($0) > EventQueue.retention } ?? true
                if !expired && !event.conversation.isRead(observedAt: event.observedAt, in: marks) {
                    do { try queue.enqueue(event) }
                    catch PetError.queueFull { break } // still drain the existing queue; reader retries the rest
                }
                accepted.insert(event.identity)
            }
            reader.acknowledge(accepted)
        }
        if smokeNotificationMode, statuses.sources[.kakao] == .observing {
            let ready = paths.root.appendingPathComponent("baseline.ready")
            if !FileManager.default.fileExists(atPath: ready.path) { try Data("1".utf8).write(to: ready) }
        }
        return statuses
    }

    private func explainPermissionsIfNeeded() {
        guard smokeReport == nil, !previewMode else { return }
        for source in [PetSource.messages, .kakao] {
            let needsPermission = source == .kakao ? kakaoAccessibilityStatus == .permissionRequired
                : sourceStatuses[source] == .permissionRequired || kakaoNotificationStatus == .permissionRequired
            guard needsPermission else { continue }
            guard permissionNotices.insert(source).inserted else { continue }
            let alert = NSAlert()
            alert.messageText = source == .messages ? "메시지 말풍선에 전체 디스크 접근이 필요합니다" : "카카오톡 말풍선에 손쉬운 사용 권한이 필요합니다"
            alert.informativeText = source == .messages
                ? "시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근에서 설치된 InstagramPet.app을 추가하고 켜 주세요. 메시지와 카카오톡 개별 알림 DB를 읽기 전용으로 확인하며 과거 이력은 재생하지 않습니다. 권한을 켠 뒤 앱을 다시 열어 주세요."
                : "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 InstagramPet.app을 켜 주세요. 설정한 카카오톡 채팅 목록의 미리보기만 읽습니다. 카카오톡 앱과 목록 창이 있어야 합니다."
            alert.addButton(withTitle: "확인")
            // One notice per source per launch. No permission is granted by the app itself.
            // In front: a modal alert hidden behind other windows silently freezes the pet until dismissed.
            NSApp.activate(ignoringOtherApps: true)
            alert.window.level = .statusBar + 1
            alert.runModal()
        }
    }

    private func poll() {
        guard queue != nil, !pollInFlight else { return }
        pruneExpiredMemory()
        // Leave excess events on disk rather than silently dropping them from memory.
        pollInFlight = true
        let generation = queueGeneration
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { (try self.pollLocalSources(), try self.queue.pending(), try self.queue.reads()) }
            DispatchQueue.main.async {
                self.pollInFlight = false
                guard generation == self.queueGeneration else { return }
                switch result {
                case .success(let (statuses, events, reads)):
                    self.lastError = nil
                    if let statuses {
                        self.sourceStatuses = statuses.sources
                        self.kakaoAccessibilityStatus = statuses.accessibility
                        self.kakaoNotificationStatus = statuses.notifications
                    }
                    self.applyReads(reads)
                    for event in events where !self.isRead(event) {
                        if self.smokeReport == nil && !Self.acceptsEvent(event, config: self.sourceConfig) {
                            self.io.async { [weak self] in try? self?.queue?.consume(event) }
                            continue
                        }
                        guard self.pending.count < 100 else { break }
                        if self.knownIDs.contains(event.identity) { continue }
                        // Validate again at the display boundary, including the URL.
                        guard (try? event.validate()) != nil else { continue }
                        self.knownIDs.insert(event.identity)
                        self.knownOrder.append(event.identity)
                        self.pending.append(event)
                    }
                    self.pending.sort {
                        let a = PetEvent.date($0.observedAt) ?? .distantPast, b = PetEvent.date($1.observedAt) ?? .distantPast
                        return a == b ? $0.identity < $1.identity : a < b
                    }
                    self.trimKnownIDs()
                    // A new message always shows: it ends any timed hide (bubbles or pet) right away.
                    // A pet tucked behind its arrow stays tucked: only the bubbles come back.
                    if !self.pending.isEmpty {
                        if self.isHidden { self.showNow() } else if self.paused { self.resumeBubbles() }
                    }
                    self.presentNextIfPossible()
                case .failure:
                    self.lastError = "Queue read failed · check data folder"
                }
                self.updateStatus()
                self.explainPermissionsIfNeeded()
            }
        }
    }

    /// Seen in Chrome (or opened from a bubble): that thread's bubbles disappear.
    private func isRead(_ event: PetEvent) -> Bool {
        event.conversation.isRead(observedAt: event.observedAt, in: readMarks)
    }

    private func applyReads(_ reads: [ConversationKey: Date]) {
        var merged = reads
        for (key, at) in readMarks where Date().timeIntervalSince(at) <= EventQueue.retention {
            merged[key] = max(at, merged[key] ?? .distantPast)
        }
        guard merged != readMarks else { return }
        readMarks = merged
        pending.removeAll(where: isRead)
        let before = (recent + [current].compactMap { $0 }).map(\.identity)
        recent.removeAll(where: isRead)
        if let shown = current, isRead(shown) { current = recent.popLast() }
        let still = recent + [current].compactMap { $0 }
        guard !bubble.isHidden, still.map(\.identity) != before else { return }
        // Other threads' bubbles stay; if nothing is left, the queue moves on or goes quiet.
        if still.isEmpty { dismissCurrent() } else { bubble.show(still) }
        updateStatus()
    }

    private func markRead(_ conversation: ConversationKey) {
        let at = Date()
        var marks = readMarks
        marks[conversation] = at
        applyReads(marks)
        io.async { [weak self] in try? self?.queue?.markRead(conversation, at: at) }
    }

    private func presentNextIfPossible() {
        guard !paused, !isHidden else { return }
        // Existing unread bubbles never delay a new arrival. Keep the latest five together.
        while !pending.isEmpty { present(pending.removeFirst()) }
    }

    /// Delivery can be delayed independently per source; newest means observedAt, not arrival order.
    private func rememberForDisplay(_ event: PetEvent) -> [PetEvent] {
        let previous = (recent + [current].compactMap { $0 }).filter { $0.identity != event.identity && $0.kind != "test" }
        let ordered = Orbit.capped((previous + [event]).sorted {
            let a = PetEvent.date($0.observedAt) ?? .distantPast, b = PetEvent.date($1.observedAt) ?? .distantPast
            return a == b ? $0.identity < $1.identity : a < b
        })
        recent = Array(ordered.dropLast()); current = ordered.last
        return ordered
    }

    private func present(_ event: PetEvent) {
        guard !paused, !isHidden else { return }
        bubble.show(rememberForDisplay(event))
        layoutOverlay(animated: false)
        // Retain undisplayed events on disk across app quits. Consume only on display.
        io.async { [weak self] in
            guard let queue = self?.queue else { return }
            try? queue.consume(event)
        }
        cat.excited = true
        if smokeReport == nil { overlay.orderFrontRegardless(); if !isTucked && !isHidden { panel.orderFrontRegardless() } }
        updateStatus()
        if let expected = smokeBurstCount, let output = smokeReport {
            let delay = Date().timeIntervalSince(PetEvent.date(event.observedAt) ?? Date()) * 1000
            smokeBurstSamples.append([Double((recent + [current].compactMap { $0 }).count), max(0, delay)])
            if smokeBurstSamples.count >= expected {
                try? JSONSerialization.data(withJSONObject: smokeBurstSamples).write(to: output)
                NSApplication.shared.terminate(nil)
            }
        } else if smokeReport != nil { finishSmokeTest() }
    }

    @objc private func dismissCurrent() {
        bubble.isHidden = true; cat.excited = false
        // With a backlog the bubbles shift in place: the newest one enters on the right.
        presentNextIfPossible()
    }

    private func toggleLatest() {
        if bubble.isHidden { showLatest() } // a click never closes bubbles; only hiding does
    }

    @objc private func showLatest() {
        if isHidden || paused { showNow(); return }
        if let current { present(current) } else { presentNextIfPossible() }
    }

    @objc private func showDemo() {
        guard let event = demoEvent() else { return }
        pending.insert(event, at: 0)
        if isHidden || paused { showNow() }
        dismissCurrent()
        updateStatus()
    }

    // MARK: Temporary hiding (never indefinite)

    @objc private func hideBubblesFor(_ sender: NSMenuItem) {
        hideBubblesUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        arrowKey = ""
        updateStatus()
    }

    @objc private func hidePetFor(_ sender: NSMenuItem) {
        hidePetUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        // Only the small slime arrow stays, so the pet can always be called back.
        panel.orderOut(nil)
        arrowKey = ""
        updateStatus()
    }

    @objc private func showNow() {
        if isTucked { untuck() }
        if isHidden {
            hidePetUntil = nil
            arrowKey = ""
            overlay.orderFrontRegardless(); panel.orderFrontRegardless()
        }
        if paused { resumeBubbles() } else { presentNextIfPossible() }
        updateStatus()
    }

    private func checkHideExpiry() {
        let now = Date()
        if let until = hidePetUntil, until <= now { showNow() }
        if let until = tuckedUntil, until <= now { untuck(); updateStatus() }
        if let until = hideBubblesUntil, until <= now { resumeBubbles(); updateStatus() }
    }

    /// Coming back shows the newest message with the two before it, not a slow replay of the backlog.
    private func resumeBubbles() {
        hideBubblesUntil = nil
        arrowKey = ""
        if pending.count > 1, let last = pending.last {
            let skipped = Array(pending.dropLast())
            let prior = recent + [current].compactMap { $0 } + skipped
            recent = Orbit.capped(prior.filter { $0.kind != "test" }.sorted {
                (PetEvent.date($0.observedAt) ?? .distantPast) < (PetEvent.date($1.observedAt) ?? .distantPast)
            })
            current = nil
            pending = [last]
            io.async { [weak self] in
                guard let queue = self?.queue else { return }
                for event in skipped { try? queue.consume(event) }
            }
        }
        presentNextIfPossible()
    }

    /// The arrow follows the pointer exactly, and the hidden pet moves with it, so a click brings it out there.
    private func dragArrow(_ delta: NSPoint) {
        if arrowDragStart == nil { arrowDragStart = (panel.frame.origin, arrow.frame.origin) }
        guard let start = arrowDragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.panel.x + delta.x, y: start.panel.y + delta.y))
        arrow.setFrameOrigin(NSPoint(x: start.arrow.x + delta.x, y: start.arrow.y + delta.y))
        lastCatOrigin = panel.frame.origin
    }

    /// Dropped anywhere: the arrow settles flush on the nearest screen edge, the hidden pet moving with it.
    private func arrowDropped() {
        arrowDragStart = nil; arrowKey = ""
        guard isTucked, let screen = catScreen() else { return }
        let o = overlay.frame.origin, area = screen.frame.offsetBy(dx: -o.x, dy: -o.y)
        let here = NSPoint(x: arrow.frame.midX, y: arrow.frame.midY), there = Orbit.snapToEdge(here, area: area)
        tuckArrowCenter = there
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + there.x - here.x, y: panel.frame.minY + there.y - here.y))
        lastCatOrigin = panel.frame.origin
    }

    private func arrowClicked(_ view: HideArrow) {
        showNow()
    }

    // MARK: Layout

    /// The screen showing most of the pet, or the nearest one when it is tucked fully off-screen.
    private func catScreen() -> NSScreen? {
        let sprite = catSpriteOnScreen()
        func overlap(_ screen: NSScreen) -> CGFloat { let x = screen.frame.intersection(sprite); return x.width * x.height }
        func distance(_ screen: NSScreen) -> CGFloat { hypot(screen.frame.midX - sprite.midX, screen.frame.midY - sprite.midY) }
        if let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        return NSScreen.screens.min { distance($0) < distance($1) } ?? NSScreen.main
    }

    private func catSpriteOnScreen() -> NSRect {
        cat.spriteRect.offsetBy(dx: panel.frame.minX + cat.frame.minX, dy: panel.frame.minY + cat.frame.minY)
    }

    private func layoutOverlay(animated: Bool) {
        guard let screen = catScreen() else { return }
        if overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: false) }
        let origin = overlay.frame.origin
        let pet = cat.bodyRect.offsetBy(dx: panel.frame.minX + cat.frame.minX - origin.x, dy: panel.frame.minY + cat.frame.minY - origin.y)
        // The display's real border, like the pet: bubbles and the arrow press flush into the very corner,
        // over the menu bar and Dock, with no gap.
        let area = screen.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        place(pet: pet, area: area, animated: animated)
    }

    /// Shared by the live overlay and the preview renderer.
    private func place(pet: NSRect, area: NSRect, animated: Bool) {
        // Tucked away: the bubbles line up along the edge where the arrow sits (the pet's spot, clamped on screen).
        // Tucked away: everything follows the arrow. It starts at the pet's spot (clamped on screen), moves with
        // a drag, and settles on the nearest edge when dropped.
        if isTucked {
            if tuckArrowCenter == nil {
                tuckArrowCenter = Orbit.snapToEdge(NSPoint(x: min(max(pet.midX, area.minX), area.maxX), y: min(max(pet.midY, area.minY), area.maxY)), area: area)
            }
            if arrow.isDragging { tuckArrowCenter = NSPoint(x: arrow.frame.midX, y: arrow.frame.midY) }
            Orbit.tuckAnchor = tuckArrowCenter
        } else { Orbit.tuckAnchor = nil; tuckArrowCenter = nil }
        if !bubble.isHidden { bubble.update(pet: pet, area: area, animated: animated) }
        // The arrow appears whenever something is hidden — the pet, or just its bubbles — so a click always undoes it.
        let tucked = isHidden || isTucked || paused
        arrow.isHidden = !tucked
        guard !arrow.isHidden else { return }
        let obstacles = bubble.isHidden ? [] : bubble.footprints
        let key = "\(pet.integral)|\(area)|\(obstacles)|\(String(describing: Orbit.tuckAnchor))"
        if key != arrowKey && !arrow.isDragging {
            arrowKey = key
            let spot = Orbit.place([[HideArrow.size]], slots: [Orbit.bubbleCount], pet: pet, area: area, obstacles: obstacles)[0].rect
            arrow.goal = spot
        }
        arrow.tucked = tucked
        arrow.count = isHidden || paused ? pending.count : 0
        arrow.pulse += 0.12
        let visible = pet.intersection(area).isEmpty ? pet : pet.intersection(area)
        arrow.toward = NSPoint(x: visible.midX, y: visible.midY)
        arrow.walls = [Wall(point: NSPoint(x: area.minX, y: 0), normal: NSPoint(x: -1, y: 0)), Wall(point: NSPoint(x: area.maxX, y: 0), normal: NSPoint(x: 1, y: 0)),
                       Wall(point: NSPoint(x: 0, y: area.minY), normal: NSPoint(x: 0, y: -1)), Wall(point: NSPoint(x: 0, y: area.maxY), normal: NSPoint(x: 0, y: 1))]
        arrow.toolTip = isTucked ? "펫 \(remaining(tuckedUntil)) · 클릭하면 바로 꺼내기"
            : isHidden ? "펫 \(remaining(hidePetUntil)) · 클릭하면 바로 보기"
            : paused ? "말풍선 \(remaining(hideBubblesUntil)) · 클릭하면 바로 보기" : "말풍선 잠깐 숨기기"
        arrow.step(animated: animated)
    }

    private func demoEvent(text: String = "안녕! 새 DM이 오면 이렇게 알려줄게요.\nDrag me anywhere. Keep Instagram open in Chrome.", minutesAgo: Int = 0) -> PetEvent? {
        // Decode the same wire model to exercise the bubble without requiring Chrome or a login.
        let sample: [String: Any] = [
            "version": 1, "type": "dm", "eventId": "demo-\(UUID().uuidString)",
            "sender": "demo.pet", "displayName": "Demo Pet", "text": text,
            "threadUrl": "https://www.instagram.com/direct/t/demo/", "observedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(minutesAgo) * 60)), "kind": "test"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sample) else { return nil }
        return try? JSONDecoder().decode(PetEvent.self, from: data)
    }

    // MARK: Previews

    /// The form and real asynchronous save/apply path, using only an isolated private home and fake contacts.
    private func checkSettings(to output: URL) {
        guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil,
              paths.root.resolvingSymlinksInPath().path.hasPrefix("/private/tmp/") ||
              paths.root.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/") else {
            NSApp.terminate(nil); return
        }
        func finish(_ values: [String: Any]) {
            try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            NSApp.terminate(nil)
        }
        do {
            let initial = SourcesConfig(kakao: .init(name: "Fixture Friend"), messages: .init(handle: "fixture@example.invalid"))
            try initial.save(paths: paths)
            let original = try Data(contentsOf: paths.root.appendingPathComponent("sources.json"))
            sourceConfig = initial; queue = EventQueue(paths: paths)
            // Reader construction is lazy; previewMode suppresses automatic polling after each save.
            localReaders = [MessagesReader(handle: initial.messages?.handle), KakaoCombinedReader(name: initial.kakao?.name)]
            let oldMessages = ObjectIdentifier(localReaders[0]), oldKakao = ObjectIdentifier(localReaders[1])
            buildPanel(); buildMenu(); statusItem.isVisible = false
            let events = mixedSourceEvents()
            recent = Array(events.dropLast()); current = events.last; pending = [events[0], events[1], events[4]]
            bubble.show(events)
            layoutOverlay(animated: false)
            for event in pending { try queue.enqueue(event) }
            try queue.markRead(events[0].conversation, at: Date().addingTimeInterval(-3600))
            readMarks = try queue.reads()
            let marks = readMarks
            let form = SourcesSettingsWindowController(config: try SourcesConfig.load(paths: paths))
            settingsWindow = form
            let prefilled = !form.draft.managesInstagram && form.draft.messagesHandle == initial.messages?.handle && form.draft.kakaoName == initial.kakao?.name
            form.username.stringValue = "fixture.sender"
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.username))
            let automaticInstagram = form.draft.managesInstagram
            form.username.stringValue = ""
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.username))
            let clearedInstagram = (try? form.draft.validated())?.instagram == SourcesConfig.Instagram(username: "", threadId: "")
            form.setDraft(SettingsDraft(initial))
            var multiple = SettingsDraft(initial)
            multiple.managesInstagram = true
            multiple.username = "fixture.sender, other.sender"; multiple.threadId = "12345, 67890"
            multiple.messagesHandle = "fixture@example.invalid, next@example.invalid"
            multiple.kakaoName = "Fixture Friend, Fixture Other"
            let multipleConfig = try multiple.validated()
            let multipleSaved = multipleConfig.instagramSelections.count == 2 && multipleConfig.messageHandles.count == 2 && multipleConfig.kakaoNames.count == 2
            multiple.threadId = "12345"
            let mismatchedRejected = (try? multiple.validated()) == nil
            var added = initial
            added.messages = .init(handle: "fixture@example.invalid,next@example.invalid")
            applySettings(added, changed: Self.changedSources(from: initial, to: added))
            let retainedOnAdd = recent.count + (current == nil ? 0 : 1) == 5 && pending.count == 3
            sourceConfig = initial
            if let content = form.window?.contentView {
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: output.deletingLastPathComponent().appendingPathComponent("settings-window.png"))
                }
            }
            var submissions = 0
            form.onSave = { [weak self] config, completion in
                guard let self else { return }
                submissions += 1
                self.saveSettings(config, completion: completion)
            }
            var invalid = form.draft
            invalid.managesInstagram = true; invalid.username = "fixture.sender"; invalid.threadId = "not-a-number"
            form.setDraft(invalid); form.save()
            let afterInvalid = try Data(contentsOf: paths.root.appendingPathComponent("sources.json"))
            let invalidRejected = form.hasValidationError && submissions == 0 && original == afterInvalid
            var edited = SettingsDraft(initial); edited.messagesHandle = "next@example.invalid"
            form.setDraft(edited)
            form.onSave = { [weak self] config, completion in
                guard let self else { return }
                submissions += 1
                self.saveSettings(config) { result in
                    completion(result)
                    guard case .success = result else { finish(["ok": false, "stage": 1]); return }
                    let stored = try? SourcesConfig.load(paths: self.paths)
                    let shown = self.recent + [self.current].compactMap { $0 }
                    let isolated = shown.count == 3 && shown.allSatisfy { $0.source != .messages } && self.pending.count == 2
                    let recreated = self.localReaders.count == 2 && ObjectIdentifier(self.localReaders[0]) != oldMessages && ObjectIdentifier(self.localReaders[1]) == oldKakao
                    let marksPreserved = self.readMarks == marks && (try? self.queue.reads()) == marks
                    let saved = stored?.messages?.handle == "next@example.invalid" && stored?.kakao == initial.kakao && stored?.instagram == nil
                    let disabled = SourcesConfig(instagram: .init(username: "", threadId: ""))
                    self.saveSettings(disabled) { disabledResult in
                        guard case .success = disabledResult else { finish(["ok": false, "stage": 2]); return }
                        let final = try? SourcesConfig.load(paths: self.paths)
                        let blankDisabled = final?.messages == nil && final?.kakao == nil && final?.instagram?.username == "" && self.sourceStatuses[.messages] == .disabled && self.sourceStatuses[.kakao] == .disabled
                        let selected = multipleConfig
                        let right = PetEvent(eventId: "settings-selected", sender: "fixture.sender", text: "synthetic", threadUrl: "https://www.instagram.com/direct/t/12345/", observedAt: PetEvent.timestamp(), kind: "thread-message")
                        let wrong = PetEvent(eventId: "settings-other", sender: "other.sender", text: "synthetic", threadUrl: right.threadUrl, observedAt: right.observedAt, kind: "thread-message")
                        let second = PetEvent(eventId: "settings-second", sender: "other.sender", text: "synthetic", threadUrl: "https://www.instagram.com/direct/t/67890/", observedAt: right.observedAt, kind: "thread-message")
                        let message = PetEvent(eventId: "settings-message", sender: "messages.contact", text: "synthetic", threadUrl: ConversationKey.local(.messages, identifier: "next@example.invalid").key, observedAt: right.observedAt, kind: "thread-message", source: .messages)
                        let kakao = PetEvent(eventId: "settings-kakao", sender: "kakao.contact", text: "synthetic", threadUrl: ConversationKey.local(.kakao, identifier: "Fixture Other").key, observedAt: right.observedAt, kind: "inbox-preview", source: .kakao)
                        let selection = Self.acceptsEvent(right, config: selected) && Self.acceptsEvent(second, config: selected) && Self.acceptsEvent(message, config: selected) && Self.acceptsEvent(kakao, config: selected) && !Self.acceptsEvent(wrong, config: selected) && !Self.acceptsEvent(right, config: disabled)
                        let mode = (try? FileManager.default.attributesOfItem(atPath: self.paths.root.appendingPathComponent("sources.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600
                        finish(["prefilled": prefilled, "automaticInstagram": automaticInstagram, "clearedInstagram": clearedInstagram, "multipleTargets": multipleSaved, "mismatchedRejected": mismatchedRejected, "retainedOnAdd": retainedOnAdd, "invalidRejected": invalidRejected, "saved": saved,
                            "sourceIsolation": isolated, "readerRecreated": recreated, "readMarksPreserved": marksPreserved,
                            "blankDisabled": blankDisabled, "selectionGuard": selection, "privateMode": mode,
                            "ok": prefilled && automaticInstagram && clearedInstagram && multipleSaved && mismatchedRejected && retainedOnAdd && invalidRejected && saved && isolated && recreated && marksPreserved && blankDisabled && selection && mode])
                    }
                }
            }
            form.save()
        } catch { finish(["ok": false, "stage": 0]) }
    }

    /// Regression for the recorded wall gaps and folded image rows, without user data or visible windows.
    private func checkPetGeometry(to output: URL) {
        let view = CatView(frame: NSRect(origin: .zero, size: CatView.size))
        let rect = view.spriteRect
        var cases = 0, contact = true, continuous = true, coverage = true, inBounds = true, matchesBody = true
        let cap = CatView.spriteHeight * CatView.maxTrail
        for wall in 0..<4 {
            for depth: CGFloat in [0.1, 0.35, 0.8] {
                for held: CGFloat in [0, 0.1, 0.5, 0.9, 1] {
                    for side: CGFloat in [-1, 0, 1] {
                        for pull in [NSPoint(x: -cap, y: -cap), NSPoint(x: cap, y: cap), .zero] {
                            var press: [CGFloat] = [0, 0, 0, 0]
                            press[wall] = depth * (wall < 2 ? rect.width : rect.height)
                            view.press(left: press[0], right: press[1], bottom: press[2], top: press[3], immediately: true)
                            view.hold(at: held, side: side); view.setPull(pull)
                            var area = NSRect(x: rect.midX - 720, y: rect.midY - 450, width: 1440, height: 900)
                            // A full drag trail still separates the panel's sprite from the screen boundary.
                            if wall == 0 { area.origin.x = rect.minX - cap }
                            if wall == 1 { area.origin.x = rect.maxX + cap - area.width }
                            if wall == 2 { area.origin.y = rect.minY - cap }
                            if wall == 3 { area.origin.y = rect.maxY + cap - area.height }
                            view.area = area
                            let strips = view.strips(in: rect), body = view.bodyRect
                            let edge = [body.minX - area.minX, body.maxX - area.maxX, body.minY - area.minY, body.maxY - area.maxY][wall]
                            contact = contact && abs(edge) < 0.000001
                            coverage = coverage && strips.first?.source.minY == 0 && abs((strips.last?.source.maxY ?? 0) - 1) < 0.000001
                            var previous: CatView.Strip?
                            for strip in strips {
                                continuous = continuous && strip.destination.width > 0 && strip.destination.height > 0
                                inBounds = inBounds && view.bounds.insetBy(dx: -0.001, dy: -0.001).contains(strip.destination)
                                if let previous {
                                    continuous = continuous && abs(previous.destination.maxY - strip.destination.minY) < 0.000001
                                    coverage = coverage && abs(previous.source.maxY - strip.source.minY) < 0.000001
                                }
                                previous = strip
                            }
                            matchesBody = matchesBody && body == strips.reduce(NSRect.null) { $0.union($1.destination) }
                            cases += 1
                        }
                    }
                }
            }
        }
        view.area = nil; view.press(left: 0, right: 0, bottom: 0, top: 0, immediately: true)
        view.hold(at: 0.5); view.setPull(NSPoint(x: 15, y: 10))
        let free = view.strips(in: rect)
        let freePull = free.allSatisfy { strip in
            let t = strip.source.minY, dy = (t - 0.5) * rect.height
            let expected = rect.minY + rect.height * t + 10 * exp(-dy * dy / (2 * 60 * 60))
            return abs(strip.destination.minY - expected) < 0.000001
        }
        var localRebound = true
        for wall in 0..<4 {
            var press: [CGFloat] = [0, 0, 0, 0]
            press[wall] = 0.8 * (wall < 2 ? rect.width : rect.height)
            view.press(left: press[0], right: press[1], bottom: press[2], top: press[3], immediately: true)
            view.press(left: 0, right: 0, bottom: 0, top: 0)
            view.setPull(.zero)
            view.area = NSRect(x: -480, y: -682, width: 1440, height: 2046)
            localRebound = localRebound && view.bounds.contains(view.bodyRect)
        }
        let report: [String: Any] = ["cases": cases, "contact": contact, "continuous": continuous, "sourceCoverage": coverage,
            "insideView": inBounds, "bodyMatchesDrawing": matchesBody, "freePullPreserved": freePull,
            "releaseReboundsLocally": localRebound,
            "ok": contact && continuous && coverage && inBounds && matchesBody && freePull && localRebound]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { fputs("Could not save pet geometry report\n", stderr) }
    }

    /// Deliberately numeric-only. Runs the production reader with this app's signing identity.
    private func measureLiveAccessibility() {
        guard let config = try? SourcesConfig.load(paths: paths) else { print("[0]"); return }
        var captures: [KakaoCaptureMetrics] = [], polls: [Double] = []
        var statuses = Array(repeating: 0, count: 5)
        let reader = KakaoReader(name: config.kakaoNames.first, captureMetrics: { captures.append($0) })
        for _ in 0..<100 {
            let started = ProcessInfo.processInfo.systemUptime
            let batch = reader.poll(now: Date())
            polls.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let index: Int
            switch batch.status {
            case .disabled: index = 0
            case .idle: index = 1
            case .observing: index = 2
            case .permissionRequired: index = 3
            case .unavailable: index = 4
            }
            statuses[index] += 1
            reader.acknowledge(Set(batch.events.map(\.identity)))
            usleep(100_000)
        }
        func summary(_ values: [Double]) -> [Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [0, 0, 0] }
            return [sorted[(sorted.count - 1) / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!]
        }
        var report: [Double] = [Double(polls.count)]
        report.append(contentsOf: summary(polls))
        report.append(contentsOf: summary(captures.map(\.milliseconds)))
        report.append(Double(captures.filter(\.deadlineExceeded).count))
        report.append(Double(captures.map(\.nodes).reduce(0, +)) / Double(max(1, captures.count)))
        report.append(contentsOf: statuses.map { Double($0) })
        if let data = try? JSONSerialization.data(withJSONObject: report), let output = String(data: data, encoding: .utf8) { print(output) }
    }

    /// Fake contacts only. Reused event IDs across sources exercise the source-qualified UI identity.
    /// Preview only: nil = the usual samples; otherwise (kakao, instagram, messages) counts, interleaved in time.
    private var fullDesk: (Int, Int, Int)?
    private func fullSourceEvents(_ counts: (Int, Int, Int)) -> [PetEvent] {
        let plan: [(PetSource, Int)] = [(.kakao, counts.0), (.instagram, counts.1), (.messages, counts.2)]
        let texts = ["보고 싶다 ❤️", "ㅋㅋㅋ", "(릴스)", "오늘 저녁에 뭐 먹을래?", "자기가 결정해용", "(이미지)", "응응"]
        var all: [(PetSource, Int)] = []
        for round in 0..<7 { for (source, n) in plan where round < n { all.append((source, round)) } }
        return all.enumerated().map { index, item in
            let (source, n) = item
            let key = source == .instagram ? "https://www.instagram.com/direct/t/fixture/"
                : ConversationKey.local(source, identifier: source == .messages ? "fixture@example.invalid" : "fixture.friend").key
            let label = source == .kakao ? "카톡" : source == .instagram ? "인스타" : "메시지"
            return PetEvent(eventId: "full-\(source)-\(n)", sender: "fixture.sender", text: "\(label) \(n + 1) \(texts[(n + index) % texts.count])", threadUrl: key,
                            observedAt: PetEvent.timestamp(Date().addingTimeInterval(Double(index - all.count) * 60)),
                            kind: source == .kakao ? "inbox-preview" : "thread-message", source: source)
        }
    }

    private func mixedSourceEvents() -> [PetEvent] {
        let samples: [(PetSource, String, String)] = [
            (.instagram, "mixed-1", "Instagram 1 · 사진이 도착했어요"),
            (.messages, "mixed-1", "Messages 1 · 안녕!"),
            (.instagram, "mixed-2", "Instagram 2 · (릴스)"),
            (.messages, "mixed-2", "Messages 2 · 조금 뒤에 만나요"),
            (.kakao, "mixed-1", "KakaoTalk · 새 메시지 예시")
        ]
        return samples.enumerated().map { index, sample in
            let (source, id, text) = sample
            let key = source == .instagram ? "https://www.instagram.com/direct/t/fixture/"
                : ConversationKey.local(source, identifier: source == .messages ? "fixture@example.invalid" : "fixture.friend").key
            return PetEvent(eventId: id, sender: "fixture.sender", text: text, threadUrl: key,
                            observedAt: PetEvent.timestamp(Date().addingTimeInterval(Double(index - samples.count) * 60)),
                            kind: source == .kakao ? "inbox-preview" : "thread-message", source: source)
        }
    }

    /// Exercise real read removal and queue backpressure with synthetic sources in the isolated test home.
    private func checkSourceReads(to output: URL) {
        buildPanel()
        buildMenu()
        statusItem.isVisible = false
        let events = mixedSourceEvents()
        recent = Array(events.dropLast())
        current = events.last
        pending = PetSource.allCases.compactMap { source in
            guard let sample = events.first(where: { $0.source == source }) else { return nil }
            return PetEvent(eventId: "waiting", sender: sample.sender, text: sample.text,
                            threadUrl: sample.threadUrl, observedAt: sample.observedAt, kind: sample.kind, source: source)
        }
        bubble.show(events)
        func shown() -> [PetEvent] { recent + [current].compactMap { $0 } }
        var counts = [shown().count], waiting = [pending.count]
        var sourcesAfterKakao: [String] = []
        for source in [PetSource.kakao, .messages, .instagram] {
            guard let conversation = events.first(where: { $0.source == source })?.conversation else { continue }
            var marks = readMarks
            marks[conversation] = Date()
            applyReads(marks)
            counts.append(shown().count)
            waiting.append(pending.count)
            if source == .kakao { sourcesAfterKakao = shown().map { $0.source.rawValue } }
        }
        let distinct = Set(events.map(\.identity)).count == events.count
        let previousMarks = readMarks
        applyReads([:]) // an older in-flight disk snapshot cannot undo a click/read watermark
        let monotonicReads = readMarks == previousMarks
        // A delayed, older Instagram delivery joins at the oldest end (Instagram has room) and evicts none of the others.
        recent = Array(events.dropLast()); current = events.last
        let delayed = PetEvent(eventId: "late-old", sender: "fixture.sender", text: "synthetic",
            threadUrl: events[0].threadUrl, observedAt: PetEvent.timestamp(Date().addingTimeInterval(-3600)), kind: "thread-message")
        let orderPreserved = rememberForDisplay(delayed).map(\.identity) == ([delayed] + events).map(\.identity)
        recent = []; current = nil
        let capacityRecovery = checkSourceCapacity()
        let report: [String: Any] = [
            "version": 1, "visibleCounts": counts, "pendingCounts": waiting,
            "sourcesAfterKakaoRead": sourcesAfterKakao, "sourceIdentitiesDistinct": distinct,
            "capacityRecovery": capacityRecovery,
            "orderPreserved": orderPreserved,
            "monotonicReads": monotonicReads,
            "ok": counts == [5, 4, 2, 0] && waiting == [3, 2, 1, 0] && distinct && bubble.isHidden && capacityRecovery && orderPreserved && monotonicReads
        ]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("Source read smoke report: \(output.path)")
        } catch { fputs("Could not save source read smoke report\n", stderr) }
    }

    private func checkSourceCapacity() -> Bool {
        // Never use the user's queue when a smoke flag is invoked without an isolated home.
        let resolved = paths.root.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil,
              resolved.hasPrefix(temporary + "/") || resolved.hasPrefix("/private/tmp/") else { return false }
        final class FixtureReader: LocalSourceReader {
            let source = PetSource.messages
            let value: PetEvent
            var accepted = Set<String>()
            init(_ value: PetEvent) { self.value = value }
            func poll(now: Date) -> SourcePoll { SourcePoll(events: [value], status: .observing) }
            func acknowledge(_ identities: Set<String>) { accepted.formUnion(identities) }
        }
        queue = EventQueue(paths: paths)
        defer { try? queue.clear(); localReaders = [] }
        do {
            guard try queue.count() == 0 else { return false }
            var first: PetEvent?
            for index in 0..<EventQueue.capacity {
                let e = PetEvent(eventId: "capacity-\(index)", sender: "fixture.sender", text: "synthetic",
                    threadUrl: "https://www.instagram.com/direct/t/fixture/", observedAt: PetEvent.timestamp(), kind: "thread-message")
                if first == nil { first = e }
                try queue.enqueue(e)
            }
            let value = PetEvent(eventId: "capacity-local", sender: "messages.contact", text: "synthetic",
                threadUrl: ConversationKey.local(.messages, identifier: "fixture@example.invalid").key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
            let reader = FixtureReader(value)
            localReaders = [reader]; lastSourcesPoll = .distantPast
            _ = try pollLocalSources()
            guard reader.accepted.isEmpty, try queue.pending().count == EventQueue.capacity else { return false }
            try queue.consume(first!)
            lastSourcesPoll = .distantPast
            _ = try pollLocalSources()
            let remaining = try queue.count()
            return reader.accepted == [value.identity] && remaining == EventQueue.capacity
        } catch { return false }
    }

    private final class Desk: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.93, alpha: 1).setFill(); bounds.fill()
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: bounds.maxY - 25, width: bounds.width, height: 25).fill()
        }
    }

    /// Renders the pet and five bubbles on a fake 1440×900 desktop with the cat at `catOrigin`.
    private enum DeskMode { case normal, mixed, mixedRead, bubblesHidden, petHidden, moving, pushing, tucked, crowded, squashRight, squashBottom, headRight, headUp, waistRight, bagRight, handLeft, headDown, feetUp, bagLeft, rightFoot, shoulder, knee, bottomContact, topContact, leftContact, rightContact, bottomDeepPull, topDeepPull, leftDeepPull, rightDeepPull }

    private func renderDesk(catOrigin: NSPoint, mode: DeskMode, to output: URL) {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900), area = screen
        let desk = Desk(frame: screen)
        desk.appearance = NSAppearance(named: .aqua)
        // `catOrigin` is in the old 200×390 layout (sprite at +32.65, +4); place the sprite at the same spot.
        cat = CatView(frame: NSRect(origin: .zero, size: CatView.size))
        let spriteAt = { (o: NSPoint) in NSPoint(x: o.x + 32.65 - self.cat.spriteRect.minX, y: o.y + 4 - self.cat.spriteRect.minY) }
        cat.setFrameOrigin(spriteAt(catOrigin))
        cat.excited = ![.bubblesHidden, .petHidden, .tucked].contains(mode)
        bubble = BubbleField(frame: screen)
        arrow = HideArrow(frame: .zero)
        [cat, bubble, arrow].forEach { desk.addSubview($0!) }
        let long = (1...40).map(String.init).joined()
        let samples = mode == .crowded ? [(long, -4), (long, -3), (long, -2), (long, -1), (long, 0)]
            : [("1 (이미지)", -20), ("2 보고 싶다 ❤️", -14), ("3 ㅋㅋㅋ", -9), ("4 (릴스)", -4), ("5 오늘 저녁에 뭐 먹을래? 나는 떡볶이 먹고 싶어!", 0)]
        var events = fullDesk.map(fullSourceEvents) ?? ((mode == .mixed || mode == .mixedRead) ? mixedSourceEvents()
            : samples.compactMap { demoEvent(text: $0.0, minutesAgo: $0.1) })
        if mode == .mixedRead {
            let marks = [ConversationKey.local(.kakao, identifier: "fixture.friend"): Date()]
            events.removeAll { $0.conversation.isRead(observedAt: $0.observedAt, in: marks) }
        }
        hideBubblesUntil = mode == .bubblesHidden ? Date().addingTimeInterval(23 * 60) : nil
        hidePetUntil = mode == .petHidden ? Date().addingTimeInterval(37 * 60) : nil
        tuckedUntil = mode == .tucked ? Date().addingTimeInterval(52 * 60) : nil
        tuckArrowCenter = nil
        cat.isHidden = mode == .petHidden || mode == .tucked
        if mode == .bubblesHidden || mode == .petHidden {
            bubble.isHidden = true
            pending = events
        } else {
            pending = []
            bubble.show(events)
        }
        arrowKey = ""
        cat.area = area.offsetBy(dx: -cat.frame.minX, dy: -cat.frame.minY)
        if mode == .squashRight { cat.press(left: 0, right: 95, bottom: 0, top: 0, immediately: true) }
        if mode == .squashBottom { cat.press(left: 0, right: 0, bottom: 230, top: 0, immediately: true) }
        let edgePulls: [DeskMode: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, NSPoint)] = [
            .bottomContact: (0, 0, 120, 0, 0.9, 0, NSPoint(x: 0, y: -50)),
            .topContact: (0, 0, 0, 120, 0.1, 0, NSPoint(x: 0, y: 50)),
            .leftContact: (55, 0, 0, 0, 0.5, 0.8, NSPoint(x: -50, y: 0)),
            .rightContact: (0, 55, 0, 0, 0.5, -0.8, NSPoint(x: 50, y: 0)),
            .bottomDeepPull: (0, 0, 270, 0, 0.9, 0, NSPoint(x: 0, y: -50)),
            .topDeepPull: (0, 0, 0, 270, 0.1, 0, NSPoint(x: 0, y: 50)),
            .leftDeepPull: (105, 0, 0, 0, 0.5, 0.8, NSPoint(x: -50, y: 0)),
            .rightDeepPull: (0, 105, 0, 0, 0.5, -0.8, NSPoint(x: 50, y: 0))
        ]
        if let edge = edgePulls[mode] {
            cat.press(left: edge.0, right: edge.1, bottom: edge.2, top: edge.3, immediately: true)
            cat.hold(at: edge.4, side: edge.5)
            cat.setPull(edge.6)
        }
        place(pet: cat.bodyRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY), area: area, animated: false)
        if mode == .crowded {
            // Long messages crowded into a corner while the pet is dragged down into it.
            for _ in 1...6 {
                cat.setFrameOrigin(NSPoint(x: cat.frame.minX - 25, y: cat.frame.minY - 25))
                cat.shake(by: NSPoint(x: -25, y: -25))
                place(pet: cat.bodyRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY), area: area, animated: true)
            }
        }
        // A few ticks into a fast drag, held at a given height (0 feet … 1 head): the far parts trail behind.
        // Pushing: a very fast drag left, straight into the left bubble, which must be shoved, not passed through.
        let drags: [DeskMode: (step: NSPoint, held: CGFloat, side: CGFloat)] = [
            .moving: (NSPoint(x: 28, y: 0), 0.03, 0), .pushing: (NSPoint(x: -60, y: 0), 0.03, 0),
            .headRight: (NSPoint(x: 30, y: 0), 0.9, 0), .headUp: (NSPoint(x: 0, y: 30), 0.9, 0), .waistRight: (NSPoint(x: 30, y: 0), 0.5, 0),
            .bagRight: (NSPoint(x: 30, y: 0), 0.6, 0.85), .handLeft: (NSPoint(x: -30, y: 0), 0.55, -0.8),
            .headDown: (NSPoint(x: 0, y: -30), 0.9, 0), .feetUp: (NSPoint(x: 0, y: 30), 0.03, 0), .bagLeft: (NSPoint(x: -30, y: 0), 0.6, 0.85),
            .rightFoot: (NSPoint(x: 30, y: 0), 0.03, 0.4), .shoulder: (NSPoint(x: 30, y: 0), 0.72, 0.45), .knee: (NSPoint(x: 30, y: 0), 0.25, 0.25)]
        if let drag = drags[mode] {
            cat.hold(at: drag.held, side: drag.side)
            for tick in 1...5 {
                let moved = NSPoint(x: catOrigin.x + CGFloat(tick) * drag.step.x, y: catOrigin.y + CGFloat(tick) * drag.step.y)
                cat.setFrameOrigin(spriteAt(moved))
                cat.shake(by: drag.step)
                cat.setPull(NSPoint(x: drag.step.x * 1.5, y: drag.step.y * 1.5)) // the pointer 45pt ahead of the body
                place(pet: cat.bodyRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY), area: area, animated: true)
            }
        }
        desk.layoutSubtreeIfNeeded()
        guard let bitmap = desk.bitmapImageRepForCachingDisplay(in: desk.bounds) else { return }
        desk.cacheDisplay(in: desk.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try image.write(to: output); print("Preview rendered: \(output.path)") }
        catch { fputs("Could not save preview\n", stderr) }
    }

    private func renderPreview(to output: URL) {
        renderDesk(catOrigin: NSPoint(x: 1195, y: 20), mode: .normal, to: output)
    }

    private func renderScenarios(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenarios: [(String, NSPoint, DeskMode)] = [
            ("1-center", NSPoint(x: 620, y: 200), .normal),
            ("1b-mixed-sources", NSPoint(x: 620, y: 200), .mixed),
            ("1c-mixed-after-kakao-read", NSPoint(x: 620, y: 200), .mixedRead),
            ("2-bottom-right-corner", NSPoint(x: 1272.6, y: -4), .normal),
            ("3-top-left-corner", NSPoint(x: -32.6, y: 533), .normal),
            ("4-top-center", NSPoint(x: 620, y: 533), .normal),
            ("4b-top-right-corner", NSPoint(x: 1272.6, y: 533), .normal),
            ("4c-bottom-left-corner", NSPoint(x: -32.6, y: -4), .normal),
            ("4d-left-edge-middle", NSPoint(x: -32.6, y: 250), .normal),
            ("5-bubbles-hidden-with-new-messages", NSPoint(x: 620, y: 200), .bubblesHidden),
            ("6-pet-hidden-arrow-only", NSPoint(x: 1315, y: 20), .petHidden),
            ("7-held-by-feet-dragged-right", NSPoint(x: 500, y: 200), .moving),
            ("8-tucked-in-corner-messages-still-show", NSPoint(x: 1400, y: -300), .tucked),
            ("8b-tucked-bottom-middle", NSPoint(x: 620, y: -330), .tucked),
            ("8c-tucked-top-middle", NSPoint(x: 620, y: 880), .tucked),
            ("8d-tucked-left-middle", NSPoint(x: -170, y: 300), .tucked),
            ("8e-tucked-right-middle", NSPoint(x: 1408, y: 300), .tucked),
            ("8f-tucked-top-left", NSPoint(x: -150, y: 880), .tucked),
            ("8g-tucked-top-right", NSPoint(x: 1408, y: 880), .tucked),
            ("8h-tucked-bottom-left", NSPoint(x: -150, y: -330), .tucked),
            ("8i-tucked-bottom-right-of-middle", NSPoint(x: 1000, y: -330), .tucked),
            ("8j-tucked-left-lower", NSPoint(x: -170, y: 120), .tucked),
            ("8k-tucked-dropped-mid-screen", NSPoint(x: 600, y: 300), .tucked),
            ("9-fast-drag-left-shoves-bubble", NSPoint(x: 800, y: 200), .pushing),
            ("10-long-messages-crowded-bottom-left", NSPoint(x: 20, y: -100), .crowded),
            ("11-pressed-into-right-edge-squashes", NSPoint(x: 1272.6, y: 200), .squashRight),
            ("12-pressed-into-bottom-edge-squashes", NSPoint(x: 620, y: -4), .squashBottom),
            ("13-held-by-head-dragged-right", NSPoint(x: 500, y: 200), .headRight),
            ("14-held-by-head-dragged-up", NSPoint(x: 620, y: 100), .headUp),
            ("15-held-by-waist-dragged-right", NSPoint(x: 500, y: 200), .waistRight),
            ("16-held-by-bag-dragged-right", NSPoint(x: 500, y: 200), .bagRight),
            ("17-held-by-hand-dragged-left", NSPoint(x: 700, y: 200), .handLeft),
            ("18-held-by-head-dragged-down", NSPoint(x: 620, y: 400), .headDown),
            ("19-held-by-feet-dragged-up", NSPoint(x: 620, y: 100), .feetUp),
            ("20-held-by-bag-dragged-left", NSPoint(x: 700, y: 200), .bagLeft),
            ("21-held-by-right-foot-dragged-right", NSPoint(x: 500, y: 200), .rightFoot),
            ("22-held-by-shoulder-dragged-right", NSPoint(x: 500, y: 200), .shoulder),
            ("23-held-by-knee-dragged-right", NSPoint(x: 500, y: 200), .knee),
            ("24-bottom-contact-while-body-trails", NSPoint(x: 620, y: 46), .bottomContact),
            ("25-top-contact-while-body-trails", NSPoint(x: 620, y: 508), .topContact),
            ("26-left-contact-while-body-trails", NSPoint(x: 17.35, y: 200), .leftContact),
            ("27-right-contact-while-body-trails", NSPoint(x: 1222.65, y: 200), .rightContact),
            ("28-bottom-deep-press-pulling-head", NSPoint(x: 620, y: 46), .bottomDeepPull),
            ("29-top-deep-press-pulling-feet", NSPoint(x: 620, y: 508), .topDeepPull),
            ("30-left-deep-press-pulling-bag", NSPoint(x: 17.35, y: 200), .leftDeepPull),
            ("31-right-deep-press-pulling-hand", NSPoint(x: 1222.65, y: 200), .rightDeepPull),
        ]
        for (name, origin, mode) in scenarios {
            renderDesk(catOrigin: origin, mode: mode, to: directory.appendingPathComponent("\(name).png"))
        }
        // Per-app cap: Kakao 1 + Messages 1 + seven Instagram keeps 1 + 1 + 4.
        let kept = Orbit.capped(fullSourceEvents((1, 7, 1)))
        precondition(kept.count == 6 && kept.filter { $0.source == .instagram }.count == 4
                     && kept.contains { $0.source == .kakao } && kept.contains { $0.source == .messages }, "per-source cap")
        precondition(Orbit.capped(fullSourceEvents((7, 7, 7))).count == 12, "total cap")
        let full = scenarios.filter { ["1-center", "2-bottom-right-corner", "3-top-left-corner", "4-top-center", "4b-top-right-corner",
                                       "4c-bottom-left-corner", "4d-left-edge-middle"].contains($0.0) || $0.2 == .tucked }
        for (counts, tag) in [((4, 4, 4), "12"), ((1, 7, 1), "kakao1-ig7-msg1")] {
            fullDesk = counts
            for (name, origin, mode) in full {
                renderDesk(catOrigin: origin, mode: mode, to: directory.appendingPathComponent("F\(tag)-\(name).png"))
            }
        }
        fullDesk = nil
    }

    private func finishSmokeTest() {
        guard smokeBurstCount == nil, let output = smokeReport, !smokeFinishing else { return }
        smokeFinishing = true
        // This runs after the consume already enqueued by present(), on the same serial queue.
        io.async { [weak self] in
            guard let self else { return }
            let remaining = (try? self.queue?.count()) ?? -1
            DispatchQueue.main.async {
                let report: [String: Any] = [
                    "version": 1, "displayedEventId": self.current?.eventId as Any? ?? NSNull(),
                    "remainingQueueCount": remaining, "bubbleVisible": !self.bubble.isHidden, "petTucked": self.isTucked,
                    "ok": self.current != nil && !self.bubble.isHidden
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output)
                    print("AppKit smoke report: \(output.path)")
                } catch { fputs("Could not save smoke report\n", stderr) }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @objc private func clearMessages() {
        queueGeneration += 1
        pending.removeAll(); current = nil; recent.removeAll()
        bubble.isHidden = true; cat.excited = false
        io.async { [weak self] in
            guard let self, let queue = self.queue else { return }
            try? queue.clear()
        }
        updateStatus()
    }

    private func openURLInChrome(_ url: URL) {
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { _, _ in }
        } else { NSWorkspace.shared.open(url) }
    }

    private func openConversation(_ event: PetEvent) {
        guard let destination = event.destination(messagesHandle: sourceConfig.messages?.handle) else {
            lastError = "Conversation unavailable · check sources.json"
            updateStatus()
            return
        }
        switch destination {
        case .instagram(let url):
            openURLInChrome(url)
        case .messages(let url):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else {
                lastError = "Messages is not installed"
                updateStatus()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error == nil { self.markRead(event.conversation) }
                    else { self.lastError = "Could not open Messages"; self.updateStatus() }
                }
            }
            return
        case .kakao:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kakao.KakaoTalkMac") else {
                lastError = "KakaoTalk is not installed"
                updateStatus()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error == nil { self.markRead(event.conversation) }
                    else { self.lastError = "Could not open KakaoTalk"; self.updateStatus() }
                }
            }
            return
        }
        if event.kind == "test" { dismissCurrent() } else { markRead(event.conversation) }
    }

    @objc private func openInbox() { openURLInChrome(URL(string: "https://www.instagram.com/direct/inbox/")!) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func persistPosition() {
        let sprite = catSpriteOnScreen()
        UserDefaults.standard.set([sprite.minX, sprite.minY], forKey: "pet.sprite.origin")
    }

    @objc private func screenChanged() {
        petTarget = nil; petDragArea = nil
        cat.setPull(.zero)
        cat.press(left: 0, right: 0, bottom: 0, top: 0)
        clampPosition(); persistPosition()
    }

    private func trimKnownIDs() {
        guard knownOrder.count > 1024 else { return }
        knownOrder = Array(knownOrder.suffix(512))
        knownIDs = Set(knownOrder).union(pending.map(\.identity))
        if let current { knownIDs.insert(current.identity) }
    }

    /// Shown bubbles expire on their own only after 12 hours.
    static let bubbleLifetime: TimeInterval = 12 * 60 * 60

    private func pruneExpiredMemory() {
        let cutoff = Date().addingTimeInterval(-EventQueue.retention)
        pending.removeAll { (PetEvent.date($0.observedAt) ?? .distantPast) < cutoff }
        let stale = Date().addingTimeInterval(-Self.bubbleLifetime)
        func old(_ event: PetEvent) -> Bool { (PetEvent.date(event.observedAt) ?? .distantPast) < stale }
        let before = (recent + [current].compactMap { $0 }).map(\.identity)
        recent.removeAll(where: old)
        if let event = current, old(event) { current = recent.popLast() }
        let still = recent + [current].compactMap { $0 }
        guard still.map(\.identity) != before else { return }
        if still.isEmpty { bubble.isHidden = true; cat.excited = false }
        else if !bubble.isHidden { bubble.show(still) }
    }

    private func updateClickThrough() {
        guard !cat.isDragging, !arrow.isDragging else { return }
        let mouse = NSEvent.mouseLocation
        let catBounds = cat.spriteRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY)
        // Transparent space must allow interaction with the application underneath.
        if !isHidden && !isTucked {
            let over = catBounds.contains(panel.convertPoint(fromScreen: mouse))
            panel.ignoresMouseEvents = !over
            // An open hand over the pet (re-asserted on every move, since other apps reset the cursor).
            if over { NSCursor.openHand.set() } else if overPet { NSCursor.arrow.set() }
            overPet = over
        } else if overPet { NSCursor.arrow.set(); overPet = false }
        let point = overlay.convertPoint(fromScreen: mouse)
        overlay.ignoresMouseEvents = bubble.hitTest(point) == nil && arrow.hitTest(point) == nil
    }

    /// A drop that leaves almost nothing of the pet on screen tucks it away behind its arrow.
    /// Dragging into an edge: the pet stays on screen and is pressed into the wall by however far the pointer
    /// went past it. The screen under the pointer counts, so the pet can still move between displays.
    private func dragPet(to origin: NSPoint) {
        let sprite = cat.spriteRect.offsetBy(dx: origin.x + cat.frame.minX, dy: origin.y + cat.frame.minY)
        let mouse = NSEvent.mouseLocation
        // The pet's walls are the display's real border (over the menu bar and Dock), so it squashes flush.
        guard let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? catScreen())?.frame else { return }
        let left = max(0, area.minX - sprite.minX), right = max(0, sprite.maxX - area.maxX)
        let bottom = max(0, area.minY - sprite.minY), top = max(0, sprite.maxY - area.maxY)
        petTarget = NSPoint(x: origin.x + left - right, y: origin.y + bottom - top)
        petDragArea = area
        cat.press(left: left, right: right, bottom: bottom, top: top)
        lastPress = (left, right, bottom, top)
        followPet(step: 0) // re-pull at the mouse's own event rate, not just on the 20 fps tick
    }

    /// The body eases after the pointer; the grabbed spot stays under it, so the gap is drawn as the pull.
    /// Rubbing back and forth fast therefore squashes the held part while the body barely moves.
    /// A gap beyond 15% of the height drags the body along.
    private func followPet(step: CGFloat) {
        guard let target = petTarget else { return }
        var origin = panel.frame.origin
        origin = NSPoint(x: origin.x + (target.x - origin.x) * step, y: origin.y + (target.y - origin.y) * step)
        var gap = NSPoint(x: target.x - origin.x, y: target.y - origin.y)
        let cap = cat.spriteRect.height * CatView.maxTrail, length = hypot(gap.x, gap.y)
        if length > cap {
            origin = NSPoint(x: target.x - gap.x * cap / length, y: target.y - gap.y * cap / length)
            gap = NSPoint(x: target.x - origin.x, y: target.y - origin.y)
        }
        if hypot(gap.x, gap.y) < 0.3 && !cat.isDragging { origin = target; gap = .zero }
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
        updatePetArea()
        cat.setPull(gap)
        if gap == .zero && !cat.isDragging {
            petTarget = nil; petDragArea = nil
            clampPosition(); persistPosition()
        }
    }

    /// Panel motion and screen-local wall coordinates must change in the same mouse event.
    private func updatePetArea() {
        guard let area = petDragArea ?? catScreen()?.frame else { return }
        cat.area = area.offsetBy(dx: -panel.frame.minX - cat.frame.minX, dy: -panel.frame.minY - cat.frame.minY)
    }

    private func droppedPet() {
        let press = lastPress
        let corner = max(press.left, press.right) >= Self.cornerPress && max(press.bottom, press.top) >= Self.cornerPress
        lastPress = (0, 0, 0, 0)
        cat.press(left: 0, right: 0, bottom: 0, top: 0)
        if corner {
            if let target = petTarget { panel.setFrameOrigin(target) }
            petTarget = nil; petDragArea = nil
            cat.setPull(.zero)
            // Slip just past the corner, so the arrow and incoming bubbles huddle right in it.
            let sprite = catSpriteOnScreen()
            let dx = press.right > press.left ? sprite.width - 20 : -(sprite.width - 20)
            let dy = press.top > press.bottom ? sprite.height - 20 : -(sprite.height - 20)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
            cat.press(left: 0, right: 0, bottom: 0, top: 0, immediately: true)
            tuckedUntil = Date().addingTimeInterval(TimeInterval(Self.tuckMinutes * 60))
            panel.orderOut(nil)
            arrowKey = ""
            updateStatus()
        } else if petTarget == nil {
            petDragArea = nil
            clampPosition()
            persistPosition()
        } // otherwise the body finishes catching up on the tick, then clamps and saves
    }

    /// Pop the pet back out, fully on screen next to the edge it was tucked behind.
    private func untuck() {
        tuckedUntil = nil
        clampPosition(keep: .infinity)
        persistPosition()
        cat.shake(by: NSPoint(x: 0, y: 25))
        arrowKey = ""
        panel.orderFrontRegardless()
        updateStatus()
    }

    private func clampPosition(keep requested: CGFloat = PetController.keepVisible) {
        // The character may hide partly off-screen, but keepVisible points of it always stay reachable.
        let sprite = catSpriteOnScreen()
        guard let area = catScreen()?.frame else { return }
        let keepX = min(requested, sprite.width), keepY = min(requested, sprite.height)
        let x = min(max(sprite.minX, area.minX - sprite.width + keepX), area.maxX - keepX)
        let y = min(max(sprite.minY, area.minY - sprite.height + keepY), area.maxY - keepY)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + x - sprite.minX, y: panel.frame.minY + y - sprite.minY))
        updatePetArea()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()

// shortcut: private WindowServer SPI (widely used by cursor/pet apps); if a macOS update removes it, the hand shows only while the app is active.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
