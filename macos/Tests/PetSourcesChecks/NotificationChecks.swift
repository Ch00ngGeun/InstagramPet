import Foundation
import SQLite3
import PetCore
import PetSources

private final class NotificationFixture {
    let directory: URL
    var databaseURL: URL { directory.appendingPathComponent("notifications.db") }
    var writer: OpaquePointer?
    let name = "Fixture Friend"

    init(wal: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pet Notification Fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try open(wal: wal)
    }
    deinit { if let writer { sqlite3_close(writer) }; try? FileManager.default.removeItem(at: directory) }
    func open(wal: Bool = false) throws {
        try sourceCheck(sqlite3_open(databaseURL.path, &writer) == SQLITE_OK, "notification fixture open")
        try execute("""
            CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier VARCHAR,badge INTEGER);
            CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,data BLOB,request_date REAL,request_last_date REAL,delivered_date REAL,presented BOOL,style INTEGER,snooze_fire_date REAL);
            INSERT INTO app(app_id,identifier) VALUES(1,'com.kakao.KakaotalkMac'),(2,'com.example.Other');
            """)
        if wal { try execute("PRAGMA journal_mode=WAL") }
    }
    func execute(_ sql: String) throws { try sourceCheck(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK, "notification fixture SQL") }
    func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        try sourceCheck(sqlite3_prepare_v2(writer, sql, -1, &result, nil) == SQLITE_OK, "notification fixture prepare")
        guard let result else { throw SourceCheckFailure("notification fixture statement") }; return result
    }
    func payload(_ text: String, title: String? = nil, subtitle: Any? = nil, bundle: String = "com.kakao.KakaoTalkMac",
                 requestID: String? = "synthetic-request", metadata: Int? = nil) throws -> Data {
        var request: [String: Any] = ["titl": title ?? name + "💕", "body": text]
        if let requestID { request["iden"] = requestID }
        if let metadata { request["presentation-metadata"] = metadata }
        if let subtitle { request["subt"] = subtitle }
        return try PropertyListSerialization.data(fromPropertyList: ["app": bundle, "req": request], format: .binary, options: 0)
    }
    @discardableResult func add(_ text: String = "synthetic notification", at date: Date,
                               title: String? = nil, subtitle: Any? = nil, app: Int32 = 1,
                               bundle: String = "com.kakao.KakaoTalkMac", data: Data? = nil) throws -> Int64 {
        let query = try statement("INSERT INTO record(app_id,uuid,data,request_date,request_last_date,delivered_date,presented,style) VALUES(?,?,?,?,?,?,1,0)")
        defer { sqlite3_finalize(query) }
        let body = try data ?? payload(text, title: title, subtitle: subtitle, bundle: bundle)
        var uuid = UUID().uuid
        let bytes = withUnsafeBytes(of: &uuid) { Data($0) }
        sqlite3_bind_int(query, 1, app)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        _ = body.withUnsafeBytes { sqlite3_bind_blob(query, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        for index: Int32 in 4...6 { sqlite3_bind_double(query, index, date.timeIntervalSinceReferenceDate) }
        try sourceCheck(sqlite3_step(query) == SQLITE_DONE, "notification fixture insert")
        return sqlite3_last_insert_rowid(writer)
    }
    func revise(_ id: Int64, text: String, at date: Date, requestID: String? = "synthetic-request",
                requestedAt: Date? = nil, metadata: Int? = nil) throws {
        let query = try statement("UPDATE record SET data=?,request_last_date=?,delivered_date=?,request_date=COALESCE(?,request_date) WHERE rec_id=?")
        defer { sqlite3_finalize(query) }
        let body = try payload(text, requestID: requestID, metadata: metadata)
        _ = body.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_double(query, 2, date.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(query, 3, date.timeIntervalSinceReferenceDate)
        if let requestedAt { sqlite3_bind_double(query, 4, requestedAt.timeIntervalSinceReferenceDate) }
        else { sqlite3_bind_null(query, 4) }
        sqlite3_bind_int64(query, 5, id)
        try sourceCheck(sqlite3_step(query) == SQLITE_DONE, "notification fixture revise")
    }
    func replace() throws {
        if let writer { sqlite3_close(writer) }; writer = nil
        try FileManager.default.moveItem(at: databaseURL, to: directory.appendingPathComponent("previous.db"))
        try open()
    }
}

private final class NotificationStub: LocalSourceReader {
    let source = PetSource.kakao
    var events: [PetEvent] = []
    var reads: [ConversationKey: Date] = [:]
    var status = SourceStatus.observing
    var accepted = Set<String>()
    func poll(now: Date) -> SourcePoll { SourcePoll(events: events, reads: reads, status: status) }
    func acknowledge(_ identities: Set<String>) {
        accepted.formUnion(identities); events.removeAll { identities.contains($0.identity) }
    }
}

private func notificationEvent(_ id: String, text: String = "synthetic notification", at date: Date, kind: String = "thread-message") -> PetEvent {
    PetEvent(eventId: id, sender: "local.kakao", text: text,
        threadUrl: ConversationKey.local(.kakao, identifier: "Fixture Friend").key,
        observedAt: PetEvent.timestamp(date), kind: kind, source: .kakao)
}

func notificationChecks() -> [(String, () throws -> Void)] {
    [
        ("Kakao notifications baseline old records, preserve a burst and retry until acknowledgement", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            try f.add("old synthetic", at: start.addingTimeInterval(-20))
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            try sourceCheck(reader.poll(now: start).events.isEmpty)
            for index in 1...3 { try f.add("same synthetic text", at: start.addingTimeInterval(Double(index) * 0.1)) }
            let first = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(first.status == .observing && first.events.count == 3, "notification burst collapsed")
            try sourceCheck(Set(first.events.map(\.identity)).count == 3)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events == first.events, "notification retry changed identity")
            reader.acknowledge(Set(first.events.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
        }),
        ("Kakao notifications filter exact app and contact while refusing groups and masked generic titles", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let at = start.addingTimeInterval(0.1)
            try f.add("foreign database app", at: at, app: 2)
            try f.add("foreign payload app", at: at, bundle: "com.example.Other")
            try f.add("wrong contact", at: at, title: "Fixture Friendship")
            try f.add("group room", at: at, subtitle: "Synthetic Room")
            try f.add("hidden preview", at: at, title: "KakaoTalk")
            try f.add("", at: at)
            try f.add("supported synthetic", at: at, bundle: "COM.KAKAO.KAKAOTALKMAC")
            let result = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(result.events.map(\.text) == ["supported synthetic"])
        }),
        ("Kakao notification revisions detect changed bodies but ignore unchanged delivery rewrites", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let id = try f.add("prelaunch notification", at: start.addingTimeInterval(-20))
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.revise(id, text: "replacement synthetic", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.map(\.text) == ["replacement synthetic"])
            reader.acknowledge(Set(first.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty)
            try f.revise(id, text: "replacement synthetic", at: start.addingTimeInterval(2.1))
            let repeated = reader.poll(now: start.addingTimeInterval(3)).events
            try sourceCheck(repeated.isEmpty, "delivery revision replayed unchanged message content")
        }),
        ("Kakao notification presentation metadata changes never duplicate an accepted message", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let id = try f.add("synthetic unchanged message", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.count == 1)
            reader.acknowledge(Set(first.map(\.identity)))
            try f.revise(id, text: "synthetic unchanged message", at: start.addingTimeInterval(1.1), metadata: 1)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty, "raw plist metadata became another bubble")
            try f.revise(id, text: "synthetic unchanged message", at: start.addingTimeInterval(2.1), metadata: 2)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.isEmpty)
        }),
        ("Kakao repeated text with a new request identifier or request date remains distinct", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let id = try f.add("synthetic repeated message", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.count == 1)
            reader.acknowledge(Set(first.map(\.identity)))
            try f.revise(id, text: "synthetic repeated message", at: start.addingTimeInterval(1.1), requestID: "synthetic-request-2")
            let byID = reader.poll(now: start.addingTimeInterval(2)).events
            try sourceCheck(byID.count == 1 && byID[0].identity != first[0].identity, "new request identity was collapsed")
            reader.acknowledge(Set(byID.map(\.identity)))
            try f.revise(id, text: "synthetic repeated message", at: start.addingTimeInterval(2.1), requestID: "synthetic-request-2", requestedAt: start.addingTimeInterval(2.1))
            let byDate = reader.poll(now: start.addingTimeInterval(3)).events
            try sourceCheck(byDate.count == 1 && byDate[0].identity != byID[0].identity, "new original request date was collapsed")
        }),
        ("Kakao in-place A to B to A message changes each retain their own event identity", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let id = try f.add("synthetic A", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            reader.acknowledge(Set(first.map(\.identity)))
            try f.revise(id, text: "synthetic B", at: start.addingTimeInterval(1.1))
            let middle = reader.poll(now: start.addingTimeInterval(2)).events
            reader.acknowledge(Set(middle.map(\.identity)))
            try f.revise(id, text: "synthetic A", at: start.addingTimeInterval(2.1))
            let last = reader.poll(now: start.addingTimeInterval(3)).events
            try sourceCheck(first.count == 1 && middle.count == 1 && last.count == 1)
            try sourceCheck(Set((first + middle + last).map(\.identity)).count == 3, "returning content was mistaken for an old duplicate")
        }),
        ("Kakao distinct records with identical text stay distinct through metadata refreshes", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let firstID = try f.add("synthetic identical text", at: start.addingTimeInterval(0.1))
            let secondID = try f.add("synthetic identical text", at: start.addingTimeInterval(0.2))
            let delivered = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(delivered.count == 2 && Set(delivered.map(\.identity)).count == 2)
            reader.acknowledge(Set(delivered.map(\.identity)))
            try f.revise(firstID, text: "synthetic identical text", at: start.addingTimeInterval(1.1), metadata: 1)
            try f.revise(secondID, text: "synthetic identical text", at: start.addingTimeInterval(1.2), metadata: 2)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.isEmpty)
        }),
        ("Kakao canonical message state advances only after retry outbox capacity is available", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            let id = try f.add("synthetic capacity original", at: start.addingTimeInterval(0.001))
            for index in 2...200 { try f.add("synthetic capacity filler", at: start.addingTimeInterval(Double(index) * 0.001)) }
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.count == 200)
            try f.revise(id, text: "synthetic capacity changed", at: start.addingTimeInterval(1.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.count == 200)
            let original = first.first { $0.text == "synthetic capacity original" }!
            reader.acknowledge([original.identity])
            let retried = reader.poll(now: start.addingTimeInterval(3)).events
            try sourceCheck(retried.count == 200 && retried.contains { $0.text == "synthetic capacity changed" }, "rejected state change was remembered before durable acceptance")
            reader.acknowledge(Set(retried.map(\.identity)))
            try f.revise(id, text: "synthetic capacity changed", at: start.addingTimeInterval(3.1), metadata: 3)
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.isEmpty)
        }),
        ("Kakao notification revision watermark excludes another app's future timestamp", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let id = try f.add("prelaunch notification", at: start.addingTimeInterval(-20))
            try f.add("foreign future notification", at: start.addingTimeInterval(120), app: 2, bundle: "com.example.Other")
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            try sourceCheck(reader.poll(now: start).events.isEmpty)
            try f.revise(id, text: "replacement after foreign future timestamp", at: start.addingTimeInterval(0.1))
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.map(\.text) == ["replacement after foreign future timestamp"], "another app advanced the Kakao revision watermark")
            reader.acknowledge(Set(first.map(\.identity)))
            try f.revise(id, text: "another replacement", at: start.addingTimeInterval(1.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.map(\.text) == ["another replacement"])
        }),
        ("Kakao notifications observe live WAL writes without changing database bytes or creating missing files", {
            let f = try NotificationFixture(wal: true), start = Date().addingTimeInterval(-10)
            try f.add("old WAL baseline", at: start.addingTimeInterval(-20))
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            try sourceCheck(reader.poll(now: start).status == .observing, "310 WAL baseline did not open")
            try f.add("WAL synthetic", at: start.addingTimeInterval(0.1))
            let before = try Data(contentsOf: f.databaseURL)
            let update = reader.poll(now: start.addingTimeInterval(1))
            try sourceCheck(update.status == .observing, "311 WAL update status")
            try sourceCheck(update.events.map(\.text) == ["WAL synthetic"], "301 WAL update was not observed")
            try sourceCheck(try Data(contentsOf: f.databaseURL) == before, "302 source database bytes changed")
            let missing = f.directory.appendingPathComponent("does-not-exist.db")
            let absent = KakaoNotificationReader(name: f.name, databaseURL: missing)
            try sourceCheck(absent.poll(now: start).status == .unavailable, "303 missing database status")
            try sourceCheck(!FileManager.default.fileExists(atPath: missing.path), "304 missing source database was created")
        }),
        ("Kakao notification malformed payloads, oversized blobs and stale imported rows never deliver", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.add(at: start.addingTimeInterval(0.1), data: Data([0, 1, 2]))
            try f.add(at: start.addingTimeInterval(0.1), data: Data(repeating: 65, count: 65537))
            try f.add("imported synthetic", at: start.addingTimeInterval(-20))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(1)).events.isEmpty)
            try f.add(String(repeating: "한", count: 3000), at: start.addingTimeInterval(1.1))
            let long = reader.poll(now: start.addingTimeInterval(2)).events
            try sourceCheck(long.count == 1 && long[0].text.count == 2000, "long notification exceeded event bound")
        }),
        ("Kakao notification database replacement rebaselines while preserving its unaccepted outbox", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            try f.add("before replacement", at: start.addingTimeInterval(0.1))
            let queued = reader.poll(now: start.addingTimeInterval(1)).events
            try f.replace()
            try f.add("replacement history", at: start.addingTimeInterval(1.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events == queued)
            reader.acknowledge(Set(queued.map(\.identity)))
            try f.add("after replacement", at: start.addingTimeInterval(2.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).events.map(\.text) == ["after replacement"])
        }),
        ("Kakao notification capacity preserves the next event across acknowledgement and transient locking", {
            let f = try NotificationFixture(), start = Date().addingTimeInterval(-10)
            let reader = KakaoNotificationReader(name: f.name, databaseURL: f.databaseURL)
            _ = reader.poll(now: start)
            for index in 1...201 { try f.add("burst synthetic", at: start.addingTimeInterval(Double(index) * 0.001)) }
            let first = reader.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.count == 200)
            reader.acknowledge(Set(first.map(\.identity)))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(2)).events.count == 1)
            try f.execute("BEGIN EXCLUSIVE")
            try f.add("after lock", at: start.addingTimeInterval(2.1))
            try sourceCheck(reader.poll(now: start.addingTimeInterval(3)).status == .unavailable)
            try f.execute("COMMIT")
            try sourceCheck(reader.poll(now: start.addingTimeInterval(4)).events.contains { $0.text == "after lock" })
        }),
        ("Kakao combined notifications win over matching AX previews without collapsing repeated UUIDs", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            let first = notificationEvent("notification-1", at: start)
            let repeatText = notificationEvent("notification-2", at: start.addingTimeInterval(0.1))
            let preview = notificationEvent("ax-1", at: start.addingTimeInterval(0.2))
            notifications.events = [first, repeatText]; ax.events = [preview]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            let result = combined.poll(now: start.addingTimeInterval(1))
            try sourceCheck(Set(result.events.map(\.identity)) == Set([first.identity, repeatText.identity]))
            try sourceCheck(ax.accepted.contains(preview.identity))
            try sourceCheck(combined.poll(now: start.addingTimeInterval(2)).events.count == 2)
            combined.acknowledge(Set(result.events.map(\.identity)))
            try sourceCheck(combined.poll(now: start.addingTimeInterval(3)).events.isEmpty)
        }),
        ("Kakao combined AX fallback remains available after a short grace when notifications are absent", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            notifications.status = .unavailable
            let preview = notificationEvent("ax-fallback", text: "fallback synthetic", at: start)
            ax.events = [preview]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            try sourceCheck(combined.poll(now: start).events.isEmpty)
            try sourceCheck(combined.poll(now: start.addingTimeInterval(0.5)).events.isEmpty)
            let delivered = combined.poll(now: start.addingTimeInterval(1))
            try sourceCheck(delivered.status == .observing && delivered.events.map(\.identity) == [preview.identity])
            try sourceCheck(combined.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [preview.identity])
            combined.acknowledge([preview.identity])
            try sourceCheck(combined.poll(now: start.addingTimeInterval(3)).events.isEmpty)
        }),
        ("Kakao combined unused earlier burst notifications cannot consume the next genuine AX message", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            let first = notificationEvent("burst-first", at: start)
            let second = notificationEvent("burst-second", at: start.addingTimeInterval(0.1))
            let initialAX = notificationEvent("ax-burst-latest", at: start.addingTimeInterval(0.2), kind: "inbox-preview")
            notifications.events = [first, second]; ax.events = [initialAX]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            let delivered = combined.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(Set(delivered.map(\.identity)) == Set([first.identity, second.identity]))
            combined.acknowledge(Set(delivered.map(\.identity)))
            let genuinelyNew = notificationEvent("ax-new-without-notification", at: start.addingTimeInterval(1.2), kind: "inbox-preview")
            ax.events = [genuinelyNew]
            try sourceCheck(combined.poll(now: start.addingTimeInterval(2)).events.isEmpty)
            try sourceCheck(!ax.accepted.contains(genuinelyNew.identity), "old unused notification consumed the next AX event")
            try sourceCheck(combined.poll(now: start.addingTimeInterval(3)).events.map(\.identity) == [genuinelyNew.identity])
        }),
        ("Kakao combined complete prefix messages remain distinct without an explicit truncation marker", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            let long = notificationEvent("long-complete-notification", text: "a sufficiently long synthetic notification body", at: start)
            let short = notificationEvent("ax-short-complete-message", text: "a sufficiently long synthetic", at: start.addingTimeInterval(0.1), kind: "inbox-preview")
            notifications.events = [long]; ax.events = [short]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            let first = combined.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.map(\.identity) == [long.identity])
            combined.acknowledge(Set(first.map(\.identity)))
            try sourceCheck(!ax.accepted.contains(short.identity), "an ordinary prefix was treated as truncated")
            try sourceCheck(combined.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [short.identity])
        }),
        ("Kakao combined newer notifications cannot be consumed by an earlier fallback AX message", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            let earlier = notificationEvent("ax-earlier-fallback", at: start, kind: "inbox-preview")
            ax.events = [earlier]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            _ = combined.poll(now: start)
            let first = combined.poll(now: start.addingTimeInterval(1)).events
            try sourceCheck(first.map(\.identity) == [earlier.identity])
            combined.acknowledge(Set(first.map(\.identity)))
            ax.status = .unavailable
            let genuinelyNew = notificationEvent("newer-independent-notification", at: start.addingTimeInterval(1.1))
            notifications.events = [genuinelyNew]
            try sourceCheck(combined.poll(now: start.addingTimeInterval(2)).events.map(\.identity) == [genuinelyNew.identity], "earlier AX consumed a genuinely newer notification")
            try sourceCheck(!notifications.accepted.contains(genuinelyNew.identity))
        }),
        ("Kakao combined late and truncated notifications pair only one counterpart and preserve read marks", {
            let start = Date().addingTimeInterval(-10), ax = NotificationStub(), notifications = NotificationStub()
            let text = "a sufficiently long synthetic notification body"
            let preview = notificationEvent("ax-before", text: "a sufficiently long synthetic…", at: start, kind: "inbox-preview")
            ax.events = [preview]
            let combined = KakaoCombinedReader(name: "Fixture Friend", axReader: ax, notificationReader: notifications)
            _ = combined.poll(now: start)
            let shown = combined.poll(now: start.addingTimeInterval(1))
            combined.acknowledge(Set(shown.events.map(\.identity)))
            let late = notificationEvent("late-notification", text: text, at: start.addingTimeInterval(-0.1))
            let another = notificationEvent("another-notification", text: text, at: start.addingTimeInterval(1.1))
            notifications.events = [late, another]
            let result = combined.poll(now: start.addingTimeInterval(2))
            try sourceCheck(result.events.map(\.identity) == [another.identity], "late-pair suppressed two distinct notifications")
            try sourceCheck(notifications.accepted.contains(late.identity))
            let key = preview.conversation
            ax.reads = [key: start.addingTimeInterval(2)]
            try sourceCheck(combined.poll(now: start.addingTimeInterval(3)).reads[key] == start.addingTimeInterval(2))
        })
    ]
}
