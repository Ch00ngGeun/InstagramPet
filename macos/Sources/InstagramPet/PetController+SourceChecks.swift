import AppKit
import PetCore
import PetSources

extension PetController {
    /// Deliberately numeric-only. Runs the production reader with this app's signing identity.
    func measureLiveAccessibility() {
        guard let config = try? SourcesConfig.load(paths: paths) else { print("[0]"); return }
        var captures: [KakaoCaptureMetrics] = [], polls: [Double] = []
        var statuses = Array(repeating: 0, count: 5)
        let reader = KakaoReader(name: config.kakaoNames.first, captureMetrics: { captures.append($0) })
        for _ in 0..<100 {
            let started = ProcessInfo.processInfo.systemUptime
            let batch = reader.poll(now: Date())
            polls.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let index: Int
            switch batch.status {
            case .disabled: index = 0
            case .idle: index = 1
            case .observing: index = 2
            case .permissionRequired: index = 3
            case .unavailable: index = 4
            }
            statuses[index] += 1
            reader.acknowledge(Set(batch.events.map(\.identity)))
            usleep(100_000)
        }
        func summary(_ values: [Double]) -> [Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [0, 0, 0] }
            return [sorted[(sorted.count - 1) / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!]
        }
        var report: [Double] = [Double(polls.count)]
        report.append(contentsOf: summary(polls))
        report.append(contentsOf: summary(captures.map(\.milliseconds)))
        report.append(Double(captures.filter(\.deadlineExceeded).count))
        report.append(Double(captures.map(\.nodes).reduce(0, +)) / Double(max(1, captures.count)))
        report.append(contentsOf: statuses.map { Double($0) })
        if let data = try? JSONSerialization.data(withJSONObject: report), let output = String(data: data, encoding: .utf8) { print(output) }
    }

    /// Fake contacts only. Reused event IDs across sources exercise the source-qualified UI identity.
    func fullSourceEvents(_ counts: (Int, Int, Int)) -> [PetEvent] {
        let plan: [(PetSource, Int)] = [(.kakao, counts.0), (.instagram, counts.1), (.messages, counts.2)]
        let texts = ["보고 싶다 ❤️", "ㅋㅋㅋ", "(릴스)", "오늘 저녁에 뭐 먹을래?", "자기가 결정해용", "(이미지)", "응응"]
        var all: [(PetSource, Int)] = []
        for round in 0..<7 { for (source, n) in plan where round < n { all.append((source, round)) } }
        return all.enumerated().map { index, item in
            let (source, n) = item
            let key = source == .instagram ? "https://www.instagram.com/direct/t/fixture/"
                : ConversationKey.local(source, identifier: source == .messages ? "fixture@example.invalid" : "fixture.friend").key
            let label = source == .kakao ? "카톡" : source == .instagram ? "인스타" : "메시지"
            return PetEvent(eventId: "full-\(source)-\(n)", sender: "fixture.sender", text: "\(label) \(n + 1) \(texts[(n + index) % texts.count])", threadUrl: key,
                            observedAt: PetEvent.timestamp(Date().addingTimeInterval(Double(index - all.count) * 60)),
                            kind: source == .kakao ? "inbox-preview" : "thread-message", source: source)
        }
    }

    func mixedSourceEvents() -> [PetEvent] {
        let samples: [(PetSource, String, String)] = [
            (.instagram, "mixed-1", "Instagram 1 · 사진이 도착했어요"),
            (.messages, "mixed-1", "Messages 1 · 안녕!"),
            (.instagram, "mixed-2", "Instagram 2 · (릴스)"),
            (.messages, "mixed-2", "Messages 2 · 조금 뒤에 만나요"),
            (.kakao, "mixed-1", "KakaoTalk · 새 메시지 예시")
        ]
        return samples.enumerated().map { index, sample in
            let (source, id, text) = sample
            let key = source == .instagram ? "https://www.instagram.com/direct/t/fixture/"
                : ConversationKey.local(source, identifier: source == .messages ? "fixture@example.invalid" : "fixture.friend").key
            return PetEvent(eventId: id, sender: "fixture.sender", text: text, threadUrl: key,
                            observedAt: PetEvent.timestamp(Date().addingTimeInterval(Double(index - samples.count) * 60)),
                            kind: source == .kakao ? "inbox-preview" : "thread-message", source: source)
        }
    }

    /// Exercise real read removal and queue backpressure with synthetic sources in the isolated test home.
    func checkSourceReads(to output: URL) {
        buildPanel()
        buildMenu()
        statusItem.isVisible = false
        let events = mixedSourceEvents()
        recent = Array(events.dropLast())
        current = events.last
        pending = PetSource.allCases.compactMap { source in
            guard let sample = events.first(where: { $0.source == source }) else { return nil }
            return PetEvent(eventId: "waiting", sender: sample.sender, text: sample.text,
                            threadUrl: sample.threadUrl, observedAt: sample.observedAt, kind: sample.kind, source: source)
        }
        bubble.show(events)
        func shown() -> [PetEvent] { recent + [current].compactMap { $0 } }
        var counts = [shown().count], waiting = [pending.count]
        var sourcesAfterKakao: [String] = []
        for source in [PetSource.kakao, .messages, .instagram] {
            guard let conversation = events.first(where: { $0.source == source })?.conversation else { continue }
            var marks = readMarks
            marks[conversation] = Date()
            applyReads(marks)
            counts.append(shown().count)
            waiting.append(pending.count)
            if source == .kakao { sourcesAfterKakao = shown().map { $0.source.rawValue } }
        }
        let distinct = Set(events.map(\.identity)).count == events.count
        let previousMarks = readMarks
        applyReads([:]) // an older in-flight disk snapshot cannot undo a click/read watermark
        let monotonicReads = readMarks == previousMarks
        // A delayed, older Instagram delivery joins at the oldest end (Instagram has room) and evicts none of the others.
        recent = Array(events.dropLast()); current = events.last
        let delayed = PetEvent(eventId: "late-old", sender: "fixture.sender", text: "synthetic",
            threadUrl: events[0].threadUrl, observedAt: PetEvent.timestamp(Date().addingTimeInterval(-3600)), kind: "thread-message")
        let orderPreserved = rememberForDisplay(delayed).map(\.identity) == ([delayed] + events).map(\.identity)
        recent = []; current = nil
        let capacityRecovery = checkSourceCapacity()
        let report: [String: Any] = [
            "version": 1, "visibleCounts": counts, "pendingCounts": waiting,
            "sourcesAfterKakaoRead": sourcesAfterKakao, "sourceIdentitiesDistinct": distinct,
            "capacityRecovery": capacityRecovery,
            "orderPreserved": orderPreserved,
            "monotonicReads": monotonicReads,
            "ok": counts == [5, 4, 2, 0] && waiting == [3, 2, 1, 0] && distinct && bubble.isHidden && capacityRecovery && orderPreserved && monotonicReads
        ]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            print("Source read smoke report: \(output.path)")
        } catch { fputs("Could not save source read smoke report\n", stderr) }
    }

    /// Actual queue failures with fake readers; never opens a user's source database.
    func checkSourceFailures(to output: URL) {
        final class FixtureReader: LocalSourceReader {
            let source: PetSource
            let batch: SourcePoll
            var accepted = Set<String>()
            init(_ source: PetSource, _ batch: SourcePoll) { self.source = source; self.batch = batch }
            func poll(now: Date) -> SourcePoll { batch }
            func acknowledge(_ identities: Set<String>) { accepted.formUnion(identities) }
        }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let root = paths.root.resolvingSymlinksInPath().path
        guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil,
              root.hasPrefix(temporary + "/") || root.hasPrefix("/private/tmp/") else { return }
        queue = EventQueue(paths: paths)
        var results: [Bool] = []
        for readFailure in [false, true] {
            do {
                try queue.clear()
                func event(_ id: String, _ source: PetSource, text: String = "synthetic") -> PetEvent {
                    PetEvent(eventId: "failure-\(readFailure)-\(id)", sender: "fixture.sender", text: text,
                        threadUrl: ConversationKey.local(source, identifier: "fixture@example.invalid").key,
                        observedAt: PetEvent.timestamp(), kind: "thread-message", source: source)
                }
                let good = event("first", .messages), bad = event("bad", .messages, text: ""), tail = event("tail", .messages)
                let other = event("other", .kakao)
                let first = FixtureReader(.messages, SourcePoll(events: [good, bad, tail],
                    reads: readFailure ? [ConversationKey(source: .messages, key: "invalid"): Date()] : [:], status: .observing))
                let second = FixtureReader(.kakao, SourcePoll(events: [other], status: .observing))
                localReaders = [first, second]; lastSourcesPoll = .distantPast
                let (_, waiting, _) = try pollSnapshot()
                let expected = readFailure ? Set([other.identity]) : Set([good.identity, other.identity])
                results.append(Set(waiting.map(\.identity)) == expected && second.accepted == [other.identity]
                    && first.accepted == (readFailure ? [] : [good.identity]))
            } catch { results.append(false) }
        }
        do {
            try queue.clear()
            let read = PetEvent(eventId: "partial-read", sender: "fixture.sender", text: "synthetic",
                threadUrl: ConversationKey.local(.messages, identifier: "fixture@example.invalid").key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
            try queue.enqueue(read)
            let file = try FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path); try? queue.clear() }
            let first = FixtureReader(.messages, SourcePoll(reads: [read.conversation: Date()], status: .observing))
            let other = PetEvent(eventId: "partial-read-other", sender: "fixture.sender", text: "synthetic",
                threadUrl: ConversationKey.local(.kakao, identifier: "Fixture Other").key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .kakao)
            let second = FixtureReader(.kakao, SourcePoll(events: [other], status: .observing))
            localReaders = [first, second]; lastSourcesPoll = .distantPast
            let (_, waiting, marks) = try pollSnapshot()
            results.append(FileManager.default.fileExists(atPath: file.path) && waiting.map(\.identity) == [other.identity]
                && second.accepted == [other.identity]
                && read.conversation.isRead(observedAt: read.observedAt, in: marks))
        } catch { results.append(false) }
        let report: [String: Any] = ["cases": results.count, "ok": results.count == 3 && results.allSatisfy { $0 }]
        try? JSONSerialization.data(withJSONObject: report).write(to: output)
    }

    private func checkSourceCapacity() -> Bool {
        // Never use the user's queue when a smoke flag is invoked without an isolated home.
        let resolved = paths.root.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil,
              resolved.hasPrefix(temporary + "/") || resolved.hasPrefix("/private/tmp/") else { return false }
        final class FixtureReader: LocalSourceReader {
            let source = PetSource.messages
            let value: PetEvent
            var accepted = Set<String>()
            init(_ value: PetEvent) { self.value = value }
            func poll(now: Date) -> SourcePoll { SourcePoll(events: [value], status: .observing) }
            func acknowledge(_ identities: Set<String>) { accepted.formUnion(identities) }
        }
        queue = EventQueue(paths: paths)
        defer { try? queue.clear(); localReaders = [] }
        do {
            guard try queue.count() == 0 else { return false }
            var first: PetEvent?
            for index in 0..<EventQueue.capacity {
                let e = PetEvent(eventId: "capacity-\(index)", sender: "fixture.sender", text: "synthetic",
                    threadUrl: "https://www.instagram.com/direct/t/fixture/", observedAt: PetEvent.timestamp(), kind: "thread-message")
                if first == nil { first = e }
                try queue.enqueue(e)
            }
            let value = PetEvent(eventId: "capacity-local", sender: "messages.contact", text: "synthetic",
                threadUrl: ConversationKey.local(.messages, identifier: "fixture@example.invalid").key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
            let reader = FixtureReader(value)
            localReaders = [reader]; lastSourcesPoll = .distantPast
            _ = try pollSnapshot()
            guard reader.accepted.isEmpty, try queue.pending().count == EventQueue.capacity else { return false }
            try queue.consume(first!)
            lastSourcesPoll = .distantPast
            _ = try pollSnapshot()
            let remaining = try queue.count()
            return reader.accepted == [value.identity] && remaining == EventQueue.capacity
        } catch { return false }
    }
}
