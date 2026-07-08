// alt-drag — menu-bar app entry point.
// LSUIElement (set in Info.plist) keeps it out of the Dock; .accessory is a
// belt-and-suspenders in case it's launched as a bare binary during dev.
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
