import Foundation
import Darwin
import PetCore

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

// Development commands deliberately do not use framed stdout. Chrome never passes these switches.
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

// Ignore broken pipe so a Chrome disconnect exits cleanly instead of a crash report.
signal(SIGPIPE, SIG_IGN)
do {
    while let payload = try NativeFrame.read(from: .standardInput) {
        do {
            guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let version = request["version"] as? Int, version == 1,
                  let type = request["type"] as? String else { throw PetError.invalid("request envelope") }
            if type == "ping" {
                try response(["version": 1, "type": "pong", "ok": true, "queueDepth": try queue.count(),
                    "appInstalled": FileManager.default.fileExists(atPath: config.appPath)])
            } else if type == "config" {
                guard Set(request.keys) == Set(["version", "type"]) else { throw PetError.invalid("configuration request") }
                // Re-read on every request: this connection may outlive edits made in the app.
                // SourcesConfig validates each comma-separated pair; no other contact data crosses this boundary.
                let selected = try SourcesConfig.load(paths: paths).instagram
                var instagram: Any = NSNull()
                if let selected { instagram = ["username": selected.username, "threadId": selected.threadId] }
                try response(["version": 1, "type": "config", "ok": true, "instagram": instagram])
            } else if type == "dm" {
                let event = try JSONDecoder().decode(PetEvent.self, from: payload)
                guard event.source == .instagram else { throw PetError.invalid("Chrome source") }
                let isNew = try queue.enqueue(event)
                try response(["version": 1, "type": "ack", "eventId": event.eventId, "ok": true, "queued": true])
                // A retry of an accepted event need not re-open the app after the user has quit it.
                if isNew { launchPetIfConfigured() }
            } else if type == "read" {
                guard request["source"] == nil || request["source"] as? String == "instagram" else { throw PetError.invalid("Chrome source") }
                // Only a validated thread URL is stored; the host's own clock decides what counts as read.
                guard let thread = request["threadUrl"] as? String, PetEvent.isThreadURL(thread) else { throw PetError.invalid("thread URL") }
                try queue.markRead(threadUrl: thread)
                try response(["version": 1, "type": "ack", "ok": true])
            } else { throw PetError.invalid("unsupported request type") }
        } catch {
            // Never echo untrusted JSON, sender, URL, message text, or decoder diagnostics.
            let reason = (error as? PetError)?.description ?? "invalid JSON/schema or local storage failure"
            try response(["version": 1, "type": "error", "ok": false, "error": reason])
            diagnostic(reason)
        }
    }
} catch {
    // A malformed/truncated frame loses stream alignment; close the port instead of guessing.
    diagnostic("framing/connection closed")
    exit(1)
}
