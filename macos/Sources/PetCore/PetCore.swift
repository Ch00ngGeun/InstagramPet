import Foundation
import CryptoKit
import Darwin

public enum PetError: Error, CustomStringConvertible {
    case invalid(String), io(String), queueFull
    public var description: String {
        switch self {
        case .invalid(let reason): return "invalid: \(reason)"
        case .io(let reason): return "local storage: \(reason)"
        case .queueFull: return "local queue full (200); open the pet app or clear its pending messages"
        }
    }
}

public struct PetEvent: Codable, Equatable {
    public let version: Int
    public let type: String
    public let eventId: String
    public let sender: String
    public let displayName: String?
    public let text: String
    public let threadUrl: String
    public let observedAt: String
    public let kind: String

    public init(version: Int = 1, type: String = "dm", eventId: String,
                sender: String, displayName: String? = nil, text: String,
                threadUrl: String, observedAt: String, kind: String) {
        self.version = version; self.type = type; self.eventId = eventId
        self.sender = sender; self.displayName = displayName; self.text = text
        self.threadUrl = threadUrl; self.observedAt = observedAt; self.kind = kind
    }

    public func validate() throws {
        guard version == 1, type == "dm" else { throw PetError.invalid("unsupported version/type") }
        guard Self.matches(eventId, "^[A-Za-z0-9._:-]{1,128}$") else { throw PetError.invalid("eventId") }
        guard Self.matches(sender, "^[a-z0-9._]{1,30}$") else { throw PetError.invalid("sender username") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 2000, !text.contains("\0") else { throw PetError.invalid("text") }
        guard (displayName?.count ?? 0) <= 100 else { throw PetError.invalid("displayName") }
        guard Self.isThreadURL(threadUrl) else { throw PetError.invalid("thread URL") }
        guard ["thread-message", "inbox-preview", "test"].contains(kind) else { throw PetError.invalid("kind") }
        guard let timestamp = Self.date(observedAt), timestamp.timeIntervalSinceNow <= 300 else {
            throw PetError.invalid("timestamp (ISO8601, no more than 5 minutes in the future)")
        }
    }

    public static func isThreadURL(_ value: String) -> Bool {
        matches(value, "^https://www\\.instagram\\.com/direct/t/[A-Za-z0-9_-]{1,128}/$")
    }

    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }
}

public struct PetPaths {
    public let root: URL
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var receipts: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    /// "Read" marks: one content-free file per thread the user looked at in Chrome.
    public var reads: URL { root.appendingPathComponent("reads", isDirectory: true) }
    public var config: URL { root.appendingPathComponent("config.json") }

    public init(root: URL? = nil) {
        // Override is for isolated automated tests/development; no network location is used.
        let override = ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"]
        self.root = root ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/InstagramPet", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [root, inbox, receipts, reads] {
            var info = stat()
            if lstat(directory.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                    throw PetError.io("unsafe directory owner/type")
                }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            guard chmod(directory.path, 0o700) == 0 else { throw PetError.io("cannot protect directory") }
        }
    }
}

public struct BridgeConfig: Codable {
    public let extensionId: String
    public let appPath: String
    public let autoLaunch: Bool
    public init(extensionId: String, appPath: String, autoLaunch: Bool = true) {
        self.extensionId = extensionId; self.appPath = appPath; self.autoLaunch = autoLaunch
    }
    public static func load(paths: PetPaths) throws -> BridgeConfig {
        try JSONDecoder().decode(BridgeConfig.self, from: Data(contentsOf: paths.config))
    }
}

public final class EventQueue {
    public let paths: PetPaths
    private let fileManager = FileManager.default
    private var lastCleanup = Date.distantPast
    public static let retention: TimeInterval = 24 * 60 * 60
    public static let capacity = 200
    public init(paths: PetPaths = PetPaths()) { self.paths = paths }

    /// Returns false for an already accepted event. Receipt ids contain no message content.
    @discardableResult public func enqueue(_ event: PetEvent) throws -> Bool {
        try event.validate()
        guard let observed = PetEvent.date(event.observedAt), Date().timeIntervalSince(observed) <= Self.retention else {
            throw PetError.invalid("event older than 24 hours")
        }
        return try locked {
            try cleanup()
            let filename = digest(event.eventId) + ".json"
            let receipt = paths.receipts.appendingPathComponent(filename)
            let destination = paths.inbox.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: receipt.path) || fileManager.fileExists(atPath: destination.path) { return false }
            guard try jsonFiles(paths.inbox).count < Self.capacity else { throw PetError.queueFull }
            let data = try JSONEncoder().encode(event)
            try atomicProtectedWrite(data, to: destination)
            // Inbox presence also deduplicates if the process crashes before the receipt write.
            try atomicProtectedWrite(Data("{\"acceptedAt\":\"\(PetEvent.timestamp())\"}".utf8), to: receipt)
            return true
        }
    }

    public func pending() throws -> [PetEvent] {
        try locked {
            try cleanup()
            var result: [PetEvent] = []
            for url in try jsonFiles(paths.inbox) {
                do {
                    let event = try JSONDecoder().decode(PetEvent.self, from: protectedRead(url))
                    try event.validate()
                    result.append(event)
                } catch {
                    // Corrupt/untrusted files never reach the UI. Delete only queue-owned regular files.
                    try? fileManager.removeItem(at: url)
                }
            }
            return result.sorted {
                let left = PetEvent.date($0.observedAt) ?? .distantPast
                let right = PetEvent.date($1.observedAt) ?? .distantPast
                return left == right ? $0.eventId < $1.eventId : left < right
            }
        }
    }

    public func consume(_ event: PetEvent) throws {
        try locked {
            let destination = paths.inbox.appendingPathComponent(digest(event.eventId) + ".json")
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        }
    }

    /// The user saw this thread in Chrome: remember when, and drop its not-yet-shown messages up to then.
    public func markRead(threadUrl: String, at date: Date = Date()) throws {
        guard PetEvent.isThreadURL(threadUrl) else { throw PetError.invalid("thread URL") }
        try locked {
            let mark = try JSONSerialization.data(withJSONObject: ["threadUrl": threadUrl, "readAt": PetEvent.timestamp(date)], options: [.sortedKeys])
            try atomicProtectedWrite(mark, to: paths.reads.appendingPathComponent(digest(threadUrl) + ".json"))
            for url in try jsonFiles(paths.inbox) {
                guard let event = try? JSONDecoder().decode(PetEvent.self, from: protectedRead(url)),
                      event.threadUrl == threadUrl, let observed = PetEvent.date(event.observedAt), observed <= date else { continue }
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// Latest read time per thread URL, within the 24h retention.
    public func reads() throws -> [String: Date] {
        try locked {
            try cleanup()
            var result: [String: Date] = [:]
            for url in try jsonFiles(paths.reads) {
                guard let object = (try? JSONSerialization.jsonObject(with: protectedRead(url))) as? [String: Any],
                      let thread = object["threadUrl"] as? String, PetEvent.isThreadURL(thread),
                      let at = (object["readAt"] as? String).flatMap(PetEvent.date) else { try? fileManager.removeItem(at: url); continue }
                result[thread] = max(at, result[thread] ?? .distantPast)
            }
            return result
        }
    }

    public func count() throws -> Int { try locked { try cleanup(); return try jsonFiles(paths.inbox).count } }

    /// Removes pending message content. Retains content-free receipts to suppress retries.
    public func clear() throws {
        try locked { for url in try jsonFiles(paths.inbox) { try fileManager.removeItem(at: url) } }
    }

    private func digest(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try paths.prepare()
        let lockPath = paths.root.appendingPathComponent(".queue.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError.io("cannot open queue lock") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              flock(fd, LOCK_EX) == 0 else { throw PetError.io("cannot lock queue") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func jsonFiles(_ directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func protectedRead(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PetError.io("cannot open file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= 65_536 else { Darwin.close(fd); throw PetError.io("unsafe queue file") }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
    }

    private func atomicProtectedWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError.io("cannot create queue file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fileManager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw PetError.io("cannot commit queue file") }
    }

    private func cleanup() throws {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) >= 30 else { return }
        lastCleanup = now
        for directory in [paths.inbox, paths.receipts, paths.reads] {
            for url in try jsonFiles(directory) {
                do {
                    let data = try protectedRead(url)
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let key = directory == paths.inbox ? "observedAt" : directory == paths.reads ? "readAt" : "acceptedAt"
                    let timestamp = object?[key] as? String
                    guard let timestamp, let date = PetEvent.date(timestamp), now.timeIntervalSince(date) <= Self.retention else {
                        try fileManager.removeItem(at: url); continue
                    }
                } catch { try? fileManager.removeItem(at: url) }
            }
        }
        // Bound content-free receipts under long sessions; pending inbox ids still deduplicate.
        let receipts = try jsonFiles(paths.receipts)
        if receipts.count > 4096 {
            let ordered = receipts.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
            for url in ordered.prefix(receipts.count - 4096) { try? fileManager.removeItem(at: url) }
        }
    }
}

/// Chrome native messaging frames are UInt32 native endian + UTF-8 JSON.
public enum NativeFrame {
    public static let maxBytes: UInt32 = 65_536
    public static func read(from input: FileHandle) throws -> Data? {
        guard let header = try exact(4, from: input, allowEOF: true) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length > 0, length <= maxBytes else { throw PetError.invalid("frame size") }
        guard let payload = try exact(Int(length), from: input, allowEOF: false) else { throw PetError.invalid("truncated frame") }
        return payload
    }
    public static func write(_ data: Data, to output: FileHandle) throws {
        guard data.count <= Int(maxBytes) else { throw PetError.invalid("response too large") }
        var length = UInt32(data.count)
        try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        try output.write(contentsOf: data)
    }
    private static func exact(_ count: Int, from handle: FileHandle, allowEOF: Bool) throws -> Data? {
        var data = Data()
        while data.count < count {
            let part = try handle.read(upToCount: count - data.count) ?? Data()
            if part.isEmpty {
                if allowEOF && data.isEmpty { return nil }
                throw PetError.invalid("truncated frame")
            }
            data.append(part)
        }
        return data
    }
}
