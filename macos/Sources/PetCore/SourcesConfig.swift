import Foundation
import Darwin

// 사용자의 연락처 선택(sources.json): 검증, 비공개 원자적 저장, Messages 핸들
// 정규화, 그리고 말풍선을 눌렀을 때 열 대화 위치.

/// 연락처 선택은 사용자의 비공개 sources.json에 있다. 확장 프로그램에는 Instagram만 넘긴다.
public struct SourcesConfig: Codable, Equatable {
    public struct Instagram: Codable, Equatable {
        public let username: String
        public let threadId: String
        public init(username: String, threadId: String) { self.username = username; self.threadId = threadId }
    }
    public struct Kakao: Codable, Equatable {
        public let name: String
        public init(name: String) { self.name = name }
    }
    public struct Messages: Codable, Equatable {
        public let handle: String
        public init(handle: String) { self.handle = handle }
    }
    public var kakao: Kakao?
    public var messages: Messages?
    /// 값이 없으면 확장 프로그램의 수동 설정을 따르고, 빈 쌍이면 Instagram을 명시적으로 끈다.
    public var instagram: Instagram?
    public init(kakao: Kakao? = nil, messages: Messages? = nil, instagram: Instagram? = nil) {
        self.kakao = kakao; self.messages = messages; self.instagram = instagram
    }

    /// 기존 단일 값 JSON 필드와 호환된다. 여러 개 선택은 표준 ASCII 쉼표로 구분한다.
    public var instagramSelections: [Instagram] {
        guard let value = try? validated(), let selected = value.instagram, !selected.username.isEmpty else { return [] }
        return zip(selected.username.components(separatedBy: ","), selected.threadId.components(separatedBy: ","))
            .map { Instagram(username: $0.0, threadId: $0.1) }
    }
    public var messageHandles: [String] {
        guard let value = try? validated(), let selected = value.messages else { return [] }
        return selected.handle.components(separatedBy: ",")
    }
    public var kakaoNames: [String] {
        guard let value = try? validated(), let selected = value.kakao else { return [] }
        return selected.name.components(separatedBy: ",")
    }

    private static let maximumBytes = 16_384
    public static let maximumSelections = 100

    private static func selections(_ input: String, reason: String) throws -> [String] {
        guard input.utf8.count <= maximumBytes else { throw PetError.invalid(reason) }
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let values = clean.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard values.count <= maximumSelections, values.allSatisfy({ !$0.isEmpty }) else { throw PetError.invalid(reason) }
        return values
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func rootDirectory(paths: PetPaths, create: Bool) throws -> Int32 {
        if create { try paths.prepare() }
        let fd = Darwin.open(paths.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            if !create && errno == ENOENT { return -1 }
            throw PetError.io("cannot open sources directory")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(fd); throw PetError.io("unsafe sources directory")
        }
        return fd
    }

    private static func checkDestination(_ directory: Int32) throws {
        var info = stat()
        if fstatat(directory, "sources.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
                throw PetError.io("unsafe sources configuration")
            }
        } else if errno != ENOENT { throw PetError.io("cannot inspect sources configuration") }
    }

    public static func load(paths: PetPaths) throws -> SourcesConfig {
        let directory = try rootDirectory(paths: paths, create: false)
        guard directory >= 0 else { return SourcesConfig() }
        defer { Darwin.close(directory) }
        let fd = openat(directory, "sources.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return SourcesConfig() }
            throw PetError.io("cannot read sources configuration")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { Darwin.close(fd); throw PetError.io("unsafe sources configuration") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: maximumBytes + 1 - data.count), !part.isEmpty {
            data.append(part)
            guard data.count <= maximumBytes else { throw PetError.io("unsafe sources configuration") }
        }
        let value: SourcesConfig
        do { value = try JSONDecoder().decode(SourcesConfig.self, from: data) }
        catch { throw PetError.invalid("sources configuration") }
        return try value.validated()
    }

    /// 파일을 바꾸기 전에 전부 검증해서, 실패한 수정이 선택을 일부만 바꾸는 일이 없게 한다.
    public func validated() throws -> SourcesConfig {
        var value = self
        if let name = value.kakao?.name {
            let names = try Self.selections(name, reason: "Kakao contact configuration").map { item -> String in
                let clean = item.precomposedStringWithCanonicalMapping
                guard clean.count <= 100, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw PetError.invalid("Kakao contact configuration")
                }
                return clean
            }
            value.kakao = names.isEmpty ? nil : Kakao(name: Self.unique(names).joined(separator: ","))
        }
        if let handle = value.messages?.handle {
            let handles = try Self.selections(handle, reason: "Messages contact configuration").map { item -> String in
                guard let normalized = Self.normalizeHandle(item) else { throw PetError.invalid("Messages contact configuration") }
                return normalized
            }
            value.messages = handles.isEmpty ? nil : Messages(handle: Self.unique(handles).joined(separator: ","))
        }
        if let instagram = value.instagram {
            let names = try Self.selections(instagram.username, reason: "Instagram contact configuration")
            let threads = try Self.selections(instagram.threadId, reason: "Instagram contact configuration")
            if names.isEmpty && threads.isEmpty { value.instagram = Instagram(username: "", threadId: "") }
            else {
                guard names.count == threads.count, Set(threads).count == threads.count else {
                    throw PetError.invalid("Instagram contact configuration")
                }
                let usernames = try names.map { item -> String in
                    var username = item.lowercased()
                    if username.hasPrefix("@") { username.removeFirst() }
                    guard username.range(of: "^[a-z0-9._]{1,30}$", options: .regularExpression) != nil else {
                        throw PetError.invalid("Instagram contact configuration")
                    }
                    return username
                }
                guard threads.allSatisfy({ (1...128).contains($0.utf8.count) && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else {
                    throw PetError.invalid("Instagram contact configuration")
                }
                value.instagram = Instagram(username: usernames.joined(separator: ","), threadId: threads.joined(separator: ","))
            }
        }
        return value
    }

    /// 고정된(심볼릭 링크를 따르지 않는) 디렉터리를 통한 비공개 원자적 교체. 평문 임시 사본이 남지 않는다.
    public func save(paths: PetPaths) throws {
        let value = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value); data.append(0x0a)
        guard data.count <= Self.maximumBytes else { throw PetError.invalid("sources configuration size") }
        let directory = try Self.rootDirectory(paths: paths, create: true)
        defer { Darwin.close(directory) }
        try Self.checkDestination(directory)
        let staged = ".sources-" + UUID().uuidString
        let fd = openat(directory, staged, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PetError.io("cannot create sources configuration") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directory, staged, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw PetError.io("cannot protect sources configuration") }
        do { try handle.write(contentsOf: data); try handle.synchronize() }
        catch { throw PetError.io("cannot write sources configuration") }
        try Self.checkDestination(directory)
        guard renameat(directory, staged, directory, "sources.json") == 0 else {
            throw PetError.io("cannot commit sources configuration")
        }
        // 파일은 이미 디스크에 기록됐다. 디렉터리 fsync는 거부하는 파일 시스템도 있어 최선 노력으로만 한다.
        _ = fsync(directory)
    }

    /// 한국 휴대폰 번호만 국내/국제 표기를 같게 본다. 다른 번호는 국가 번호를 그대로 둔다.
    public static func normalizeHandle(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") {
            guard value.count <= 254, value.range(of: "^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,63}$", options: .regularExpression) != nil else { return nil }
            return value
        }
        guard value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "+0123456789 ()-.").contains($0) }) else { return nil }
        var number = value.filter { "+0123456789".contains($0) }
        if number.hasPrefix("0082") { number = "+82" + number.dropFirst(4) }
        if number.hasPrefix("010"), number.count == 11 { number = "+82" + number.dropFirst() }
        let digits = number.hasPrefix("+") ? String(number.dropFirst()) : number
        guard (8...15).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return number
    }
}

public enum ConversationDestination: Equatable {
    case instagram(URL), kakao, messages(URL)
}

extension PetEvent {
    public func destination(messagesHandle: String? = nil) -> ConversationDestination? {
        guard (try? validate()) != nil else { return nil }
        switch source {
        case .instagram:
            return URL(string: kind == "test" ? "https://www.instagram.com/direct/inbox/" : threadUrl).map(ConversationDestination.instagram)
        case .kakao: return .kakao
        case .messages:
            guard let input = messagesHandle,
                  let selected = try? SourcesConfig(messages: .init(handle: input)).validated(),
                  let handle = selected.messageHandles.first(where: { ConversationKey.local(.messages, identifier: $0) == conversation }) else { return nil }
            var parts = URLComponents(); parts.scheme = "sms"; parts.path = handle
            return parts.url.map(ConversationDestination.messages)
        }
    }
}
