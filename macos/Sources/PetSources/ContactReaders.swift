import Foundation
import PetCore

/// A source can observe several selected contacts while retaining each contact's own baseline and outbox.
public final class ContactReaders: LocalSourceReader {
    public let source: PetSource
    private struct Entry {
        let identifier: String
        let reader: LocalSourceReader
    }
    private let entries: [Entry]
    private let ambiguousSelection: Bool

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
            // The factory is local code; a mismatched source still must not cross the source boundary.
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

    /// Emoji suffixes are optional for a single selection, so two aliases must not observe the same chat twice.
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
