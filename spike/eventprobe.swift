// alt-drag event probe — RECEIVER harness for the delivery experiments (run 3).
//
// Decisive question after run 2 falsified the first-mouse theory (app active at
// dispatch time, click still dead): do pid-posted mouse events reach
// NSApplication.sendEvent at all, and with what windowNumber?
//
// Theory under test: mouse events are normally bound to a window BY THE WINDOW
// SERVER as they pass through it; CGEventPostToPid skips the server, so the NSEvent
// arrives with no valid windowNumber and AppKit drops it before any view sees it
// (matches longstanding reports that postToPid works for keyboard but not mouse).
// Fields 91/92 may be read-only tap metadata that dispatch ignores.
//
// This app: one visible FLOATING window with a real NSButton, activation policy
// .accessory and never activated — i.e. deliberately INACTIVE, the exact
// click-through scenario. It logs every event that reaches the local-monitor and
// sendEvent stages (type, windowNumber, locationInWindow, clickCount, eventNumber,
// fields 91/92 read back from the underlying CGEvent), and "*** BUTTON ACTUATED ***"
// when the button really fires. On launch it prints its pid, windowNumber, and the
// CG coordinates of the button so the poster can aim at it:
//
//   ./eventprobe                       # leave running; note the printed values
//   ./clickthrough2 --probe-pid=<pid> --probe-at=<x,y> --probe-wid=<windowNumber> \
//                   [--probe-post=pid|sl|session] [--probe-scan]
//
// Poster pairs are tagged via clickState (arrives as NSEvent.clickCount):
//   1 = plain pair, 2 = fields-91/92 pair, 51..58 = raw-field-scan pair for that
//   CGEvent field number (candidate windowNumber carriers).

import Cocoa

func plog(_ s: String) { FileHandle.standardError.write(("[eventprobe] " + s + "\n").data(using: .utf8)!) }
let t0 = DispatchTime.now().uptimeNanoseconds
func ts() -> String { String(format: "%.1fms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) }

func describe(_ e: NSEvent, via: String) {
    var s = "\(ts()) \(via): type=\(e.type)(\(e.type.rawValue)) windowNumber=\(e.windowNumber) hasWindow=\(e.window != nil)"
    switch e.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        s += String(format: " locInWindow=(%.0f,%.0f) clickCount=%d eventNumber=%d",
                    e.locationInWindow.x, e.locationInWindow.y, e.clickCount, e.eventNumber)
        if let cg = e.cgEvent {
            s += " f91=\(cg.getIntegerValueField(.mouseEventWindowUnderMousePointer))"
            s += " f92=\(cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))"
            // Raw-field dump: read back candidate window-binding fields so a
            // server-bound (session-posted) event reveals which private fields carry
            // windowNumber and the window-local location. 52/53 also as doubles.
            var raw = ""
            for f: UInt32 in 51...58 {
                if let field = CGEventField(rawValue: f) {
                    raw += " f\(f)=\(cg.getIntegerValueField(field))"
                }
            }
            if let f52 = CGEventField(rawValue: 52), let f53 = CGEventField(rawValue: 53) {
                raw += String(format: " d52=%.1f d53=%.1f",
                              cg.getDoubleValueField(f52), cg.getDoubleValueField(f53))
            }
            s += raw
        }
    case .leftMouseDragged, .rightMouseDragged, .mouseMoved:
        s += String(format: " locInWindow=(%.0f,%.0f)", e.locationInWindow.x, e.locationInWindow.y)
    case .keyDown, .keyUp:
        s += " keyCode=\(e.keyCode)"
    default:
        break
    }
    plog(s)
}

final class ProbeApp: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        describe(event, via: "sendEvent")
        super.sendEvent(event)
    }
}

final class ButtonTarget: NSObject {
    @objc func pressed(_ sender: Any?) { plog("\(ts()) *** BUTTON ACTUATED ***") }
}

let app = ProbeApp.shared              // must be first NSApplication.shared call
app.setActivationPolicy(.accessory)    // visible window, but the app stays INACTIVE

// Local monitor fires when the event is dequeued, BEFORE sendEvent dispatch — so a
// "monitor" line without a matching view reaction pins the drop inside sendEvent,
// while total silence means the event never entered this process's queue at all.
NSEvent.addLocalMonitorForEvents(matching: .any) { e in
    describe(e, via: "monitor")
    return e
}

let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 240),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.title = "eventprobe"
win.level = .floating                  // topmost at its spot, so session-posted control clicks hit it
win.isReleasedWhenClosed = false

let target = ButtonTarget()            // global: NSControl.target is weak
let button = NSButton(title: "probe target", target: target, action: #selector(ButtonTarget.pressed(_:)))
button.setFrameSize(NSSize(width: 160, height: 48))
if let cv = win.contentView {
    button.setFrameOrigin(NSPoint(x: (cv.bounds.width - 160) / 2, y: (cv.bounds.height - 48) / 2))
    cv.addSubview(button)
}
win.orderFrontRegardless()             // show WITHOUT activating the app

// Aiming data. CG global coords are top-left-origin of the primary display; Cocoa
// screen coords are bottom-left-origin — convert via the primary screen's maxY.
let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
let btnScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
let cgPoint = CGPoint(x: btnScreen.midX, y: primaryMaxY - btnScreen.midY)
// Our CGS/SLS window-server connection id — candidate payload for CGEvent field 52
// (a genuine server-bound event carries a connection-id-shaped value there).
typealias MainCidFn = @convention(c) () -> Int32
var cid: Int32 = 0
for name in ["CGSMainConnectionID", "SLSMainConnectionID"] {
    if let p = dlsym(dlopen(nil, RTLD_LAZY), name) {
        cid = unsafeBitCast(p, to: MainCidFn.self)(); break
    }
}
plog("pid=\(getpid()) windowNumber=\(win.windowNumber) connectionId=\(cid)")
plog(String(format: "button center (CG coords) = (%.0f,%.0f)", cgPoint.x, cgPoint.y))
plog("poster: ./clickthrough2 --probe-pid=\(getpid()) --probe-at=\(Int(cgPoint.x)),\(Int(cgPoint.y)) --probe-wid=\(win.windowNumber)")
plog("running — logging every event that reaches monitor/sendEvent. Ctrl+C to quit.")
app.run()
