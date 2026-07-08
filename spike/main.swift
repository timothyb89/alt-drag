// alt-drag spike — prove the core hypothesis:
// remapping Option+left-drag onto the native Ctrl+Cmd window-move gesture
// (NSWindowShouldDragOnGesture) yields a pixel-perfect native drag.
//
// It does ONE thing: install a session-level CGEventTap, and while an
// Option+left-drag is in progress, rewrite the event's modifier flags from
// Option -> Control+Command and return the mutated (real) event. The window
// server then performs its own native move — snapping, guides, drag zones,
// cross-monitor — all for free.
//
// No window is ever identified or repositioned by us. That's the whole point.

import Cocoa
import CoreGraphics

// The flags the native gesture wants.
let dragFlags: CGEventFlags = [.maskControl, .maskCommand]

// True from an Option+leftMouseDown until the matching leftMouseUp.
// Drives rewriting so a mid-drag Option release doesn't drop the gesture.
var dragging = false

func log(_ s: String) { FileHandle.standardError.write(("[alt-drag] " + s + "\n").data(using: .utf8)!) }

func rewrite(_ event: CGEvent) {
    var f = event.flags
    f.remove(.maskAlternate)          // strip Option so apps don't see it
    f.formUnion(dragFlags)            // add Ctrl+Cmd -> native move gesture
    event.flags = f
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        log("tap disabled by system; re-enabling")
        if let tap = sharedTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)

    case .leftMouseDown:
        if event.flags.contains(.maskAlternate) {
            dragging = true
            log("Option+down -> starting native move")
            rewrite(event)
        }

    case .leftMouseDragged:
        if dragging { rewrite(event) }

    case .leftMouseUp:
        if dragging {
            rewrite(event)            // keep gesture coherent through release
            dragging = false
            log("up -> ending move")
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

var sharedTap: CFMachPort?

// --- Prerequisite check: NSWindowShouldDragOnGesture -----------------------
let g = UserDefaults.standard
let gestureOn = (g.object(forKey: "NSWindowShouldDragOnGesture") as? Bool) ?? false
if !gestureOn {
    log("NSWindowShouldDragOnGesture is OFF. Enable it, then re-launch apps:")
    log("    defaults write -g NSWindowShouldDragOnGesture -bool true")
    log("(continuing anyway so you can test Ctrl+Cmd manually)")
}

// --- Event tap -------------------------------------------------------------
let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,             // .defaultTap = may modify/drop events
    eventsOfInterest: mask,
    callback: callback,
    userInfo: nil
) else {
    log("FAILED to create event tap — grant Accessibility permission to your terminal")
    log("System Settings > Privacy & Security > Accessibility")
    exit(1)
}
sharedTap = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

log("running. Hold Option and left-drag any window. Ctrl+C to quit.")
CFRunLoopRun()
