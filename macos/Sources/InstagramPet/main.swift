import AppKit
import PetCore
import PetSources

// 진입점: Dock 아이콘 없는 보조 앱으로 띄우고 PetController에 맡긴다.

// 이 앱에는 일부러 네트워크 클라이언트가 없다. 로컬 소스는 Chrome과 같은 비공개 큐로 들어간다.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()

// shortcut: 비공개 WindowServer SPI(커서·펫 앱들이 흔히 씀). macOS 업데이트로 사라지면 손 모양 커서는 앱이 활성일 때만 보인다.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
