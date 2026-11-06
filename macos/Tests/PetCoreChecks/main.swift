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
