import AppKit
import PetCore

// The application deliberately has no network client. Chrome is the only DM source.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = NSColor(calibratedRed: 0.34, green: 0.27, blue: 0.23, alpha: 1)
        titleField.lineBreakMode = .byTruncatingTail
        messageField.font = .systemFont(ofSize: 14)
        messageField.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        messageField.maximumNumberOfLines = 4
        messageField.lineBreakMode = .byWordWrapping
        messageField.cell?.wraps = true
        messageField.cell?.usesSingleLineMode = false
        hintField.font = .systemFont(ofSize: 10)
        hintField.textColor = .secondaryLabelColor
        [titleField, messageField, hintField].forEach {
            $0.isSelectable = false
            addSubview($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Click to open this conversation in Google Chrome")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 0.98).setFill()
        card.fill()
        NSColor(calibratedRed: 0.83, green: 0.78, blue: 0.71, alpha: 1).setStroke()
        card.lineWidth = 1; card.stroke()
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(x: 16, y: bounds.height - 32, width: bounds.width - 32, height: 18)
        messageField.frame = NSRect(x: 16, y: 36, width: bounds.width - 32, height: bounds.height - 76)
        hintField.frame = NSRect(x: 16, y: 13, width: bounds.width - 32, height: 15)
    }

    func show(_ event: PetEvent, waiting: Int) {
        let name = event.displayName.flatMap { $0.isEmpty ? nil : "\($0) · @\(event.sender)" } ?? "@\(event.sender)"
        titleField.stringValue = event.kind == "test" ? "DEMO · Instagram Pet" : name
        // Rendering is intentionally bounded. The entire event never enters a log.
        messageField.stringValue = String(event.text.prefix(360))
        let kind = event.kind == "inbox-preview" ? "Inbox preview · " : ""
        let extra = waiting > 0 ? " · \(waiting) waiting" : ""
        hintField.stringValue = "\(kind)Click to open in Chrome\(extra)"
        setAccessibilityLabel("\(titleField.stringValue): \(messageField.stringValue)")
        toolTip = "Open conversation in Google Chrome"
        isHidden = false
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) && !isHidden ? self : nil
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

final class CatView: NSView {
    var phase: CGFloat = 0
    var excited = false
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var petMenu: NSMenu?
    private var dragStart: NSPoint?
    private var initialOrigin: NSPoint?
    private var dragged = false
    private(set) var isDragging = false
    // Bundled cutout character; missing only when run outside the .app bundle.
    private let sprite = Bundle.main.image(forResource: "pet")
    private let pink = NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.52, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Instagram Pet")
        setAccessibilityHelp("Drag to move. Click to show or dismiss the latest message. Right-click for controls.")
        toolTip = "Drag me · Click for latest message · Right-click for controls"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The character's drawn area, used so transparent space stays click-through.
    var spriteRect: NSRect {
        guard let size = sprite?.size, size.height > 0 else { return bounds }
        let height = bounds.height - 12, width = height * size.width / size.height
        return NSRect(x: bounds.midX - width / 2, y: 4, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bob = sin(phase) * (excited ? 4 : 1.5)
        let rect = spriteRect.offsetBy(dx: 0, dy: bob)
        sprite?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        if excited {
            let heart: NSString = "♥"
            heart.draw(at: NSPoint(x: min(rect.maxX - 4, bounds.maxX - 24), y: rect.maxY - 34 + sin(phase) * 3), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: pink])
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStart = NSEvent.mouseLocation
        initialOrigin = window?.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = initialOrigin else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - start.x, dy = point.y - start.y
        if abs(dx) + abs(dy) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        isDragging = false
        dragStart = nil; initialOrigin = nil
    }
    override func menu(for event: NSEvent) -> NSMenu? { petMenu }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

final class PetController: NSObject, NSApplicationDelegate {
    private let paths = PetPaths()
    private var queue: EventQueue!
    private var panel: PetPanel!
    private var bubble: BubbleView!
    private var cat: CatView!
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var visibilityItem: NSMenuItem!
    private var privacyItem: NSMenuItem!
    private var animationTimer: Timer?
    private var pollTimer: Timer?
    private var bubbleTimer: Timer?
    private var pending: [PetEvent] = []
    private var current: PetEvent?
    private var knownIDs = Set<String>()
    private var knownOrder: [String] = []
    private var queueGeneration = 0
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pollInFlight = false
    private var isHidden = false
    private var paused = false
    private var lastError: String?
    private let io = DispatchQueue(label: "com.instagrampet.queue", qos: .utility)
    private var smokeReport: URL?
    private var smokeFinishing = false
    private var previewMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
            previewMode = true
            renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            NSApplication.shared.terminate(nil)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > flag + 1 {
            smokeReport = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        }
        queue = EventQueue(paths: paths)
        do { try paths.prepare() }
        catch { lastError = "Cannot open private queue" }
        buildPanel()
        buildMenu()
        if smokeReport == nil { panel.orderFrontRegardless() }
        else { statusItem.isVisible = false }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            self.cat.phase += 0.12
            self.cat.needsDisplay = true
            self.updateClickThrough()
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updateClickThrough() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateClickThrough(); return event
        }
        updateClickThrough()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        poll()
        if smokeReport != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishSmokeTest() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if smokeReport == nil, !previewMode { persistPosition() }
        animationTimer?.invalidate(); pollTimer?.invalidate(); bubbleTimer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    private func buildPanel() {
        let size = NSSize(width: 340, height: 530)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = NSPoint(x: visible.maxX - size.width - 22, y: visible.minY + 18)
        panel = PetPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Instagram Pet"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content
        bubble = BubbleView(frame: NSRect(x: 5, y: 357, width: 330, height: 166))
        bubble.isHidden = true
        bubble.onClick = { [weak self] in self?.openConversation() }
        content.addSubview(bubble)
        cat = CatView(frame: NSRect(x: 183, y: 5, width: 150, height: 350))
        cat.onClick = { [weak self] in self?.toggleLatest() }
        cat.onMoved = { [weak self] in self?.clampPosition(); self?.persistPosition() }
        content.addSubview(cat)
        if let saved = UserDefaults.standard.array(forKey: "pet.position") as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        }
        clampPosition()
    }

    private func item(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Instagram Pet controls")
        statusItem.button?.toolTip = "Instagram Pet · requires an open Instagram tab"
        let menu = NSMenu()
        menu.addItem(item("Instagram Pet · MVP"))
        statusLine = item("Waiting for Chrome observations"); menu.addItem(statusLine)
        menu.addItem(.separator())
        visibilityItem = item("Hide Pet", action: #selector(toggleVisibility), key: "h"); menu.addItem(visibilityItem)
        privacyItem = item("Pause Message Display", action: #selector(togglePause)); menu.addItem(privacyItem)
        menu.addItem(item("Show Latest Message", action: #selector(showLatest)))
        menu.addItem(item("Show Demo Bubble", action: #selector(showDemo)))
        menu.addItem(item("Dismiss Current Bubble", action: #selector(dismissCurrent)))
        menu.addItem(item("Clear Waiting Messages", action: #selector(clearMessages)))
        menu.addItem(.separator())
        menu.addItem(item("Open Instagram Inbox", action: #selector(openInbox)))
        menu.addItem(item("Open Local Data Folder", action: #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Instagram Pet", action: #selector(quit), key: "q"))
        statusItem.menu = menu
        cat.petMenu = menu
        updateStatus()
    }

    private func updateStatus() {
        if let lastError { statusLine.title = lastError }
        else if paused { statusLine.title = "Paused · \(pending.count) waiting" }
        else if !pending.isEmpty { statusLine.title = "\(pending.count) message(s) waiting" }
        else { statusLine.title = "Ready · open Instagram tab required" }
        visibilityItem.title = isHidden ? "Show Pet" : "Hide Pet"
        privacyItem.title = paused ? "Resume Message Display" : "Pause Message Display"
    }

    private func poll() {
        guard queue != nil, !pollInFlight else { return }
        pruneExpiredMemory()
        // Leave excess events on disk rather than silently dropping them from memory.
        guard pending.count < 100 else { return }
        pollInFlight = true
        let generation = queueGeneration
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.queue.pending() }
            DispatchQueue.main.async {
                self.pollInFlight = false
                guard generation == self.queueGeneration else { return }
                switch result {
                case .success(let events):
                    self.lastError = nil
                    for event in events {
                        guard self.pending.count < 100 else { break }
                        if self.knownIDs.contains(event.eventId) { continue }
                        // Validate again at the display boundary, including the URL.
                        guard (try? event.validate()) != nil else { continue }
                        self.knownIDs.insert(event.eventId)
                        self.knownOrder.append(event.eventId)
                        self.pending.append(event)
                    }
                    self.trimKnownIDs()
                    self.presentNextIfPossible()
                case .failure:
                    self.lastError = "Queue read failed · check data folder"
                }
                self.updateStatus()
            }
        }
    }

    private func presentNextIfPossible() {
        guard !paused, !isHidden, bubble.isHidden, !pending.isEmpty else { return }
        current = pending.removeFirst()
        if let current { present(current) }
    }

    private func present(_ event: PetEvent) {
        guard !paused, !isHidden else { return }
        bubbleTimer?.invalidate()
        bubble.show(event, waiting: pending.count)
        // Retain undisplayed events on disk across app quits. Consume only on display.
        io.async { [weak self] in
            guard let queue = self?.queue else { return }
            try? queue.consume(event)
        }
        cat.excited = true
        if smokeReport == nil { panel.orderFrontRegardless() }
        // A readable, finite display period; the latest bubble remains available via the menu.
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in self?.dismissCurrent() }
        updateStatus()
        if smokeReport != nil { finishSmokeTest() }
    }

    @objc private func dismissCurrent() {
        bubbleTimer?.invalidate(); bubbleTimer = nil
        bubble.isHidden = true; cat.excited = false
        // Brief separation prevents queued bubbles from appearing to be one changing message.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.presentNextIfPossible() }
    }

    private func toggleLatest() {
        if bubble.isHidden { showLatest() } else { dismissCurrent() }
    }

    @objc private func showLatest() {
        guard !paused else { return }
        if isHidden { toggleVisibility() }
        if let current { present(current) } else { presentNextIfPossible() }
    }

    @objc private func showDemo() {
        guard let event = demoEvent() else { return }
        pending.insert(event, at: 0)
        if paused { togglePause() }
        if isHidden { toggleVisibility() }
        dismissCurrent()
        updateStatus()
    }

    private func demoEvent() -> PetEvent? {
        // Decode the same wire model to exercise the bubble without requiring Chrome or a login.
        let sample: [String: Any] = [
            "version": 1, "type": "dm", "eventId": "demo-\(UUID().uuidString)",
            "sender": "demo.pet", "displayName": "Demo Pet", "text": "안녕! 새 DM이 오면 이렇게 알려줄게요.\nDrag me anywhere. Keep Instagram open in Chrome.",
            "threadUrl": "https://www.instagram.com/direct/t/demo/", "observedAt": ISO8601DateFormatter().string(from: Date()), "kind": "test"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sample) else { return nil }
        return try? JSONDecoder().decode(PetEvent.self, from: data)
    }

    private func renderPreview(to output: URL) {
        buildPanel()
        guard let event = demoEvent(), let content = panel.contentView else { return }
        content.appearance = NSAppearance(named: .aqua)
        bubble.show(event, waiting: 0)
        cat.excited = true
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try image.write(to: output); print("Preview rendered: \(output.path)") }
        catch { fputs("Could not save preview\n", stderr) }
    }

    private func finishSmokeTest() {
        guard let output = smokeReport, !smokeFinishing else { return }
        smokeFinishing = true
        // This runs after the consume already enqueued by present(), on the same serial queue.
        io.async { [weak self] in
            guard let self else { return }
            let remaining = (try? self.queue?.count()) ?? -1
            DispatchQueue.main.async {
                let report: [String: Any] = [
                    "version": 1, "displayedEventId": self.current?.eventId as Any? ?? NSNull(),
                    "remainingQueueCount": remaining, "bubbleVisible": !self.bubble.isHidden,
                    "ok": self.current != nil && !self.bubble.isHidden
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output)
                    print("AppKit smoke report: \(output.path)")
                } catch { fputs("Could not save smoke report\n", stderr) }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @objc private func clearMessages() {
        queueGeneration += 1
        pending.removeAll(); current = nil
        bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false
        io.async { [weak self] in
            guard let self, let queue = self.queue else { return }
            try? queue.clear()
        }
        updateStatus()
    }

    @objc private func toggleVisibility() {
        isHidden.toggle()
        if isHidden { bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false; panel.orderOut(nil) }
        else { panel.orderFrontRegardless(); presentNextIfPossible() }
        updateStatus()
    }

    @objc private func togglePause() {
        paused.toggle()
        if paused { bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false }
        else { presentNextIfPossible() }
        updateStatus()
    }

    private func openURLInChrome(_ url: URL) {
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { _, _ in }
        } else { NSWorkspace.shared.open(url) }
    }

    private func openConversation() {
        guard let current, (try? current.validate()) != nil else { return }
        // Demo bubbles never pretend that the artificial thread exists.
        let link = current.kind == "test" ? "https://www.instagram.com/direct/inbox/" : current.threadUrl
        guard let url = URL(string: link) else { return }
        openURLInChrome(url)
        dismissCurrent()
    }

    @objc private func openInbox() { openURLInChrome(URL(string: "https://www.instagram.com/direct/inbox/")!) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func persistPosition() {
        UserDefaults.standard.set([panel.frame.origin.x, panel.frame.origin.y], forKey: "pet.position")
    }

    @objc private func screenChanged() { clampPosition(); persistPosition() }

    private func trimKnownIDs() {
        guard knownOrder.count > 1024 else { return }
        knownOrder = Array(knownOrder.suffix(512))
        knownIDs = Set(knownOrder).union(pending.map(\.eventId))
        if let current { knownIDs.insert(current.eventId) }
    }

    private func pruneExpiredMemory() {
        let cutoff = Date().addingTimeInterval(-EventQueue.retention)
        pending.removeAll { (PetEvent.date($0.observedAt) ?? .distantPast) < cutoff }
        if let event = current, (PetEvent.date(event.observedAt) ?? .distantPast) < cutoff {
            current = nil
            bubbleTimer?.invalidate(); bubble.isHidden = true; cat.excited = false
        }
    }

    private func updateClickThrough() {
        guard !isHidden, !cat.isDragging else { return }
        let pointer = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let catBounds = cat.spriteRect.offsetBy(dx: cat.frame.minX, dy: cat.frame.minY)
        let overPet = catBounds.contains(pointer)
        let overBubble = !bubble.isHidden && bubble.frame.contains(pointer)
        // Transparent space must allow interaction with the application underneath.
        panel.ignoresMouseEvents = !(overPet || overBubble)
    }

    private func clampPosition() {
        // Clamp the complete bubble/pet panel to the nearest available display.
        let origin = panel.frame.origin
        let screens = NSScreen.screens
        let screen = screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let x = min(max(origin.x, area.minX), max(area.minX, area.maxX - panel.frame.width))
        let y = min(max(origin.y, area.minY), max(area.minY, area.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()
