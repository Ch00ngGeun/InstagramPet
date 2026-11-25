import AppKit
import PetCore
import PetSources

// 말풍선을 누르면 해당 대화를 Chrome·메시지·카카오톡에서 열고 읽음 처리한다.

extension PetController {
    func openURLInChrome(_ url: URL) {
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { _, _ in }
        } else { NSWorkspace.shared.open(url) }
    }

    func openConversation(_ event: PetEvent) {
        guard let destination = event.destination(messagesHandle: sourceConfig.messages?.handle) else {
            lastError = "Conversation unavailable · check sources.json"
            updateStatus()
            return
        }
        switch destination {
        case .instagram(let url):
            openURLInChrome(url)
        case .messages(let url):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else {
                lastError = "Messages is not installed"
                updateStatus()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error == nil { self.markRead(event.conversation) }
                    else { self.lastError = "Could not open Messages"; self.updateStatus() }
                }
            }
            return
        case .kakao:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kakao.KakaoTalkMac") else {
                lastError = "KakaoTalk is not installed"
                updateStatus()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if error == nil { self.markRead(event.conversation) }
                    else { self.lastError = "Could not open KakaoTalk"; self.updateStatus() }
                }
            }
            return
        }
        if event.kind == "test" { dismissCurrent() } else { markRead(event.conversation) }
    }
}
