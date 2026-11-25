import AppKit
import PetCore
import PetSources

// 시간제 숨기기, 화살표 뒤로 펫 집어넣기, 펫·화살표 끌기, 말풍선 오버레이 배치.

extension PetController {
    // MARK: 시간제 숨기기(무기한은 없음)

    @objc func hideBubblesFor(_ sender: NSMenuItem) {
        hideBubblesUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        arrowKey = ""
        updateStatus()
    }

    @objc func hidePetFor(_ sender: NSMenuItem) {
        hidePetUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        // 작은 슬라임 화살표만 남겨서 언제든 펫을 다시 부를 수 있다.
        panel.orderOut(nil)
        arrowKey = ""
        updateStatus()
    }

    @objc func showNow() {
        if isTucked { untuck() }
        if isHidden {
            hidePetUntil = nil
            arrowKey = ""
            overlay.orderFrontRegardless(); panel.orderFrontRegardless()
        }
        if paused { resumeBubbles() } else { presentNextIfPossible() }
        updateStatus()
    }

    func checkHideExpiry() {
        let now = Date()
        if let until = hidePetUntil, until <= now { showNow() }
        if let until = tuckedUntil, until <= now { untuck(); updateStatus() }
        if let until = hideBubblesUntil, until <= now { resumeBubbles(); updateStatus() }
    }

    /// 다시 나올 때는 밀린 메시지를 천천히 재생하지 않고, 최신 메시지와 그 앞 메시지들(Orbit 상한 안)을 한 번에 보여 준다.
    func resumeBubbles() {
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

    /// 화살표는 포인터를 정확히 따라가고 숨은 펫도 함께 옮겨지므로, 클릭하면 그 자리에서 나온다.
    func dragArrow(_ delta: NSPoint) {
        if arrowDragStart == nil { arrowDragStart = (panel.frame.origin, arrow.frame.origin) }
        guard let start = arrowDragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.panel.x + delta.x, y: start.panel.y + delta.y))
        arrow.setFrameOrigin(NSPoint(x: start.arrow.x + delta.x, y: start.arrow.y + delta.y))
        lastCatOrigin = panel.frame.origin
    }

    /// 어디에 놓든 화살표는 가장 가까운 화면 가장자리에 딱 붙고, 숨은 펫도 함께 옮겨진다.
    func arrowDropped() {
        arrowDragStart = nil; arrowKey = ""
        guard isTucked, let screen = catScreen() else { return }
        let o = overlay.frame.origin, area = screen.frame.offsetBy(dx: -o.x, dy: -o.y)
        let here = NSPoint(x: arrow.frame.midX, y: arrow.frame.midY), there = Orbit.snapToEdge(here, area: area)
        tuckArrowCenter = there
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + there.x - here.x, y: panel.frame.minY + there.y - here.y))
        lastCatOrigin = panel.frame.origin
    }

    func arrowClicked(_ view: HideArrow) {
        showNow()
    }

    // MARK: 배치

    /// 펫이 가장 많이 보이는 화면. 펫이 화면 밖으로 완전히 들어갔으면 가장 가까운 화면.
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

    func layoutOverlay(animated: Bool) {
        guard let screen = catScreen() else { return }
        if overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: false) }
        let origin = overlay.frame.origin
        let pet = cat.bodyRect.offsetBy(dx: panel.frame.minX + cat.frame.minX - origin.x, dy: panel.frame.minY + cat.frame.minY - origin.y)
        // 펫과 마찬가지로 디스플레이의 실제 경계: 말풍선과 화살표가 메뉴 막대와 Dock 위로
        // 모서리 끝까지 틈 없이 붙는다.
        let area = screen.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        place(pet: pet, area: area, animated: animated)
    }

    /// 실제 오버레이와 미리보기 렌더러가 함께 쓴다.
    func place(pet: NSRect, area: NSRect, animated: Bool) {
        // 집어넣은 상태: 모두 화살표를 따른다. 화살표는 펫 자리(화면 안으로 제한)에서 시작해 끌면 함께
        // 움직이고, 놓으면 가장 가까운 가장자리에 자리 잡는다.
        if isTucked {
            if tuckArrowCenter == nil {
                tuckArrowCenter = Orbit.snapToEdge(NSPoint(x: min(max(pet.midX, area.minX), area.maxX), y: min(max(pet.midY, area.minY), area.maxY)), area: area)
            }
            if arrow.isDragging { tuckArrowCenter = NSPoint(x: arrow.frame.midX, y: arrow.frame.midY) }
            Orbit.tuckAnchor = tuckArrowCenter
        } else { Orbit.tuckAnchor = nil; tuckArrowCenter = nil }
        if !bubble.isHidden { bubble.update(pet: pet, area: area, animated: animated, petIsSolid: !isTucked && !isHidden) }
        // 무언가 숨겨져 있으면(펫이든 말풍선만이든) 화살표가 나타나서, 클릭 한 번으로 늘 되돌릴 수 있다.
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
        let tip = isTucked ? "펫 \(remaining(tuckedUntil)) · 클릭하면 바로 꺼내기"
            : isHidden ? "펫 \(remaining(hidePetUntil)) · 클릭하면 바로 보기"
            : paused ? "말풍선 \(remaining(hideBubblesUntil)) · 클릭하면 바로 보기" : "말풍선 잠깐 숨기기"
        if arrow.toolTip != tip { arrow.toolTip = tip }
        arrow.step(animated: animated)
    }

    func persistPosition() {
        let sprite = catSpriteOnScreen()
        UserDefaults.standard.set([sprite.minX, sprite.minY], forKey: "pet.sprite.origin")
    }

    @objc func screenChanged() {
        petTarget = nil; petDragArea = nil
        cat.setPull(.zero)
        cat.press(left: 0, right: 0, bottom: 0, top: 0)
        clampPosition(); persistPosition()
    }

    func updateClickThrough() {
        guard !cat.isDragging, !arrow.isDragging else { return }
        let mouse = NSEvent.mouseLocation
        let catBounds = cat.spriteRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY)
        // 투명한 곳에선 아래 앱을 조작할 수 있어야 한다.
        if !isHidden && !isTucked {
            let over = catBounds.contains(panel.convertPoint(fromScreen: mouse))
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
            // 펫 위에선 펼친 손 커서(다른 앱이 커서를 바꾸므로 움직일 때마다 다시 정한다).
            if over { NSCursor.openHand.set() } else if overPet { NSCursor.arrow.set() }
            overPet = over
        } else if overPet { NSCursor.arrow.set(); overPet = false }
        let point = overlay.convertPoint(fromScreen: mouse)
        let ignores = bubble.hitTest(point) == nil && arrow.hitTest(point) == nil
        if overlay.ignoresMouseEvents != ignores { overlay.ignoresMouseEvents = ignores }
    }

    // MARK: 펫 끌기와 집어넣기

    /// 가장자리로 끌면 펫은 화면 안에 머물고, 포인터가 넘어간 만큼 벽에 눌린다.
    /// 포인터 아래 화면을 기준으로 하므로 펫은 여전히 다른 디스플레이로 옮겨 갈 수 있다.
    func dragPet(to origin: NSPoint) {
        let sprite = cat.spriteRect.offsetBy(dx: origin.x + cat.frame.minX, dy: origin.y + cat.frame.minY)
        let mouse = NSEvent.mouseLocation
        // 펫의 벽은 디스플레이의 실제 경계(메뉴 막대와 Dock 위)라서 딱 붙어 찌그러진다.
        guard let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? catScreen())?.frame else { return }
        let left = max(0, area.minX - sprite.minX), right = max(0, sprite.maxX - area.maxX)
        let bottom = max(0, area.minY - sprite.minY), top = max(0, sprite.maxY - area.maxY)
        petTarget = NSPoint(x: origin.x + left - right, y: origin.y + bottom - top)
        petDragArea = area
        cat.press(left: left, right: right, bottom: bottom, top: top)
        lastPress = (left, right, bottom, top)
        followPet(step: 0) // 20fps 틱만이 아니라 마우스 이벤트마다 다시 당긴다
    }

    /// 몸은 포인터를 천천히 따라가고 잡은 지점은 포인터 아래에 머무르므로, 그 차이가 당김으로 그려진다.
    /// 그래서 빠르게 앞뒤로 문지르면 몸은 거의 안 움직이고 잡은 부분만 찌그러진다.
    /// 차이가 높이의 15%를 넘으면 몸이 끌려온다.
    func followPet(step: CGFloat) {
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

    /// 패널 이동과 화면 기준 벽 좌표는 같은 마우스 이벤트 안에서 함께 바뀌어야 한다.
    func updatePetArea() {
        guard let area = petDragArea ?? catScreen()?.frame else { return }
        cat.area = area.offsetBy(dx: -panel.frame.minX - cat.frame.minX, dy: -panel.frame.minY - cat.frame.minY)
    }

    /// 모서리의 두 벽에 cornerPress 이상 눌린 채 놓으면 펫이 화살표 뒤로 들어간다.
    func droppedPet() {
        let press = lastPress
        let corner = max(press.left, press.right) >= Self.cornerPress && max(press.bottom, press.top) >= Self.cornerPress
        lastPress = (0, 0, 0, 0)
        cat.press(left: 0, right: 0, bottom: 0, top: 0)
        if corner {
            if let target = petTarget { panel.setFrameOrigin(target) }
            petTarget = nil; petDragArea = nil
            cat.setPull(.zero)
            // 모서리를 살짝 넘어가게 해서 화살표와 새 말풍선이 그 모서리에 바로 모이게 한다.
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
        } // 아니면 몸이 틱마다 마저 따라온 뒤 위치를 제한하고 저장한다
    }

    /// 펫을 다시 꺼낸다: 숨어 있던 가장자리 옆, 화면 안에 완전히 보이게.
    private func untuck() {
        tuckedUntil = nil
        clampPosition(keep: .infinity)
        persistPosition()
        cat.shake(by: NSPoint(x: 0, y: 25))
        arrowKey = ""
        panel.orderFrontRegardless()
        updateStatus()
    }

    func clampPosition(keep requested: CGFloat = PetController.keepVisible) {
        // 캐릭터를 축마다 `requested` pt는 화면 안에 남긴다. 기본값 keepVisible(무한대)이면 완전히 화면 안에 둔다.
        let sprite = catSpriteOnScreen()
        guard let area = catScreen()?.frame else { return }
        let keepX = min(requested, sprite.width), keepY = min(requested, sprite.height)
        let x = min(max(sprite.minX, area.minX - sprite.width + keepX), area.maxX - keepX)
        let y = min(max(sprite.minY, area.minY - sprite.height + keepY), area.maxY - keepY)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + x - sprite.minX, y: panel.frame.minY + y - sprite.minY))
        updatePetArea()
    }
}
