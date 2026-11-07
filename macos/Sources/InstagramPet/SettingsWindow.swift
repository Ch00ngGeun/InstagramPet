import AppKit
import PetCore
import PetSources

struct SettingsFormError: Error {
    let message: String
}

/// A draft never changes the user's file until every enabled source is valid.
struct SettingsDraft {
    var managesInstagram: Bool
    var username: String
    var threadId: String
    var messagesHandle: String
    var kakaoName: String

    init(_ config: SourcesConfig) {
        managesInstagram = config.instagram != nil
        username = config.instagram?.username.replacingOccurrences(of: ",", with: ", ") ?? ""
        threadId = config.instagram?.threadId.replacingOccurrences(of: ",", with: ", ") ?? ""
        messagesHandle = config.messages?.handle.replacingOccurrences(of: ",", with: ", ") ?? ""
        kakaoName = config.kakao?.name.replacingOccurrences(of: ",", with: ", ") ?? ""
    }

    func validated() throws -> SourcesConfig {
        var config = SourcesConfig()
        if managesInstagram {
            do {
                config.instagram = try SourcesConfig(instagram: .init(username: username, threadId: threadId)).validated().instagram
            } catch {
                throw SettingsFormError(message: "인스타 ID와 대화 번호의 형식·개수를 확인해 주세요. 여러 개는 쉼표(,)로 구분하고 같은 순서로 입력하세요.")
            }
        }
        do {
            config.messages = try SourcesConfig(messages: .init(handle: messagesHandle)).validated().messages
        } catch {
            throw SettingsFormError(message: "전화번호 또는 이메일을 확인해 주세요. 여러 개는 쉼표(,)로 구분합니다.")
        }
        do {
            config.kakao = try SourcesConfig(kakao: .init(name: kakaoName)).validated().kakao
        } catch {
            throw SettingsFormError(message: "이름은 쉼표(,)로 구분하고 각 이름을 100자 이내로 입력해 주세요. 줄바꿈은 사용할 수 없습니다.")
        }
        if ContactReaders.hasAmbiguousKakaoNames(config.kakaoNames) {
            throw SettingsFormError(message: "이모지의 유무만 다른 이름은 하나만 등록해 주세요.")
        }
        return config
    }
}

final class SourcesSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    let username = NSTextField(), threadId = NSTextField(), messagesHandle = NSTextField(), kakaoName = NSTextField()
    private var managesInstagram = false
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "저장", target: nil, action: nil)
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    var onSave: ((SourcesConfig, @escaping (Result<Void, SettingsFormError>) -> Void) -> Void)?

    init(config: SourcesConfig) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 610),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "메시지 알림 설정"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        setDraft(SettingsDraft(config))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var draft: SettingsDraft {
        var value = SettingsDraft(SourcesConfig())
        value.managesInstagram = managesInstagram
        value.username = username.stringValue; value.threadId = threadId.stringValue
        value.messagesHandle = messagesHandle.stringValue; value.kakaoName = kakaoName.stringValue
        return value
    }

    func setDraft(_ draft: SettingsDraft) {
        managesInstagram = draft.managesInstagram
        username.stringValue = draft.username; threadId.stringValue = draft.threadId
        messagesHandle.stringValue = draft.messagesHandle; kakaoName.stringValue = draft.kakaoName
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, heading: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = heading ? .systemFont(ofSize: 22, weight: .semibold) : .systemFont(ofSize: 13)
        field.textColor = heading ? .labelColor : .secondaryLabelColor
        return field
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
        func add(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func section(_ title: String, hint: String = "여러 개 등록 가능 · 쉼표(,)로 구분") -> NSStackView {
            let section = NSStackView()
            section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
            let heading = label(title, heading: true)
            section.addArrangedSubview(heading)
            heading.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            let help = label(hint)
            help.font = .systemFont(ofSize: 12)
            section.addArrangedSubview(help)
            help.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            add(section)
            return section
        }
        func row(_ title: String, _ field: NSTextField, placeholder: String, in section: NSStackView) {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(title)
            field.font = .systemFont(ofSize: 14)
            field.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let titleField = label(title)
            section.addArrangedSubview(titleField); section.addArrangedSubview(field)
            titleField.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        let instagram = section("인스타그램", hint: "여러 개 등록 가능 · 쉼표(,)로 구분 · ID와 번호는 같은 순서")
        row("상대ID(@생략)", username, placeholder: "partner.name", in: instagram)
        row("DM대화창주소의 번호", threadId, placeholder: "https://www.instagram.com/direct/t/번호/의 번호부분", in: instagram)
        username.delegate = self; threadId.delegate = self
        let messages = section("메세지")
        row("전화번호 / 이메일", messagesHandle, placeholder: "전화번호(:+821012345678) / 또는 이메일", in: messages)
        let kakao = section("카카오톡")
        row("표시 이름", kakaoName, placeholder: "채팅 목록에 보이는 이름", in: kakao)
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityLabel("설정 오류")
        errorLabel.isHidden = true
        add(errorLabel)
        let spacer = NSView()
        saveButton.target = self; saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton]); buttons.spacing = 12
        add(buttons)
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20).isActive = true
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === username || field === threadId {
            // Preserve legacy extension-only selection until these fields are deliberately edited.
            managesInstagram = true
        }
    }
    @objc private func cancel() { close() }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
    }

    /// Also used by the offscreen form smoke test; errors never include entered values.
    @objc func save() {
        let value: SourcesConfig
        do { value = try draft.validated() }
        catch let error as SettingsFormError { showError(error.message); return }
        catch { showError("입력 내용을 확인해 주세요."); return }
        guard let onSave else { return }
        saveButton.isEnabled = false; cancelButton.isEnabled = false
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        showError("")
        onSave(value) { [weak self] result in
            guard let self else { return }
            self.saveButton.isEnabled = true; self.cancelButton.isEnabled = true
            self.window?.standardWindowButton(.closeButton)?.isEnabled = true
            switch result {
            case .success: self.close()
            case .failure(let error): self.showError(error.message)
            }
        }
    }

    var hasValidationError: Bool { !errorLabel.stringValue.isEmpty }
}
