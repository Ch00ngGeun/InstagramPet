import Foundation
import PetCore
import PetSources

private func kakaoRow(name: String = "Fixture Friend💕", preview: String = "fixture old", time: String = "오후 1:23",
                      badge: String? = "2", y: CGFloat = 50, extra: [KakaoAXNode] = [], complete: Bool = true,
                      duplicateBadgeFrame: Bool = false) -> KakaoAXNode {
    let nameFrame = CGRect(x: 60, y: y + 10, width: 160, height: 20)
    var fields = [
        KakaoAXNode(role: "AXStaticText", value: name, frame: nameFrame),
        KakaoAXNode(role: "AXStaticText", value: preview, frame: CGRect(x: 60, y: y + 42, width: 220, height: 18)),
        KakaoAXNode(role: "AXStaticText", value: time, frame: CGRect(x: 310, y: y + 10, width: 70, height: 18))
    ]
    if let badge {
        fields.append(KakaoAXNode(role: "AXStaticText", value: badge, label: "읽지 않은 메시지", identifier: "unread-count",
                                  frame: duplicateBadgeFrame ? nameFrame : CGRect(x: 355, y: y + 45, width: 25, height: 20)))
    }
    return KakaoAXNode(role: "AXRow", frame: CGRect(x: 0, y: y, width: 400, height: 80), children: fields + extra, complete: complete)
}

private func kakaoTree(_ row: KakaoAXNode = kakaoRow(), others: [KakaoAXNode] = [], title: String = "KakaoTalk", complete: Bool = true) -> KakaoAXNode {
    let area = CGRect(x: 0, y: 0, width: 400, height: 600)
    return KakaoAXNode(role: "AXApplication", children: [
        KakaoAXNode(role: "AXWindow", title: title, frame: area, children: [
            KakaoAXNode(role: "AXTable", frame: area, children: [row] + others)
        ])
    ], complete: complete)
}

/// Measured chat-list roles and relative geometry with synthetic content. The preview's
/// accessibility frame extends four points below its 74-point row in this layout.
private func kakaoCellRow(name: String = "Fixture Friend💕", preview: String = "fixture nested old",
                          time: String = "오전 9:47", badge: String? = "2", y: CGFloat = 50,
                          profile: Bool = true, pinned: Bool = true, participants: String? = nil,
                          extra: [KakaoAXNode] = [], complete: Bool = true, previewHeight: CGFloat = 40) -> KakaoAXNode {
    var fields: [KakaoAXNode] = []
    if profile {
        fields.append(KakaoAXNode(role: "AXButton", label: "Fixture profile", frame: CGRect(x: 20, y: y + 15, width: 44, height: 44)))
    }
    fields.append(KakaoAXNode(role: "AXStaticText", value: name,
                              frame: CGRect(x: 73, y: y + 17, width: participants == nil ? 75 : 103, height: 19)))
    if let participants {
        fields.append(KakaoAXNode(role: "AXStaticText", value: participants, identifier: "fixture-id0",
                                  frame: CGRect(x: 175, y: y + 17, width: 15, height: 18)))
    }
    fields.append(KakaoAXNode(role: "AXStaticText", value: time,
                              frame: CGRect(x: participants == nil ? 232 : 225, y: y + 16,
                                            width: participants == nil ? 56 : 63, height: 17)))
    fields.append(KakaoAXNode(role: "AXScrollArea", frame: CGRect(x: 65, y: y + 38, width: participants == nil ? 158 : 151, height: previewHeight), children: [
        KakaoAXNode(role: "AXTextArea", value: preview,
                    frame: CGRect(x: 75, y: y + 38, width: participants == nil ? 148 : 141, height: previewHeight))
    ]))
    if pinned {
        fields.append(KakaoAXNode(role: "AXImage", label: "Fixture pinned", frame: CGRect(x: 148, y: y + 20, width: 15, height: 15)))
    }
    if let badge {
        fields.append(KakaoAXNode(role: "AXStaticText", value: badge,
                                  frame: CGRect(x: 270, y: y + 38, width: 12, height: 15)))
    }
    let rect = CGRect(x: 0, y: y, width: 305, height: 74)
    let cell = KakaoAXNode(role: "AXCell", frame: rect, children: fields + extra, complete: complete)
    return KakaoAXNode(role: "AXRow", frame: rect, children: [cell])
}

private func kakaoCellTree(_ row: KakaoAXNode = kakaoCellRow(), others: [KakaoAXNode] = []) -> KakaoAXNode {
    let area = CGRect(x: 0, y: 0, width: 305, height: 600)
    return KakaoAXNode(role: "AXApplication", children: [
        KakaoAXNode(role: "AXWindow", title: "카카오톡", frame: area, children: [
            KakaoAXNode(role: "AXScrollArea", frame: area, children: [
                KakaoAXNode(role: "AXTable", frame: area, children: [row] + others)
            ])
        ])
    ])
}

func kakaoChecks() -> [(String, () throws -> Void)] {
    [
        ("Kakao display-name matching accepts only exact names or trailing emoji graphemes", {
            let accepted = ["Fixture Friend", " Fixture Friend💕 ", "Fixture Friend ❤️", "Fixture Friend👨‍👩‍👧", "Fixture Friend🇰🇷"]
            let rejected = ["Fixture Friendship", "Fixture Friend2", "Fixture Friend 2", "Fixture Friend💕2", "Fixture Friend님", "Fixture Friend#", "Fixture Friend\u{200d}", "Fixture Friend\u{1f3fb}"]
            for value in accepted { try sourceCheck(KakaoReader.nameMatches(value, configured: "Fixture Friend"), "valid emoji suffix rejected") }
            for value in rejected { try sourceCheck(!KakaoReader.nameMatches(value, configured: "Fixture Friend"), "textual prefix accepted") }
            try sourceCheck(!KakaoReader.nameMatches("fixture", configured: "   "))
            let composed = "테스트친구"
            try sourceCheck(KakaoReader.nameMatches(composed.decomposedStringWithCanonicalMapping + "💕", configured: composed), "NFC normalization")
        }),
        ("Kakao initial unread is baseline; new preview or absolute time retries until acknowledged", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            try sourceCheck(reader.poll(now: start).events.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture new", badge: "3")))
            let first = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(first.status == .observing && first.events.map(\.text) == ["fixture new"])
            let event = first.events[0]
            try sourceCheck(event.source == .kakao && event.kind == "inbox-preview")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [event.identity])
            reader.acknowledge([event.identity])
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture new", time: "오후 1:24", badge: "4")))
            let repeated = reader.poll(now: start.addingTimeInterval(4)).events
            try sourceCheck(repeated.count == 1 && repeated[0].identity != event.identity, "absolute-time repeat missed")
            reader.acknowledge(Set(repeated.map(\.identity)))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture new", time: "오후 1:24", badge: "5")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(5)).events.isEmpty, "one badge sample invented a message")
            let confirmed = reader.poll(now: start.addingTimeInterval(6)).events
            try sourceCheck(confirmed.count == 1 && confirmed[0].identity != repeated[0].identity,
                            "stable badge increase missed an identical same-minute message")
        }),
        ("Kakao consecutive unread previews update without reading or clearing earlier events", {
            let start = Date().addingTimeInterval(-10)
            for nested in [false, true] {
                func tree(_ preview: String, _ unread: Int) -> KakaoAXNode {
                    nested ? kakaoCellTree(kakaoCellRow(preview: preview, time: "오전 9:47", badge: String(unread)))
                        : kakaoTree(kakaoRow(preview: preview, time: "오전 9:47", badge: String(unread)))
                }
                var state = KakaoCapture.snapshot(pid: 42, root: tree("fixture baseline", 2))
                let reader = KakaoReader(name: "Fixture Friend", capture: { state })
                _ = reader.poll(now: start)
                var identities = Set<String>()
                for index in 1...3 {
                    let preview = "fixture consecutive \(index)"
                    state = .snapshot(pid: 42, root: tree(preview, index + 2))
                    let result = reader.poll(now: start.addingTimeInterval(Double(index)))
                    try sourceCheck(result.events.map(\.text) == [preview], "unread preview did not update")
                    try sourceCheck(result.reads.isEmpty, "unread conversation was cleared")
                    identities.formUnion(result.events.map(\.identity))
                    reader.acknowledge(Set(result.events.map(\.identity)))
                }
                try sourceCheck(identities.count == 3, "consecutive unread messages shared an identity")
            }
        }),
        ("Kakao same-preview same-minute repeats require two stable count increases", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture repeated", badge: "2")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty)
            var identities = Set<String>()
            for (offset, unread) in [3, 4].enumerated() {
                let firstAt = start.addingTimeInterval(Double(2 + offset * 2))
                state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture repeated", badge: String(unread))))
                try sourceCheck(reader.poll(now: firstAt).events.isEmpty, "single count sample emitted")
                let confirmed = reader.poll(now: firstAt.addingTimeInterval(1))
                try sourceCheck(confirmed.events.map(\.text) == ["fixture repeated"] && confirmed.reads.isEmpty)
                try sourceCheck(abs((confirmed.events.first.flatMap { PetEvent.date($0.observedAt) } ?? .distantPast).timeIntervalSince(firstAt)) < 0.002,
                                "confirmation lost first observation time")
                identities.formUnion(confirmed.events.map(\.identity))
                reader.acknowledge(Set(confirmed.events.map(\.identity)))
            }
            try sourceCheck(identities.count == 2)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(7)).events.isEmpty, "stable count replayed after acknowledgement")
        }),
        ("Kakao initial count hydration, transient increases and count rebounds do not invent messages", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: "2")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            for (index, unread) in [7, 7, 8, 7, 2, 7, 7].enumerated() {
                state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: String(unread))))
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.isEmpty && result.reads.isEmpty, "hydration or count rebound invented a message")
            }
        }),
        ("Kakao a delayed preview change replaces its count candidate without duplicate delivery", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: "2")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            _ = reader.poll(now: start.addingTimeInterval(1))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: "3")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture hydrated preview", badge: "3")))
            let changed = reader.poll(now: start.addingTimeInterval(3))
            try sourceCheck(changed.events.map(\.text) == ["fixture hydrated preview"])
            reader.acknowledge(Set(changed.events.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty, "preview and badge delivered twice")
        }),
        ("Kakao identical new preview after a confirmed zero count remains newer than its read mark", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture identical", badge: nil)))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            let read = reader.poll(now: start.addingTimeInterval(1)).reads
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture identical", badge: "1")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty)
            let incoming = reader.poll(now: start.addingTimeInterval(3))
            try sourceCheck(incoming.events.count == 1 && incoming.reads == read)
            let event = incoming.events[0]
            try sourceCheck(!event.conversation.isRead(observedAt: event.observedAt, in: incoming.reads), "old read mark erased repeated unread preview")
        }),
        ("Kakao two complete badge-absent snapshots clear only its conversation after acknowledgement", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture incoming")))
            let event = reader.poll(now: start.addingTimeInterval(1)).events[0]
            reader.acknowledge([event.identity])
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture incoming", badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).reads.isEmpty, "single missing badge cleared bubbles")
            let read = reader.poll(now: start.addingTimeInterval(3))
            let key = ConversationKey.local(.kakao, identifier: "Fixture Friend")
            try sourceCheck(read.reads.count == 1 && key.isRead(observedAt: event.observedAt, in: read.reads))
            try sourceCheck(read.reads.keys.allSatisfy { $0.source == .kakao })
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).reads == read.reads, "idle poll refreshed read cutoff")
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "after reading", time: "오후 1:25", badge: "1")))
            let new = reader.poll(now: start.addingTimeInterval(5))
            try sourceCheck(new.events.count == 1 && !key.isRead(observedAt: new.events[0].observedAt, in: new.reads))
        }),
        ("Kakao stable zero at startup publishes one read mark for an earlier process's queue", {
            let start = Date().addingTimeInterval(-5)
            let state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: nil)))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            try sourceCheck(reader.poll(now: start).reads.isEmpty)
            let second = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(second.events.isEmpty && second.reads.count == 1)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).reads == second.reads)
        }),
        ("Kakao long gaps and PID changes rebaseline while preserving unacknowledged events", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "before gap")))
            let queued = reader.poll(now: start.addingTimeInterval(1)).events
            state = .unavailable
            let unavailable = reader.poll(now: start.addingTimeInterval(5))
            try sourceCheck(unavailable.status == .unavailable && unavailable.events == queued && unavailable.reads.isEmpty)
            reader.acknowledge(Set(queued.map(\.identity)))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "during gap")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(6)).events.isEmpty, "long gap history replayed")
            state = .snapshot(pid: 43, root: kakaoTree(kakaoRow(preview: "PID replacement")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(7)).events.isEmpty, "PID replacement replayed")
            state = .snapshot(pid: 43, root: kakaoTree(kakaoRow(preview: "after PID baseline")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(8)).events.map(\.text) == ["after PID baseline"])
        }),
        ("Kakao brief unavailable captures retain same-process preview changes but never confirmation candidates", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: "2")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            _ = reader.poll(now: start.addingTimeInterval(1))
            state = .unavailable
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).status == .unavailable)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture after short timeout", badge: "3")))
            let recovered = reader.poll(now: start.addingTimeInterval(3))
            try sourceCheck(recovered.events.map(\.text) == ["fixture after short timeout"], "short timeout discarded new preview")
            reader.acknowledge(Set(recovered.events.map(\.identity)))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture after short timeout", badge: "4")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty)
            state = .unavailable
            _ = reader.poll(now: start.addingTimeInterval(5))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture after short timeout", badge: "4")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(6)).events.isEmpty, "badge candidate crossed a failed capture")
            let confirmed = reader.poll(now: start.addingTimeInterval(7))
            try sourceCheck(confirmed.events.count == 1)
            reader.acknowledge(Set(confirmed.events.map(\.identity)))
            state = .snapshot(pid: 43, root: kakaoTree(kakaoRow(preview: "fixture new process", badge: "5")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(8)).events.isEmpty, "short PID replacement reused old baseline")
        }),
        ("Kakao zero confirmation never crosses a PID change or a brief timeout", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: nil)))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 43, root: kakaoTree(kakaoRow(badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).reads.isEmpty, "zero confirmation crossed process replacement")
            state = .unavailable
            _ = reader.poll(now: start.addingTimeInterval(2))
            state = .snapshot(pid: 43, root: kakaoTree(kakaoRow(badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).reads.isEmpty, "zero confirmation crossed timeout")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).reads.count == 1)
        }),
        ("Kakao a long pause between complete snapshots rebaselines before new delivery", {
            let start = Date().addingTimeInterval(-10)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture during long pause", badge: "3")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(5)).events.isEmpty, "long paused capture replayed")
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture after pause", badge: "4")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(6)).events.map(\.text) == ["fixture after pause"])
        }),
        ("Kakao duplicate matching rows and standalone conversation windows are rejected", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "ambiguous one"), others: [kakaoRow(name: "Fixture Friend❤️", preview: "ambiguous two", y: 140)]))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "conversation transcript"), title: "Fixture Friend"))
            let transcript = reader.poll(now: start.addingTimeInterval(2))
            try sourceCheck(transcript.status == .idle && transcript.events.isEmpty && transcript.reads.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(name: "Fixture Friendship", preview: "wrong name")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "safe baseline"), title: "카카오톡"))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty)
        }),
        ("Kakao numeric and time-like previews remain distinct from right-side badge and time", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "123", badge: "2")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "12:34", badge: "3")))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.map(\.text) == ["12:34"], "time-like preview classified as time")
            reader.acknowledge(Set(first.map(\.identity)))
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "123", badge: "99+")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.text) == ["123"], "numeric preview classified as badge")
        }),
        ("Kakao incomplete, extra-field and overlapping-field trees never imply read", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            let broken = [
                kakaoTree(kakaoRow(preview: "partial", badge: nil, complete: false)),
                kakaoTree(kakaoRow(preview: "empty badge", badge: "")),
                kakaoTree(kakaoRow(preview: "overlap", duplicateBadgeFrame: true)),
                kakaoTree(kakaoRow(preview: "extra", extra: [KakaoAXNode(role: "AXStaticText", value: "unclassified", frame: CGRect(x: 60, y: 112, width: 100, height: 14))])),
                kakaoTree(kakaoRow(preview: "bad badge", badge: "unknown")),
                kakaoTree(kakaoRow(preview: "bad time", time: "1분 전")),
                kakaoTree(kakaoRow(preview: "truncated root", badge: nil), complete: false)
            ]
            for (index, tree) in broken.enumerated() {
                state = .snapshot(pid: 42, root: tree)
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.isEmpty && result.reads.isEmpty, "malformed tree emitted data")
            }
        }),
        ("Kakao calendar rollover and relative elapsed age do not replay an old preview", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree(kakaoRow(time: "오후 11:59")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            for (index, time) in ["어제", "월요일", "11. 7."].enumerated() {
                state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(time: time)))
                try sourceCheck(reader.poll(now: start.addingTimeInterval(Double(index + 1))).events.isEmpty, "calendar label invented a message")
            }
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(time: "2분 전")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty)
        }),
        ("Kakao interrupted zero-badge confirmation starts over after partial tree", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).reads.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: nil, complete: false)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).reads.isEmpty)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).reads.isEmpty)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).reads.count == 1)
        }),
        ("Kakao bounded retry outbox holds latest preview until capacity is acknowledged", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            var full: [PetEvent] = []
            for index in 1...201 {
                state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "fixture \(index)")))
                full = reader.poll(now: start.addingTimeInterval(Double(index) * 0.005)).events
                try sourceCheck(full.count <= 200, "outbox exceeded bound")
            }
            try sourceCheck(full.count == 200)
            reader.acknowledge(Set(full.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.text) == ["fixture 201"], "capacity did not admit latest preview")
        }),
        ("Kakao nested AXCell and AXTextArea chat-list preview has a quiet baseline and durable retry", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            let baseline = reader.poll(now: start)
            try sourceCheck(baseline.status == .observing && baseline.events.isEmpty && baseline.reads.isEmpty,
                            "nested chat-list row did not establish baseline")
            state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture nested incoming", badge: "3")))
            let first = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(first.events.map(\.text) == ["fixture nested incoming"], "AXTextArea preview was not delivered")
            let event = first.events[0]
            try sourceCheck(event.source == .kakao && event.kind == "inbox-preview"
                            && event.conversation == ConversationKey.local(.kakao, identifier: "Fixture Friend"))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [event.identity],
                            "nested preview changed identity before acknowledgement")
            reader.acknowledge([event.identity])
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
        }),
        ("Kakao nested badge disappearance clears only the tracked conversation after two full snapshots", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture nested unread")))
            let incoming = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(incoming.events.count == 1, "nested unread preview missing")
            let event = incoming.events[0]
            reader.acknowledge([event.identity])
            state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture nested unread", badge: nil)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).reads.isEmpty,
                            "one nested badge-absent snapshot cleared unread")
            let cleared = reader.poll(now: start.addingTimeInterval(3))
            let key = ConversationKey.local(.kakao, identifier: "Fixture Friend")
            try sourceCheck(cleared.reads.count == 1 && key.isRead(observedAt: event.observedAt, in: cleared.reads))
            try sourceCheck(!ConversationKey.local(.messages, identifier: "fixture@example.invalid")
                .isRead(observedAt: event.observedAt, in: cleared.reads), "nested Kakao read crossed source")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).reads == cleared.reads)
        }),
        ("Kakao nested group participant count beside the name never becomes a badge or read mark", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            try sourceCheck(reader.poll(now: start).status == .observing, "individual nested baseline missing")
            for (index, badge) in [Optional("3"), nil, nil].enumerated() {
                state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture group \(index)", badge: badge, participants: "9")))
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.isEmpty && result.reads.isEmpty,
                                "group row with participant count emitted message or read")
            }
            state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture individual baseline")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty,
                            "returning individual row replayed group gap")
        }),
        ("Kakao numeric and clock-like AXTextArea previews stay distinct from unread and time", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "123")))
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            let baseline = reader.poll(now: start)
            try sourceCheck(baseline.status == .observing && baseline.events.isEmpty)
            for (index, preview) in ["12:34", "99", "오전 9:47"].enumerated() {
                state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: preview, badge: String(index + 3))))
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.map(\.text) == [preview], "AXTextArea text was treated as unread count or clock")
                reader.acknowledge(Set(result.events.map(\.identity)))
            }
        }),
        ("Kakao nested profile buttons and pin images are optional decorations", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            _ = reader.poll(now: start)
            for (index, icons) in [(false, false), (true, false), (false, true), (true, true)].enumerated() {
                let preview = "fixture icon variant \(index)"
                state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: preview, profile: icons.0, pinned: icons.1)))
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.map(\.text) == [preview], "decorative profile or pin blocked preview")
                reader.acknowledge(Set(result.events.map(\.identity)))
            }
            state = .snapshot(pid: 42, root: kakaoCellTree(kakaoCellRow(preview: "fixture icon variant 3", profile: false, pinned: false)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(5)).events.isEmpty,
                            "changing only decorations invented a message")
        }),
        ("Kakao nested partial previews and duplicate matching rows do not imply read", {
            let start = Date().addingTimeInterval(-5)
            var state = KakaoCapture.snapshot(pid: 42, root: kakaoCellTree())
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            try sourceCheck(reader.poll(now: start).status == .observing, "valid nested baseline missing")
            let malformed = [
                kakaoCellTree(kakaoCellRow(preview: "fixture partial", badge: nil, complete: false)),
                kakaoCellTree(kakaoCellRow(preview: "", badge: nil)),
                kakaoCellTree(kakaoCellRow(preview: "fixture excessive overflow", badge: nil, previewHeight: 49)),
                kakaoCellTree(kakaoCellRow(preview: "fixture first", badge: nil),
                              others: [kakaoCellRow(name: "Fixture Friend❤️", preview: "fixture duplicate", badge: nil, y: 140)]),
                kakaoCellTree(kakaoCellRow(preview: "fixture ambiguous", badge: nil, extra: [
                    KakaoAXNode(role: "AXScrollArea", frame: CGRect(x: 80, y: 106, width: 180, height: 18), children: [
                        KakaoAXNode(role: "AXTextArea", value: "fixture second preview", frame: CGRect(x: 80, y: 106, width: 170, height: 18))
                    ])
                ]))
            ]
            for (index, root) in malformed.enumerated() {
                state = .snapshot(pid: 42, root: root)
                let result = reader.poll(now: start.addingTimeInterval(Double(index + 1)))
                try sourceCheck(result.events.isEmpty && result.reads.isEmpty,
                                "partial or ambiguous nested row emitted data")
            }
        }),
        ("Kakao disabled config avoids captures and permission denial remains idle without false data", {
            let start = Date().addingTimeInterval(-5)
            var calls = 0
            let disabled = KakaoReader(name: nil, capture: { calls += 1; return .permissionRequired })
            try sourceCheck(disabled.poll(now: start).status == .disabled && calls == 0)
            var state = KakaoCapture.permissionRequired
            let reader = KakaoReader(name: "Fixture Friend", capture: { state })
            let denied = reader.poll(now: start)
            try sourceCheck(denied.status == .permissionRequired && denied.events.isEmpty && denied.reads.isEmpty)
            state = .idle
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).status == .idle)
            state = .snapshot(pid: 42, root: kakaoTree(kakaoRow(preview: "permission-gap baseline")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty)
        })
    ]
}
