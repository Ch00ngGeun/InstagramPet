import AppKit
import PetCore
import PetSources

/// “중력” 배치: 최신부터, 각 항목은 펫 둘레 궤도 자리에 가장 가까운 빈 곳을 차지한다.
/// 보이는 영역 안에 완전히 들어가고, 보이는 펫과 이미 놓인 항목을 피한다.
/// 자리가 화면 밖이면 화면 안의 가장 가까운 곳으로 밀려나서, 펫이 숨은 쪽에 모여든다.
enum Orbit {
    static let gap: CGFloat = 28, margin: CGFloat = 0, step: CGFloat = 8

    /// 말풍선은 모두 합쳐 최대 12개. 펫이 화면에 있으면 5개까지는 가장 넓은 쪽으로 펼친 호 위에 시간 순으로 놓인다:
    /// 위·아래 호는 왼쪽 → 오른쪽, 옆 호는 위 → 아래로 읽고, 모서리 근처에선 호 전체가 안쪽으로 밀린다.
    /// 그보다 많으면 펫 옆에 블록으로 놓이고, 펫을 화살표 뒤로 집어넣으면 화살표가 있는 가장자리를 따라
    /// 줄지어 선다. 인덱스 0이 가장 새 말풍선이다.
    static let bubbleCount = 12
    /// 앱(카카오톡, 인스타그램, 메시지)마다 4개까지. 한 앱에서 몰려와도 다른 앱의 말풍선을 밀어내지 않는다.
    static let perSource = 4
    /// 호에 놓이는 최대 개수(원래의 5칸 간격). 이보다 많으면 호 대신 블록으로 놓인다.
    static let innerArc = 5

    /// `events`는 오래된 순. 소스마다 최신 `perSource`개, 전체로는 최신 `bubbleCount`개만 남기며 여전히 오래된 순이다.
    static func capped(_ events: [PetEvent]) -> [PetEvent] {
        var counts: [PetSource: Int] = [:]
        let kept = events.reversed().filter { event in
            counts[event.source, default: 0] += 1
            return counts[event.source]! <= perSource
        }
        return Array(kept.reversed().suffix(bubbleCount))
    }

    /// 집어넣은 펫이 있는 모서리. 펫이 (대부분) 화면 안에 있으면 nil.
    static func tuckCorner(pet: NSRect, area: NSRect) -> NSPoint? {
        let shown = pet.intersection(area)
        guard shown.width * shown.height < pet.width * pet.height * 0.3 else { return nil }
        return NSPoint(x: pet.midX < area.midX ? area.minX : area.maxX, y: pet.midY < area.midY ? area.minY : area.maxY)
    }

    /// 호가 향하는 방향(라디안): 위 가장자리 근처(위 모서리 포함)면 발 아래, 옆 가장자리 가운데면
    /// 바깥 옆, 그 밖(아래 모서리 포함)에는 머리 위.
    static func facing(pet: NSRect, area: NSRect) -> CGFloat {
        let above = area.maxY - pet.maxY, below = pet.minY - area.minY
        let left = pet.minX - area.minX, right = area.maxX - pet.maxX
        if above < 170 { return -.pi / 2 }
        if (left < 180 || right < 180) && below >= 120 { return right >= left ? 0 : .pi }
        return .pi / 2
    }

    static func arcGoal(_ slot: Int, size: NSSize, pet: NSRect, facing: CGFloat) -> NSPoint {
        let spread: CGFloat = 95 * .pi / 180, step = 2 * spread / CGFloat(innerArc - 1)
        // 거의 가로인 호에선 시간이 왼쪽 → 오른쪽, 거의 세로인 호에선 위 → 아래로 흐른다:
        // 가장 새 쪽은 오른쪽 끝, 또는 아래쪽 끝이다.
        let ends = [facing - spread, facing + spread]
        let horizontal = abs(sin(facing)) >= abs(cos(facing)) - 0.01
        let newest = horizontal ? ends.max { cos($0) < cos($1) }! : ends.min { sin($0) < sin($1) }!
        let angle = newest + (newest == ends[0] ? step : -step) * CGFloat(slot)
        let c = cos(angle), s = sin(angle)
        let up = sin(facing) > 0.9, down = sin(facing) < -0.9
        // 호가 감싸는 몸 끝 가까이에 기준점을 둔다(위면 머리, 아래면 발, 그 밖엔 상체).
        let anchor = NSPoint(x: pet.midX, y: up ? pet.maxY - pet.height * 0.18 : down ? pet.minY + pet.height * 0.18 : pet.minY + pet.height * 0.55)
        let radiusY = up || down ? pet.height * 0.18 + gap : pet.height * 0.42 + gap
        let reach = hypot(c * (pet.width / 2 + gap), s * radiusY) + abs(c) * size.width / 2 + abs(s) * size.height / 2
        return NSPoint(x: anchor.x + c * reach, y: anchor.y + s * reach)
    }

    /// 펫을 화살표 뒤로 집어넣은 동안 설정되는 화살표 자리. 말풍선은 화살표가 있는 화면 가장자리를 따라
    /// 빈틈없이 줄지어 선다: 위·아래 가장자리면 가로줄(왼쪽 → 오른쪽), 옆이면 세로줄(위 → 아래),
    /// 모서리면 그 모서리에 모여 쌓인다.
    static var tuckAnchor: NSPoint?

    /// 집어넣은 동안의 화살표 사각형: 기준점에서 가장 가까운 화면 가장자리(또는 모서리)에 딱 붙는다.
    static func tuckArrowRect(anchor: NSPoint, area: NSRect) -> NSRect {
        let w = HideArrow.size.width, h = HideArrow.size.height
        return NSRect(x: min(max(anchor.x - w / 2, area.minX), area.maxX - w), y: min(max(anchor.y - h / 2, area.minY), area.maxY - h), width: w, height: h)
    }

    /// 화면 어디에 있든 기준점에서 가장 가까운 가장자리 지점: 놓은 화살표가 자리 잡는 곳.
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

    /// 집어넣은 상태의 배치(탐색 없이, 그래서 늘 화살표를 정확히 따라간다). 말풍선은 서로와 화면 가장자리에
    /// 맞닿고, 화살표 바로 옆에서 시작해 가장자리 가운데 쪽으로 이어진다: 위·아래면 왼쪽 → 오른쪽으로 읽는 가로줄,
    /// 옆이면 위 → 아래로 읽는 세로줄, 모서리면 3개씩 묶은 줄을 모서리에서부터 쌓는다.
    /// 최신부터 순서로 사각형을 돌려준다.
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
            // 줄은 위 → 아래, 오래된 순으로 읽는다: 위쪽이면 가장 오래된 줄이, 아래쪽이면
            // 가장 새 줄이 가장자리에 붙는다.
            var rowRects: [[NSRect]] = [], placed: [NSRect] = []
            for row in (top ? rows : rows.reversed()) {
                let total = row.reduce(0) { $0 + $1.width }
                // 가장자리 줄에서는 모서리에 화살표 자리를 비워 둔다.
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
            // 한 줄에 다 안 들어가면 여러 줄로 감싼다. 가장 오래된 줄이 위 가장자리, 가장 새 줄이 아래 가장자리에 온다.
            var placed: [NSRect] = []
            // 줄이 화살표를 덮지 않도록, 화살표의 더 넓은 쪽 폭에 맞춰 감싼다.
            let lines = wrap(oldest, limit: max(arrow.minX - area.minX, area.maxX - arrow.maxX)) { $0.width }
            // 모든 줄이 화살표 옆 같은 지점에서 시작하므로, 감싼 줄들이 서로 빈틈없이 쌓인다.
            let widest = lines.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0
            var start = arrow.midX < area.midX ? arrow.maxX : arrow.minX - widest
            if start + widest > area.maxX { start = arrow.minX - widest }
            if start < area.minX { start = arrow.maxX }
            start = min(max(start, area.minX), area.maxX - widest)
            let towardRight = start >= arrow.maxX - 1
            for line in top ? lines : lines.reversed() {
                let total = line.reduce(0) { $0 + $1.width }
                // 화살표 옆에서 가운데 쪽으로 이어진다.
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
            // 한 세로줄에 다 안 들어가면 가장자리에서 안쪽으로 세로줄을 더 만든다.
            var x = right ? area.maxX : area.minX
            for line in wrap(oldest, limit: max(arrow.minY - area.minY, area.maxY - arrow.maxY), { $0.height }) {
                let total = line.reduce(0) { $0 + $1.height }, width = line.map(\.width).max() ?? 0
                var top = arrow.midY > area.midY ? arrow.minY : arrow.maxY + total
                if top - total < area.minY { top = arrow.maxY + total }
                if top > area.maxY { top = arrow.minY }
                top = min(max(top, area.minY + total), area.maxY)
                for size in line {
                    // 이미 있는 세로줄에 닿을 때까지 가장자리에서 밀어 넣는다(들쭉날쭉한 틈 없이).
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

    /// 5개 초과: 호로는 읽기 좋은 순서를 지킬 수 없어서, 펫의 가장 넓은 쪽 옆에 블록으로 놓인다.
    /// 3개씩 왼쪽 → 오른쪽으로 읽는 줄, 가장 오래된 줄이 위. 최신부터 순서로 중심점을 돌려준다.
    static func blockGoals(_ sizes: [NSSize], pet: NSRect, area: NSRect) -> [NSPoint] {
        let oldest = Array(sizes.reversed())
        let rows = stride(from: 0, to: oldest.count, by: 3).map { Array(oldest[$0..<min($0 + 3, oldest.count)]) }
        let widths = rows.map { $0.reduce(0) { $0 + $1.width } }, heights = rows.map { $0.map(\.height).max() ?? 0 }
        let w = widths.max() ?? 0, h = heights.reduce(0, +)
        let shown = pet.intersection(area).isEmpty ? pet : pet.intersection(area)
        let body = shown.insetBy(dx: -gap / 2 - 1, dy: -gap / 2 - 1)
        let midY = shown.midY + shown.height * 0.15
        // (블록 원점, 짧은 줄을 펫 쪽으로 맞추는 방향: -1 왼쪽, 0 가운데, 1 오른쪽, 그쪽 여유 공간)
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
        // 각 말풍선은 바로 위 말풍선에 매달린다(줄 높이만큼의 틈 없음).
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

    /// 말풍선을 가장자리 쪽으로 곧게 떨어뜨려(아래면 바닥으로, 위면 천장으로) 이미 쌓인 것 위에
    /// 얹히게 한다. 높이가 달라도 틈이 생기지 않는다.
    static func settle(x: CGFloat, size: NSSize, top: Bool, on placed: [NSRect], area: NSRect) -> NSRect {
        let under = placed.filter { min($0.maxX, x + size.width) - max($0.minX, x) > 1 }
        let y = top ? (under.map(\.minY).min() ?? area.maxY) - size.height : under.map(\.maxY).max() ?? area.minY
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 순서를 지키는 탐욕적 줄바꿈: 한 줄에 `limit` 안에 들어가는 만큼 넣는다.
    static func wrap(_ sizes: [NSSize], limit: CGFloat, _ length: (NSSize) -> CGFloat) -> [[NSSize]] {
        var lines: [[NSSize]] = [], used: CGFloat = 0
        for size in sizes {
            if lines.isEmpty || used + length(size) > limit { lines.append([]); used = 0 }
            lines[lines.count - 1].append(size); used += length(size)
        }
        // 줄 수는 같게 두고, 그래도 들어가면 고르게 채운다(8 + 4가 아니라 12 → 6 + 6).
        let per = (sizes.count + lines.count - 1) / max(1, lines.count)
        let even = stride(from: 0, to: sizes.count, by: max(1, per)).map { Array(sizes[$0..<min($0 + per, sizes.count)]) }
        return even.count == lines.count && even.allSatisfy({ $0.reduce(0) { $0 + length($1) } <= limit }) ? even : lines
    }

    /// 이 크기들의 말풍선 중심점(최신부터).
    static func lineGoals(_ sizes: [NSSize], pet: NSRect, area: NSRect) -> [NSPoint] {
        guard !sizes.isEmpty else { return [] }
        if let corner = tuckCorner(pet: pet, area: area) { return Array(repeating: corner, count: sizes.count) }
        if sizes.count > innerArc { return blockGoals(sizes, pet: pet, area: area) }
        let facing = facing(pet: pet, area: area)
        var goals = sizes.enumerated().map { arcGoal($0.offset, size: $0.element, pet: pet, facing: facing) }
        // 모서리 근처에선 호 일부가 화면 밖으로 나가므로, 순서를 유지한 채 호 전체를 안쪽으로 민다.
        let rects = zip(goals, sizes).map { NSRect(x: $0.x - $1.width / 2, y: $0.y - $1.height / 2, width: $1.width, height: $1.height) }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        var shift = NSPoint.zero
        if union.width <= area.width { shift.x = max(0, area.minX - union.minX) + min(0, area.maxX - union.maxX) }
        if union.height <= area.height { shift.y = max(0, area.minY - union.minY) + min(0, area.maxY - union.maxY) }
        goals = goals.map { NSPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
        return goals
    }

    /// 작은 숨기기 화살표의 자리: 머리 옆.
    static func target(_ slot: Int, size: NSSize, pet: NSRect) -> NSPoint {
        NSPoint(x: pet.maxX + size.width / 2, y: pet.maxY - size.height)
    }

    /// `options[i]`는 항목 i가 가질 수 있는 크기들(기본 모양이 먼저). 각 항목의 사각형과 고른 모양을 돌려준다.
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
        // 블록은 이미 겹치지 않고 읽는 순서대로라서 그대로 쓴다.
        if options.count > innerArc && line.count == options.count && tuckCorner(pet: pet, area: area) == nil {
            return zip(line, options).map { goal, sizes in
                (NSRect(x: goal.x - sizes[0].width / 2, y: goal.y - sizes[0].height / 2, width: sizes[0].width, height: sizes[0].height), 0)
            }
        }
        // 각 항목은 바로 앞에 놓인 것(바로 다음으로 새 메시지)에 붙는다. 그래서 모서리에 몰려도
        // 빈틈을 아무렇게나 채우지 않고 시간 순서대로 사슬을 이룬다.
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
                // 화면 안으로 제한한 목표점에 맞춘 격자라서, 막힌 게 없으면 항목이 정확히 제자리에 놓인다.
                let gx = min(max(goal.x, inner.minX), inner.maxX), gy = min(max(goal.y, inner.minY), inner.maxY)
                let x0 = gx - ((gx - inner.minX) / step).rounded(.down) * step
                let y0 = gy - ((gy - inner.minY) / step).rounded(.down) * step
                for y in stride(from: y0, through: inner.maxY, by: step) {
                    for x in stride(from: x0, through: inner.maxX, by: step) {
                        let rect = NSRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
                        if rect.intersects(body) || placed.contains(where: { $0.intersects(rect) }) { continue }
                        // 자리 쪽, 펫 쪽(위성), 이미 놓인 슬라임 쪽으로 끌어당겨서 무리가 틈 없이
                        // 붙어 있게 한다. 찌그러진 모양은 비용이 더 든다.
                        let cost = hypot(x - goal.x, y - goal.y) + 0.5 * hypot(x - core.x, y - core.y) + 2.5 * gapTo(rect) + CGFloat(shape) * 30
                        if best == nil || cost < best!.cost { best = (rect, shape, cost) }
                    }
                }
            }
            let chosen: (rect: NSRect, shape: Int)
            if let best { chosen = (best.rect, best.shape) } else {
                // 빈 곳이 없으면(아주 작은 화면) 겹치더라도 화면 안에 둔다.
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
