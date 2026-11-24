import AppKit
import PetCore
import PetSources

extension PetController {
    final class Desk: NSView {
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

    func renderPreview(to output: URL) {
        renderDesk(catOrigin: NSPoint(x: 1195, y: 20), mode: .normal, to: output)
    }

    func renderScenarios(to directory: URL) {
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

    func finishSmokeTest() {
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
}
