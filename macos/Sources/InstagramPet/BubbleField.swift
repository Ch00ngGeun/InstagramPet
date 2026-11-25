import AppKit
import PetCore
import PetSources

/// 펫 주위의 메시지 말풍선들(앱당 4개, 모두 12개까지): Orbit으로 자리를 정하고, 매 틱 스프링과 충돌을 처리한다.
final class BubbleField: NSView {
    private var views: [String: BubbleView] = [:]
    private var order: [PetEvent] = []
    private var solvedKey = ""
    private(set) var footprints: [NSRect] = []
    var onClick: ((PetEvent) -> Void)?
    var contextMenu: NSMenu?

    /// `events`는 오래된 순이며, 마지막이 현재 메시지다.
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

    /// 펫·화면·메시지가 바뀔 때만 자리를 다시 계산하고, 스프링은 매 틱 움직인다.
    /// `petIsSolid`가 false면 펫이 집어넣어졌거나 숨겨진 것이므로, 예전 자리가 말풍선을 밀거나 납작하게 만들면 안 된다
    /// (그러면 말풍선이 그 자리에서 목표와 계속 다투다가 모서리에서 부서진 조각처럼 늘어난 채로 남았다).
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
        // 벽: 화면 가장자리, 그리고 이웃끼리는 두 몸이 맞닿을 선.
        let edges = [Wall(point: NSPoint(x: area.minX, y: 0), normal: NSPoint(x: -1, y: 0)), Wall(point: NSPoint(x: area.maxX, y: 0), normal: NSPoint(x: 1, y: 0)),
                     Wall(point: NSPoint(x: 0, y: area.minY), normal: NSPoint(x: 0, y: -1)), Wall(point: NSPoint(x: 0, y: area.maxY), normal: NSPoint(x: 0, y: 1))]
        // 충돌은 도착 순서대로 푼다. 딕셔너리 순서면 다시 흐르는 줄이 이웃 뒤에 갇힐 수 있다.
        let all = order.compactMap { views[$0.identity] }
        for view in all { view.step(animated: animated) }
        // 단단한 몸: 빠르게 움직이는 펫은 말풍선을 통과하지 않고 밀어내며, 말풍선끼리도 서로 민다.
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
                // 맞닿는 면은 늘 곧고 축에 나란하며(나란히 놓이면 세로, 쌓이면 가로), 두 가장자리의 한가운데에 있다.
                // 이웃이 어긋나 있거나 크기가 달라도 마찬가지다. 비스듬한 면은 외곽선을 출렁이게 하고
                // 들쭉날쭉한 틈을 남겼다.
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
                // 이웃이 그려지는 타원: 몸(footprint에서 tailRoom을 뺀 것)을 bulge만큼 키운 것.
                let body = theirs.insetBy(dx: BubbleView.tailRoom, dy: BubbleView.tailRoom)
                let zone = body.insetBy(dx: -body.width * (BubbleView.bulge - 1) / 2, dy: -body.height * (BubbleView.bulge - 1) / 2)
                walls.append(Wall(point: point, normal: n, zone: zone))
            }
            // 펫도 벽이다: 늘어나거나 찌그러진 말풍선은 펫과 겹치지 않고 펫에 대고 납작해진다.
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

    /// `a`를 `b` 밖으로 꺼내는 가장 작은 이동. 겹치지 않으면 nil.
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
