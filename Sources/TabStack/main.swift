import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon or menu bar: TabStack lives in its sidebar (quit from the workspace menu).
app.setActivationPolicy(.accessory)
app.run()
