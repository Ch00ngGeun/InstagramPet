import AppKit
import PetCore
import PetSources

extension PetController {
    /// Off the main thread. Reader outboxes are acknowledged only after durable queue acceptance.
    func pollSnapshot() throws -> (ReaderStatuses?, [PetEvent], [ConversationKey: Date]) {
        var waiting = try queue.pending(), marks = try queue.reads()
        let statuses = try pollLocalSources(waiting: &waiting, marks: &marks)
        return (statuses, waiting, marks)
    }

    private func pollLocalSources(waiting: inout [PetEvent], marks: inout [ConversationKey: Date]) throws -> ReaderStatuses? {
        let now = Date()
        guard now.timeIntervalSince(lastSourcesPoll) >= 0.45 else { return nil }
        lastSourcesPoll = now
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
            var readFailed = false
            for (key, at) in batch.reads {
                do {
                    try queue.markRead(key, at: at)
                    marks[key] = max(marks[key] ?? .distantPast, at)
                    waiting.removeAll { $0.conversation.isRead(observedAt: $0.observedAt, in: marks) }
                } catch {
                    // markRead may commit its watermark before an inbox deletion fails.
                    if let recovered = try? queue.reads() {
                        for (key, at) in recovered { marks[key] = max(marks[key] ?? .distantPast, at) }
                        waiting.removeAll { $0.conversation.isRead(observedAt: $0.observedAt, in: marks) }
                    }
                    readFailed = true; break
                }
            }
            if readFailed { continue } // A failed write is retried by this reader, without stopping others.
            var accepted = Set<String>()
            for event in batch.events {
                let expired = PetEvent.date(event.observedAt).map { now.timeIntervalSince($0) > EventQueue.retention } ?? true
                if !expired && !event.conversation.isRead(observedAt: event.observedAt, in: marks) {
                    do { if try queue.enqueue(event) { waiting.append(event) } }
                    catch { break } // Acknowledge the accepted prefix; this reader retries the rest on any write failure.
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

    func poll() {
        guard queue != nil, !pollInFlight else { return }
        pruneExpiredMemory()
        // Leave excess events on disk rather than silently dropping them from memory.
        pollInFlight = true
        let generation = queueGeneration
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.pollSnapshot() }
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
    func isRead(_ event: PetEvent) -> Bool {
        event.conversation.isRead(observedAt: event.observedAt, in: readMarks)
    }

    func applyReads(_ reads: [ConversationKey: Date]) {
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

    func markRead(_ conversation: ConversationKey) {
        let at = Date()
        var marks = readMarks
        marks[conversation] = at
        applyReads(marks)
        io.async { [weak self] in try? self?.queue?.markRead(conversation, at: at) }
    }

    func presentNextIfPossible() {
        guard !paused, !isHidden else { return }
        // Existing unread bubbles never delay a new arrival. Keep the latest five together.
        while !pending.isEmpty { present(pending.removeFirst()) }
    }

    /// Delivery can be delayed independently per source; newest means observedAt, not arrival order.
    func rememberForDisplay(_ event: PetEvent) -> [PetEvent] {
        let previous = (recent + [current].compactMap { $0 }).filter { $0.identity != event.identity && $0.kind != "test" }
        let ordered = Orbit.capped((previous + [event]).sorted {
            let a = PetEvent.date($0.observedAt) ?? .distantPast, b = PetEvent.date($1.observedAt) ?? .distantPast
            return a == b ? $0.identity < $1.identity : a < b
        })
        recent = Array(ordered.dropLast()); current = ordered.last
        return ordered
    }

    func present(_ event: PetEvent) {
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

    @objc func dismissCurrent() {
        bubble.isHidden = true; cat.excited = false
        // With a backlog the bubbles shift in place: the newest one enters on the right.
        presentNextIfPossible()
    }

    func toggleLatest() {
        if bubble.isHidden { showLatest() } // a click never closes bubbles; only hiding does
    }

    @objc func showLatest() {
        if isHidden || paused { showNow(); return }
        if let current { present(current) } else { presentNextIfPossible() }
    }

    @objc func showDemo() {
        guard let event = demoEvent() else { return }
        pending.insert(event, at: 0)
        if isHidden || paused { showNow() }
        dismissCurrent()
        updateStatus()
    }

    func demoEvent(text: String = "안녕! 새 DM이 오면 이렇게 알려줄게요.\nDrag me anywhere. Keep Instagram open in Chrome.", minutesAgo: Int = 0) -> PetEvent? {
        // Decode the same wire model to exercise the bubble without requiring Chrome or a login.
        let sample: [String: Any] = [
            "version": 1, "type": "dm", "eventId": "demo-\(UUID().uuidString)",
            "sender": "demo.pet", "displayName": "Demo Pet", "text": text,
            "threadUrl": "https://www.instagram.com/direct/t/demo/", "observedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(minutesAgo) * 60)), "kind": "test"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sample) else { return nil }
        return try? JSONDecoder().decode(PetEvent.self, from: data)
    }

    @objc func clearMessages() {
        queueGeneration += 1
        pending.removeAll(); current = nil; recent.removeAll()
        bubble.isHidden = true; cat.excited = false
        io.async { [weak self] in
            guard let self, let queue = self.queue else { return }
            try? queue.clear()
        }
        updateStatus()
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
}
