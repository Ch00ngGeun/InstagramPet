import AppKit
import PetCore
import PetSources

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
