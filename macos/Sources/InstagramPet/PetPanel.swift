import AppKit
import PetCore
import PetSources

// 포커스를 가져가지 않는 테두리 없는 패널. 펫 창과 말풍선 오버레이 창에 쓴다.

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
