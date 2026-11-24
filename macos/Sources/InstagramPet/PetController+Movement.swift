import AppKit
import PetCore
import PetSources

extension PetController {
    // MARK: Temporary hiding (never indefinite)

    @objc func hideBubblesFor(_ sender: NSMenuItem) {
        hideBubblesUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        arrowKey = ""
        updateStatus()
    }

    @objc func hidePetFor(_ sender: NSMenuItem) {
        hidePetUntil = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        bubble.isHidden = true; cat.excited = false
        // Only the small slime arrow stays, so the pet can always be called back.
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

    /// Coming back shows the newest message with the two before it, not a slow replay of the backlog.
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

    /// The arrow follows the pointer exactly, and the hidden pet moves with it, so a click brings it out there.
    func dragArrow(_ delta: NSPoint) {
        if arrowDragStart == nil { arrowDragStart = (panel.frame.origin, arrow.frame.origin) }
        guard let start = arrowDragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.panel.x + delta.x, y: start.panel.y + delta.y))
        arrow.setFrameOrigin(NSPoint(x: start.arrow.x + delta.x, y: start.arrow.y + delta.y))
        lastCatOrigin = panel.frame.origin
    }

    /// Dropped anywhere: the arrow settles flush on the nearest screen edge, the hidden pet moving with it.
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

    func layoutOverlay(animated: Bool) {
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
    func place(pet: NSRect, area: NSRect, animated: Bool) {
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
        if !bubble.isHidden { bubble.update(pet: pet, area: area, animated: animated, petIsSolid: !isTucked && !isHidden) }
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
        // Transparent space must allow interaction with the application underneath.
        if !isHidden && !isTucked {
            let over = catBounds.contains(panel.convertPoint(fromScreen: mouse))
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
            // An open hand over the pet (re-asserted on every move, since other apps reset the cursor).
            if over { NSCursor.openHand.set() } else if overPet { NSCursor.arrow.set() }
            overPet = over
        } else if overPet { NSCursor.arrow.set(); overPet = false }
        let point = overlay.convertPoint(fromScreen: mouse)
        let ignores = bubble.hitTest(point) == nil && arrow.hitTest(point) == nil
        if overlay.ignoresMouseEvents != ignores { overlay.ignoresMouseEvents = ignores }
    }

    /// A drop that leaves almost nothing of the pet on screen tucks it away behind its arrow.
    /// Dragging into an edge: the pet stays on screen and is pressed into the wall by however far the pointer
    /// went past it. The screen under the pointer counts, so the pet can still move between displays.
    func dragPet(to origin: NSPoint) {
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

    /// Panel motion and screen-local wall coordinates must change in the same mouse event.
    func updatePetArea() {
        guard let area = petDragArea ?? catScreen()?.frame else { return }
        cat.area = area.offsetBy(dx: -panel.frame.minX - cat.frame.minX, dy: -panel.frame.minY - cat.frame.minY)
    }

    func droppedPet() {
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

    func clampPosition(keep requested: CGFloat = PetController.keepVisible) {
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
