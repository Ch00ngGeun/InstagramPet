import AppKit
import PetCore
import PetSources

// 메뉴 막대·우클릭 메뉴 구성과 캐릭터 고르기·추가·삭제.

extension PetController {
    func item(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    func hideMenu(action: Selector) -> NSMenu {
        let menu = NSMenu()
        for minutes in Self.hideMinutes {
            let entry = item(minutes == 60 ? "1시간" : "\(minutes)분", action: action)
            entry.tag = minutes
            menu.addItem(entry)
        }
        return menu
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Instagram Pet controls")
        statusItem.button?.toolTip = "Instagram Pet · Instagram / KakaoTalk / Messages"
        let menu = NSMenu()
        menu.addItem(item("Instagram Pet · MVP"))
        statusLine = item("Waiting for Chrome observations"); menu.addItem(statusLine)
        for source in [PetSource.messages, .kakao] {
            let line = item("\(source.title): disabled")
            sourceStatusItems[source] = line
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let bubbles = item("말풍선 잠깐 숨기기"); bubbles.submenu = hideMenu(action: #selector(hideBubblesFor(_:))); menu.addItem(bubbles)
        let pet = item("펫 잠깐 숨기기"); pet.submenu = hideMenu(action: #selector(hidePetFor(_:))); menu.addItem(pet)
        showNowItem = item("지금 다시 보이기", action: #selector(showNow)); menu.addItem(showNowItem)
        menu.addItem(item("Show Latest Message", action: #selector(showLatest)))
        menu.addItem(item("Show Demo Bubble", action: #selector(showDemo)))
        menu.addItem(item("Clear Waiting Messages", action: #selector(clearMessages)))
        menu.addItem(.separator())
        menu.addItem(item("설정…", action: #selector(openSettings), key: ","))
        let character = item("캐릭터"); character.submenu = characterMenu; menu.addItem(character)
        menu.addItem(item("Open Instagram Inbox", action: #selector(openInbox)))
        menu.addItem(item("Open Local Data Folder", action: #selector(openDataFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Instagram Pet", action: #selector(quit), key: "q"))
        menu.autoenablesItems = false
        statusItem.menu = menu
        cat.petMenu = menu
        characterMenu.autoenablesItems = false
        applyCharacter()
        updateStatus()
    }

    // 캐릭터: 사용자가 추가한 PNG는 로컬 데이터 폴더에, 고른 파일 이름은 defaults에 둔다.
    private var charactersFolder: URL { paths.root.appendingPathComponent("characters", isDirectory: true) }
    private var chosenCharacter: String? {
        get { UserDefaults.standard.string(forKey: "pet.character") }
        set { UserDefaults.standard.set(newValue, forKey: "pet.character") }
    }

    private func applyCharacter() {
        // 없거나 읽을 수 없는 파일이면 번들 펫으로 돌아간다.
        let custom = chosenCharacter.flatMap { NSImage(contentsOf: charactersFolder.appendingPathComponent($0)) }
        if custom == nil { chosenCharacter = nil }
        cat.sprite = custom ?? Bundle.main.image(forResource: "pet")
        characterMenu.removeAllItems()
        let files = ((try? FileManager.default.contentsOfDirectory(at: charactersFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.map(\.lastPathComponent).sorted()
        for name in [nil] + files.map(Optional.some) {
            let choice = item(name.map { ($0 as NSString).deletingPathExtension } ?? "기본 펫", action: #selector(chooseCharacter(_:)))
            choice.representedObject = name
            choice.state = name == chosenCharacter ? .on : .off
            characterMenu.addItem(choice)
        }
        characterMenu.addItem(.separator())
        characterMenu.addItem(item("캐릭터 추가…", action: #selector(addCharacter)))
        let remove = item("현재 캐릭터 삭제…", action: #selector(deleteCharacter))
        remove.isEnabled = chosenCharacter != nil
        characterMenu.addItem(remove)
    }

    @objc private func chooseCharacter(_ sender: NSMenuItem) {
        chosenCharacter = sender.representedObject as? String
        applyCharacter()
    }

    @objc private func addCharacter() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.message = "캐릭터로 쓸 그림을 고르세요. 배경이 투명한 PNG가 가장 자연스럽습니다."
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            let name = try Self.saveCharacter(from: url, into: charactersFolder)
            chosenCharacter = name
            applyCharacter()
        } catch {
            let alert = NSAlert()
            alert.messageText = "이 그림은 캐릭터로 쓸 수 없습니다."
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func deleteCharacter() {
        guard let name = chosenCharacter else { return }
        let alert = NSAlert()
        alert.messageText = "'\((name as NSString).deletingPathExtension)' 캐릭터를 삭제할까요?"
        alert.informativeText = "기본 펫으로 돌아갑니다."
        alert.addButton(withTitle: "삭제"); alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: charactersFolder.appendingPathComponent(name))
        chosenCharacter = nil
        applyCharacter()
    }

    /// 어떤 그림이든 그려지는 높이의 2배 이하 PNG로 복사한다(픽셀 단위 검사를 빠르게 유지).
    /// 이름은 원본 파일을 따르고, 겹치면 " 2", " 3"…을 붙인다. 저장한 파일 이름을 돌려준다.
    static func saveCharacter(from source: URL, into folder: URL) throws -> String {
        guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
            throw PetError.invalid("그림 파일을 읽지 못했습니다.")
        }
        let scale = min(1, CatView.spriteHeight * 2 / image.size.height)
        let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw PetError.invalid("그림을 변환하지 못했습니다.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PetError.invalid("그림을 변환하지 못했습니다.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var name = "\(stem).png", copy = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { name = "\(stem) \(copy).png"; copy += 1 }
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    func remaining(_ until: Date?) -> String {
        guard let until else { return "" }
        return "\(max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up))))분 후 다시 표시"
    }

    @objc private func openInbox() { openURLInChrome(URL(string: "https://www.instagram.com/direct/inbox/")!) }
    @objc private func openDataFolder() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
