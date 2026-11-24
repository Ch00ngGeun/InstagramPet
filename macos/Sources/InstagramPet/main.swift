import AppKit
import PetCore
import PetSources

// The application deliberately has no network client. Local sources join Chrome's private queue.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = PetController()
app.delegate = controller
app.run()

// shortcut: private WindowServer SPI (widely used by cursor/pet apps); if a macOS update removes it, the hand shows only while the app is active.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32
