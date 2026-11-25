import AppKit
import PetCore
import PetSources

// 화면 밖 자체 점검: 설정 폼 저장 경로, 펫 찌그러짐 기하, 집어넣은 펫 옆 말풍선 배치(--smoke-* 플래그).

extension PetController {
    /// 폼과 실제 비동기 저장·적용 경로를 점검한다. 격리된 비공개 홈과 가짜 연락처만 쓴다.
    func checkSettings(to output: URL) {
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
            // 리더는 늦게 만들어진다. previewMode라서 저장할 때마다 자동 폴링하지 않는다.
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

    /// 기록된 벽 틈과 접힌 이미지 줄의 회귀 점검. 사용자 데이터나 보이는 창 없이 돌린다.
    func checkPetGeometry(to output: URL) {
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
                            // 끌림 자국이 최대여도 패널의 스프라이트와 화면 경계 사이엔 그만큼 거리가 있다.
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

    /// 집어넣은 펫은 예전 자리가 메시지와 겹치더라도 물리적으로 아무 영향이 없어야 한다.
    /// 실제 배치·스프링을 돌려, 모서리마다 같은 펫을 화면 밖 멀리 옮긴 경우와 비교한다.
    func checkBubbleGeometry(to output: URL, requireIdle: Bool = false) {
        let area = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let corners: [(String, NSPoint)] = [("bottom-left", .zero), ("bottom-right", NSPoint(x: 1440, y: 0)),
            ("top-left", NSPoint(x: 0, y: 900)), ("top-right", NSPoint(x: 1440, y: 900))]
        var cases = 0, settled = true, independent = true, inside = true, complete = true
        var maxGoalError: CGFloat = 0, maxOutlineError: CGFloat = 0
        var details: [[String: Any]] = []
        var idleRedraws = 0, idleArrowRedraws = 0
        let fixtures = fullSourceEvents((4, 4, 4))
        for (corner, anchor) in corners {
            for long in [false, true] {
                let events = fixtures.map { event in
                    PetEvent(eventId: event.eventId, sender: event.sender,
                        text: long ? String(repeating: "긴 메시지와 링크 https://example.invalid/12345 확인. ", count: 12) : event.text,
                        threadUrl: event.threadUrl, observedAt: event.observedAt, kind: event.kind, source: event.source)
                }
                var reference: [String: [NSPoint]] = [:]
                for overlapping in [false, true] {
                    var caseGoalError: CGFloat = 0
                    let desk = Desk(frame: area)
                    desk.appearance = NSAppearance(named: .aqua)
                    bubble = BubbleField(frame: area); arrow = HideArrow(frame: .zero)
                    desk.addSubview(bubble); desk.addSubview(arrow)
                    hidePetUntil = nil; hideBubblesUntil = nil
                    tuckedUntil = Date().addingTimeInterval(600); tuckArrowCenter = anchor
                    Orbit.tuckAnchor = nil; arrowKey = ""
                    let pet = overlapping ? NSRect(x: anchor.x == 0 ? 0 : area.maxX - 140,
                        y: anchor.y == 0 ? 0 : area.maxY - 360, width: 140, height: 360)
                        : NSRect(x: -2000, y: -2000, width: 140, height: 360)
                    // 이미 집어넣은 상태에서 말풍선이 하나부터 여러 소스가 섞인 전체 묶음까지 늘어난다.
                    for count in 1...events.count {
                        bubble.show(Array(events.prefix(count)))
                        for _ in 0..<8 { place(pet: pet, area: area, animated: true) }
                    }
                    for tick in 0..<240 {
                        let before = bubble.subviews.compactMap { $0 as? BubbleView }.map(\.redrawRequests).reduce(0, +)
                        let arrowBefore = arrow.redrawRequests
                        place(pet: pet, area: area, animated: true)
                        guard tick >= 220 else { continue }
                        if requireIdle { idleRedraws += bubble.subviews.compactMap { $0 as? BubbleView }.map(\.redrawRequests).reduce(0, +) - before }
                        if requireIdle { idleArrowRedraws += arrow.redrawRequests - arrowBefore }
                        for view in bubble.subviews.compactMap({ $0 as? BubbleView }) {
                            let f = view.footprintNow, g = view.goal
                            let error = max(abs(f.minX - g.minX), abs(f.minY - g.minY), abs(f.width - g.width), abs(f.height - g.height))
                            maxGoalError = max(maxGoalError, error)
                            caseGoalError = max(caseGoalError, error)
                            settled = settled && error < 1
                            inside = inside && area.insetBy(dx: -1, dy: -1).contains(f)
                        }
                    }
                    details.append(["corner": corner, "long": long, "overlappingPet": overlapping, "goalError": caseGoalError])
                    desk.layoutSubtreeIfNeeded()
                    let views = bubble.subviews.compactMap { $0 as? BubbleView }
                    complete = complete && views.count == events.count
                        && Set(views.compactMap { $0.event?.identity }) == Set(events.map(\.identity))
                    for view in views {
                        guard let identity = view.event?.identity else { independent = false; continue }
                        let path = view.blob
                        var points: [NSPoint] = []
                        var element = [NSPoint](repeating: .zero, count: 3)
                        for index in 0..<path.elementCount {
                            let kind = path.element(at: index, associatedPoints: &element)
                            let count = kind == .curveTo ? 3 : kind == .closePath ? 0 : 1
                            points.append(contentsOf: element.prefix(count))
                        }
                        if !overlapping { reference[identity] = points }
                        else if let expected = reference[identity], expected.count == points.count {
                            for (a, b) in zip(points, expected) {
                                let error = hypot(a.x - b.x, a.y - b.y)
                                maxOutlineError = max(maxOutlineError, error)
                                independent = independent && error < 1
                            }
                        } else { independent = false }
                    }
                    if overlapping, let bitmap = desk.bitmapImageRepForCachingDisplay(in: area) {
                        desk.cacheDisplay(in: area, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to:
                            output.deletingLastPathComponent().appendingPathComponent("\(corner)-\(long ? "long" : "short").png"))
                    }
                }
                cases += 1
            }
        }
        Orbit.tuckAnchor = nil
        let probe = bubble.subviews.compactMap { $0 as? BubbleView }.first!
        let walls = probe.walls
        let unchanged = probe.redrawRequests
        probe.walls = walls
        let sameWallsStayQuiet = probe.redrawRequests == unchanged
        let changed = probe.redrawRequests
        probe.walls = walls + [Wall(point: .zero, normal: NSPoint(x: 1, y: 0))]
        let wallChangesInvalidate = probe.redrawRequests > changed
        let moved = probe.redrawRequests
        probe.shove(NSPoint(x: 6, y: 0))
        let movementInvalidates = probe.redrawRequests > moved
        probe.step(animated: false)
        let resized = probe.redrawRequests
        probe.goal.size.width += 4; probe.step(animated: true)
        let resizeInvalidates = probe.redrawRequests > resized
        probe.step(animated: false); probe.alphaValue = 0
        let faded = probe.redrawRequests
        probe.step(animated: true)
        let fadeInvalidates = probe.redrawRequests > faded
        arrow.tucked = true; arrow.count = 2
        let pulseBefore = arrow.redrawRequests
        arrow.pulse += 0.12
        let alertPulseInvalidates = arrow.redrawRequests > pulseBefore
        let idleOK = idleRedraws == 0 && idleArrowRedraws == 0 && sameWallsStayQuiet && wallChangesInvalidate && movementInvalidates && resizeInvalidates && fadeInvalidates && alertPulseInvalidates
        let report: [String: Any] = ["cases": cases, "settled": settled, "insideScreen": inside,
            "hiddenPetHasNoEffect": independent, "maxGoalError": maxGoalError, "maxOutlineError": maxOutlineError,
            "allMessagesPresent": complete, "details": details, "idleRedraws": idleRedraws,
            "idleArrowRedraws": idleArrowRedraws, "alertPulseInvalidates": alertPulseInvalidates,
            "sameWallsStayQuiet": sameWallsStayQuiet, "wallChangesInvalidate": wallChangesInvalidate,
            "movementInvalidates": movementInvalidates, "resizeInvalidates": resizeInvalidates, "fadeInvalidates": fadeInvalidates,
            "ok": settled && independent && inside && complete && (!requireIdle || idleOK)]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output) }
        catch { fputs("Could not save bubble geometry report\n", stderr) }
    }
}
