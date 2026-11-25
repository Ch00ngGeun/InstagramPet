import AppKit
import PetCore
import PetSources

// 소스 관련 자체 점검: 카카오톡 손쉬운 사용 측정, 가짜 메시지 생성, 읽음 제거·큐 실패·큐 용량 점검.

extension PetController {
    /// 일부러 숫자만 출력한다. 이 앱의 서명으로 실제 리더를 돌린다.
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

    /// 가짜 연락처만 쓴다. 소스끼리 같은 이벤트 ID를 써서, 소스까지 포함한 화면 식별자를 시험한다.
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

    /// 격리된 시험용 홈에서 가짜 소스로 실제 읽음 제거와, 큐가 찼을 때 받기를 미루는 동작을 시험한다.
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
        applyReads([:]) // 늦게 도착한 예전 디스크 결과가 클릭·읽음 워터마크를 되돌리지 못한다
        let monotonicReads = readMarks == previousMarks
        // 늦게 온 더 오래된 인스타그램 메시지는 가장 오래된 쪽에 끼고(인스타그램 자리가 남음) 다른 것을 밀어내지 않는다.
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

    /// 가짜 리더로 실제 큐 실패를 시험한다. 사용자의 소스 데이터베이스는 절대 열지 않는다.
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
        // 격리된 홈 없이 smoke 플래그로 실행되면 사용자의 큐는 절대 쓰지 않는다.
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
