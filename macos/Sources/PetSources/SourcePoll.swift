import Foundation
import PetCore

public enum SourceStatus: String {
    case disabled, idle, observing, permissionRequired, unavailable
}

public protocol LocalSourceReader: AnyObject {
    var source: PetSource { get }
    func restorePending(_ events: [PetEvent])
    func poll(now: Date) -> SourcePoll
    func acknowledge(_ identities: Set<String>)
}

extension LocalSourceReader {
    public func restorePending(_ events: [PetEvent]) {}
}

public struct SourcePoll {
    public let events: [PetEvent]
    public let reads: [ConversationKey: Date]
    public let status: SourceStatus
    public init(events: [PetEvent] = [], reads: [ConversationKey: Date] = [:], status: SourceStatus) {
        self.events = events; self.reads = reads; self.status = status
    }
}
