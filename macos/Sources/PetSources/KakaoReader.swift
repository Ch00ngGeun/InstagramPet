import Foundation
import AppKit
import ApplicationServices
import PetCore

// KakaoTalk 채팅 목록 리더: 손쉬운 사용(AX)으로 KakaoTalk 창을 읽고, 선택한 연락처의 행
// (미리보기, 시간, 안 읽음 배지)을 미리보기 이벤트와 읽음 표시로 바꾼다.

/// 크기가 제한된 메모리 속 손쉬운 사용 데이터. 실제로는 KakaoTalk 프로세스만 캡처한다.
/// 공개 값 모델이라 손쉬운 사용 권한 없이도 합성 데이터로 파서를 테스트할 수 있다.
public struct KakaoAXNode {
    public let role: String
    public let value: String?
    public let title: String?
    public let label: String?
    public let identifier: String?
    public let frame: CGRect?
    public let children: [KakaoAXNode]
    public let complete: Bool
    public init(role: String, value: String? = nil, title: String? = nil, label: String? = nil,
                identifier: String? = nil, frame: CGRect? = nil, children: [KakaoAXNode] = [], complete: Bool = true) {
        self.role = role; self.value = value; self.title = title; self.label = label
        self.identifier = identifier; self.frame = frame; self.children = children; self.complete = complete
    }
}

public enum KakaoCapture {
    case permissionRequired, idle, unavailable
    case snapshot(pid: Int32, root: KakaoAXNode)
}

public struct KakaoCaptureMetrics {
    public let milliseconds: Double
    public let nodes: Int
    public let deadlineExceeded: Bool
}

/// 채팅 목록 미리보기는 일부러 완전한 메시지 기록으로 취급하지 않는다.
/// 모든 상태와 호출은 앱의 직렬 I/O 큐에서만 다룬다. 이 리더는 AX 동작(클릭 등)을 하지 않는다.
public final class KakaoReader: LocalSourceReader {
    public let source = PetSource.kakao
    private struct Row {
        let preview: String
        let time: String
        let clockTime: Bool
        let unread: Int
        let layout: String
        var zeroSignature: String { preview + "\n" + time + "\n" + layout }
    }
    private enum Parsed { case row(Row), missing, invalid }
    private let name: String?
    private let conversation: ConversationKey?
    private let capture: () -> KakaoCapture
    private var previous: (pid: Int32, row: Row)?
    private var lastSnapshotAt: Date?
    private var zeroCandidate: (signature: String, count: Int)?
    private var confirmedZero: String?
    private var badgeBaseline: (signature: String, unread: Int)?
    private var badgeCandidate: (signature: String, unread: Int, observedAt: Date)?
    private var outbox: [String: PetEvent] = [:]
    private var readThrough: Date?

    public init(name: String?, capture: (() -> KakaoCapture)? = nil,
                captureMetrics: ((KakaoCaptureMetrics) -> Void)? = nil) {
        let clean = name.map(Self.normalize)
        self.name = clean.flatMap { value in
            !value.isEmpty && value.count <= 100 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? value : nil
        }
        self.conversation = self.name.map { ConversationKey.local(.kakao, identifier: $0) }
        let selectedName = self.name
        self.capture = capture ?? { Self.systemCapture(names: selectedName.map { [$0] } ?? [], report: captureMetrics) }
    }

    public func acknowledge(_ identities: Set<String>) {
        for identity in identities { outbox.removeValue(forKey: identity) }
    }

    public func poll(now: Date = Date()) -> SourcePoll {
        guard let name, let conversation else { return SourcePoll(status: .disabled) }
        // 이 outbox에는 우리가 만든 표준 UTC 타임스탬프만 있으므로 문자열로 바로 비교한다.
        let expiry = PetEvent.timestamp(now.addingTimeInterval(-12 * 60 * 60))
        outbox = outbox.filter { $0.value.observedAt >= expiry }
        switch capture() {
        case .permissionRequired:
            gap()
            return batch(.permissionRequired)
        case .idle:
            gap()
            return batch(.idle)
        case .unavailable:
            interrupted(at: now)
            return batch(.unavailable)
        case .snapshot(let pid, let root):
            switch Self.parse(root, name: name) {
            case .missing:
                gap()
                return batch(.idle)
            case .invalid:
                interrupted(at: now)
                return batch(.unavailable)
            case .row(let row):
                if let previous {
                    let elapsed = lastSnapshotAt.map { now.timeIntervalSince($0) } ?? .infinity
                    if previous.pid != pid || elapsed < 0 || elapsed > 3 { gap() }
                }
                lastSnapshotAt = now
                if row.unread == 0 {
                    badgeCandidate = nil
                    if confirmedZero != row.zeroSignature {
                        let count = zeroCandidate?.signature == row.zeroSignature ? (zeroCandidate?.count ?? 0) + 1 : 1
                        zeroCandidate = (row.zeroSignature, count)
                        if count >= 2 {
                            readThrough = max(readThrough ?? .distantPast, now)
                            outbox.removeAll()
                            confirmedZero = row.zeroSignature
                            zeroCandidate = nil
                            badgeBaseline = (row.zeroSignature, 0)
                        }
                    }
                } else {
                    confirmedZero = nil
                    zeroCandidate = nil
                }
                guard let old = previous, old.pid == pid else {
                    previous = (pid, row)
                    return batch(.observing)
                }
                let changed = old.row.preview != row.preview
                    || (old.row.clockTime && row.clockTime && old.row.time != row.time)
                var observation: Date?
                if row.unread > 0 {
                    if changed {
                        observation = now
                    } else if let baseline = badgeBaseline, baseline.signature == row.zeroSignature {
                        if row.unread > baseline.unread {
                            if let candidate = badgeCandidate, candidate.signature == row.zeroSignature,
                               candidate.unread == row.unread {
                                observation = candidate.observedAt
                            } else {
                                badgeCandidate = (row.zeroSignature, row.unread, now)
                            }
                        } else {
                            // 개수가 잠깐 줄었다가 다시 늘어도 새 메시지로 치면 안 된다.
                            badgeCandidate = nil
                        }
                    } else {
                        badgeCandidate = nil
                        // 완전한 관측이 두 번 일치한 뒤에야 개수만으로 판단할 기준을 세운다.
                        // 처음 배지가 채워지는 것은 기준선일 뿐 알림이 아니다.
                        badgeBaseline = old.row.zeroSignature == row.zeroSignature && old.row.unread == row.unread
                            ? (row.zeroSignature, row.unread) : nil
                    }
                }
                if let observation {
                    // 가득 차면 이전 상태를 유지해서, 확인 응답 뒤에 최신 미리보기를 받아들일 수 있게 한다.
                    guard outbox.count < 200 else { return batch(.observing) }
                    let event = PetEvent(eventId: "kakao-" + UUID().uuidString, sender: "local.kakao", displayName: "KakaoTalk",
                                         text: String(row.preview.prefix(2000)), threadUrl: conversation.key,
                                         observedAt: PetEvent.timestamp(observation), kind: "inbox-preview", source: .kakao)
                    if (try? event.validate()) != nil {
                        outbox[event.identity] = event
                        badgeBaseline = (row.zeroSignature, row.unread)
                        badgeCandidate = nil
                    }
                }
                previous = (pid, row)
                return batch(.observing)
            }
        }
    }

    private func gap() {
        previous = nil; lastSnapshotAt = nil; zeroCandidate = nil; confirmedZero = nil
        badgeBaseline = nil; badgeCandidate = nil
    }

    private func interrupted(at now: Date) {
        zeroCandidate = nil; badgeCandidate = nil
        // 짧은 AX 시간 초과 때문에 성공한 재시도마다 기준선을 새로 잡으면 안 된다.
        // 확인 후보는 실패한 캡처를 넘어가지 않는다. 마지막 완전한 행만 남는다.
        guard let lastSnapshotAt, (0...3).contains(now.timeIntervalSince(lastSnapshotAt)) else {
            gap()
            return
        }
    }

    private func batch(_ status: SourceStatus) -> SourcePoll {
        let events = outbox.values.sorted {
            $0.observedAt == $1.observedAt ? $0.identity < $1.identity : $0.observedAt < $1.observedAt
        }
        let reads = conversation.flatMap { conversation in readThrough.map { [conversation: $0] } } ?? [:]
        return SourcePoll(events: events, reads: reads, status: status)
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 글자 접두사만으로는 부족하다: 접미사는 실제 이모지 문자만 허용한다.
    public static func nameMatches(_ candidate: String, configured: String) -> Bool {
        let value = normalize(candidate), wanted = normalize(configured)
        guard !wanted.isEmpty, value.hasPrefix(wanted) else { return false }
        let suffix = value.dropFirst(wanted.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.allSatisfy { character in
            let scalars = Array(character.unicodeScalars)
            return scalars.contains { $0.properties.isEmoji && !$0.properties.isEmojiModifier && $0.value > 0x7f }
                && scalars.allSatisfy { ($0.properties.isEmoji && $0.value > 0x7f) || $0.properties.isEmojiModifier || $0.value == 0xfe0f || $0.value == 0x200d }
        }
    }

    private static let lists: Set<String> = ["AXTable", "AXOutline", "AXList"]
    private static let rows: Set<String> = ["AXRow", "AXGroup", "AXCell", "AXButton"]

    private static func plain(_ node: KakaoAXNode) -> String? {
        [node.value, node.title].compactMap { $0 }.map(normalize).first(where: { !$0.isEmpty })
    }

    private static func valid(_ frame: CGRect?) -> CGRect? {
        guard let frame, frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private static func parse(_ root: KakaoAXNode, name: String) -> Parsed {
        var count = 0, complete = true
        func check(_ node: KakaoAXNode, depth: Int) {
            count += 1
            if !node.complete || count > 500 || depth > 14 { complete = false; return }
            for child in node.children { check(child, depth: depth + 1) }
        }
        check(root, depth: 0)
        guard complete else { return .invalid }
        var candidates: [(KakaoAXNode, CGRect)] = []
        func collectRows(_ node: KakaoAXNode, in area: CGRect) {
            for child in node.children {
                if child.role == "AXRow" { candidates.append((child, area)) }
                else if rows.contains(child.role) {
                    if child.children.contains(where: { $0.role == "AXRow" }) { collectRows(child, in: area) }
                    else { candidates.append((child, area)) }
                }
            }
        }
        func findLists(_ node: KakaoAXNode, window: CGRect) {
            if lists.contains(node.role) {
                guard let frame = valid(node.frame), window.intersects(frame) else { return }
                collectRows(node, in: frame.intersection(window))
                return
            }
            let viewport = node.role == "AXScrollArea" ? valid(node.frame).map { window.intersection($0) } ?? window : window
            for child in node.children { findLists(child, window: viewport) }
        }
        func findWindows(_ node: KakaoAXNode) {
            if node.role == "AXWindow" {
                guard let title = node.title.map(normalize), ["KakaoTalk", "카카오톡"].contains(title), let frame = valid(node.frame) else { return }
                findLists(node, window: frame)
                return
            }
            for child in node.children { findWindows(child) }
        }
        findWindows(root)
        func leaves(_ node: KakaoAXNode) -> [KakaoAXNode] {
            if node.role == "AXStaticText" || node.role == "AXTextArea" { return [node] }
            // 프로필 버튼과 선택적인 상태/고정 이미지에는 설명만 있고 메시지 본문은 없다.
            if node.role == "AXButton" || node.role == "AXImage" { return [] }
            return node.children.flatMap(leaves)
        }
        let matching = candidates.filter { candidate, _ in
            leaves(candidate).contains { plain($0).map { nameMatches($0, configured: name) } ?? false }
        }
        guard matching.count == 1, let (node, area) = matching.first else { return matching.isEmpty ? .missing : .invalid }
        guard let rowFrame = valid(node.frame), area.insetBy(dx: -1, dy: -1).contains(rowFrame), rowFrame.width >= 160, rowFrame.height >= 35 else { return .invalid }
        let fields = leaves(node)
        guard (3...5).contains(fields.count), fields.allSatisfy({ field in
            // Kakao의 두 줄 텍스트 영역은 74pt 행보다 4pt 아래로 삐져나온다.
            let bounds = rowFrame.insetBy(dx: -1, dy: field.role == "AXTextArea" ? -8 : -1)
            return plain(field) != nil && (valid(field.frame).map { bounds.contains($0) } ?? false)
        }) else { return .invalid }
        for (index, field) in fields.enumerated() {
            guard !fields.dropFirst(index + 1).contains(where: { $0.frame == field.frame }) else { return .invalid }
        }
        let groupHints = ([node.label, node.identifier] + fields.flatMap { [$0.label, $0.identifier] }).compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !["group chat", "openchat", "그룹", "단체", "오픈채팅"].contains(where: groupHints.contains) else { return .invalid }
        let names = fields.filter { plain($0).map { nameMatches($0, configured: name) } ?? false }
        guard names.count == 1, let nameField = names.first, let nameFrame = nameField.frame,
              nameFrame.minX < rowFrame.midX, nameFrame.midY < rowFrame.midY else { return .invalid }
        // 그룹 인원 수는 이름 옆에 있고, 안 읽음 배지는 오른쪽 아래에 있다.
        guard !fields.contains(where: { field in
            guard field.frame != nameFrame, field.role == "AXStaticText", let frame = field.frame,
                  let value = plain(field), value.range(of: "^[0-9]{1,5}$", options: .regularExpression) != nil else { return false }
            return frame.minX >= nameFrame.maxX - 2 && abs(frame.midY - nameFrame.midY) <= 6
        }) else { return .invalid }
        let times = fields.filter { field in
            guard let text = plain(field), let frame = field.frame else { return false }
            return timeKind(text) != nil && frame.minX >= max(rowFrame.midX, nameFrame.maxX + 4)
                && frame.midY <= nameFrame.maxY + 4
        }
        guard times.count == 1, let timeField = times.first, let timeFrame = timeField.frame, let time = plain(timeField) else { return .invalid }
        let previews = fields.filter { field in
            guard let frame = field.frame else { return false }
            return frame.minX <= nameFrame.minX + 32 && frame.midY > nameFrame.midY + 4
                && frame.minX < rowFrame.midX
        }
        guard previews.count == 1, let previewField = previews.first, let preview = plain(previewField),
              !preview.isEmpty, !preview.contains("\0") else { return .invalid }
        let extra = fields.filter { field in
            guard let frame = field.frame else { return true }
            return frame != nameFrame && frame != timeFrame && frame != previewField.frame
        }
        guard extra.count <= 1 else { return .invalid }
        var unread = 0
        if let badge = extra.first {
            guard let frame = badge.frame, frame.minX >= rowFrame.midX, frame.minY >= timeFrame.maxY - 2,
                  frame.width <= 64, frame.height <= 40, let value = plain(badge),
                  value.range(of: "^[0-9]{1,4}\\+?$", options: .regularExpression) != nil,
                  let number = Int(value.replacingOccurrences(of: "+", with: "")) else { return .invalid }
            unread = min(number, 10_000)
        }
        func relative(_ frame: CGRect) -> String {
            "\(Int((frame.minX - rowFrame.minX).rounded())),\(Int((frame.minY - rowFrame.minY).rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
        }
        let layout = [nameFrame, timeFrame, previewField.frame!].map(relative).joined(separator: "|")
        return .row(Row(preview: preview, time: time, clockTime: timeKind(time) == true, unread: unread, layout: layout))
    }

    /// 경과 시간 표시는 새 메시지 없이도 바뀐다. 날짜 표시는 반복 메시지의 근거로 쓰지 않는다.
    private static func timeKind(_ value: String) -> Bool? {
        if value.range(of: "^(?:(?:오전|오후)\\s*(?:[1-9]|1[0-2])|(?:[01]?[0-9]|2[0-3])):[0-5][0-9]$", options: .regularExpression) != nil { return true }
        if ["오늘", "어제", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일"].contains(value) { return false }
        if value.range(of: "^(?:[0-9]{4}[./-]\\s*)?[0-9]{1,2}[./-]\\s*[0-9]{1,2}\\.?$", options: .regularExpression) != nil { return false }
        return nil
    }

    // MARK: KakaoTalk 전용 손쉬운 사용(AX) 어댑터

    private enum CaptureFailure: Error { case unavailable }
    private final class AXCapture {
        let pid: pid_t
        let names: [String]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        var count = 0
        var deadlineExceeded = false
        init(pid: pid_t, names: [String]) { self.pid = pid; self.names = names }

        func attribute(_ element: AXUIElement, _ name: String, optionalMetadata: Bool = false) throws -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { deadlineExceeded = true; throw CaptureFailure.unavailable }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
                  AXUIElementSetMessagingTimeout(element, 0.06) == .success else { throw CaptureFailure.unavailable }
            var result: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            if code == .attributeUnsupported || code == .noValue { return nil }
            // Kakao는 없는 선택적 설명에 noValue뿐 아니라 AXError.failure도 돌려준다.
            if optionalMetadata && code == .failure { return nil }
            guard code == .success else { throw CaptureFailure.unavailable }
            return result
        }
        func string(_ element: AXUIElement, _ name: String, optionalMetadata: Bool = false, truncate: Bool = false) throws -> String? {
            guard let value = try attribute(element, name, optionalMetadata: optionalMetadata) else { return nil }
            let string: String
            if let text = value as? String { string = text }
            else if name == kAXValueAttribute, let number = value as? NSNumber { string = number.stringValue }
            else { throw CaptureFailure.unavailable }
            if truncate { return String(string.prefix(4000)) }
            guard string.count <= 4000 else { throw CaptureFailure.unavailable }
            return string
        }

        /// 다른 행은 얕은 이름 필드만 읽는다. 그 행의 미리보기는 이 연락처에 영향을 줄 수 없다.
        func matchesName(_ element: AXUIElement, depth: Int = 0) throws -> Bool {
            count += 1
            guard count <= 500, depth <= 4, !names.isEmpty else { throw CaptureFailure.unavailable }
            guard let role = try string(element, kAXRoleAttribute) else { throw CaptureFailure.unavailable }
            if role == "AXStaticText" {
                return try string(element, kAXValueAttribute).map { value in names.contains { KakaoReader.nameMatches(value, configured: $0) } } ?? false
            }
            guard ["AXRow", "AXCell", "AXGroup"].contains(role) else { return false }
            for child in try elements(element, kAXChildrenAttribute) ?? [] {
                if try matchesName(child, depth: depth + 1) { return true }
            }
            return false
        }
        func elements(_ element: AXUIElement, _ name: String) throws -> [AXUIElement]? {
            guard let value = try attribute(element, name) else { return nil }
            guard let array = value as? [AXUIElement], array.count <= 100 else { throw CaptureFailure.unavailable }
            return array
        }
        func frame(_ element: AXUIElement) throws -> CGRect? {
            guard let position = try attribute(element, kAXPositionAttribute), let size = try attribute(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            let p = unsafeBitCast(position, to: AXValue.self), s = unsafeBitCast(size, to: AXValue.self)
            guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        func node(_ element: AXUIElement, depth: Int = 0, inList: Bool = false) throws -> KakaoAXNode {
            count += 1
            guard count <= 500, depth <= 14 else { throw CaptureFailure.unavailable }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success else { throw CaptureFailure.unavailable }
            if owner != pid {
                // 내장 광고는 WebKit 프로세스 소속일 수 있다. 그 하위 트리는 절대 들여다보지 않는다.
                guard !inList else { throw CaptureFailure.unavailable }
                return KakaoAXNode(role: "AXExcluded")
            }
            guard let role = try string(element, kAXRoleAttribute) else { throw CaptureFailure.unavailable }
            let list = KakaoReader.lists.contains(role)
            let structural: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXTabGroup", "AXTable", "AXOutline", "AXList"]
            if !inList && !structural.contains(role) { return KakaoAXNode(role: role) }
            let rect = try frame(element)
            if inList && role == "AXRow", !names.isEmpty, try !matchesName(element) {
                return KakaoAXNode(role: role, frame: rect)
            }
            if inList && ["AXButton", "AXImage"].contains(role) { return KakaoAXNode(role: role, frame: rect) }
            let children: [AXUIElement]
            if list {
                children = try elements(element, kAXVisibleRowsAttribute)
                    ?? elements(element, kAXVisibleChildrenAttribute)
                    ?? elements(element, kAXChildrenAttribute) ?? []
            } else { children = try elements(element, kAXChildrenAttribute) ?? [] }
            let nodes = try children.map { try node($0, depth: depth + 1, inList: inList || list) }
            if inList {
                let text = role == "AXStaticText" || role == "AXTextArea"
                return KakaoAXNode(role: role, value: text ? try string(element, kAXValueAttribute, truncate: role == "AXTextArea") : nil,
                                   title: text ? try string(element, kAXTitleAttribute, optionalMetadata: true) : nil,
                                   label: try string(element, kAXDescriptionAttribute, optionalMetadata: true),
                                   identifier: try string(element, kAXIdentifierAttribute, optionalMetadata: true),
                                   frame: rect, children: nodes)
            }
            return KakaoAXNode(role: role, title: role == "AXWindow" ? try string(element, kAXTitleAttribute) : nil, frame: rect, children: nodes)
        }
    }

    static func systemCapture(names: [String], report: ((KakaoCaptureMetrics) -> Void)? = nil) -> KakaoCapture {
        let started = ProcessInfo.processInfo.systemUptime
        var measured: AXCapture?
        defer {
            report?(KakaoCaptureMetrics(milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                nodes: measured?.count ?? 0, deadlineExceeded: measured?.deadlineExceeded ?? false))
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kakao.KakaoTalkMac").filter { !$0.isTerminated }
        guard !apps.isEmpty else { return .idle }
        guard apps.count == 1, let app = apps.first else { return .unavailable }
        guard AXIsProcessTrusted() else { return .permissionRequired }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let capture = AXCapture(pid: app.processIdentifier, names: names)
        measured = capture
        do {
            let windows = try capture.elements(application, kAXWindowsAttribute) ?? []
            guard !windows.isEmpty, windows.count <= 8 else { return .idle }
            var nodes: [KakaoAXNode] = []
            for window in windows {
                if (try capture.attribute(window, kAXMinimizedAttribute)) as? Bool == true { continue }
                nodes.append(try capture.node(window))
            }
            guard !nodes.isEmpty else { return .idle }
            return .snapshot(pid: app.processIdentifier, root: KakaoAXNode(role: "AXApplication", children: nodes))
        } catch { return .unavailable }
    }
}
