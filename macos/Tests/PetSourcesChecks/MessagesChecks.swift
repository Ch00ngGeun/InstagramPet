import Foundation
import Darwin
import SQLite3
import PetCore
import PetSources

private final class MessagesFixture {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("chat.db") }
    var writer: OpaquePointer?
    let phone = "+821012345678"

    init(wal: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pet Messages Fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try open(wal: wal)
    }
    deinit {
        if let writer { sqlite3_close(writer) }
        try? FileManager.default.removeItem(at: directory)
    }
    func open(wal: Bool = false) throws {
        try sourceCheck(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, "fixture open")
        try execute("""
            CREATE TABLE message(text TEXT, attributedBody BLOB, is_from_me INTEGER, is_read INTEGER, date INTEGER, handle_id INTEGER);
            CREATE TABLE handle(id TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment(mime_type TEXT);
            CREATE TABLE message_attachment_join(message_id INTEGER, attachment_id INTEGER);
            INSERT INTO handle(ROWID,id) VALUES(1,'01012345678'),(2,'other@example.invalid'),(3,'+821012345678');
            INSERT INTO chat_handle_join(chat_id,handle_id) VALUES(1,1),(2,1),(2,2),(3,2),(4,3);
            """)
        if wal { try execute("PRAGMA journal_mode=WAL") }
    }
    func execute(_ sql: String) throws {
        try sourceCheck(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK, "fixture SQL")
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        try sourceCheck(sqlite3_prepare_v2(writer, sql, -1, &result, nil) == SQLITE_OK, "fixture prepare")
        guard let result else { throw SourceCheckFailure("fixture statement") }
        return result
    }
    @discardableResult func add(_ text: String? = nil, body: Data? = nil, at date: Date,
                               fromMe: Bool = false, read: Bool = false, handleID: Int = 1,
                               chatID: Int = 1, attachments: [String] = []) throws -> Int64 {
        let query = try prepare("INSERT INTO message(text,attributedBody,is_from_me,is_read,date,handle_id) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(query) }
        if let text { sqlite3_bind_text(query, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        if let body {
            _ = body.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        sqlite3_bind_int(query, 3, fromMe ? 1 : 0)
        sqlite3_bind_int(query, 4, read ? 1 : 0)
        sqlite3_bind_int64(query, 5, Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000))
        sqlite3_bind_int(query, 6, Int32(handleID))
        try sourceCheck(sqlite3_step(query) == SQLITE_DONE, "fixture insert")
        let id = sqlite3_last_insert_rowid(writer)
        try execute("INSERT INTO chat_message_join(chat_id,message_id) VALUES(\(chatID),\(id))")
        for mime in attachments {
            let insert = try prepare("INSERT INTO attachment(mime_type) VALUES(?)")
            sqlite3_bind_text(insert, 1, mime, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let code = sqlite3_step(insert)
            sqlite3_finalize(insert)
            try sourceCheck(code == SQLITE_DONE, "fixture attachment")
            let attachment = sqlite3_last_insert_rowid(writer)
            try execute("INSERT INTO message_attachment_join(message_id,attachment_id) VALUES(\(id),\(attachment))")
        }
        return id
    }
    func hydrate(_ id: Int64, body: Data) throws {
        let query = try prepare("UPDATE message SET attributedBody=? WHERE ROWID=?")
        defer { sqlite3_finalize(query) }
        _ = body.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_int64(query, 2, id)
        try sourceCheck(sqlite3_step(query) == SQLITE_DONE, "fixture hydrate")
    }
    func replace() throws {
        if let writer { sqlite3_close(writer) }; writer = nil
        try FileManager.default.moveItem(at: databaseURL, to: directory.appendingPathComponent("old.db"))
        try open()
    }
}

func messagesChecks() -> [(String, () throws -> Void)] {
    [
        ("Messages baseline, source-qualified retry outbox and identical repeated text", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            try f.add("old fixture", at: start.addingTimeInterval(-30))
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            try sourceCheck(reader.poll(now: start).events.isEmpty, "history replayed")
            try f.add("fixture hello", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(first.status == .observing && first.events.count == 1, "new incoming missing")
            let event = first.events[0]
            try sourceCheck(event.source == .messages && event.text == "fixture hello")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [event.identity], "outbox did not retry")
            reader.acknowledge([event.identity])
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
            try f.add("fixture hello", at: start.addingTimeInterval(3.1))
            let repeated = reader.poll(now: start.addingTimeInterval(4)).events
            try sourceCheck(repeated.count == 1 && repeated[0].identity != event.identity, "repeat collapsed")
        }),
        ("Messages rejects outgoing, other handles, groups, already-read and imported stale rows", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: "01012345678", databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let sent = start.addingTimeInterval(0.1)
            try f.add("outgoing", at: sent, fromMe: true)
            try f.add("another contact", at: sent, handleID: 2, chatID: 3)
            try f.add("group", at: sent, chatID: 2)
            try f.add("read before poll", at: sent, read: true)
            try f.add("imported history", at: start.addingTimeInterval(-3600))
            try f.add("international variant", at: sent, handleID: 3, chatID: 4)
            let result = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(result.events.map(\.text) == ["international variant"], "source filtering")
        }),
        ("Messages excludes tapback additions and removals while allowing ordinary null and zero types", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-60)
            try f.execute("ALTER TABLE message ADD COLUMN associated_message_type INTEGER")
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.add("ordinary null type", at: start.addingTimeInterval(0.1))
            let plain = try f.add("ordinary zero type", at: start.addingTimeInterval(0.2))
            let reaction = try f.add("synthetic reaction", at: start.addingTimeInterval(0.3))
            let removal = try f.add("synthetic reaction removal", at: start.addingTimeInterval(0.4))
            try f.execute("UPDATE message SET associated_message_type=0 WHERE ROWID=\(plain); UPDATE message SET associated_message_type=2000 WHERE ROWID=\(reaction); UPDATE message SET associated_message_type=3000 WHERE ROWID=\(removal)")
            let received = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(received.map(\.text) == ["ordinary null type", "ordinary zero type"], "tapback became a message")
            reader.acknowledge(Set(received.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(40)).events.isEmpty, "tapback became a delayed fallback")
        }),
        ("Messages removed watched rows stop blocking reads and leave no retry outbox entry", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-10)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let removed = try f.add("synthetic removed message", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events[0]
            let read = try f.add("synthetic read message", at: start.addingTimeInterval(1.1))
            let second = reader.poll(now: start.addingTimeInterval(2)).events.last!
            try f.add("synthetic still unread", at: start.addingTimeInterval(2.1))
            let third = reader.poll(now: start.addingTimeInterval(3)).events.last!
            try f.execute("DELETE FROM message WHERE ROWID=\(removed); UPDATE message SET is_read=1 WHERE ROWID=\(read)")
            let result = reader.poll(now: start.addingTimeInterval(4))
            let key = ConversationKey.local(.messages, identifier: f.phone)
            try sourceCheck(key.isRead(observedAt: first.observedAt, in: result.reads), "deleted row blocked the read watermark")
            try sourceCheck(key.isRead(observedAt: second.observedAt, in: result.reads), "later read row remained blocked")
            try sourceCheck(!key.isRead(observedAt: third.observedAt, in: result.reads), "newer unread row was cleared")
            try sourceCheck(result.events.map(\.identity) == [third.identity], "deleted row remained in the retry outbox")
        }),
        ("Messages deletion-only read resolution waits for older unread rows and survives cursor regression", {
            for hasOlderUnread in [false, true] {
                let f = try MessagesFixture(), start = Date().addingTimeInterval(-10)
                let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
                _ = reader.poll(now: start)
                var older: Int64?
                if hasOlderUnread {
                    older = try f.add("synthetic older unread", at: start.addingTimeInterval(0.1))
                    _ = reader.poll(now: start.addingTimeInterval(1))
                }
                let removed = try f.add("synthetic deleted newest row", at: start.addingTimeInterval(1.1))
                let event = reader.poll(now: start.addingTimeInterval(2)).events.last!
                try f.execute("DELETE FROM message WHERE ROWID=\(removed)")
                let deleted = reader.poll(now: start.addingTimeInterval(3))
                if let older {
                    try sourceCheck(deleted.reads.isEmpty, "deletion cleared an older unread message")
                    try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(older)")
                }
                let resolved = reader.poll(now: start.addingTimeInterval(4))
                try sourceCheck(event.conversation.isRead(observedAt: event.observedAt, in: resolved.reads), "deleted newest row never advanced reads")
                try sourceCheck(resolved.events.isEmpty, "deleted newest row remained queued")
            }
        }),
        ("Messages waiting bodies survive deletion of a later highest ROWID", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-60)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.add(at: start.addingTimeInterval(0.1))
            _ = reader.poll(now: start.addingTimeInterval(1))
            let later = try f.add("synthetic later deleted row", at: start.addingTimeInterval(1.1))
            let received = reader.poll(now: start.addingTimeInterval(2)).events
            reader.acknowledge(Set(received.map(\.identity)))
            try f.execute("DELETE FROM message WHERE ROWID=\(later)")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).reads.isEmpty, "deletion erased a pending earlier body")
            let fallback = reader.poll(now: start.addingTimeInterval(31.1)).events
            try sourceCheck(fallback.map(\.text) == ["(메시지)"], "cursor regression discarded the waiting body")
        }),
        ("Messages missing and undecodable bodies fall back after thirty seconds with stable retries", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-60)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let missing = try f.add(at: start.addingTimeInterval(0.1))
            let corrupt = try f.add(body: Data("synthetic invalid archive".utf8), at: start.addingTimeInterval(0.2))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(30.9)).events.isEmpty, "body fallback was premature")
            let fallback = reader.poll(now: start.addingTimeInterval(31.1)).events
            try sourceCheck(fallback.count == 2 && fallback.allSatisfy { $0.text == "(메시지)" }, "unresolved body disappeared without a fallback")
            try sourceCheck(fallback.allSatisfy { abs(PetEvent.date($0.observedAt)!.timeIntervalSince(start.addingTimeInterval(1))) < 0.002 }, "fallback lost first observation")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(32)).events.map(\.identity) == fallback.map(\.identity), "fallback retry identity changed")
            reader.acknowledge(Set(fallback.map(\.identity)))
            try f.hydrate(missing, body: NSArchiver.archivedData(withRootObject: NSAttributedString(string: "synthetic late hydration")))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(33)).events.isEmpty, "late hydration replayed a fallback")
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID IN (\(missing),\(corrupt))")
            let read = reader.poll(now: start.addingTimeInterval(34)).reads
            try sourceCheck(fallback.allSatisfy { $0.conversation.isRead(observedAt: $0.observedAt, in: read) }, "fallback lost read tracking")
        }),
        ("Messages queued body fallbacks restore read tracking after restart and late hydration", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-60)
            let queue = EventQueue(paths: PetPaths(root: f.directory.appendingPathComponent("queue")))
            let original = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = original.poll(now: start)
            let id = try f.add(at: start.addingTimeInterval(0.1))
            _ = original.poll(now: start.addingTimeInterval(1))
            let fallback = original.poll(now: start.addingTimeInterval(32)).events
            try sourceCheck(fallback.count == 1 && fallback[0].text == "(메시지)", "fallback missing before restart")
            try queue.enqueue(fallback[0])
            original.acknowledge([fallback[0].identity])
            try f.hydrate(id, body: NSArchiver.archivedData(withRootObject: NSAttributedString(string: "synthetic hydrated after fallback")))
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(id)")
            let restarted = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            restarted.restorePending(try queue.pending())
            let result = restarted.poll(now: start.addingTimeInterval(33))
            for (key, at) in result.reads { try queue.markRead(key, at: at) }
            try sourceCheck(result.events.isEmpty && (try queue.count()) == 0, "queued fallback was not reconnected to its original row")
        }),
        ("Messages decodes bounded text, secure keyed and legacy typedstream bodies", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let values = ["Fixture 한글 🐱\n둘째 줄", String(repeating: "한", count: 200), String(repeating: "x", count: 127), String(repeating: "y", count: 128), String(repeating: "z", count: 40_000)]
            for value in values {
                let data = NSArchiver.archivedData(withRootObject: NSMutableAttributedString(string: value))
                try f.add(body: data, at: start.addingTimeInterval(0.1))
            }
            let keyed = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "secure keyed fixture"), requiringSecureCoding: true)
            try f.add(body: keyed, at: start.addingTimeInterval(0.1))
            try f.add("explicit text wins", body: keyed, at: start.addingTimeInterval(0.1))
            let result = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(result.events.map(\.text) == values.map { String($0.prefix(2000)) } + ["secure keyed fixture", "explicit text wins"], "body decode or row ordering")
            try sourceCheck(result.events.allSatisfy { $0.text.count <= 2000 })
        }),
        ("Messages malformed typedstream never exposes archive metadata as body", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let good = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "fixture"))
            guard let marker = good.range(of: Data([0x84,1,0x2b])) else { throw SourceCheckFailure("synthetic archive layout") }
            var invalidUTF8 = good; invalidUTF8[marker.upperBound + 1] = 0xff
            var wrongTerminator = good; wrongTerminator[marker.upperBound + 1 + 7] = 0
            var oversized = good; oversized[marker.upperBound] = 0x82
            let payloads = [Data("not an archive NSString fixture".utf8), Data(good.prefix(marker.upperBound)), invalidUTF8, wrongTerminator, oversized,
                            Data(repeating: 0x41, count: 65_537)]
            for body in payloads { try f.add(body: body, at: start.addingTimeInterval(0.1)) }
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty, "corrupt archive displayed")
        }),
        ("Messages attachment MIME placeholders and delayed body hydration", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.add("\u{FFFC}", at: start.addingTimeInterval(0.1), attachments: ["image/jpeg"])
            try f.add(at: start.addingTimeInterval(0.1), attachments: ["video/mp4"])
            try f.add(at: start.addingTimeInterval(0.1), attachments: ["application/pdf"])
            let waiting = try f.add(at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(first.events.map(\.text) == ["(이미지)", "(동영상)", "(첨부)"], "attachment placeholders")
            reader.acknowledge(Set(first.events.map(\.identity)))
            try f.hydrate(waiting, body: NSArchiver.archivedData(withRootObject: NSAttributedString(string: "hydrated fixture")))
            let hydrated = reader.poll(now: start.addingTimeInterval(2)).events
            try sourceCheck(hydrated.map(\.text) == ["hydrated fixture"], "hydration missed")
            try sourceCheck(abs((hydrated.first.flatMap { PetEvent.date($0.observedAt) } ?? .distantPast).timeIntervalSince(start.addingTimeInterval(1))) < 0.002, "hydration lost first observation")
        }),
        ("Messages read watermark preserves newer unread bubbles and survives outbox acknowledgements", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let old = try f.add("older unread", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            reader.acknowledge(Set(first.map(\.identity)))
            let newer = try f.add("newer unread", at: start.addingTimeInterval(1.1))
            let second = reader.poll(now: start.addingTimeInterval(2)).events
            reader.acknowledge(Set(second.map(\.identity)))
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(newer)")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).reads.isEmpty, "later read erased earlier unread")
            try f.execute("UPDATE message SET is_read=0 WHERE ROWID=\(newer); UPDATE message SET is_read=1 WHERE ROWID=\(old)")
            let partial = reader.poll(now: start.addingTimeInterval(4)).reads
            let key = ConversationKey.local(.messages, identifier: f.phone)
            try sourceCheck(key.isRead(observedAt: first[0].observedAt, in: partial))
            try sourceCheck(!key.isRead(observedAt: second[0].observedAt, in: partial), "new unread erased")
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(newer)")
            let all = reader.poll(now: start.addingTimeInterval(5)).reads
            try sourceCheck(key.isRead(observedAt: second[0].observedAt, in: all))
            try sourceCheck(all.keys.allSatisfy { $0.source == .messages })
        }),
        ("Messages restart restores queued read tracking without replaying database history", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-10)
            let queue = EventQueue(paths: PetPaths(root: f.directory.appendingPathComponent("queue")))
            let original = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = original.poll(now: start)
            let older = try f.add("queued before restart", at: start.addingTimeInterval(0.1))
            let first = original.poll(now: start.addingTimeInterval(1)).events
            for event in first { try queue.enqueue(event) }
            original.acknowledge(Set(first.map(\.identity)))
            let newer = try f.add("still unread after restart", at: start.addingTimeInterval(1.1))
            let second = original.poll(now: start.addingTimeInterval(2)).events
            for event in second { try queue.enqueue(event) }
            try sourceCheck(first.count == 1 && second.count == 1)
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(older)")
            try f.add("history received while pet was stopped", at: start.addingTimeInterval(2.1))

            let restarted = MessagesReader(handle: "010-1234-5678", databaseURL: f.databaseURL)
            restarted.restorePending(try queue.pending())
            let baseline = restarted.poll(now: start.addingTimeInterval(3))
            try sourceCheck(baseline.events.isEmpty, "restart replayed history")
            for (key, at) in baseline.reads { try queue.markRead(key, at: at) }
            try sourceCheck(try queue.pending().map(\.identity) == second.map(\.identity), "restart failed to clear only the read queued row")
            restarted.restorePending(try queue.pending())
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(newer)")
            let read = restarted.poll(now: start.addingTimeInterval(4))
            for (key, at) in read.reads { try queue.markRead(key, at: at) }
            try sourceCheck(try queue.count() == 0, "restored unread row lost future read tracking")
            try f.add("fresh after restart", at: start.addingTimeInterval(4.1))
            try sourceCheck(restarted.poll(now: start.addingTimeInterval(5)).events.map(\.text) == ["fresh after restart"])
        }),
        ("Messages restoration rejects another handle, groups and reused ROWIDs in a replacement database", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let original = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = original.poll(now: start)
            let sent = start.addingTimeInterval(0.1)
            let id = try f.add("row provenance fixture", at: sent)
            let queued = original.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(queued.count == 1)
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(id)")
            let anotherHandle = MessagesReader(handle: "other@example.invalid", databaseURL: f.databaseURL)
            anotherHandle.restorePending(queued)
            try sourceCheck(anotherHandle.poll(now: start.addingTimeInterval(2)).reads.isEmpty, "another conversation restored")
            let event = queued[0]
            let forged = PetEvent(eventId: event.eventId, sender: event.sender, text: event.text,
                threadUrl: ConversationKey.local(.messages, identifier: "other@example.invalid").key,
                observedAt: event.observedAt, kind: event.kind, source: .messages)
            anotherHandle.restorePending([forged])
            try sourceCheck(anotherHandle.poll(now: start.addingTimeInterval(2)).reads.isEmpty, "row handle was not verified")

            try f.execute("UPDATE chat_message_join SET chat_id=2 WHERE message_id=\(id)")
            let grouped = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            grouped.restorePending(queued)
            try sourceCheck(grouped.poll(now: start.addingTimeInterval(2)).reads.isEmpty, "group row restored")
            try f.replace()
            try sourceCheck(try f.add("row provenance fixture", at: sent, read: true) == id, "fixture did not reuse ROWID")
            let replacement = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            replacement.restorePending(queued)
            let result = replacement.poll(now: start.addingTimeInterval(3))
            try sourceCheck(result.reads.isEmpty && result.events.isEmpty, "replacement ROWID marked an unrelated queued event read")
        }),
        ("Messages unresolved unread body blocks a later read watermark until hydration", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let waiting = try f.add(at: start.addingTimeInterval(0.1))
            _ = reader.poll(now: start.addingTimeInterval(1))
            let later = try f.add("later decoded", at: start.addingTimeInterval(1.1))
            let decoded = reader.poll(now: start.addingTimeInterval(2)).events
            reader.acknowledge(Set(decoded.map(\.identity)))
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(later)")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).reads.isEmpty, "unresolved unread was marked read")
            try f.hydrate(waiting, body: NSArchiver.archivedData(withRootObject: NSAttributedString(string: "late hydration")))
            let hydrated = reader.poll(now: start.addingTimeInterval(4))
            try sourceCheck(hydrated.events.map(\.text) == ["late hydration"] && hydrated.reads.isEmpty)
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(waiting)")
            try sourceCheck(!reader.poll(now: start.addingTimeInterval(5)).reads.isEmpty)
        }),
        ("Messages keeps same-millisecond unread observations beyond an older read", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let observed = PetEvent.date(PetEvent.timestamp(start.addingTimeInterval(1)))!
            let old = try f.add("first in millisecond", at: start.addingTimeInterval(0.1))
            _ = reader.poll(now: observed.addingTimeInterval(0.0001))
            try f.add("second in millisecond", at: start.addingTimeInterval(0.2))
            _ = reader.poll(now: observed.addingTimeInterval(0.0002))
            try f.execute("UPDATE message SET is_read=1 WHERE ROWID=\(old)")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).reads.isEmpty, "timestamp rounding erased same-millisecond unread")
        }),
        ("Messages RO polling observes a live WAL writer and does not create missing databases", {
            let f = try MessagesFixture(wal: true), start = Date().addingTimeInterval(-5)
            try f.add("WAL baseline history", at: start.addingTimeInterval(-30))
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            try sourceCheck(reader.poll(now: start).status == .observing, "WAL baseline unavailable")
            try f.add("live WAL fixture", at: start.addingTimeInterval(0.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.map(\.text) == ["live WAL fixture"], "live WAL write missed")
            let missing = f.directory.appendingPathComponent("does-not-exist.db")
            let absent = MessagesReader(handle: f.phone, databaseURL: missing)
            try sourceCheck(absent.poll(now: start).status == .unavailable)
            try sourceCheck(!FileManager.default.fileExists(atPath: missing.path), "RO reader created database")
            let disabled = MessagesReader(handle: nil, databaseURL: missing)
            try sourceCheck(disabled.poll(now: start).status == .disabled)
        }),
        ("Messages replacement and permission recovery rebaseline without replaying history", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            try f.add("initial history", at: start.addingTimeInterval(-10))
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.replace()
            try f.add("replacement history", at: start.addingTimeInterval(0.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty, "replacement history replayed")
            try sourceCheck(chmod(f.databaseURL.path, 0) == 0)
            defer { _ = chmod(f.databaseURL.path, 0o600) }
            let denied = reader.poll(now: start.addingTimeInterval(2))
            try sourceCheck(denied.status == .permissionRequired, "permission status")
            try sourceCheck(chmod(f.databaseURL.path, 0o600) == 0)
            try f.add("permission-gap history", at: start.addingTimeInterval(2.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty, "permission-gap history replayed")
            try f.add("after recovery", at: start.addingTimeInterval(3.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.map(\.text) == ["after recovery"])
        }),
        ("Messages retained outbox remains bounded across database replacement", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            for _ in 0..<200 { try f.add("before replacement", at: start.addingTimeInterval(0.1)) }
            let old = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(old.count == 200)
            try f.replace()
            _ = reader.poll(now: start.addingTimeInterval(2))
            for _ in 0..<200 { try f.add("after replacement", at: start.addingTimeInterval(2.1)) }
            let held = reader.poll(now: start.addingTimeInterval(3)).events
            try sourceCheck(held.count == 200 && held.allSatisfy { $0.text == "before replacement" }, "outbox exceeded bound")
            reader.acknowledge(Set(old.map(\.identity)))
            let resumed = reader.poll(now: start.addingTimeInterval(4)).events
            try sourceCheck(resumed.count == 200 && resumed.allSatisfy { $0.text == "after replacement" }, "bounded backlog did not resume")
        }),
        ("Messages transient exclusive lock preserves its cursor and retries after commit", {
            let f = try MessagesFixture(), start = Date().addingTimeInterval(-5)
            let reader = MessagesReader(handle: f.phone, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.execute("BEGIN EXCLUSIVE")
            try f.add("after lock", at: start.addingTimeInterval(0.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).status == .unavailable, "locked DB status")
            try f.execute("COMMIT")
            let before = try Data(contentsOf: f.databaseURL)
            let result = reader.poll(now: start.addingTimeInterval(2))
            try sourceCheck(result.events.map(\.text) == ["after lock"], "transient error lost newly committed row")
            try sourceCheck(try Data(contentsOf: f.databaseURL) == before, "reader modified database bytes")
        })
    ]
}
