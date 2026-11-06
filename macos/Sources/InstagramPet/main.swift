import AppKit
import PetCore

// The application deliberately has no network client. Chrome is the only DM source.
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
    static let bubbleCount = 5

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
        let spread: CGFloat = 95 * .pi / 180, step = 2 * spread / CGFloat(bubbleCount - 1)
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
            var y = top ? area.maxY : area.minY
            var rowRects: [[NSRect]] = []
            for row in (top ? rows : rows.reversed()) {
                let height = row.map(\.height).max() ?? 0
                let total = row.reduce(0) { $0 + $1.width }
                // Leave the arrow its own spot in the corner on the edge row.
                let inset = rowRects.isEmpty ? arrow.width : 0
                var x = right ? area.maxX - inset - total : area.minX + inset
                var cells: [NSRect] = []
                for size in row {
                    cells.append(NSRect(x: x, y: top ? y - size.height : y, width: size.width, height: size.height))
                    x += size.width
                }
                if top { rowRects.append(cells) } else { rowRects.insert(cells, at: 0) }
                y += top ? -height : height
            }
            rects = rowRects.flatMap { $0 }
        } else if min(db, dt) <= min(dl, dr) {
            let top = dt < db, total = oldest.reduce(0) { $0 + $1.width }
            // Run from beside the arrow toward the middle; flip if that side lacks room.
            var x = arrow.midX < area.midX ? arrow.maxX : arrow.minX - total
            if x + total > area.maxX { x = arrow.minX - total }
            if x < area.minX { x = arrow.maxX }
            x = min(max(x, area.minX), area.maxX - total)
            for size in oldest {
                rects.append(NSRect(x: x, y: top ? area.maxY - size.height : area.minY, width: size.width, height: size.height))
                x += size.width
            }
        } else {
            let right = dr < dl, total = oldest.reduce(0) { $0 + $1.height }
            var top = arrow.midY > area.midY ? arrow.minY : arrow.maxY + total
            if top - total < area.minY { top = arrow.maxY + total }
            if top > area.maxY { top = arrow.minY }
            top = min(max(top, area.minY + total), area.maxY)
            for size in oldest {
                rects.append(NSRect(x: right ? area.maxX - size.width : area.minX, y: top - size.height, width: size.width, height: size.height))
                top -= size.height
            }
        }
        return rects.reversed()
    }

    /// Centres for bubbles of these sizes (newest first).
    static func lineGoals(_ sizes: [NSSize], pet: NSRect, area: NSRect) -> [NSPoint] {
        guard !sizes.isEmpty else { return [] }
        if let corner = tuckCorner(pet: pet, area: area) { return Array(repeating: corner, count: sizes.count) }
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

/// One soft slime blob: flat white, no outline or tail. It flattens where it touches a screen edge or a neighbour,
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
        setAccessibilityHelp("Click to open this conversation in Google Chrome. Right-click to hide bubbles for a while.")
        toolTip = "Open conversation in Google Chrome · Right-click to hide for a while"
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

    override func draw(_ dirtyRect: NSRect) { Slime.fill(blob) }

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
        wobble = Slime.wobble(event.eventId)
        messageField.stringValue = Self.message(event)
        timeField.stringValue = Self.time(event)
        setAccessibilityLabel("\(timeField.stringValue): \(messageField.stringValue)")
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
        order = Array(events.suffix(Orbit.bubbleCount))
        let ids = Set(order.map(\.eventId))
        for (id, view) in views where !ids.contains(id) { view.removeFromSuperview(); views[id] = nil }
        for event in order where views[event.eventId] == nil {
            let view = BubbleView(frame: .zero)
            view.alphaValue = 0
            view.onClick = { [weak self] in self?.onClick?($0) }
            view.show(event)
            addSubview(view); views[event.eventId] = view
        }
        solvedKey = ""
        isHidden = false
    }

    /// Re-solve only when the pet, the screen or the messages change; spring every tick.
    func update(pet: NSRect, area: NSRect, animated: Bool) {
        let key = "\(pet.integral)|\(area)|\(order.map(\.eventId))|\(String(describing: Orbit.tuckAnchor))"
        if key != solvedKey {
            solvedKey = key
            let newest = Array(order.reversed())
            let options = newest.map { event in BubbleView.shapes.indices.map { BubbleView.footprint(for: event, shape: $0) } }
            let spots = Orbit.place(options, slots: Array(newest.indices), pet: pet, area: area)
            footprints = spots.map(\.rect)
            for (event, spot) in zip(newest, spots) {
                guard let view = views[event.eventId] else { continue }
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
                let theirs = other.footprintNow, d = NSPoint(x: theirs.midX - c.x, y: theirs.midY - c.y)
                let distance = hypot(d.x, d.y)
                guard distance > 1 else { continue }
                let n = NSPoint(x: d.x / distance, y: d.y / distance)
                let reachMine = abs(n.x) * mine.width / 2 + abs(n.y) * mine.height / 2
                let reachTheirs = abs(n.x) * theirs.width / 2 + abs(n.y) * theirs.height / 2
                let share = distance * reachMine / (reachMine + reachTheirs)
                // The neighbour's drawn ellipse: body (footprint minus tailRoom) grown by the bulge.
                let body = theirs.insetBy(dx: BubbleView.tailRoom, dy: BubbleView.tailRoom)
                let zone = body.insetBy(dx: -body.width * (BubbleView.bulge - 1) / 2, dy: -body.height * (BubbleView.bulge - 1) / 2)
                walls.append(Wall(point: NSPoint(x: c.x + n.x * share, y: c.y + n.y * share), normal: n, zone: zone))
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
    /// Room on every side of the sprite for a 30% trail, lean and squash bulge.
    static let room: CGFloat = 112
    static let size = NSSize(width: 360, height: 338 + 2 * 112)
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
        let rect = spriteRect
        let l = max(0, squash[0]), r = max(0, squash[1]), b = max(0, squash[2]), t = max(0, squash[3])
        let squeezeX = l + r, squeezeY = b + t
        let width = max(rect.width * 0.2, rect.width - squeezeX), height = max(rect.height * 0.2, rect.height - squeezeY)
        let minX = l >= r ? rect.minX : rect.maxX - width, minY = b >= t ? rect.minY : rect.maxY - height
        // Same bulges as drawn: a puddle spreads sideways, a side squeeze swells away from the wall.
        let spread = squeezeY * 0.4, swell = squeezeX * 0.55
        var body = NSRect(x: minX - spread, y: minY, width: width + 2 * spread, height: height)
        if l > r { body.size.width += swell } else if r > l { body.origin.x -= swell; body.size.width += swell }
        return body
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
            let top = NSPoint(x: lag.x * pull(x: 0.85, t: 0.9), y: lag.y * pull(x: 0.85, t: 0.9))
            // Rides on the real (possibly squashed) head, not where the head would be unsquashed.
            let body = bodyRect.offsetBy(dx: 0, dy: rect.minY - spriteRect.minY)
            heart.draw(at: NSPoint(x: min(body.maxX - 4, bounds.maxX - 24) + top.x, y: body.maxY - 34 + sin(phase) * 3 + top.y), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: pink])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The sprite in thin horizontal strips: pressed against a wall it flattens there and its mass bulges out
    /// elsewhere, so it loses its shape like slime instead of being clipped by the screen edge.
    private func drawSquashed(_ sprite: NSImage, in rect: NSRect) {
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        let l = squash[0], r = squash[1], b = squash[2], t = squash[3]
        guard squash.contains(where: { abs($0) > 0.3 }) || abs(lag.x) + abs(lag.y) > 0.3 else {
            sprite.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints); return
        }
        let squeezeX = l + r, squeezeY = b + t
        // The wall side stays put; the far side gives way.
        let width = max(rect.width * 0.2, rect.width - squeezeX), height = max(rect.height * 0.2, rect.height - squeezeY)
        let minX = l >= r ? rect.minX : rect.maxX - width
        let minY = b >= t ? rect.minY : rect.maxY - height
        // Strips about 2pt tall, so neighbouring strips differ too little to show steps.
        let n = max(48, Int(height / 2)), size = sprite.size
        for i in 0..<n {
            let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n), tm = (t0 + t1) / 2
            // Squeezed sideways: fattest in the middle, bulging away from the wall.
            let swell = squeezeX * 0.55 * sin(.pi * tm)
            // Squashed from above or below: the mass spreads like a puddle near that wall.
            let nearWall = b >= t ? 1 - tm : tm
            let spread = squeezeY * 0.4 * pow(sin(.pi / 2 * (0.25 + 0.75 * nearWall)), 2)
            var x0 = minX - spread - (r > l ? swell : 0), x1 = minX + width + spread + (l >= r && l > 0 ? swell : 0)
            if l > 0 && r > 0 { x0 = minX - swell / 2 - spread; x1 = minX + width + swell / 2 + spread }
            // Each strip's ends and edges move with the grabbed area by their own amount: stretched where it is
            // pulled away, squashed where it is pushed into the body, untouched far away.
            x0 += lag.x * pull(x: 0, t: tm); x1 += lag.x * pull(x: 1, t: tm)
            if let area { x0 = max(x0, area.minX); x1 = min(x1, area.maxX) }
            let column = (grabSide + 1) / 2
            var y0 = minY + height * t0 + lag.y * pull(x: column, t: t0), y1 = minY + height * t1 + lag.y * pull(x: column, t: t1)
            if let area { y0 = max(area.minY, min(area.maxY, y0)); y1 = max(area.minY, min(area.maxY, y1)) }
            guard x1 > x0, y1 > y0 else { continue }
            let source = NSRect(x: 0, y: size.height * t0, width: size.width, height: size.height * (t1 - t0))
            sprite.draw(in: NSRect(x: x0, y: y0, width: max(1, x1 - x0), height: y1 - y0 + 0.6), from: source,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
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
    private var bubbleTimer: Timer?
    private var shownAt = Date()
    private var pending: [PetEvent] = []
    private var current: PetEvent?
    private var recent: [PetEvent] = [] // the (up to four) messages shown before `current`
    private var readMarks: [String: Date] = [:]
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
    private var overPet = false
    private var lastPress: (left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat) = (0, 0, 0, 0)
    private var arrowDragStart: (panel: NSPoint, arrow: NSPoint)?
    private var lastError: String?
    private let io = DispatchQueue(label: "com.instagrampet.queue", qos: .utility)
    private var smokeReport: URL?
    private var smokeFinishing = false
    private var previewMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        }
        queue = EventQueue(paths: paths)
        do { try paths.prepare() }
        catch { lastError = "Cannot open private queue" }
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
                if let visible = self.catScreen()?.frame {
                    self.cat.area = visible.offsetBy(dx: -origin.x - self.cat.frame.minX, dy: -origin.y - self.cat.frame.minY)
                }
                self.lastCatOrigin = origin
                self.cat.needsDisplay = true
            }
            self.layoutOverlay(animated: true)
            self.updateClickThrough()
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updateClickThrough() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateClickThrough(); return event
        }
        updateClickThrough()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        poll()
        if smokeReport != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishSmokeTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if smokeReport == nil, !previewMode { persistPosition() }
        animationTimer?.invalidate(); pollTimer?.invalidate(); bubbleTimer?.invalidate()
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
        statusItem.button?.toolTip = "Instagram Pet · requires an open Instagram tab"
        let menu = NSMenu()
        menu.addItem(item("Instagram Pet · MVP"))
        statusLine = item("Waiting for Chrome observations"); menu.addItem(statusLine)
        menu.addItem(.separator())
        let bubbles = item("말풍선 잠깐 숨기기"); bubbles.submenu = hideMenu(action: #selector(hideBubblesFor(_:))); menu.addItem(bubbles)
        let pet = item("펫 잠깐 숨기기"); pet.submenu = hideMenu(action: #selector(hidePetFor(_:))); menu.addItem(pet)
        showNowItem = item("지금 다시 보이기", action: #selector(showNow)); menu.addItem(showNowItem)
        menu.addItem(item("Show Latest Message", action: #selector(showLatest)))
        menu.addItem(item("Show Demo Bubble", action: #selector(showDemo)))
        menu.addItem(item("Clear Waiting Messages", action: #selector(clearMessages)))
        menu.addItem(.separator())
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

    private func updateStatus() {
        if let lastError { statusLine.title = lastError }
        else if isTucked { statusLine.title = "펫 가장자리에 숨김 · \(remaining(tuckedUntil))" }
        else if isHidden { statusLine.title = "펫 숨김 · \(remaining(hidePetUntil)) · \(pending.count) waiting" }
        else if paused { statusLine.title = "말풍선 숨김 · \(remaining(hideBubblesUntil)) · \(pending.count) waiting" }
        else if !pending.isEmpty { statusLine.title = "\(pending.count) message(s) waiting" }
        else { statusLine.title = "Ready · open Instagram tab required" }
        showNowItem.isEnabled = isHidden || paused || isTucked
    }

    private func poll() {
        guard queue != nil, !pollInFlight else { return }
        pruneExpiredMemory()
        // Leave excess events on disk rather than silently dropping them from memory.
        guard pending.count < 100 else { return }
        pollInFlight = true
        let generation = queueGeneration
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { (try self.queue.pending(), try self.queue.reads()) }
            DispatchQueue.main.async {
                self.pollInFlight = false
                guard generation == self.queueGeneration else { return }
                switch result {
                case .success(let (events, reads)):
                    self.lastError = nil
                    self.applyReads(reads)
                    for event in events where !self.isRead(event) {
                        guard self.pending.count < 100 else { break }
                        if self.knownIDs.contains(event.eventId) { continue }
                        // Validate again at the display boundary, including the URL.
                        guard (try? event.validate()) != nil else { continue }
                        self.knownIDs.insert(event.eventId)
                        self.knownOrder.append(event.eventId)
                        self.pending.append(event)
                    }
                    self.trimKnownIDs()
                    self.presentNextIfPossible()
                    if !self.bubble.isHidden { self.scheduleDismiss() }
                case .failure:
                    self.lastError = "Queue read failed · check data folder"
                }
                self.updateStatus()
            }
        }
    }

    /// Seen in Chrome (or opened from a bubble): that thread's bubbles disappear.
    private func isRead(_ event: PetEvent) -> Bool {
        guard let at = readMarks[event.threadUrl], let observed = PetEvent.date(event.observedAt) else { return false }
        return observed <= at
    }

    private func applyReads(_ reads: [String: Date]) {
        guard reads != readMarks else { return }
        readMarks = reads
        pending.removeAll(where: isRead)
        let before = (recent + [current].compactMap { $0 }).map(\.eventId)
        recent.removeAll(where: isRead)
        if let shown = current, isRead(shown) { current = recent.popLast() }
        let still = recent + [current].compactMap { $0 }
        guard !bubble.isHidden, still.map(\.eventId) != before else { return }
        // Other threads' bubbles stay; if nothing is left, the queue moves on or goes quiet.
        if still.isEmpty { dismissCurrent() } else { bubble.show(still) }
        updateStatus()
    }

    private func markRead(_ threadUrl: String) {
        var marks = readMarks
        marks[threadUrl] = Date()
        applyReads(marks)
        io.async { [weak self] in try? self?.queue?.markRead(threadUrl: threadUrl) }
    }

    private func presentNextIfPossible() {
        guard !paused, !isHidden, bubble.isHidden, !pending.isEmpty else { return }
        if let previous = current, previous.kind != "test" { recent = Array((recent + [previous]).suffix(Orbit.bubbleCount - 1)) }
        current = pending.removeFirst()
        if let current { present(current) }
    }

    private func present(_ event: PetEvent) {
        guard !paused, !isHidden else { return }
        bubbleTimer?.invalidate()
        bubble.show(recent.filter { $0.eventId != event.eventId } + [event])
        layoutOverlay(animated: false)
        // Retain undisplayed events on disk across app quits. Consume only on display.
        io.async { [weak self] in
            guard let queue = self?.queue else { return }
            try? queue.consume(event)
        }
        cat.excited = true
        if smokeReport == nil { overlay.orderFrontRegardless(); panel.orderFrontRegardless() }
        // A readable, finite display period; the latest bubble remains available via the menu.
        shownAt = Date(); bubbleTimer = nil
        scheduleDismiss()
        updateStatus()
        if smokeReport != nil { finishSmokeTest() }
    }

    // 12s when alone; when more are waiting, ~15 chars/s reading time (1.5–4s) so a burst doesn't back up.
    static func burstHold(_ text: String) -> TimeInterval { min(4, max(1.5, 1 + Double(text.count) * 0.07)) }
    /// Bubbles stay up: they leave only when hidden, read in Chrome, or 12 hours old. The timer just paces
    /// a backlog, moving on to the next waiting message after a short read.
    private func scheduleDismiss() {
        guard !pending.isEmpty else { bubbleTimer?.invalidate(); bubbleTimer = nil; return }
        let fire = shownAt.addingTimeInterval(Self.burstHold(current?.text ?? ""))
        if let timer = bubbleTimer, timer.isValid, timer.fireDate <= fire { return }
        bubbleTimer?.invalidate()
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: max(0, fire.timeIntervalSinceNow), repeats: false) { [weak self] _ in self?.dismissCurrent() }
    }

    @objc private func dismissCurrent() {
        bubbleTimer?.invalidate(); bubbleTimer = nil
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
        bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false
        arrowKey = ""
        updateStatus()
    }

    @objc private func hidePetFor(_ sender: NSMenuItem) {
        hidePetUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false
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
            recent = Array(prior.filter { $0.kind != "test" }.suffix(Orbit.bubbleCount - 1))
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

    private final class Desk: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(calibratedRed: 0.86, green: 0.89, blue: 0.93, alpha: 1).setFill(); bounds.fill()
            NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: bounds.maxY - 25, width: bounds.width, height: 25).fill()
        }
    }

    /// Renders the pet and five bubbles on a fake 1440×900 desktop with the cat at `catOrigin`.
    private enum DeskMode { case normal, bubblesHidden, petHidden, moving, pushing, tucked, crowded, squashRight, squashBottom, headRight, headUp, waistRight, bagRight, handLeft, headDown, feetUp, bagLeft, rightFoot, shoulder, knee }

    private func renderDesk(catOrigin: NSPoint, mode: DeskMode, to output: URL) {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900), area = NSRect(x: 0, y: 0, width: 1440, height: 875)
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
        hideBubblesUntil = mode == .bubblesHidden ? Date().addingTimeInterval(23 * 60) : nil
        hidePetUntil = mode == .petHidden ? Date().addingTimeInterval(37 * 60) : nil
        tuckedUntil = mode == .tucked ? Date().addingTimeInterval(52 * 60) : nil
        tuckArrowCenter = nil
        cat.isHidden = mode == .petHidden || mode == .tucked
        if mode == .bubblesHidden || mode == .petHidden {
            bubble.isHidden = true
            pending = samples.compactMap { demoEvent(text: $0.0, minutesAgo: $0.1) }
        } else {
            pending = []
            bubble.show(samples.compactMap { demoEvent(text: $0.0, minutesAgo: $0.1) })
        }
        arrowKey = ""
        cat.area = area.offsetBy(dx: -cat.frame.minX, dy: -cat.frame.minY)
        if mode == .squashRight { cat.press(left: 0, right: 95, bottom: 0, top: 0, immediately: true) }
        if mode == .squashBottom { cat.press(left: 0, right: 0, bottom: 230, top: 0, immediately: true) }
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
        ]
        for (name, origin, mode) in scenarios {
            renderDesk(catOrigin: origin, mode: mode, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    private func finishSmokeTest() {
        guard let output = smokeReport, !smokeFinishing else { return }
        smokeFinishing = true
        // This runs after the consume already enqueued by present(), on the same serial queue.
        io.async { [weak self] in
            guard let self else { return }
            let remaining = (try? self.queue?.count()) ?? -1
            DispatchQueue.main.async {
                let report: [String: Any] = [
                    "version": 1, "displayedEventId": self.current?.eventId as Any? ?? NSNull(),
                    "remainingQueueCount": remaining, "bubbleVisible": !self.bubble.isHidden,
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
        bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false
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
        guard (try? event.validate()) != nil else { return }
        // Demo bubbles never pretend that the artificial thread exists.
        let link = event.kind == "test" ? "https://www.instagram.com/direct/inbox/" : event.threadUrl
        guard let url = URL(string: link) else { return }
        openURLInChrome(url)
        if event.kind == "test" { dismissCurrent() } else { markRead(event.threadUrl) }
    }

    @objc private func openInbox() { openURLInChrome(URL(string: "https://www.instagram.com/direct/inbox/")!) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func persistPosition() {
        let sprite = catSpriteOnScreen()
        UserDefaults.standard.set([sprite.minX, sprite.minY], forKey: "pet.sprite.origin")
    }

    @objc private func screenChanged() { clampPosition(); persistPosition() }

    private func trimKnownIDs() {
        guard knownOrder.count > 1024 else { return }
        knownOrder = Array(knownOrder.suffix(512))
        knownIDs = Set(knownOrder).union(pending.map(\.eventId))
        if let current { knownIDs.insert(current.eventId) }
    }

    /// Shown bubbles expire on their own only after 12 hours.
    static let bubbleLifetime: TimeInterval = 12 * 60 * 60

    private func pruneExpiredMemory() {
        let cutoff = Date().addingTimeInterval(-EventQueue.retention)
        pending.removeAll { (PetEvent.date($0.observedAt) ?? .distantPast) < cutoff }
        let stale = Date().addingTimeInterval(-Self.bubbleLifetime)
        func old(_ event: PetEvent) -> Bool { (PetEvent.date(event.observedAt) ?? .distantPast) < stale }
        let before = (recent + [current].compactMap { $0 }).map(\.eventId)
        recent.removeAll(where: old)
        if let event = current, old(event) { current = recent.popLast() }
        let still = recent + [current].compactMap { $0 }
        guard still.map(\.eventId) != before else { return }
        if still.isEmpty { bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false }
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
        cat.setPull(gap)
        if gap == .zero && !cat.isDragging {
            petTarget = nil
            clampPosition(); persistPosition()
        }
    }

    private func droppedPet() {
        let press = lastPress
        let corner = max(press.left, press.right) >= Self.cornerPress && max(press.bottom, press.top) >= Self.cornerPress
        lastPress = (0, 0, 0, 0)
        cat.press(left: 0, right: 0, bottom: 0, top: 0)
        if corner {
            if let target = petTarget { panel.setFrameOrigin(target) }
            petTarget = nil
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
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()
