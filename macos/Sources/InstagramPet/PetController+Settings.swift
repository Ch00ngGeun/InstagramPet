import AppKit
import PetCore
import PetSources

// 소스 설정 창 열기·저장, 바뀐 소스의 리더 교체, 선택한 대화만 받는 필터, 상태 표시 갱신.

extension PetController {
    @objc func openSettings() {
        if let settingsWindow, settingsWindow.window?.isVisible == true { settingsWindow.show(); return }
        guard !settingsOpening else { return }
        settingsOpening = true
        io.async { [weak self] in
            guard let self else { return }
            let result = Result { try SourcesConfig.load(paths: self.paths) }
            DispatchQueue.main.async {
                self.settingsOpening = false
                switch result {
                case .failure:
                    self.lastError = "설정 파일을 읽을 수 없습니다 · 로컬 데이터 폴더 확인"
                    self.updateStatus()
                case .success(let config):
                    let controller = SourcesSettingsWindowController(config: config)
                    controller.onSave = { [weak self] value, completion in self?.saveSettings(value, completion: completion) }
                    self.settingsWindow = controller
                    controller.show()
                }
            }
        }
    }

    /// 메인 스레드에서 호출한다. I/O 큐가 파일 교체와 리더 변경을 폴링과 차례대로 처리한다.
    func saveSettings(_ value: SourcesConfig, completion: @escaping (Result<Void, SettingsFormError>) -> Void) {
        let previous = sourceConfig
        queueGeneration += 1 // 예전 선택으로 찍은 폴링 결과는 무시한다.
        io.async { [weak self] in
            guard let self else { return }
            do {
                let config = try value.validated()
                try config.save(paths: self.paths)
                let changed = Self.changedSources(from: previous, to: config)
                self.localReaders = self.localReaders.map { reader in
                    guard changed.contains(reader.source) else { return reader }
                    return self.makeContactReaders(reader.source, config: config, reusing: reader as? ContactReaders)
                }
                self.lastSourcesPoll = .distantPast
                // 받은 기록과 대화별 읽음 표시는 선택이 바뀌어도 남는다.
                // 지금 정리하지 못하면, 더 이상 선택되지 않은 대기 이벤트는 나중에 화면에 띄우기 직전에 걸러진다.
                if let waiting = try? self.queue?.pending() {
                    for event in waiting where changed.contains(event.source) && !Self.acceptsEvent(event, config: config) {
                        try? self.queue?.consume(event)
                    }
                }
                DispatchQueue.main.async {
                    self.applySettings(config, changed: changed)
                    completion(.success(()))
                    if !self.previewMode { self.poll() }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(SettingsFormError(message: "설정을 저장하지 못했습니다. 로컬 데이터 폴더의 소유권·권한과 입력을 확인해 주세요.")))
                }
            }
        }
    }

    func makeContactReaders(_ source: PetSource, config: SourcesConfig, reusing previous: ContactReaders? = nil) -> ContactReaders {
        if source == .messages {
            return ContactReaders(source: source, identifiers: config.messageHandles, reusing: previous) { MessagesReader(handle: $0) }
        }
        return ContactReaders.kakao(identifiers: config.kakaoNames, reusing: previous, fallbackGrace: 0.5)
    }

    static func changedSources(from previous: SourcesConfig, to config: SourcesConfig) -> Set<PetSource> {
        var changed = Set<PetSource>()
        if previous.instagram != config.instagram { changed.insert(.instagram) }
        if previous.messages != config.messages { changed.insert(.messages) }
        if previous.kakao != config.kakao { changed.insert(.kakao) }
        return changed
    }

    func applySettings(_ config: SourcesConfig, changed: Set<PetSource>) {
        sourceConfig = config; sourceConfigError = nil; lastError = nil
        pending.removeAll { changed.contains($0.source) && !Self.acceptsEvent($0, config: config) }
        recent.removeAll { changed.contains($0.source) && !Self.acceptsEvent($0, config: config) }
        if let event = current, changed.contains(event.source), !Self.acceptsEvent(event, config: config) { current = recent.popLast() }
        let shown = recent + [current].compactMap { $0 }
        if shown.isEmpty { bubble.isHidden = true; cat.excited = false }
        else if !bubble.isHidden { bubble.show(shown) }
        for source in changed {
            permissionNotices.remove(source)
            if source == .messages { sourceStatuses[source] = config.messages == nil ? .disabled : .idle }
            if source == .kakao {
                sourceStatuses[source] = config.kakao == nil ? .disabled : .idle
                kakaoAccessibilityStatus = config.kakao == nil ? .disabled : .idle
                kakaoNotificationStatus = config.kakao == nil ? .disabled : .idle
            }
        }
        updateStatus()
    }

    static func acceptsEvent(_ event: PetEvent, config: SourcesConfig) -> Bool {
        if event.kind == "test" { return true }
        switch event.source {
        case .instagram:
            guard config.instagram != nil else { return true } // 예전처럼 확장 프로그램이 선택을 관리하는 경우.
            guard let url = URL(string: event.threadUrl) else { return false }
            let path = url.path.split(separator: "/").map(String.init)
            return config.instagramSelections.contains { $0.username == event.sender && path == ["direct", "t", $0.threadId] }
        case .messages:
            return config.messageHandles.contains { ConversationKey.local(.messages, identifier: $0) == event.conversation }
        case .kakao:
            return config.kakaoNames.contains { ConversationKey.local(.kakao, identifier: $0) == event.conversation }
        }
    }

    func updateStatus() {
        if let lastError { statusLine.title = lastError }
        else if let sourceConfigError { statusLine.title = sourceConfigError }
        else if isTucked { statusLine.title = "펫 가장자리에 숨김 · \(remaining(tuckedUntil))" }
        else if isHidden { statusLine.title = "펫 숨김 · \(remaining(hidePetUntil)) · \(pending.count) waiting" }
        else if paused { statusLine.title = "말풍선 숨김 · \(remaining(hideBubblesUntil)) · \(pending.count) waiting" }
        else if !pending.isEmpty { statusLine.title = "\(pending.count) message(s) waiting" }
        else { statusLine.title = "Ready · Instagram은 대화 탭을 열어 두세요" }
        showNowItem.isEnabled = isHidden || paused || isTucked
        for (source, line) in sourceStatusItems {
            let detail: String
            switch sourceStatuses[source] ?? .disabled {
            case .disabled: detail = "꺼짐 · sources.json 확인"
            case .idle: detail = "대기 · 앱/목록 창 확인"
            case .observing: detail = "관측 중"
            case .permissionRequired: detail = source == .messages ? "전체 디스크 접근 필요" : "손쉬운 사용 권한 필요"
            case .unavailable: detail = source == .messages ? "DB/스키마 확인 필요" : "목록 구조 인식 불가"
            }
            var sourceDetail = detail
            if source == .kakao, sourceStatuses[source] == .observing {
                if kakaoAccessibilityStatus == .observing && kakaoNotificationStatus == .observing { sourceDetail = "관측 중 · 알림 + 목록" }
                else if kakaoAccessibilityStatus == .permissionRequired { sourceDetail = "알림 관측 중 · 읽음 연동에 손쉬운 사용 권한 필요" }
                else if kakaoNotificationStatus == .permissionRequired { sourceDetail = "목록 관측 중 · 개별 알림에 전체 디스크 접근 필요" }
                else if kakaoAccessibilityStatus != .observing { sourceDetail = "알림 관측 중 · 읽음 연동은 목록 창 확인" }
                else { sourceDetail = "목록 관측 중" }
            }
            line.title = "\(source.title): \(sourceDetail)"
        }
    }
}
