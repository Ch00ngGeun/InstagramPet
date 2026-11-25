import AppKit
import PetCore
import PetSources

// 앱 델리게이트: 공유 상태, 실행 플래그 분기, 펫 패널과 말풍선 오버레이 생성.
// 나머지 동작은 PetController+*.swift 확장에 나뉘어 있다.

final class PetController: NSObject, NSApplicationDelegate {
    /// 숨기기는 늘 잠시뿐이다: 여자친구는 언제나 다시 관심받아야 하니까.
    static let hideMinutes = [10, 20, 30, 40, 50, 60]
    /// 펫은 늘 화면 안에 완전히 머문다. 가장자리에 밀면 찌그러지고, 모서리에서만 숨는다.
    static let keepVisible: CGFloat = .infinity
    /// 놓을 때 모서리의 두 벽에 이만큼 깊이 눌려 있으면 펫이 화살표 뒤로 들어간다.
    static let cornerPress: CGFloat = 30
    let paths = PetPaths()
    var sourceConfig = SourcesConfig()
    var settingsWindow: SourcesSettingsWindowController?
    var settingsOpening = false
    var sourceConfigError: String?
    var localReaders: [LocalSourceReader] = [] // 실행 뒤에는 직렬 I/O 큐에서만 접근한다
    var lastSourcesPoll = Date.distantPast
    var sourceStatuses: [PetSource: SourceStatus] = [:]
    var kakaoAccessibilityStatus = SourceStatus.disabled
    var kakaoNotificationStatus = SourceStatus.disabled
    struct ReaderStatuses {
        var sources: [PetSource: SourceStatus] = [:]
        var accessibility = SourceStatus.disabled
        var notifications = SourceStatus.disabled
    }
    var sourceStatusItems: [PetSource: NSMenuItem] = [:]
    var permissionNotices = Set<PetSource>()
    var queue: EventQueue!
    var panel: PetPanel!       // 캐릭터
    var overlay: PetPanel!     // 화면 크기의, 클릭이 통과하는 말풍선·화살표 층
    var bubble: BubbleField!
    var arrow: HideArrow!
    var cat: CatView!
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var showNowItem: NSMenuItem!
    private var animationTimer: Timer?
    private var pollTimer: Timer?
    var pending: [PetEvent] = []
    var current: PetEvent?
    var recent: [PetEvent] = [] // `current` 앞에 보여 준 메시지들(최대 11개, 오래된 순)
    var readMarks: [ConversationKey: Date] = [:]
    var knownIDs = Set<String>()
    var knownOrder: [String] = []
    var queueGeneration = 0
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    var pollInFlight = false
    var hidePetUntil: Date?
    var hideBubblesUntil: Date?
    var isHidden: Bool { hidePetUntil != nil }
    /// 모서리에 눌러 놓으면 펫은 화살표 뒤로 들어가지만 말풍선은 계속 온다(그 가장자리에 모인다).
    /// 늦어도 한 시간 뒤엔 다시 나온다. 무엇도 무기한 숨지 않는다.
    var tuckedUntil: Date?
    var isTucked: Bool { tuckedUntil != nil }
    static let tuckMinutes = 60
    var paused: Bool { hideBubblesUntil != nil }
    var arrowKey = ""
    var lastCatOrigin = NSPoint.zero
    var tuckArrowCenter: NSPoint?
    var petTarget: NSPoint?
    var petDragArea: NSRect?
    var overPet = false
    var lastPress: (left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat) = (0, 0, 0, 0)
    var arrowDragStart: (panel: NSPoint, arrow: NSPoint)?
    var lastError: String?
    let io = DispatchQueue(label: "com.instagrampet.queue", qos: .userInitiated)
    var smokeReport: URL?
    var smokeFinishing = false
    var smokeBurstCount: Int?
    var smokeBurstSamples: [[Double]] = []
    var smokeNotificationMode = false
    var previewMode = false

    let characterMenu = NSMenu()
    /// 미리보기 전용: nil이면 기본 예시, 아니면 (카카오, 인스타그램, 메시지) 개수만큼 시간 순으로 섞는다.
    var fullDesk: (Int, Int, Int)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-settings"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkSettings(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-pet-geometry"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkPetGeometry(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-bubble-geometry"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkBubbleGeometry(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-idle-render"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkBubbleGeometry(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), requireIdle: true)
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--measure-live-ax") {
            previewMode = true
            measureLiveAccessibility()
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-source-reads"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkSourceReads(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-source-failures"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            checkSourceFailures(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-scenarios"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            renderScenarios(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > flag + 1 {
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            if CommandLine.arguments.contains("--start-hidden") { // 새 메시지가 시간제 숨기기를 끝내는지 확인
                hidePetUntil = Date().addingTimeInterval(600); hideBubblesUntil = Date().addingTimeInterval(600)
            }
            if CommandLine.arguments.contains("--start-tucked") { // 메시지가 오면 펫이 아니라 말풍선이 돌아와야 한다
                tuckedUntil = Date().addingTimeInterval(600); hideBubblesUntil = Date().addingTimeInterval(600)
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-burst-latency"), CommandLine.arguments.count > flag + 2 {
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            smokeBurstCount = max(1, min(100, Int(CommandLine.arguments[flag + 2]) ?? 5))
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-notification-latency"), CommandLine.arguments.count > flag + 2 {
            guard ProcessInfo.processInfo.environment["INSTAGRAMPET_HOME"] != nil else {
                previewMode = true; NSApplication.shared.terminate(nil); return
            }
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            smokeBurstCount = max(1, min(100, Int(CommandLine.arguments[flag + 2]) ?? 5))
            smokeNotificationMode = true
        }
        queue = EventQueue(paths: paths)
        do { try paths.prepare() }
        catch { lastError = "Cannot open private queue" }
        if smokeReport == nil {
            do { sourceConfig = try SourcesConfig.load(paths: paths) }
            catch { sourceConfigError = "Sources configuration unavailable · check sources.json" }
            localReaders = [makeContactReaders(.messages, config: sourceConfig), makeContactReaders(.kakao, config: sourceConfig)]
        } else if smokeNotificationMode {
            localReaders = [KakaoNotificationReader(name: "Fixture Friend", databaseURL: paths.root.appendingPathComponent("notification-fixture.db"))]
        }
        buildPanel()
        buildMenu()
        // 자체 메뉴 막대가 없으므로, 입력란에서 ⌘C/⌘V/⌘X/⌘A/⌘Z가 되려면 이 숨은 편집 메뉴가 필요하다.
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let main = NSMenu(), editItem = NSMenuItem()
        editItem.submenu = edit; main.addItem(NSMenuItem()); main.addItem(editItem); NSApp.mainMenu = main // 첫 항목은 앱 메뉴
        if smokeReport == nil { overlay.orderFrontRegardless(); panel.orderFrontRegardless() }
        else { statusItem.isVisible = false }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkHideExpiry()
            if !self.isHidden && !self.isTucked {
                self.cat.phase += 0.12
                if self.paused { self.cat.excited = !self.pending.isEmpty } // 일시정지 뒤에서 메시지가 기다리는 중
                self.followPet(step: 0.3)
                let origin = self.panel.frame.origin
                self.cat.shake(by: NSPoint(x: origin.x - self.lastCatOrigin.x, y: origin.y - self.lastCatOrigin.y))
                self.updatePetArea()
                self.lastCatOrigin = origin
                self.cat.needsDisplay = true
            }
            self.layoutOverlay(animated: true)
            self.updateClickThrough()
        }
        // 펫은 포커스를 가져가지 않으므로, 백그라운드 앱인 채로 펫 위에 펼친 손 커서를 보여 줄 수 있게 한다.
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updateClickThrough() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateClickThrough(); return event
        }
        updateClickThrough()
        pollTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(pollTimer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        poll()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if smokeReport != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishSmokeTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if smokeReport == nil, !previewMode { persistPosition() }
        animationTimer?.invalidate(); pollTimer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    private func makePanel(_ frame: NSRect) -> PetPanel {
        let result = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        result.title = "Instagram Pet"
        result.level = .floating
        result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        result.backgroundColor = .clear
        result.isOpaque = false
        result.hasShadow = false
        result.hidesOnDeactivate = false
        result.isReleasedWhenClosed = false
        result.animationBehavior = .none
        result.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        return result
    }

    func buildPanel() {
        // 스프라이트보다 넓게: 젤리처럼 기울고 찌그러질 여유.
        let size = CatView.size
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel = makePanel(NSRect(origin: NSPoint(x: visible.maxX - size.width - 22, y: visible.minY + 18), size: size))
        panel.level = .statusBar // 메뉴 막대보다 위라서 펫이 화면 맨 위 가장자리에 납작하게 눌릴 수 있다
        cat = CatView(frame: NSRect(origin: .zero, size: size))
        cat.onClick = { [weak self] in self?.toggleLatest() }
        cat.onMoved = { [weak self] in self?.droppedPet() }
        cat.onDragTo = { [weak self] in self?.dragPet(to: $0) }
        panel.contentView?.addSubview(cat)
        overlay = makePanel(NSScreen.main?.frame ?? visible)
        overlay.level = .statusBar // 메뉴 막대와 Dock보다 위라서 말풍선이 모서리에 딱 붙을 수 있다
        overlay.ignoresMouseEvents = true
        bubble = BubbleField(frame: overlay.contentView!.bounds)
        bubble.autoresizingMask = [.width, .height]
        bubble.isHidden = true
        bubble.onClick = { [weak self] in self?.openConversation($0) }
        bubble.contextMenu = hideMenu(action: #selector(hideBubblesFor(_:)))
        arrow = HideArrow(frame: .zero)
        arrow.isHidden = true
        arrow.onClick = { [weak self] in self?.arrowClicked($0) }
        arrow.onDrag = { [weak self] in self?.dragArrow($0) }
        arrow.onDragEnd = { [weak self] in self?.arrowDropped() }
        overlay.contentView?.addSubview(bubble)
        overlay.contentView?.addSubview(arrow)
        // 스프라이트 자체의 원점으로 저장해서, 패널 크기가 바뀌어도 펫이 움직이지 않는다.
        let sprite = cat.spriteRect
        if let saved = UserDefaults.standard.array(forKey: "pet.sprite.origin") as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0] - sprite.minX, y: saved[1] - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.cat.origin") as? [Double], old.count == 2 {
            // 이전 빌드: 200pt 패널, 스프라이트 위치 (32.6, 4).
            panel.setFrameOrigin(NSPoint(x: old[0] + 32.6 - sprite.minX, y: old[1] + 4 - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.position") as? [Double], old.count == 2 {
            // v1: 340pt 패널, 스프라이트 위치 (190.6, 9).
            panel.setFrameOrigin(NSPoint(x: old[0] + 190.6 - sprite.minX, y: old[1] + 9 - sprite.minY))
        }
        clampPosition()
        lastCatOrigin = panel.frame.origin
    }

}
