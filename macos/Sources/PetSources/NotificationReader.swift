import Foundation
import Darwin
import SQLite3
import CryptoKit
import PetCore

/// Optional local fallback for individually delivered KakaoTalk notifications.
/// This is an undocumented OS database, so unsupported/masked payloads leave AX as the fallback.
/// Confined to the app's I/O queue. Never writes the source database or logs notification data.
public final class KakaoNotificationReader: LocalSourceReader {
    public let source = PetSource.kakao
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    fileprivate struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }
    fileprivate struct Revision: Comparable, Hashable {
        let date: Double
        let row: Int64
        static func < (a: Revision, b: Revision) -> Bool { a.date == b.date ? a.row < b.row : a.date < b.date }
    }
    fileprivate struct Row {
        let id: Int64
        let uuid: Data
        let payload: Data
        let requested: Double
        let revised: Double
        let delivered: Double
    }
    private struct Waiting { let event: PetEvent; let at: Date }
    /// Only canonical-message digests are retained; delivery/presentation metadata is not a new message.
    private struct MessageState { let digest: String; let at: Date }
    fileprivate enum Failure: Error { case permission, unavailable, busy }
    fileprivate static let bundle = "com.kakao.kakaotalkmac"
    private static let capacity = 200
    fileprivate static let pageSize = 200
    private static let lifetime: TimeInterval = 12 * 60 * 60
    private let name: String?
    private let conversation: ConversationKey?
    private let database: KakaoNotificationDatabase
    private var file: FileIdentity?
    private var cursor: Int64?
    private var revision: Revision?
    private var baselineAt: Date?
    private var outbox: [String: Waiting] = [:]
    private var seen: [String: Date] = [:]
    private var lastMessages: [String: MessageState] = [:]

    public convenience init(name: String?, databaseURL: URL = KakaoNotificationReader.defaultDatabaseURL,
                            databaseSessionOpened: (() -> Void)? = nil) {
        self.init(name: name, database: KakaoNotificationDatabase(url: databaseURL, opened: databaseSessionOpened))
    }

    init(name: String?, database: KakaoNotificationDatabase) {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        self.name = clean.flatMap {
            !$0.isEmpty && $0.count <= 100 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? $0 : nil
        }
        conversation = self.name.map { ConversationKey.local(.kakao, identifier: $0) }
        self.database = database
    }

    public func acknowledge(_ identities: Set<String>) {
        for identity in identities { outbox.removeValue(forKey: identity) }
    }

    public func poll(now: Date = Date()) -> SourcePoll {
        guard let name, let conversation else { return SourcePoll(status: .disabled) }
        let expiry = now.addingTimeInterval(-Self.lifetime)
        outbox = outbox.filter { $0.value.at >= expiry }
        seen = seen.filter { $0.value >= expiry }
        lastMessages = lastMessages.filter { $0.value.at >= expiry }
        if seen.count > 4096 {
            let oldest = seen.sorted { $0.value < $1.value }.prefix(seen.count - 4096)
            for (identity, _) in oldest { seen.removeValue(forKey: identity) }
        }
        if lastMessages.count > 4096 {
            let oldest = lastMessages.sorted { $0.value.at < $1.value.at }.prefix(lastMessages.count - 4096)
            for (record, _) in oldest { lastMessages.removeValue(forKey: record) }
        }
        do {
            return try database.read { snapshot in
                let currentFile = snapshot.file
                if file != currentFile { reset(); file = currentFile }
                let maximum = try snapshot.highWater()
                guard let cursor, maximum.0 >= cursor, revision != nil, baselineAt != nil else {
                    self.cursor = maximum.0; revision = maximum.1; baselineAt = now
                    return batch(.observing)
                }

                // A bounded retry outbox stops cursor advancement rather than dropping a burst.
                let room = Self.capacity - outbox.count
                if room > 0 {
                    let fresh = try snapshot.rows(selection: "r.rec_id > ? AND r.rec_id <= ?", integers: [cursor, maximum.0], revision: nil, limit: min(room, Self.pageSize))
                    var next = cursor
                    for row in fresh {
                        guard try receive(row, name: name, conversation: conversation, now: now) else { break }
                        next = row.id
                    }
                    if fresh.count < min(room, Self.pageSize) { next = maximum.0 }
                    self.cursor = next
                }
                if outbox.count < Self.capacity, let before = revision {
                    let updates = try snapshot.rows(
                        selection: "(r.request_last_date > ? OR (r.request_last_date = ? AND r.rec_id > ?)) AND (r.request_last_date < ? OR (r.request_last_date = ? AND r.rec_id <= ?))",
                        integers: [], revision: (before, maximum.1), limit: Self.pageSize)
                    var next = before
                    for row in updates {
                        guard try receive(row, name: name, conversation: conversation, now: now) else { break }
                        next = Revision(date: row.revised, row: row.id)
                    }
                    // Do not skip the unprocessed remainder when the outbox becomes full.
                    if updates.count < Self.pageSize && outbox.count < Self.capacity { next = maximum.1 }
                    revision = next
                }
                return batch(.observing)
            }
        } catch Failure.permission {
            reset()
            return batch(.permissionRequired)
        } catch {
            return batch(.unavailable)
        }
    }

    private func reset() { cursor = nil; revision = nil; baselineAt = nil }

    private func batch(_ status: SourceStatus) -> SourcePoll {
        let events = outbox.values.sorted {
            $0.at == $1.at ? $0.event.identity < $1.event.identity : $0.at < $1.at
        }.map(\.event)
        return SourcePoll(events: events, status: status)
    }

    /// Returns false only for backpressure. Malformed and unrelated notifications advance the cursor.
    private func receive(_ row: Row, name: String, conversation: ConversationKey, now: Date) throws -> Bool {
        guard let baselineAt, let file else { return true }
        let time = max(row.requested, max(row.revised, row.delivered))
        guard time.isFinite, time > 0 else { return true }
        let delivered = Date(timeIntervalSinceReferenceDate: time)
        guard delivered >= baselineAt, delivered <= now.addingTimeInterval(300), row.uuid.count == 16,
              !row.payload.isEmpty,
              let plist = (try? PropertyListSerialization.propertyList(from: row.payload, options: [], format: nil)) as? [String: Any],
              let bundle = plist["app"] as? String, bundle.lowercased() == Self.bundle,
              let request = plist["req"] as? [String: Any],
              let title = request["titl"] as? String, title.count <= 200, KakaoReader.nameMatches(title, configured: name),
              let body = request["body"] as? String, !body.contains("\0"),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        // A nonempty subtitle may be a group-room name. Never infer a 1:1 contact from it.
        if let subtitle = request["subt"] {
            guard let value = subtitle as? String, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        }
        // A row can be rewritten when macOS delivers or presents an existing notification.
        // Keep only the last meaningful state per record, so A→B→A remains three arrivals while
        // unchanged text with revised delivery dates/raw plist metadata remains one arrival.
        let recordMaterial = "\(file.device):\(file.inode):\(file.birthSeconds):\(file.birthNanoseconds):\(row.id):" + row.uuid.base64EncodedString()
        let record = SHA256.hash(data: Data(recordMaterial.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        var canonical = Data()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        append(body.precomposedStringWithCanonicalMapping)
        append(String(row.requested.bitPattern))
        if let identifier = request["iden"] as? String { canonical.append(1); append(identifier) }
        else { canonical.append(0) }
        let state = SHA256.hash(data: canonical).prefix(16).map { String(format: "%02x", $0) }.joined()
        if lastMessages[record]?.digest == state { return true }
        let provenance = "\(file.device):\(file.inode):\(file.birthSeconds):\(file.birthNanoseconds):\(row.id):\(row.revised.bitPattern):\(row.delivered.bitPattern)"
        var material = Data(provenance.utf8); material.append(row.uuid); material.append(row.payload)
        let digest = SHA256.hash(data: material).prefix(16).map { String(format: "%02x", $0) }.joined()
        let event = PetEvent(eventId: "kakao-notify-" + String(format: "%020lld", row.id) + "-" + digest,
            sender: "local.kakao", displayName: "KakaoTalk", text: String(body.prefix(2000)),
            threadUrl: conversation.key, observedAt: PetEvent.timestamp(delivered), kind: "thread-message", source: .kakao)
        guard (try? event.validate()) != nil else { return true }
        if seen[event.identity] != nil || outbox[event.identity] != nil { return true }
        guard outbox.count < Self.capacity else { return false }
        seen[event.identity] = now
        outbox[event.identity] = Waiting(event: event, at: delivered)
        lastMessages[record] = MessageState(digest: state, at: now)
        return true
    }
}

/// One short-lived read-only session per contact-group poll. Reader cursors/outboxes remain independent.
final class KakaoNotificationDatabase {
    fileprivate typealias FileIdentity = KakaoNotificationReader.FileIdentity
    fileprivate typealias Revision = KakaoNotificationReader.Revision
    fileprivate typealias Row = KakaoNotificationReader.Row
    fileprivate typealias Failure = KakaoNotificationReader.Failure
    private let databaseURL: URL
    private let opened: (() -> Void)?
    private var inPoll = false
    private var snapshot: Result<Session, Error>?

    init(url: URL, opened: (() -> Void)? = nil) { databaseURL = url; self.opened = opened }
    func beginPoll() { snapshot = nil; inPoll = true }
    func endPoll() { snapshot = nil; inPoll = false }

    fileprivate func read<T>(_ body: (Session) throws -> T) throws -> T {
        let result: Result<Session, Error>
        if inPoll, let snapshot { result = snapshot }
        else {
            result = Result { try Session(url: databaseURL, file: fileIdentity(), opened: opened) }
            if inPoll { snapshot = result }
        }
        return try body(result.get())
    }

    private func fileIdentity() throws -> FileIdentity {
        var info = stat()
        guard lstat(databaseURL.path, &info) == 0 else {
            throw errno == EACCES || errno == EPERM ? Failure.permission : Failure.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }

    fileprivate static func verify(_ code: Int32) throws {
        switch code & 0xff {
        case SQLITE_OK, SQLITE_ROW, SQLITE_DONE: return
        case SQLITE_PERM, SQLITE_AUTH, SQLITE_CANTOPEN, SQLITE_READONLY: throw Failure.permission
        case SQLITE_BUSY, SQLITE_LOCKED: throw Failure.busy
        default: throw Failure.unavailable
        }
    }

    fileprivate final class Session {
        private struct Query: Hashable {
            let selection: String
            let integers: [Int64]
            let lower: Revision?
            let upper: Revision?
        }
        let file: FileIdentity
        private let database: OpaquePointer
        private var maximum: Result<(Int64, Revision), Error>?
        private var rowCache: [Query: Result<[Row], Error>] = [:]
        private static let bundle = KakaoNotificationReader.bundle
        private static let pageSize = KakaoNotificationReader.pageSize

        init(url: URL, file: FileIdentity, opened: (() -> Void)?) throws {
            self.file = file
            var handle: OpaquePointer?
            var uri = URLComponents()
            uri.scheme = "file"; uri.path = url.path
            uri.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "cache", value: "private")]
            guard let path = uri.string else { throw Failure.unavailable }
            let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
            var retained = false
            defer { if !retained, let handle { sqlite3_close(handle) } }
            try KakaoNotificationDatabase.verify(code)
            guard let handle, sqlite3_db_readonly(handle, "main") == 1 else { throw Failure.unavailable }
            database = handle
            sqlite3_busy_timeout(handle, 75)
            retained = true
            opened?()
        }
        deinit { sqlite3_close(database) }

        func highWater() throws -> (Int64, Revision) {
            let result = maximum ?? Result { try readHighWater() }
            maximum = result
            return try result.get()
        }

        func rows(selection: String, integers: [Int64], revision: (Revision, Revision)?, limit: Int) throws -> [Row] {
            let query = Query(selection: selection, integers: integers, lower: revision?.0, upper: revision?.1)
            // Read one full page so contacts with different free outbox space still reuse the same rows.
            let result = rowCache[query] ?? Result { try readRows(selection: selection, integers: integers, revision: revision, limit: Self.pageSize) }
            // Different contact backlogs may request different ranges; keep retained raw data bounded.
            if rowCache.count < 4 { rowCache[query] = result }
            return Array(try result.get().prefix(limit))
        }

        private func statement(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
            var result: OpaquePointer?
            let code = sqlite3_prepare_v2(database, sql, -1, &result, nil)
            if code != SQLITE_OK { if let result { sqlite3_finalize(result) }; try KakaoNotificationDatabase.verify(code) }
            guard let result else { throw Failure.unavailable }
            return result
        }

        private func readHighWater() throws -> (Int64, Revision) {
            let maxID = try statement(database, """
                SELECT COALESCE(MAX(r.rec_id),0), COALESCE(MAX(r.request_last_date),0)
                FROM record r JOIN app a ON a.app_id=r.app_id WHERE lower(a.identifier)=?
                """)
            defer { sqlite3_finalize(maxID) }
            try KakaoNotificationDatabase.verify(sqlite3_bind_text(maxID, 1, Self.bundle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            try KakaoNotificationDatabase.verify(sqlite3_step(maxID))
            let id = sqlite3_column_int64(maxID, 0), date = sqlite3_column_double(maxID, 1)
            guard date.isFinite, date >= 0 else { throw Failure.unavailable }
            let maxRevision = try statement(database, """
                SELECT COALESCE(MAX(r.rec_id),0) FROM record r JOIN app a ON a.app_id=r.app_id
                WHERE lower(a.identifier)=? AND r.request_last_date=?
                """)
            defer { sqlite3_finalize(maxRevision) }
            try KakaoNotificationDatabase.verify(sqlite3_bind_text(maxRevision, 1, Self.bundle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            try KakaoNotificationDatabase.verify(sqlite3_bind_double(maxRevision, 2, date))
            try KakaoNotificationDatabase.verify(sqlite3_step(maxRevision))
            return (id, Revision(date: date, row: sqlite3_column_int64(maxRevision, 0)))
        }

        private func readRows(selection: String, integers: [Int64], revision: (Revision, Revision)?, limit: Int) throws -> [Row] {
            let order = revision == nil ? "r.rec_id" : "r.request_last_date,r.rec_id"
            let query = try statement(database, """
                SELECT r.rec_id,r.uuid,
                       CASE WHEN length(r.data)<=65536 THEN r.data ELSE NULL END,
                       r.request_date,r.request_last_date,r.delivered_date
                FROM record r JOIN app a ON a.app_id=r.app_id
                WHERE lower(a.identifier)=? AND \(selection)
                ORDER BY \(order) LIMIT \(limit)
                """)
            defer { sqlite3_finalize(query) }
            try KakaoNotificationDatabase.verify(sqlite3_bind_text(query, 1, Self.bundle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            if let (lower, upper) = revision {
                for (index, value) in [lower.date, lower.date, upper.date, upper.date].enumerated() {
                    let parameter: Int32 = [2, 3, 5, 6][index]
                    try KakaoNotificationDatabase.verify(sqlite3_bind_double(query, parameter, value))
                }
                try KakaoNotificationDatabase.verify(sqlite3_bind_int64(query, 4, lower.row)); try KakaoNotificationDatabase.verify(sqlite3_bind_int64(query, 7, upper.row))
            } else {
                for (index, value) in integers.enumerated() { try KakaoNotificationDatabase.verify(sqlite3_bind_int64(query, Int32(index + 2), value)) }
            }
            var result: [Row] = []
            while true {
                let code = sqlite3_step(query); try KakaoNotificationDatabase.verify(code)
                if code == SQLITE_DONE { break }
                func bytes(_ column: Int32) -> Data {
                    let count = Int(sqlite3_column_bytes(query, column))
                    guard count > 0, count <= 65536, let pointer = sqlite3_column_blob(query, column) else { return Data() }
                    return Data(bytes: pointer, count: count)
                }
                result.append(Row(id: sqlite3_column_int64(query, 0), uuid: bytes(1), payload: bytes(2),
                    requested: sqlite3_column_double(query, 3), revised: sqlite3_column_double(query, 4), delivered: sqlite3_column_double(query, 5)))
            }
            return result
        }

    }
}

/// Notifications carry individual messages; AX remains the read-state and missing-notification fallback.
/// Both underlying retry outboxes are acknowledged only on durable app acceptance or a paired duplicate.
public final class KakaoCombinedReader: LocalSourceReader {
    public let source = PetSource.kakao
    public private(set) var notificationStatus = SourceStatus.disabled
    public private(set) var accessibilityStatus = SourceStatus.disabled
    private struct Fingerprint {
        let conversation: ConversationKey
        let date: Date
        let text: String
        let isPreview: Bool
        init(_ event: PetEvent) {
            conversation = event.conversation
            date = PetEvent.date(event.observedAt) ?? .distantPast
            text = event.text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            isPreview = event.kind == "inbox-preview"
        }
    }
    private struct Recent {
        let event: PetEvent
        let at: Date
        var paired: Bool
        let fingerprint: Fingerprint
        init(event: PetEvent, at: Date, paired: Bool) {
            self.event = event; self.at = at; self.paired = paired
            fingerprint = Fingerprint(event)
        }
    }
    private struct Held { let event: PetEvent; let releaseAt: Date; let notificationAfter: Date? }
    private let accessibility: LocalSourceReader
    private let notifications: LocalSourceReader
    private var recentNotifications: [String: Recent] = [:]
    private var releasedAX: [String: Recent] = [:]
    private var heldAX: [String: Held] = [:]
    private var axObservationWatermarks: [ConversationKey: Date] = [:]
    private let grace: TimeInterval
    private let matchWindow: TimeInterval = 5

    public init(name: String?, databaseURL: URL = KakaoNotificationReader.defaultDatabaseURL,
                axReader: LocalSourceReader? = nil, notificationReader: LocalSourceReader? = nil,
                fallbackGrace: TimeInterval = 1) {
        accessibility = axReader ?? KakaoReader(name: name)
        notifications = notificationReader ?? KakaoNotificationReader(name: name, databaseURL: databaseURL)
        grace = max(0, min(1, fallbackGrace))
    }

    public func restorePending(_ events: [PetEvent]) {
        accessibility.restorePending(events); notifications.restorePending(events)
    }

    public func acknowledge(_ identities: Set<String>) {
        accessibility.acknowledge(identities); notifications.acknowledge(identities)
        for identity in identities { heldAX.removeValue(forKey: identity) }
    }

    public func poll(now: Date = Date()) -> SourcePoll {
        let notificationBatch = notifications.poll(now: now)
        let axBatch = accessibility.poll(now: now)
        notificationStatus = notificationBatch.status; accessibilityStatus = axBatch.status
        recentNotifications = recentNotifications.filter { now.timeIntervalSince($0.value.at) <= matchWindow }
        releasedAX = releasedAX.filter { now.timeIntervalSince($0.value.at) <= matchWindow }
        var suppressNotifications = Set<String>(), suppressAX = Set<String>()
        for event in notificationBatch.events where recentNotifications[event.identity] == nil {
            let fingerprint = Fingerprint(event)
            // A genuinely newer notification must not be acknowledged as an older AX fallback.
            let latePair = releasedAX.filter {
                !$0.value.paired && fingerprint.date <= $0.value.fingerprint.date
                    && Self.sameMessage($0.value.fingerprint, fingerprint)
            }
                .max { $0.value.at < $1.value.at }
            if let (identity, _) = latePair {
                releasedAX[identity]?.paired = true
                suppressNotifications.insert(event.identity)
                recentNotifications[event.identity] = Recent(event: event, at: now, paired: true)
            } else { recentNotifications[event.identity] = Recent(event: event, at: now, paired: false) }
        }
        notifications.acknowledge(suppressNotifications)
        for event in axBatch.events {
            // A retry already released to the app can pair only with a newly arriving notification
            // in the late-pair path above, never with an unused older burst notification.
            if releasedAX[event.identity] != nil { continue }
            let fingerprint = Fingerprint(event)
            if heldAX[event.identity] == nil {
                let previousObservation = axObservationWatermarks[event.conversation]
                heldAX[event.identity] = Held(event: event, releaseAt: now.addingTimeInterval(grace), notificationAfter: previousObservation)
                axObservationWatermarks[event.conversation] = max(previousObservation ?? .distantPast, fingerprint.date)
            }
            let previousObservation = heldAX[event.identity]?.notificationAfter ?? .distantPast
            let pair = recentNotifications.filter {
                !$0.value.paired && $0.value.fingerprint.date > previousObservation
                    && Self.sameMessage(fingerprint, $0.value.fingerprint)
            }
                .max { $0.value.at < $1.value.at }
            if let (identity, _) = pair {
                recentNotifications[identity]?.paired = true
                suppressAX.insert(event.identity); heldAX.removeValue(forKey: event.identity)
            }
        }
        accessibility.acknowledge(suppressAX)
        var reads = axBatch.reads
        for (key, date) in notificationBatch.reads { reads[key] = max(reads[key] ?? .distantPast, date) }
        let readHeld = Set(heldAX.values.filter { $0.event.conversation.isRead(observedAt: $0.event.observedAt, in: reads) }.map { $0.event.identity })
        accessibility.acknowledge(readHeld)
        for identity in readHeld { heldAX.removeValue(forKey: identity) }
        var events = notificationBatch.events.filter { !suppressNotifications.contains($0.identity) }
        for event in axBatch.events where releasedAX[event.identity] != nil && !suppressAX.contains(event.identity) {
            events.append(event)
        }
        for (identity, held) in heldAX where held.releaseAt <= now {
            releasedAX[identity] = Recent(event: held.event, at: now, paired: false)
            events.append(held.event); heldAX.removeValue(forKey: identity)
        }
        events.sort { $0.observedAt == $1.observedAt ? $0.identity < $1.identity : $0.observedAt < $1.observedAt }
        let observing = notificationStatus == .observing || accessibilityStatus == .observing
        let status: SourceStatus = observing ? .observing
            : accessibilityStatus == .disabled ? .disabled
            : accessibilityStatus == .permissionRequired && notificationStatus == .permissionRequired ? .permissionRequired
            : accessibilityStatus == .idle ? .idle : .unavailable
        return SourcePoll(events: events, reads: reads, status: status)
    }

    private static func sameMessage(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        guard a.conversation == b.conversation, abs(a.date.timeIntervalSince(b.date)) <= 5 else { return false }
        let firstText = a.text, secondText = b.text
        if firstText == secondText { return true }
        func shortenedPrefix(_ short: String, isPreview: Bool, of long: String) -> Bool {
            guard isPreview, short.hasSuffix("…") || short.hasSuffix("...") else { return false }
            let prefix = short.hasSuffix("…") ? String(short.dropLast()).trimmingCharacters(in: .whitespaces)
                : short.hasSuffix("...") ? String(short.dropLast(3)).trimmingCharacters(in: .whitespaces) : short
            return prefix.count >= 12 && prefix.count < long.count && long.hasPrefix(prefix)
        }
        return shortenedPrefix(firstText, isPreview: a.isPreview, of: secondText)
            || shortenedPrefix(secondText, isPreview: b.isPreview, of: firstText)
    }
}
