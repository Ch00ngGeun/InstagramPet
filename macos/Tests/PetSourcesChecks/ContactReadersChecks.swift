import Foundation
import PetCore
import PetSources

private final class ContactFixtureReader: LocalSourceReader {
    let source: PetSource
    let conversation: ConversationKey
    var events: [PetEvent] = []
    var reads: [ConversationKey: Date] = [:]
    var status: SourceStatus = .observing
    var quietFirstPoll = false
    var pollCount = 0
    var accepted = Set<String>()
    var restored: [PetEvent] = []

    init(source: PetSource = .messages, identifier: String) {
        self.source = source
        conversation = ConversationKey.local(source, identifier: identifier)
    }
    func poll(now: Date) -> SourcePoll {
        pollCount += 1
        return SourcePoll(events: quietFirstPoll && pollCount == 1 ? [] : events.filter { !accepted.contains($0.identity) },
                          reads: reads, status: status)
    }
    func restorePending(_ events: [PetEvent]) { restored = events.filter { $0.conversation == conversation } }
    func acknowledge(_ identities: Set<String>) { accepted.formUnion(identities) }
    func event(_ id: String, at: Date) -> PetEvent {
        PetEvent(eventId: id, sender: source == .messages ? "messages.contact" : "kakao.contact", text: "synthetic",
                 threadUrl: conversation.key, observedAt: PetEvent.timestamp(at), kind: "thread-message", source: source)
    }
}

func contactReadersChecks() -> [(String, () throws -> Void)] {
    [
        ("Multiple contacts deliver in time order with independent conversation read marks", {
            let now = Date(timeIntervalSince1970: 1_800_000_000), a = ContactFixtureReader(identifier: "fixture.a@example.invalid"), b = ContactFixtureReader(identifier: "fixture.b@example.invalid")
            let first = a.event("fixture-a", at: now.addingTimeInterval(-2)), second = b.event("fixture-b", at: now.addingTimeInterval(-1))
            a.events = [first]; b.events = [second]
            a.reads = [a.conversation: now.addingTimeInterval(-3)]
            b.reads = [b.conversation: now.addingTimeInterval(-1), a.conversation: now.addingTimeInterval(-4)]
            let readers = ContactReaders(source: .messages, identifiers: ["a", "b"]) { $0 == "a" ? a : b }
            let batch = readers.poll(now: now)
            try sourceCheck(batch.events.map(\.identity) == [first.identity, second.identity], "contact delivery order")
            try sourceCheck(batch.reads.count == 2 && batch.reads[a.conversation] == a.reads[a.conversation] && batch.reads[b.conversation] == b.reads[b.conversation], "contact read marks merged incorrectly")
            try sourceCheck(!first.conversation.isRead(observedAt: first.observedAt, in: batch.reads), "another contact's read erased unread message")
            try sourceCheck(second.conversation.isRead(observedAt: second.observedAt, in: batch.reads), "read contact not reflected")
        }),
        ("Contact acknowledgements and restored events remain isolated across contacts and sources", {
            let now = Date(), a = ContactFixtureReader(identifier: "fixture.a@example.invalid"), b = ContactFixtureReader(identifier: "fixture.b@example.invalid")
            let first = a.event("fixture-a", at: now), second = b.event("fixture-b", at: now)
            let foreign = ContactFixtureReader(source: .kakao, identifier: "Fixture Other").event("fixture-foreign", at: now)
            a.events = [first, foreign]; b.events = [second]
            a.reads = [foreign.conversation: now]
            let readers = ContactReaders(source: .messages, identifiers: ["a", "b"]) { $0 == "a" ? a : b }
            readers.restorePending([first, second, foreign])
            try sourceCheck(a.restored.map(\.identity) == [first.identity] && b.restored.map(\.identity) == [second.identity], "pending restoration crossed contacts")
            readers.acknowledge([first.identity])
            let batch = readers.poll(now: now)
            try sourceCheck(batch.events.map(\.identity) == [second.identity] && batch.reads.isEmpty, "acknowledgement or foreign source crossed boundary")
        }),
        ("Adding and removing contacts reuses existing baselines and constructs only new readers", {
            let now = Date(), a = ContactFixtureReader(identifier: "fixture.a@example.invalid"), b = ContactFixtureReader(identifier: "fixture.b@example.invalid"), c = ContactFixtureReader(identifier: "fixture.c@example.invalid")
            a.quietFirstPoll = true; b.quietFirstPoll = true; c.quietFirstPoll = true
            let fixture = ["a": a, "b": b, "c": c]
            var created: [String] = []
            func make(_ id: String) -> LocalSourceReader { created.append(id); return fixture[id]! }
            let first = ContactReaders(source: .messages, identifiers: ["a", "c"], makeReader: make)
            try sourceCheck(first.poll(now: now).events.isEmpty)
            let event = a.event("fixture-new-after-baseline", at: now.addingTimeInterval(1))
            a.events = [event]; b.events = [b.event("fixture-old-before-added", at: now)]
            let next = ContactReaders(source: .messages, identifiers: ["a", "b", "a", ""], reusing: first, makeReader: make)
            let batch = next.poll(now: now.addingTimeInterval(2))
            try sourceCheck(created == ["a", "c", "b"], "unchanged or duplicate contacts were reconstructed")
            try sourceCheck(batch.events.map(\.identity) == [event.identity], "retained baseline lost or newly added history replayed")
            try sourceCheck(a.pollCount == 2 && b.pollCount == 1 && c.pollCount == 1, "removed reader was still polled")
        }),
        ("Contact status aggregation reports active contacts and falls back to actionable failures", {
            let a = ContactFixtureReader(identifier: "fixture.a@example.invalid"), b = ContactFixtureReader(identifier: "fixture.b@example.invalid")
            let readers = ContactReaders(source: .messages, identifiers: ["a", "b"]) { $0 == "a" ? a : b }
            a.status = .observing; b.status = .permissionRequired
            try sourceCheck(readers.poll(now: Date()).status == .observing)
            a.status = .idle
            try sourceCheck(readers.poll(now: Date()).status == .permissionRequired)
            b.status = .unavailable
            try sourceCheck(readers.poll(now: Date()).status == .unavailable)
            b.status = .disabled
            try sourceCheck(readers.poll(now: Date()).status == .idle)
            a.status = .disabled
            try sourceCheck(readers.poll(now: Date()).status == .disabled)
            try sourceCheck(readers.accessibilityStatus == .disabled && readers.notificationStatus == .disabled)
            var constructions = 0
            let empty = ContactReaders(source: .messages, identifiers: []) { _ in constructions += 1; return a }
            try sourceCheck(empty.poll(now: Date()).status == .disabled && constructions == 0)
        }),
        ("Kakao contact groups aggregate notification and accessibility path states separately", {
            let axA = ContactFixtureReader(source: .kakao, identifier: "Fixture A"), notificationA = ContactFixtureReader(source: .kakao, identifier: "Fixture A")
            let axB = ContactFixtureReader(source: .kakao, identifier: "Fixture B"), notificationB = ContactFixtureReader(source: .kakao, identifier: "Fixture B")
            axA.status = .observing; notificationA.status = .permissionRequired
            axB.status = .idle; notificationB.status = .observing
            let a = KakaoCombinedReader(name: "Fixture A", axReader: axA, notificationReader: notificationA)
            let b = KakaoCombinedReader(name: "Fixture B", axReader: axB, notificationReader: notificationB)
            let readers = ContactReaders(source: .kakao, identifiers: ["a", "b"]) { $0 == "a" ? a : b }
            try sourceCheck(readers.poll(now: Date()).status == .observing)
            try sourceCheck(readers.accessibilityStatus == .observing && readers.notificationStatus == .observing)
        }),
        ("Kakao overlapping emoji name aliases never poll or create duplicate events and false reads", {
            try sourceCheck(ContactReaders.hasAmbiguousKakaoNames(["Fixture", "Fixture 💕"]))
            try sourceCheck(ContactReaders.hasAmbiguousKakaoNames(["Fixture👨‍👩‍👧", "Fixture"]))
            try sourceCheck(!ContactReaders.hasAmbiguousKakaoNames(["Fixture", "Fixture Other"]))
            try sourceCheck(!ContactReaders.hasAmbiguousKakaoNames(["Fixture 💕", "Fixture ❤️"]))
            let child = ContactFixtureReader(source: .kakao, identifier: "Fixture")
            child.events = [child.event("fixture-ambiguous", at: Date())]
            child.reads = [child.conversation: Date()]
            var constructions = 0
            let readers = ContactReaders(source: .kakao, identifiers: ["Fixture", "Fixture 💕"]) { _ in
                constructions += 1; return child
            }
            let batch = readers.poll(now: Date())
            try sourceCheck(batch.status == .unavailable && batch.events.isEmpty && batch.reads.isEmpty)
            try sourceCheck(constructions == 0 && child.pollCount == 0, "ambiguous names accessed the original app")
            try sourceCheck(readers.accessibilityStatus == .unavailable && readers.notificationStatus == .unavailable)
        })
    ]
}
