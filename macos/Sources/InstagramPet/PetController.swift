import AppKit
import PetCore
import PetSources

final class PetController: NSObject, NSApplicationDelegate {
    /// Hiding is always temporary: the girlfriend always deserves attention again.
    static let hideMinutes = [10, 20, 30, 40, 50, 60]
    /// The pet always stays fully on screen; pressed into an edge it squashes, and only a corner hides it.
    static let keepVisible: CGFloat = .infinity
    /// Pressed this deep into both walls of a corner at release: the pet tucks away behind its arrow.
    static let cornerPress: CGFloat = 30
    let paths = PetPaths()
    var sourceConfig = SourcesConfig()
    var settingsWindow: SourcesSettingsWindowController?
    var settingsOpening = false
    var sourceConfigError: String?
    var localReaders: [LocalSourceReader] = [] // accessed only on the serial I/O queue after launch
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
    var panel: PetPanel!       // the character
    var overlay: PetPanel!     // screen-sized, click-through layer for bubbles and the arrow
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
    var recent: [PetEvent] = [] // the (up to four) messages shown before `current`
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
    /// Dragged off the edge: the pet is tucked away behind its arrow, but bubbles keep coming (they gather at
    /// that edge). It pops back out after an hour at most — nothing hides indefinitely.
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
    /// Preview only: nil = the usual samples; otherwise (kakao, instagram, messages) counts, interleaved in time.
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
            if CommandLine.arguments.contains("--start-hidden") { // checks that a new message ends a timed hide
                hidePetUntil = Date().addingTimeInterval(600); hideBubblesUntil = Date().addingTimeInterval(600)
            }
            if CommandLine.arguments.contains("--start-tucked") { // a message must bring back bubbles, not the pet
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
        // No menu bar of its own, so text fields need this hidden Edit menu for ⌘C/⌘V/⌘X/⌘A/⌘Z.
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"),
                                     ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let main = NSMenu(), editItem = NSMenuItem()
        editItem.submenu = edit; main.addItem(NSMenuItem()); main.addItem(editItem); NSApp.mainMenu = main // first item is the app menu
        if smokeReport == nil { overlay.orderFrontRegardless(); panel.orderFrontRegardless() }
        else { statusItem.isVisible = false }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkHideExpiry()
            if !self.isHidden && !self.isTucked {
                self.cat.phase += 0.12
                if self.paused { self.cat.excited = !self.pending.isEmpty } // messages wait behind the pause
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
        // The pet never takes focus, so let this background app show the open hand over it.
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
        // Wider than the sprite: room for the jelly lean and squash.
        let size = CatView.size
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel = makePanel(NSRect(origin: NSPoint(x: visible.maxX - size.width - 22, y: visible.minY + 18), size: size))
        panel.level = .statusBar // above the menu bar, so the pet can press flat against the very top edge
        cat = CatView(frame: NSRect(origin: .zero, size: size))
        cat.onClick = { [weak self] in self?.toggleLatest() }
        cat.onMoved = { [weak self] in self?.droppedPet() }
        cat.onDragTo = { [weak self] in self?.dragPet(to: $0) }
        panel.contentView?.addSubview(cat)
        overlay = makePanel(NSScreen.main?.frame ?? visible)
        overlay.level = .statusBar // above the menu bar and Dock, so bubbles can sit flush in a corner
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
        // Saved as the sprite's own origin, so panel size changes never move the pet.
        let sprite = cat.spriteRect
        if let saved = UserDefaults.standard.array(forKey: "pet.sprite.origin") as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0] - sprite.minX, y: saved[1] - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.cat.origin") as? [Double], old.count == 2 {
            // Previous build: a 200pt panel, sprite at (32.6, 4).
            panel.setFrameOrigin(NSPoint(x: old[0] + 32.6 - sprite.minX, y: old[1] + 4 - sprite.minY))
        } else if let old = UserDefaults.standard.array(forKey: "pet.position") as? [Double], old.count == 2 {
            // v1: a 340pt panel, sprite at (190.6, 9).
            panel.setFrameOrigin(NSPoint(x: old[0] + 190.6 - sprite.minX, y: old[1] + 9 - sprite.minY))
        }
        clampPosition()
        lastCatOrigin = panel.frame.origin
    }

}
