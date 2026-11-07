import Foundation
import Darwin
import PetCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
    guard try condition() else { throw CheckFailure(message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure("invalid input was accepted")
}
func event(_ id: String = UUID().uuidString, sender: String = "alice", text: String = "hello",
           url: String = "https://www.instagram.com/direct/t/123/", at: Date = Date()) -> PetEvent {
    PetEvent(eventId: id, sender: sender, text: text, threadUrl: url,
             observedAt: PetEvent.timestamp(at), kind: "thread-message")
}
func isolatedQueue(_ body: (EventQueue) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Instagram Pet Checks 한글 " + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(EventQueue(paths: PetPaths(root: root)))
}

let checks: [(String, () throws -> Void)] = [
    ("Comma-separated contacts normalize, deduplicate and preserve paired Instagram order", {
        let raw = SourcesConfig(kakao: .init(name: " Fixture One , Fixture Two, Fixture One "),
            messages: .init(handle: " Fixture@Example.test , 010-1234-5678, +821012345678, other@example.test "),
            instagram: .init(username: " @Fixture.One, Fixture.Two, @Fixture.One ", threadId: " 123 , 456, 789 "))
        let config = try raw.validated()
        try check(config.kakao?.name == "Fixture One,Fixture Two")
        try check(config.kakaoNames == ["Fixture One", "Fixture Two"])
        try check(config.messages?.handle == "fixture@example.test,+821012345678,other@example.test")
        try check(config.messageHandles == ["fixture@example.test", "+821012345678", "other@example.test"])
        try check(config.instagram == .init(username: "fixture.one,fixture.two,fixture.one", threadId: "123,456,789"))
        try check(config.instagramSelections == [.init(username: "fixture.one", threadId: "123"),
            .init(username: "fixture.two", threadId: "456"), .init(username: "fixture.one", threadId: "789")])
        try check(SourcesConfig().instagramSelections.isEmpty && SourcesConfig().messageHandles.isEmpty && SourcesConfig().kakaoNames.isEmpty)
        try isolatedQueue { queue in
            try raw.save(paths: queue.paths)
            try check(SourcesConfig.load(paths: queue.paths) == config)
            let file = queue.paths.root.appendingPathComponent("sources.json"), before = try Data(contentsOf: file)
            var invalid = config; invalid.instagram = .init(username: "fixture.one,fixture.two", threadId: "123")
            try rejects { try invalid.save(paths: queue.paths) }
            try check(Data(contentsOf: file) == before)
            try check((FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }),
    ("Comma-separated selections reject partial, empty, excessive and ambiguous pairs", {
        for invalid in ["fixture@example.test,", ",fixture@example.test", "fixture@example.test,,other@example.test", "fixture@example.test, invalid"] {
            try rejects { _ = try SourcesConfig(messages: .init(handle: invalid)).validated() }
        }
        for invalid in ["Fixture One,", ",Fixture One", "Fixture One,,Fixture Two", "Fixture One,Fixture\nTwo"] {
            try rejects { _ = try SourcesConfig(kakao: .init(name: invalid)).validated() }
        }
        for pair in [("fixture.one,fixture.two", "123"), ("fixture.one", "123,456"),
                     ("fixture.one,", "123,456"), ("fixture.one,,fixture.two", "123,456,789"),
                     ("fixture.one,fixture.two", "123,123"), ("fixture.one,fixture.two", "123,１２３"),
                     ("fixture.one,bad user", "123,456"), ("fixture.one,fixture.two", "123,not-numeric")] {
            try rejects { _ = try SourcesConfig(instagram: .init(username: pair.0, threadId: pair.1)).validated() }
        }
        let many = (0..<100).map { "fixture\($0)" }.joined(separator: ",")
        let threads = (1...100).map(String.init).joined(separator: ",")
        let maximum = try SourcesConfig(kakao: .init(name: many), messages: .init(handle: (0..<100).map { "fixture\($0)@example.test" }.joined(separator: ",")),
            instagram: .init(username: many, threadId: threads)).validated()
        try check(maximum.instagramSelections.count == 100 && maximum.messageHandles.count == 100 && maximum.kakaoNames.count == 100)
        try rejects { _ = try SourcesConfig(kakao: .init(name: many + ",another")).validated() }
        try rejects { _ = try SourcesConfig(messages: .init(handle: maximum.messages!.handle + ",another@example.test")).validated() }
        try rejects { _ = try SourcesConfig(instagram: .init(username: many + ",another", threadId: threads + ",101")).validated() }
        let blank = try SourcesConfig(kakao: .init(name: " "), messages: .init(handle: " "), instagram: .init(username: " ", threadId: " ")).validated()
        try check(blank.kakaoNames.isEmpty && blank.messageHandles.isEmpty && blank.instagramSelections.isEmpty && blank.instagram != nil)
    }),
    ("Messages routing selects the matching contact from a list without mixing conversations", {
        let config = try SourcesConfig(messages: .init(handle: "first@example.test,second@example.test,010-1234-5678")).validated()
        for handle in config.messageHandles {
            let message = PetEvent(eventId: "multi-routing", sender: "messages.contact", text: "synthetic",
                threadUrl: ConversationKey.local(.messages, identifier: handle).key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
            try check(message.destination(messagesHandle: config.messages?.handle) == .messages(URL(string: "sms:" + handle)!))
            try check(message.destination(messagesHandle: "different@example.test") == nil)
        }
        let outsider = PetEvent(eventId: "multi-outsider", sender: "messages.contact", text: "synthetic",
            threadUrl: ConversationKey.local(.messages, identifier: "outside@example.test").key,
            observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
        try check(outsider.destination(messagesHandle: config.messages?.handle) == nil)
        try check(outsider.destination(messagesHandle: "first@example.test,,outside@example.test") == nil)
    }),
    ("App Instagram selection validates a numeric thread and distinguishes manual from disabled", {
        try check(SourcesConfig().instagram == nil)
        let explicitNull = try JSONDecoder().decode(SourcesConfig.self, from: Data("{\"instagram\":null}".utf8)).validated()
        try check(explicitNull.instagram == nil)
        let selected = try SourcesConfig(instagram: .init(username: " @Fixture.Friend ", threadId: " 123456 ")).validated()
        try check(selected.instagram == .init(username: "fixture.friend", threadId: "123456"))
        let disabled = try SourcesConfig(kakao: .init(name: "  "), messages: .init(handle: " "),
                                        instagram: .init(username: " ", threadId: " ")).validated()
        try check(disabled.kakao == nil && disabled.messages == nil && disabled.instagram == .init(username: "", threadId: ""))
        for pair in [("fixture.friend", ""), ("", "123"), ("@", ""), ("fixture friend", "123"),
                     (String(repeating: "x", count: 31), "123"), ("fixture.friend", "12x"),
                     ("fixture.friend", String(repeating: "1", count: 129)), ("fixture.friend", "１２３"),
                     ("fixture.friend", "https://www.instagram.com/direct/t/123/")] {
            try rejects { _ = try SourcesConfig(instagram: .init(username: pair.0, threadId: pair.1)).validated() }
        }
        _ = try SourcesConfig(instagram: .init(username: String(repeating: "x", count: 30), threadId: String(repeating: "1", count: 128))).validated()
    }),
    ("App settings atomically save normalized private contacts and failed edits retain the previous bytes", {
        try isolatedQueue { queue in
            let config = SourcesConfig(kakao: .init(name: " Fixture Friend "), messages: .init(handle: "Fixture@Example.test"),
                                       instagram: .init(username: "@Fixture.Friend", threadId: "123"))
            try config.save(paths: queue.paths)
            try check(SourcesConfig.load(paths: queue.paths) == config.validated())
            let file = queue.paths.root.appendingPathComponent("sources.json")
            let original = try Data(contentsOf: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            var invalid = config; invalid.messages = .init(handle: "invalid contact")
            try rejects { try invalid.save(paths: queue.paths) }
            try check(Data(contentsOf: file) == original)
            var disabled = try SourcesConfig.load(paths: queue.paths)
            disabled.instagram = .init(username: "", threadId: "")
            try disabled.save(paths: queue.paths)
            let loaded = try SourcesConfig.load(paths: queue.paths)
            try check(loaded.kakao == config.validated().kakao && loaded.messages == config.validated().messages)
            try check(loaded.instagram == .init(username: "", threadId: ""))
            var manual = loaded; manual.instagram = nil
            try manual.save(paths: queue.paths)
            let manualWire = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            try check(manualWire["instagram"] == nil && SourcesConfig.load(paths: queue.paths).instagram == nil)
            try check(FileManager.default.contentsOfDirectory(atPath: queue.paths.root.path).filter { $0.hasPrefix(".sources-") }.isEmpty)
        }
    }),
    ("App settings refuse symlink roots and targets without modifying their destinations", {
        try isolatedQueue { queue in
            let destination = queue.paths.root.deletingLastPathComponent().appendingPathComponent("settings-canary-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let canary = Data("synthetic destination".utf8)
            try canary.write(to: destination)
            try queue.paths.prepare()
            let file = queue.paths.root.appendingPathComponent("sources.json")
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
            try rejects { try SourcesConfig().save(paths: queue.paths) }
            try rejects { _ = try SourcesConfig.load(paths: queue.paths) }
            try check(Data(contentsOf: destination) == canary)
        }
        try isolatedQueue { queue in
            try FileManager.default.createSymbolicLink(at: queue.paths.root, withDestinationURL: FileManager.default.temporaryDirectory)
            try rejects { try SourcesConfig().save(paths: queue.paths) }
            try rejects { _ = try SourcesConfig.load(paths: queue.paths) }
        }
        try isolatedQueue { queue in
            try queue.paths.prepare()
            let file = queue.paths.root.appendingPathComponent("sources.json")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            try rejects { try SourcesConfig().save(paths: queue.paths) }
        }
    }),
    ("Local contact config, Korean phone equivalence and safe per-source routing", {
        let local = "010-1234-5678", international = "+821012345678"
        try check(SourcesConfig.normalizeHandle(local) == international)
        try check(SourcesConfig.normalizeHandle("0082 10 1234 5678") == international)
        try check(SourcesConfig.normalizeHandle(" Fixture@Example.test ") == "fixture@example.test")
        for bad in ["", "abc", "sms:+123456789", "+1?body=bad", "++123456789"] { try check(SourcesConfig.normalizeHandle(bad) == nil) }
        let key = ConversationKey.local(.messages, identifier: international)
        let message = PetEvent(eventId: "routing", sender: "messages.contact", text: "synthetic", threadUrl: key.key,
            observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages)
        try check(message.destination(messagesHandle: local) == .messages(URL(string: "sms:" + international)!))
        try check(message.destination() == nil)
        try check(message.destination(messagesHandle: "fixture@example.test") == nil)
        try check(event().destination() == .instagram(URL(string: event().threadUrl)!))
        let kakao = PetEvent(eventId: "routing", sender: "kakao.contact", text: "synthetic",
            threadUrl: ConversationKey.local(.kakao, identifier: "Fixture Friend").key,
            observedAt: PetEvent.timestamp(), kind: "inbox-preview", source: .kakao)
        try check(kakao.destination() == .kakao)
        try isolatedQueue { queue in
            try check(SourcesConfig.load(paths: queue.paths) == SourcesConfig())
            try queue.paths.prepare()
            let config = SourcesConfig(kakao: .init(name: " Fixture Friend "), messages: .init(handle: local))
            let file = queue.paths.root.appendingPathComponent("sources.json")
            try JSONEncoder().encode(config).write(to: file)
            let loaded = try SourcesConfig.load(paths: queue.paths)
            try check(loaded.kakao?.name == "Fixture Friend" && loaded.messages?.handle == international)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
            try rejects { _ = try SourcesConfig.load(paths: queue.paths) }
        }
    }),
    ("Source decoding remains compatible and validates each conversation namespace", {
        let original = event("legacy")
        var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        wire.removeValue(forKey: "source")
        let decoded = try JSONDecoder().decode(PetEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        try check(decoded == original && decoded.source == .instagram)
        for source in [PetSource.kakao, .messages] {
            let key = ConversationKey.local(source, identifier: "fixture-contact")
            let local = PetEvent(eventId: "local", sender: "fixture.contact", text: "synthetic", threadUrl: key.key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: source)
            try local.validate()
            try check(try JSONDecoder().decode(PetEvent.self, from: JSONEncoder().encode(local)) == local)
            for bad in [original.threadUrl, "https://evil.test/", source.rawValue + ":fixture-contact", key.key + "\n"] {
                try rejects { try PetEvent(eventId: "bad", sender: "fixture.contact", text: "synthetic", threadUrl: bad,
                    observedAt: PetEvent.timestamp(), kind: "thread-message", source: source).validate() }
            }
            try rejects { try event(url: key.key).validate() }
        }
        wire["source"] = "unknown"
        try rejects { _ = try JSONDecoder().decode(PetEvent.self, from: JSONSerialization.data(withJSONObject: wire)) }
    }),
    ("Read marks and receipts isolate sources and conversations, including legacy marks", {
        try isolatedQueue { queue in
            let now = Date(), old = now.addingTimeInterval(-10)
            let keys = [event().conversation, ConversationKey.local(.kakao, identifier: "fixture-one"),
                        ConversationKey.local(.messages, identifier: "fixture-one"), ConversationKey.local(.messages, identifier: "fixture-two")]
            for (index, key) in keys.enumerated() {
                try queue.enqueue(PetEvent(eventId: index == 3 ? "another-message" : "shared-id", sender: "fixture.contact", text: "synthetic",
                    threadUrl: key.key, observedAt: PetEvent.timestamp(old), kind: "thread-message", source: key.source))
            }
            try check(queue.count() == 4, "source identities collided")
            try queue.markRead(keys[1], at: now)
            try queue.markRead(keys[1], at: old.addingTimeInterval(-1))
            try check(queue.pending().count == 3)
            let marks = try queue.reads()
            try check(abs(marks[keys[1]]!.timeIntervalSince(now)) < 0.002, "late read moved watermark backwards")
            try check(keys[1].isRead(observedAt: PetEvent.timestamp(old), in: marks))
            for key in [keys[0], keys[2], keys[3]] { try check(!key.isRead(observedAt: PetEvent.timestamp(old), in: marks)) }
            try check(!keys[1].isRead(observedAt: PetEvent.timestamp(now.addingTimeInterval(1)), in: marks))
            let legacy = try JSONSerialization.data(withJSONObject: ["threadUrl": keys[0].key, "readAt": PetEvent.timestamp(now)])
            try legacy.write(to: queue.paths.reads.appendingPathComponent("legacy.json"))
            try check(queue.reads()[keys[0]] != nil)
            try rejects { try queue.markRead(ConversationKey(source: .kakao, key: keys[0].key)) }
        }
        try isolatedQueue { queue in
            try queue.enqueue(event("messages:fixture"))
            let key = ConversationKey.local(.messages, identifier: "fixture-contact")
            try queue.enqueue(PetEvent(eventId: "fixture", sender: "messages.contact", text: "synthetic", threadUrl: key.key,
                observedAt: PetEvent.timestamp(), kind: "thread-message", source: .messages))
            try check(queue.count() == 2, "Chrome event ID collided with local receipt")
        }
    }),
    ("read marks drop that thread's earlier pending messages only", {
        try isolatedQueue { queue in
            let other = "https://www.instagram.com/direct/t/999/"
            try queue.enqueue(event("old", at: Date().addingTimeInterval(-60)))
            try queue.enqueue(event("other", url: other, at: Date().addingTimeInterval(-60)))
            try queue.markRead(threadUrl: "https://www.instagram.com/direct/t/123/")
            try queue.enqueue(event("new", at: Date().addingTimeInterval(1)))
            try check(Set(try queue.pending().map(\.eventId)) == ["other", "new"], "read thread kept old message")
            try check(try queue.reads()[event().conversation] != nil, "read mark missing")
            try rejects { try queue.markRead(threadUrl: "https://evil.test/direct/t/1/") }
        }
    }),
    ("URL, sender, text, event ID and timestamp validation", {
        try event().validate()
        try rejects { try event("bad-id\n").validate() }
        for url in ["http://www.instagram.com/direct/t/1/", "https://evil.test/direct/t/1/", "https://www.instagram.com.evil.test/direct/t/1/", "https://www.instagram.com/direct/t/1/?redirect=evil", "https://www.instagram.com/direct/t/../", "https://www.instagram.com/direct/t/123/\n"] {
            try rejects { try event(url: url).validate() }
        }
        for sender in ["Alice Smith", "@alice", "ALICE", "", String(repeating: "x", count: 31), "alice\n"] {
            try rejects { try event(sender: sender).validate() }
        }
        try rejects { try event(text: "  \n ").validate() }
        try rejects { try event(text: String(repeating: "한", count: 2001)).validate() }
        try rejects { try event(at: Date().addingTimeInterval(600)).validate() }
    }),
    ("Queue persists across reopen, deduplicates before and after consume", {
        try isolatedQueue { queue in
            let value = event("stable-event")
            try check(queue.enqueue(value))
            try check(!queue.enqueue(value))
            let reopened = EventQueue(paths: queue.paths)
            try check(reopened.pending() == [value])
            try reopened.consume(value)
            try check(queue.count() == 0)
            try check(!reopened.enqueue(value))
        }
    }),
    ("Identical text with distinct event IDs is delivered twice", {
        try isolatedQueue { queue in
            try queue.enqueue(event("one", text: "❤️"))
            try queue.enqueue(event("two", text: "❤️"))
            try check(queue.count() == 2)
        }
    }),
    ("Capacity, clear and private directory/file permissions", {
        try isolatedQueue { queue in
            for index in 0..<EventQueue.capacity { try queue.enqueue(event("id-\(index)")) }
            try rejects { try queue.enqueue(event("overflow")) }
            let permissions = try FileManager.default.attributesOfItem(atPath: queue.paths.inbox.path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o700)
            let first = try FileManager.default.contentsOfDirectory(at: queue.paths.inbox, includingPropertiesForKeys: nil).first!
            let filePermissions = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
            try check(filePermissions?.intValue == 0o600)
            try queue.clear()
            try check(queue.count() == 0)
        }
    }),
    ("Expired and corrupt queue files are discarded", {
        try isolatedQueue { queue in
            try queue.paths.prepare()
            let expired = event("expired", at: Date().addingTimeInterval(-90_000))
            try rejects { try queue.enqueue(expired) }
            try JSONEncoder().encode(expired).write(to: queue.paths.inbox.appendingPathComponent("old.json"))
            try Data("broken".utf8).write(to: queue.paths.inbox.appendingPathComponent("broken.json"))
            try check(queue.pending().isEmpty)
            try check(queue.count() == 0)
        }
    }),
    ("Symlink data directories are refused", {
        try isolatedQueue { queue in
            try FileManager.default.createSymbolicLink(at: queue.paths.root, withDestinationURL: FileManager.default.temporaryDirectory)
            try rejects { try queue.paths.prepare() }
        }
    }),
    ("Queue ordering compares ISO8601 instants across UTC offsets", {
        try isolatedQueue { queue in
            // Both observations must be fresh; use a fixed offset rendering of now minus 1 second.
            let olderDate = Date().addingTimeInterval(-1)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
            let older = PetEvent(eventId: "older", sender: "alice", text: "older", threadUrl: "https://www.instagram.com/direct/t/123/", observedAt: formatter.string(from: olderDate), kind: "thread-message")
            let newer = event("newer")
            try queue.enqueue(newer); try queue.enqueue(older)
            try check(queue.pending().map(\.eventId) == ["older", "newer"])
        }
    }),
    ("Native framing roundtrip, UTF8, EOF, oversized and truncated inputs", {
        let pipe = Pipe()
        let payload = Data("{\"text\":\"안녕 🐱\"}".utf8)
        try NativeFrame.write(payload, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        try check(NativeFrame.read(from: pipe.fileHandleForReading) == payload)
        try check(NativeFrame.read(from: pipe.fileHandleForReading) == nil)
        for bytes in [Data([1, 2]), Data([0, 0, 0, 0]), Data([255, 255, 255, 127]), Data([8, 0, 0, 0, 123])] {
            let malformed = Pipe()
            try malformed.fileHandleForWriting.write(contentsOf: bytes)
            try malformed.fileHandleForWriting.close()
            try rejects { _ = try NativeFrame.read(from: malformed.fileHandleForReading) }
        }
    })
]

var failures = 0
for (name, run) in checks {
    do { try run(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(checks.count - failures)/\(checks.count) PetCore check groups passed")
exit(failures == 0 ? 0 : 1)
