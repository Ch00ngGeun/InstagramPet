import Foundation
import Darwin
import PetCore

// Chrome 네이티브 메시징 호스트: 호출자가 설치된 확장 프로그램인지 확인하고, Instagram DM과 읽음 표시를
// 큐에 넣고, Instagram 연락처 선택을 알려 준다. 로컬용 --status/--demo/--clear 명령도 있다.

private func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data(("InstagramPet bridge: " + message + "\n").utf8))
}
private func response(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try NativeFrame.write(data, to: .standardOutput)
}

let paths = PetPaths()
let queue = EventQueue(paths: paths)
let arguments = Array(CommandLine.arguments.dropFirst())

// 개발용 명령은 일부러 프레임 없는 stdout을 쓴다. Chrome은 이 옵션을 넘기지 않는다.
if arguments.first == "--status" || arguments.first == "--demo" || arguments.first == "--clear" {
    do {
        try paths.prepare()
        switch arguments[0] {
        case "--demo":
            let event = PetEvent(eventId: "demo-" + UUID().uuidString, sender: "demo.pet", displayName: "Demo Pet",
                text: "연결 테스트 성공! Instagram 실수신이 아닌 로컬 데모입니다.",
                threadUrl: "https://www.instagram.com/direct/t/demo/", observedAt: PetEvent.timestamp(), kind: "test")
            try queue.enqueue(event)
            print("Local demo queued. Open InstagramPet.app to display it.")
        case "--clear":
            try queue.clear()
            print("Pending message content removed; content-free duplicate receipts retained for 24h.")
        default:
            print("Pending events: \(try queue.count()). Local queue: \(paths.inbox.path)")
        }
        exit(0)
    } catch { diagnostic(String(describing: error)); exit(1) }
}

var config: BridgeConfig

do {
    try paths.prepare()
    config = try BridgeConfig.load(paths: paths)
    guard config.extensionId.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
          arguments.first == "chrome-extension://\(config.extensionId)/" else {
        throw PetError.invalid("caller origin is not the installed Chrome extension")
    }
} catch {
    diagnostic("setup/caller check failed; run scripts/install.sh with the extension ID")
    exit(1)
}

var lastLaunch = Date.distantPast
var launcher: Process?

func launchPetIfConfigured() {
    guard config.autoLaunch, Date().timeIntervalSince(lastLaunch) > 10,
          config.appPath.hasPrefix("/"), config.appPath.hasSuffix(".app"),
          FileManager.default.fileExists(atPath: config.appPath) else { return }
    lastLaunch = Date()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", config.appPath]
    task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
    task.terminationHandler = { task in
        if task.terminationStatus != 0 { diagnostic("could not launch pet; open the installed app manually") }
    }
    do { try task.run(); launcher = task } catch { diagnostic("could not launch pet; open the installed app manually") }
}

// broken pipe를 무시해서, Chrome 연결이 끊기면 크래시 리포트 없이 깔끔하게 끝낸다.
signal(SIGPIPE, SIG_IGN)
do {
    // 명령줄 루프에는 autorelease된 Foundation 객체를 비워 줄 run loop가 없으므로, 요청마다
    // (stdin 읽기 포함) 자기 풀 안에서 돈다. 이게 없을 때 호스트는 메시지마다 8KB 읽기 버퍼 두 개를 남겨
    // 5초 간격 설정 동기화 5일 만에 1.4GB가 됐다.
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let payload = try NativeFrame.read(from: .standardInput) else { return false }
        do {
            guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let version = request["version"] as? Int, version == 1,
                  let type = request["type"] as? String else { throw PetError.invalid("request envelope") }
            if type == "ping" {
                try response(["version": 1, "type": "pong", "ok": true, "queueDepth": try queue.count(),
                    "appInstalled": FileManager.default.fileExists(atPath: config.appPath)])
            } else if type == "config" {
                guard Set(request.keys) == Set(["version", "type"]) else { throw PetError.invalid("configuration request") }
                // 요청마다 다시 읽는다: 이 연결은 앱에서 바꾼 설정보다 오래 살아 있을 수 있다.
                // SourcesConfig가 쉼표로 나뉜 쌍을 하나씩 검증한다. 다른 연락처 데이터는 이 경계를 넘지 않는다.
                let selected = try SourcesConfig.load(paths: paths).instagram
                var instagram: Any = NSNull()
                if let selected { instagram = ["username": selected.username, "threadId": selected.threadId] }
                try response(["version": 1, "type": "config", "ok": true, "instagram": instagram])
            } else if type == "dm" {
                let event = try JSONDecoder().decode(PetEvent.self, from: payload)
                guard event.source == .instagram else { throw PetError.invalid("Chrome source") }
                let isNew = try queue.enqueue(event)
                try response(["version": 1, "type": "ack", "eventId": event.eventId, "ok": true, "queued": true])
                // 이미 받은 이벤트의 재전송 때문에 사용자가 종료한 앱을 다시 열 필요는 없다.
                if isNew { launchPetIfConfigured() }
            } else if type == "read" {
                guard request["source"] == nil || request["source"] as? String == "instagram" else { throw PetError.invalid("Chrome source") }
                // 검증된 스레드 URL만 저장한다. 어디까지 읽었는지는 호스트 자신의 시계로 정한다.
                guard let thread = request["threadUrl"] as? String, PetEvent.isThreadURL(thread) else { throw PetError.invalid("thread URL") }
                try queue.markRead(threadUrl: thread)
                try response(["version": 1, "type": "ack", "ok": true])
            } else { throw PetError.invalid("unsupported request type") }
        } catch {
            // 믿을 수 없는 JSON, 보낸 사람, URL, 메시지 내용, 디코더 진단 메시지를 절대 되돌려 보내지 않는다.
            let reason = (error as? PetError)?.description ?? "invalid JSON/schema or local storage failure"
            try response(["version": 1, "type": "error", "ok": false, "error": reason])
            diagnostic(reason)
        }
        return true
    }) {}
} catch {
    // 잘못됐거나 잘린 프레임은 스트림 위치를 잃게 하므로, 추측하지 말고 포트를 닫는다.
    diagnostic("framing/connection closed")
    exit(1)
}
