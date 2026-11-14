import Foundation
import Darwin
import SQLite3
import CryptoKit
import PetCore

/// Confined to the app's serial I/O queue. No database writes, helper process or message logging.
public final class MessagesReader: LocalSourceReader {
    public let source = PetSource.messages
    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let createdSeconds: Int64
        let createdNanoseconds: Int64
    }
    private struct Row {
        let id: Int64
        let text: String?
        let body: Data?
        let read: Bool
        let sentAt: Date?
    }
    private struct WaitingBody { let firstObservedAt: Date }
    private struct Watched { let identity: String; let observedAt: Date }
    private enum Failure: Error { case permission, unavailable, busy }
    private static let capacity = 200
    private static let lifetime: TimeInterval = 12 * 60 * 60
    private static let bodyWait: TimeInterval = 30
    private static let missingBody = "(메시지)"
    private let handle: String?
    private let databaseURL: URL
    private let conversation: ConversationKey?
    private var databaseIdentity: FileIdentity?
    private var cursor: Int64?
    private var baselineAt: Date?
    private var unresolved: [Int64: WaitingBody] = [:]
    private var watched: [Int64: Watched] = [:]
    private var outbox: [String: PetEvent] = [:]
    private var readThrough: Date?
    private var pendingDeletedThrough: Date?
    private var restoring: [PetEvent] = []

    public init(handle: String?, databaseURL: URL = MessagesReader.defaultDatabaseURL) {
        self.handle = handle.flatMap(SourcesConfig.normalizeHandle)
        self.databaseURL = databaseURL
        self.conversation = self.handle.map { ConversationKey.local(.messages, identifier: $0) }
    }

    public func acknowledge(_ identities: Set<String>) {
        for identity in identities { outbox.removeValue(forKey: identity) }
    }

    /// Reconnect only already-accepted queue events; ordinary database history stays a launch baseline.
    public func restorePending(_ events: [PetEvent]) {
        guard let conversation else { return }
        restoring = Array(events.lazy.filter {
            $0.source == .messages && $0.conversation == conversation && $0.kind == "thread-message"
                && (try? $0.validate()) != nil
        }.prefix(Self.capacity))
    }

    public func poll(now: Date = Date()) -> SourcePoll {
        guard let handle, let conversation else { return SourcePoll(status: .disabled) }
        let expiry = now.addingTimeInterval(-Self.lifetime)
        watched = watched.filter { $0.value.observedAt >= expiry }
        outbox = outbox.filter { (PetEvent.date($0.value.observedAt) ?? .distantPast) >= expiry }
        unresolved = unresolved.filter { $0.value.firstObservedAt >= expiry }
        if let deleted = pendingDeletedThrough, deleted < expiry { pendingDeletedThrough = nil }
        do {
            let identity = try fileIdentity()
            if databaseIdentity != identity {
                resetBaseline()
                databaseIdentity = identity
            }
            var database: OpaquePointer?
            var parts = URLComponents()
            parts.scheme = "file"
            parts.path = databaseURL.path
            parts.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "cache", value: "private")]
            guard let uri = parts.string else { throw Failure.unavailable }
            let opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
            defer { if let database { sqlite3_close(database) } }
            try verify(opened)
            guard let database, sqlite3_db_readonly(database, "main") == 1 else { throw Failure.unavailable }
            sqlite3_busy_timeout(database, 150)
            let maximum = try maxRowID(database)
            try restoreTrackedRows(database, handle: handle, now: now)
            guard let cursor, let baselineAt else {
                self.cursor = maximum
                self.baselineAt = now
                unresolved.removeAll()
                try updateReads(database, conversation: conversation)
                return batch(.observing)
            }
            // Deleting the highest ROWID shrinks the cursor, not the lifetime of earlier pending bodies.
            let lowerCursor = min(cursor, maximum)

            if !unresolved.isEmpty {
                let ids = unresolved.keys.sorted()
                let rows = try rows(database, handle: handle, selection: "m.ROWID IN (\(ids.map { _ in "?" }.joined(separator: ",")))", values: ids, limit: Self.capacity)
                let present = Set(rows.map(\.id))
                for id in ids where !present.contains(id) { unresolved.removeValue(forKey: id) }
                for row in rows { try receive(row, database: database, baselineAt: baselineAt, now: now, conversation: conversation) }
            }

            // Stop at the bound rather than discarding unacknowledged events or unread tracking.
            let occupied = Set(watched.values.map(\.identity)).union(outbox.keys).count + unresolved.count
            let room = max(0, Self.capacity - occupied)
            var nextCursor = lowerCursor
            if room > 0 {
                let fresh = try rows(database, handle: handle, selection: "m.ROWID > ? AND m.ROWID <= ?", values: [lowerCursor, maximum], limit: room)
                for row in fresh { try receive(row, database: database, baselineAt: baselineAt, now: now, conversation: conversation) }
                nextCursor = fresh.count < room ? maximum : (fresh.last?.id ?? maximum)
            }
            try updateReads(database, conversation: conversation)
            self.cursor = nextCursor
            return batch(.observing)
        } catch Failure.permission {
            cursor = nil
            baselineAt = nil
            unresolved.removeAll()
            return batch(.permissionRequired)
        } catch {
            return batch(.unavailable)
        }
    }

    private func resetBaseline() {
        cursor = nil
        baselineAt = nil
        unresolved.removeAll()
        watched.removeAll()
        pendingDeletedThrough = nil
    }

    private func batch(_ status: SourceStatus) -> SourcePoll {
        let dated: [(event: PetEvent, date: Date)] = outbox.values.map {
            (event: $0, date: PetEvent.date($0.observedAt) ?? .distantPast)
        }
        let sorted = dated.sorted { a, b in
            a.date == b.date ? a.event.identity < b.event.identity : a.date < b.date
        }
        let events = sorted.map { $0.event }
        let reads = conversation.flatMap { conversation in readThrough.map { [conversation: $0] } } ?? [:]
        return SourcePoll(events: events, reads: reads, status: status)
    }

    private func fileIdentity() throws -> FileIdentity {
        var info = stat()
        guard lstat(databaseURL.path, &info) == 0 else {
            throw errno == EACCES || errno == EPERM ? Failure.permission : Failure.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                            createdSeconds: Int64(info.st_birthtimespec.tv_sec), createdNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }

    private func verify(_ code: Int32) throws {
        switch code & 0xff {
        case SQLITE_OK, SQLITE_ROW, SQLITE_DONE: return
        case SQLITE_PERM, SQLITE_AUTH, SQLITE_CANTOPEN, SQLITE_READONLY: throw Failure.permission
        case SQLITE_BUSY, SQLITE_LOCKED: throw Failure.busy
        default: throw Failure.unavailable
        }
    }

    private func statement(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &result, nil)
        if code != SQLITE_OK { if let result { sqlite3_finalize(result) }; try verify(code) }
        guard let result else { throw Failure.unavailable }
        return result
    }

    private func maxRowID(_ database: OpaquePointer) throws -> Int64 {
        let query = try statement(database, "SELECT COALESCE(MAX(ROWID), 0) FROM message")
        defer { sqlite3_finalize(query) }
        let code = sqlite3_step(query)
        try verify(code)
        guard code == SQLITE_ROW else { throw Failure.unavailable }
        return sqlite3_column_int64(query, 0)
    }

    private func rows(_ database: OpaquePointer, handle: String, selection: String, values: [Int64], limit: Int) throws -> [Row] {
        let compact = "replace(replace(replace(replace(replace(trim(h.id), ' ', ''), '-', ''), '(', ''), ')', ''), '.', '')"
        let phone = "CASE WHEN substr(\(compact),1,4)='0082' THEN '+' || substr(\(compact),3) WHEN substr(\(compact),1,3)='010' AND length(\(compact))=11 THEN '+82' || substr(\(compact),2) ELSE \(compact) END"
        let normalized = handle.contains("@") ? "lower(trim(h.id))" : phone
        let ordinaryMessage = try hasAssociatedMessageType(database) ? "COALESCE(m.associated_message_type,0)=0" : "1"
        let sql = """
            SELECT m.ROWID, substr(m.text,1,4000),
                   CASE WHEN length(m.attributedBody)<=65536 THEN m.attributedBody ELSE NULL END,
                   m.is_read, m.date
            FROM message m JOIN handle h ON h.ROWID=m.handle_id
            WHERE m.is_from_me=0 AND \(ordinaryMessage) AND \(normalized)=? AND \(selection)
              AND EXISTS (
                SELECT 1 FROM chat_message_join cm JOIN chat_handle_join peer ON peer.chat_id=cm.chat_id
                WHERE cm.message_id=m.ROWID AND peer.handle_id=h.ROWID
                  AND (SELECT COUNT(DISTINCT handle_id) FROM chat_handle_join participants WHERE participants.chat_id=cm.chat_id)=1
              )
              AND NOT EXISTS (
                SELECT 1 FROM chat_message_join cm WHERE cm.message_id=m.ROWID
                  AND (SELECT COUNT(DISTINCT handle_id) FROM chat_handle_join participants WHERE participants.chat_id=cm.chat_id)<>1
              )
            ORDER BY m.ROWID LIMIT \(limit)
            """
        let query = try statement(database, sql)
        defer { sqlite3_finalize(query) }
        try verify(sqlite3_bind_text(query, 1, handle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        for (index, value) in values.enumerated() { try verify(sqlite3_bind_int64(query, Int32(index + 2), value)) }
        var result: [Row] = []
        while true {
            let code = sqlite3_step(query)
            try verify(code)
            if code == SQLITE_DONE { break }
            var body: Data?
            let length = Int(sqlite3_column_bytes(query, 2))
            if length > 0, length <= 65_536, let bytes = sqlite3_column_blob(query, 2) { body = Data(bytes: bytes, count: length) }
            let rawDate = sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : Optional(sqlite3_column_double(query, 4))
            let sentAt = rawDate.flatMap { value -> Date? in
                guard value.isFinite, value > 0 else { return nil }
                return Date(timeIntervalSinceReferenceDate: value > 1_000_000_000_000 ? value / 1_000_000_000 : value)
            }
            result.append(Row(id: sqlite3_column_int64(query, 0), text: text(query, column: 1), body: body,
                              read: sqlite3_column_int(query, 3) == 1, sentAt: sentAt))
        }
        return result
    }

    /// Older databases do not expose the reaction type column.
    private func hasAssociatedMessageType(_ database: OpaquePointer) throws -> Bool {
        let query = try statement(database, "PRAGMA table_info(message)")
        defer { sqlite3_finalize(query) }
        while true {
            let code = sqlite3_step(query)
            try verify(code)
            if code == SQLITE_DONE { return false }
            if text(query, column: 1) == "associated_message_type" { return true }
        }
    }

    private func text(_ query: OpaquePointer, column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(query, column) else { return nil }
        return String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, column))), encoding: .utf8)
    }

    private func attachmentLabels(_ database: OpaquePointer, messageID: Int64) throws -> [String] {
        let query = try statement(database, "SELECT a.mime_type FROM message_attachment_join j JOIN attachment a ON a.ROWID=j.attachment_id WHERE j.message_id=? LIMIT 16")
        defer { sqlite3_finalize(query) }
        try verify(sqlite3_bind_int64(query, 1, messageID))
        var result: [String] = []
        while true {
            let code = sqlite3_step(query)
            try verify(code)
            if code == SQLITE_DONE { break }
            let mime = text(query, column: 0)?.lowercased() ?? ""
            result.append(mime.hasPrefix("image/") ? "(이미지)" : mime.hasPrefix("video/") ? "(동영상)" : "(첨부)")
        }
        return result
    }

    private func receive(_ row: Row, database: OpaquePointer, baselineAt: Date, now: Date, conversation: ConversationKey) throws {
        guard watched[row.id] == nil else { return }
        guard !row.read, let sentAt = row.sentAt, sentAt >= baselineAt, sentAt <= now.addingTimeInterval(300) else {
            unresolved.removeValue(forKey: row.id)
            return
        }
        // Use the wire timestamp's precision for watermarks too: two observations in one millisecond
        // must remain a tie, otherwise rounding could make the newer unread bubble look older.
        let observedAt = unresolved[row.id]?.firstObservedAt ?? (PetEvent.date(PetEvent.timestamp(now)) ?? now)
        var text = try messageText(row, database: database)
        if text.isEmpty {
            guard now.timeIntervalSince(observedAt) >= Self.bodyWait else {
                if unresolved[row.id] == nil { unresolved[row.id] = WaitingBody(firstObservedAt: observedAt) }
                return
            }
            text = Self.missingBody
        }
        guard let fingerprint = rowFingerprint(row) else { return }
        let event = PetEvent(eventId: "messages-" + String(format: "%020lld", row.id) + "-" + fingerprint + "-" + UUID().uuidString, sender: "local.messages", displayName: "Messages",
                             text: text, threadUrl: conversation.key,
                             observedAt: PetEvent.timestamp(observedAt), kind: "thread-message", source: .messages)
        guard (try? event.validate()) != nil else { unresolved.removeValue(forKey: row.id); return }
        unresolved.removeValue(forKey: row.id)
        watched[row.id] = Watched(identity: event.identity, observedAt: observedAt)
        outbox[event.identity] = event
    }

    private func messageText(_ row: Row, database: OpaquePointer) throws -> String {
        let decoded = row.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? row.body.flatMap(Self.decodeAttributedBody)
        let labels = try attachmentLabels(database, messageID: row.id)
        let plain = decoded?.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(([plain] + labels).filter { !$0.isEmpty }.joined(separator: "\n").prefix(2000))
    }

    /// A ROWID alone can be reused after database replacement. Bind it to this file and row timestamp.
    private func rowFingerprint(_ row: Row) -> String? {
        guard let databaseIdentity, let sentAt = row.sentAt else { return nil }
        let value = "\(databaseIdentity.device):\(databaseIdentity.inode):\(databaseIdentity.createdSeconds):\(databaseIdentity.createdNanoseconds):\(row.id):\(sentAt.timeIntervalSinceReferenceDate.bitPattern)"
        return SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func restoreTrackedRows(_ database: OpaquePointer, handle: String, now: Date) throws {
        let expiry = now.addingTimeInterval(-Self.lifetime)
        var candidates: [Int64: (PetEvent, String, Date)] = [:]
        let occupied = Set(watched.values.map(\.identity)).union(outbox.keys).count + unresolved.count
        let room = max(0, Self.capacity - occupied)
        for event in restoring {
            guard candidates.count < room, let observed = PetEvent.date(event.observedAt), observed >= expiry,
                  observed > (readThrough ?? .distantPast) else { continue }
            let parts = event.eventId.split(separator: "-", maxSplits: 3)
            guard parts.count == 4, parts[0] == "messages", parts[1].count == 20,
                  let id = Int64(parts[1]), id > 0, watched[id] == nil,
                  parts[2].count == 32, UUID(uuidString: String(parts[3])) != nil else { continue }
            candidates[id] = (event, String(parts[2]), observed)
        }
        guard !candidates.isEmpty else { return }
        let ids = candidates.keys.sorted()
        let found = try rows(database, handle: handle, selection: "m.ROWID IN (\(ids.map { _ in "?" }.joined(separator: ",")))", values: ids, limit: Self.capacity)
        for row in found {
            guard let (event, expected, observed) = candidates[row.id], rowFingerprint(row) == expected else { continue }
            let body = try messageText(row, database: database)
            // A fallback still belongs to this fingerprinted row if its body hydrated later.
            guard body == event.text || event.text == Self.missingBody else { continue }
            watched[row.id] = Watched(identity: event.identity, observedAt: observed)
        }
    }

    private func updateReads(_ database: OpaquePointer, conversation: ConversationKey) throws {
        guard !watched.isEmpty || pendingDeletedThrough != nil else { return }
        let ids = watched.keys.sorted()
        var read = Set<Int64>(), present = Set<Int64>()
        if !ids.isEmpty {
            let query = try statement(database, "SELECT ROWID,is_read FROM message WHERE is_from_me=0 AND ROWID IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
            defer { sqlite3_finalize(query) }
            for (index, id) in ids.enumerated() { try verify(sqlite3_bind_int64(query, Int32(index + 1), id)) }
            while true {
                let code = sqlite3_step(query)
                try verify(code)
                if code == SQLITE_DONE { break }
                let id = sqlite3_column_int64(query, 0)
                present.insert(id)
                if sqlite3_column_int(query, 1) == 1 { read.insert(id) }
            }
        }
        for id in ids where !present.contains(id) {
            if let removed = watched.removeValue(forKey: id) {
                outbox.removeValue(forKey: removed.identity)
                pendingDeletedThrough = max(pendingDeletedThrough ?? .distantPast, removed.observedAt)
            }
        }
        // A later read row must never erase an earlier still-unread row.
        let firstUnread = (watched.filter { !read.contains($0.key) }.map { $0.value.observedAt }
            + unresolved.values.map(\.firstObservedAt)).min() ?? .distantFuture
        var resolved = watched.filter { read.contains($0.key) && $0.value.observedAt < firstUnread }.map { $0.value.observedAt }
        // Keep only the furthest deletion until older unread messages permit a safe watermark.
        if let deleted = pendingDeletedThrough, deleted < firstUnread { resolved.append(deleted) }
        guard let through = resolved.max() else { return }
        readThrough = max(readThrough ?? .distantPast, through)
        if let deleted = pendingDeletedThrough, deleted <= through { pendingDeletedThrough = nil }
        for (id, value) in watched where value.observedAt <= through {
            watched.removeValue(forKey: id)
            outbox.removeValue(forKey: value.identity)
        }
    }

    /// Decode only an expected attributed-string root; never instantiate arbitrary archived classes.
    private static func decodeAttributedBody(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= 65_536 else { return nil }
        if data.starts(with: Data("bplist00".utf8)) {
            guard let object = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  object["$archiver"] as? String == "NSKeyedArchiver" else { return nil }
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data))?.string
        }
        let bytes = Array(data)
        guard bytes.count > 22, bytes[0] == 4, bytes[1] == 11,
              Array(bytes[2..<13]) == Array("streamtyped".utf8) else { return nil }
        var offset = 13
        func integer(_ offset: inout Int) -> Int? {
            guard offset < bytes.count else { return nil }
            let head = bytes[offset]; offset += 1
            if head <= 0x7f { return Int(head) }
            let count = head == 0x81 ? 2 : head == 0x82 ? 4 : 0
            guard count > 0, offset + count <= bytes.count else { return nil }
            var value = 0
            for index in 0..<count { value |= Int(bytes[offset + index]) << (8 * index) }
            offset += count
            return value
        }
        guard integer(&offset) != nil, offset + 6 <= bytes.count,
              Array(bytes[offset..<offset + 6]) == [0x84, 1, 0x40, 0x84, 0x84, 0x84] else { return nil }
        offset += 6
        guard let count = integer(&offset), count <= 64, offset + count <= bytes.count,
              let root = String(bytes: bytes[offset..<offset + count], encoding: .ascii),
              ["NSAttributedString", "NSMutableAttributedString", "NSString", "NSMutableString"].contains(root) else { return nil }
        let prefix = data.prefix(min(data.count, 256))
        guard let name = prefix.range(of: Data("NSString".utf8)) else { return nil }
        let marker = Data([0x84, 1, 0x2b])
        let start = name.upperBound
        guard start < data.count,
              let field = data.range(of: marker, in: start..<min(data.count, start + 64)) else { return nil }
        offset = field.upperBound
        guard let length = integer(&offset), length <= 65_536, offset + length < bytes.count,
              bytes[offset + length] == 0x86 else { return nil }
        return String(bytes: bytes[offset..<offset + length], encoding: .utf8)
    }
}
