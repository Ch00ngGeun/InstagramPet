import Foundation
import PetCore

// 소스의 선택된 연락처마다 리더를 하나씩 돌리고 폴링 결과를 합친다. KakaoTalk 리더들은
// 폴링마다 손쉬운 사용(AX) 캡처 하나와 알림 DB 세션 하나를 함께 쓴다.

/// 한 소스가 여러 연락처를 지켜보면서도 연락처마다 자기 기준선과 outbox를 따로 유지한다.
public final class ContactReaders: LocalSourceReader {
    public let source: PetSource
    private struct Entry {
        let identifier: String
        let reader: LocalSourceReader
    }
    private let entries: [Entry]
    private let ambiguousSelection: Bool
    private var kakaoInputs: KakaoSharedInputs?

    /// Kakao 리더들을 함께 만들어서 비싼 입력을 폴링마다 공유할 수 있게 한다.
    public static func kakao(identifiers: [String], reusing previous: ContactReaders? = nil,
                             databaseURL: URL = KakaoNotificationReader.defaultDatabaseURL,
                             fallbackGrace: TimeInterval = 1,
                             capture: (([String]) -> KakaoCapture)? = nil,
                             databaseSessionOpened: (() -> Void)? = nil) -> ContactReaders {
        let reusable = previous?.kakaoInputs != nil ? previous : nil
        let inputs = reusable?.kakaoInputs ?? KakaoSharedInputs(databaseURL: databaseURL, capture: capture, opened: databaseSessionOpened)
        let readers = ContactReaders(source: .kakao, identifiers: identifiers, reusing: reusable) { name in
            KakaoCombinedReader(name: name,
                axReader: KakaoReader(name: name, capture: { inputs.snapshot() }),
                notificationReader: KakaoNotificationReader(name: name, database: inputs.database),
                fallbackGrace: fallbackGrace)
        }
        readers.kakaoInputs = inputs
        return readers
    }

    public init(source: PetSource, identifiers: [String], reusing previous: ContactReaders? = nil,
                makeReader: (String) -> LocalSourceReader) {
        self.source = source
        ambiguousSelection = source == .kakao && Self.hasAmbiguousKakaoNames(identifiers)
        guard !ambiguousSelection else { entries = []; return }
        let previousEntries = previous?.source == source ? previous?.entries ?? [] : []
        let reusable = Dictionary(uniqueKeysWithValues: previousEntries.map { ($0.identifier, $0.reader) })
        var selected = Set<String>(), entries: [Entry] = []
        for identifier in identifiers where !identifier.isEmpty && selected.insert(identifier).inserted {
            let reader = reusable[identifier] ?? makeReader(identifier)
            // 팩토리는 로컬 코드지만, 소스가 맞지 않으면 여전히 소스 경계를 넘으면 안 된다.
            guard reader.source == source else { continue }
            entries.append(Entry(identifier: identifier, reader: reader))
        }
        self.entries = entries
    }

    public func restorePending(_ events: [PetEvent]) {
        let ownEvents = events.filter { $0.source == source }
        for entry in entries { entry.reader.restorePending(ownEvents) }
    }

    public func acknowledge(_ identities: Set<String>) {
        for entry in entries { entry.reader.acknowledge(identities) }
    }

    public func poll(now: Date) -> SourcePoll {
        guard !ambiguousSelection else { return SourcePoll(status: .unavailable) }
        kakaoInputs?.beginPoll(names: entries.map(\.identifier))
        defer { kakaoInputs?.endPoll() }
        var events: [PetEvent] = [], reads: [ConversationKey: Date] = [:], statuses: [SourceStatus] = []
        for entry in entries {
            let batch = entry.reader.poll(now: now)
            statuses.append(batch.status)
            events.append(contentsOf: batch.events.filter { $0.source == source })
            for (conversation, at) in batch.reads where conversation.source == source {
                reads[conversation] = max(reads[conversation] ?? .distantPast, at)
            }
        }
        var timed: [(event: PetEvent, at: Date)] = events.map { event in
            (event, PetEvent.date(event.observedAt) ?? Date.distantPast)
        }
        timed.sort { first, second in
            if first.at == second.at { return first.event.identity < second.event.identity }
            return first.at < second.at
        }
        let ordered = timed.map { $0.event }
        return SourcePoll(events: ordered, reads: reads, status: Self.aggregate(statuses))
    }

    public var accessibilityStatus: SourceStatus {
        guard source == .kakao else { return .disabled }
        guard !ambiguousSelection else { return .unavailable }
        return Self.aggregate(entries.compactMap { ($0.reader as? KakaoCombinedReader)?.accessibilityStatus })
    }

    public var notificationStatus: SourceStatus {
        guard source == .kakao else { return .disabled }
        guard !ambiguousSelection else { return .unavailable }
        return Self.aggregate(entries.compactMap { ($0.reader as? KakaoCombinedReader)?.notificationStatus })
    }

    /// 이모지 접미사는 있어도 없어도 맞으므로, 두 별칭이 같은 채팅을 두 번 지켜보면 안 된다.
    public static func hasAmbiguousKakaoNames(_ names: [String]) -> Bool {
        for first in names.indices {
            for second in names.indices where second > first {
                if KakaoReader.nameMatches(names[first], configured: names[second]) ||
                    KakaoReader.nameMatches(names[second], configured: names[first]) { return true }
            }
        }
        return false
    }

    private static func aggregate(_ statuses: [SourceStatus]) -> SourceStatus {
        for status in [SourceStatus.observing, .permissionRequired, .unavailable, .idle] where statuses.contains(status) {
            return status
        }
        return .disabled
    }
}

/// 범위는 실제 시각이 아니라 ContactReaders.poll 호출 단위다. 연속된 폴링이 같은 Date를 가질 수 있다.
/// 공유하는 것은 입력 스냅숏뿐이다. 각 하위 리더는 자기 기준선, 재시도, 읽음 상태를 따로 가진다.
private final class KakaoSharedInputs {
    let database: KakaoNotificationDatabase
    private let capture: ([String]) -> KakaoCapture
    private var names: [String] = []
    private var captured: KakaoCapture?

    init(databaseURL: URL, capture: (([String]) -> KakaoCapture)?, opened: (() -> Void)?) {
        database = KakaoNotificationDatabase(url: databaseURL, opened: opened)
        self.capture = capture ?? { KakaoReader.systemCapture(names: $0) }
    }

    func beginPoll(names: [String]) {
        self.names = names; captured = nil
        database.beginPoll()
    }
    func endPoll() {
        captured = nil; names = []
        database.endPoll()
    }
    func snapshot() -> KakaoCapture {
        if let captured { return captured }
        let result = capture(names)
        captured = result
        return result
    }
}
