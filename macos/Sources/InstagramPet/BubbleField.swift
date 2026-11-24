import AppKit
import PetCore
import PetSources

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
    /// `petIsSolid` false: the pet is tucked or hidden, so its old spot must not shove or flatten bubbles
    /// (they kept fighting their goal there and stayed stretched into broken slivers at corners).
    func update(pet: NSRect, area: NSRect, animated: Bool, petIsSolid: Bool = true) {
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
        // Resolve collisions in arrival order: dictionary order can trap a reflowing row behind its neighbours.
        let all = order.compactMap { views[$0.identity] }
        for view in all { view.step(animated: animated) }
        // Solid bodies: a fast pet shoves bubbles along instead of passing through, and bubbles shove each other.
        if animated {
            let solid = pet.insetBy(dx: 10, dy: 6)
            for _ in 0..<3 {
                if petIsSolid { for view in all { if let push = Self.separation(view.footprintNow, from: solid) { view.shove(push) } } }
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
            if petIsSolid && max(gapX, gapY) < 80 {
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
