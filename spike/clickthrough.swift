// alt-drag click-through spike — prove the core hypothesis:
//
// macOS eats the first click on an inactive window: the click only activates,
// and the mouseDown is discarded UNLESS the hit view overrides
// -[NSView acceptsFirstMouse:] to YES. That decision is made in-process, inside
// the target app's AppKit, per-view — so a session-level event tap sitting
// upstream of delivery cannot observe whether a click was eaten. We can only
// see that the click landed on a window that is NOT currently focused.
//
// The mechanism under test: SWALLOW the original first-click, activate the
// target window ourselves (AX raise + app activate), wait until it's actually
// focused, then RE-POST the click. Because we suppress the original, the
// re-post is idempotent regardless of the view's acceptsFirstMouse behavior:
//   - eats-first-mouse view:   0 actuations -> 1  (fixed)
//   - accepts-first-mouse view: 1 actuation  -> 1  (swallowed original, resent) (no double)
//
// What we're trying to LEARN from this spike:
//   1. Does a re-posted click actually actuate the control after activation?
//   2. How long does activation take (raise -> window reports focused)?
//   3. Does swallow+resend avoid double-actuation on accept-first-mouse views
//      (e.g. Safari/Chrome web content)?
//
// Simplifications vs. a shippable version (called out so the feel isn't judged
// on them): drags are buffered and replayed only at mouse-up (so live dragging
// won't feel live here); no per-app opt-out; minimal window-class filtering.

import Cocoa
import ApplicationServices

func log(_ s: String) { FileHandle.standardError.write(("[clickthrough] " + s + "\n").data(using: .utf8)!) }

// Sentinel stamped on events WE post, so our own tap ignores them (same trick
// the workspace switcher uses to tell synthetic gestures apart).
let kSyntheticTag: Int64 = 0x0A17_C71C   // "ALT CTLC"-ish marker

// Movement past this (points) demotes a click to a drag; below it is jitter.
let kDragThreshold: CGFloat = 4

// --- AX helpers ------------------------------------------------------------
func axCopyElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v = v else { return nil }
    return (v as! AXUIElement)
}

/// Walk up from the element under the cursor to its enclosing window.
func windowUnder(_ cursor: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var elt: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(cursor.x), Float(cursor.y), &elt) == .success,
          var cur = elt else { return nil }
    for _ in 0..<25 {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == (kAXWindowRole as String) { return cur }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
              let p = parent else { return nil }
        cur = (p as! AXUIElement)
    }
    return nil
}

func pid(of e: AXUIElement) -> pid_t {
    var p: pid_t = 0
    AXUIElementGetPid(e, &p)
    return p
}

/// The app AX considers focused system-wide. This is answered by the AX/window
/// server (not the target app), so it's a candidate "app is REALLY active now"
/// signal that may lead NSWorkspace.frontmostApplication (a KVO property).
let systemWide = AXUIElementCreateSystemWide()
func axFocusedAppPid() -> pid_t? {
    axCopyElement(systemWide, kAXFocusedApplicationAttribute as String).map { pid(of: $0) }
}

/// Is `win` already the focused window of the frontmost app? (the common case
/// we must pass straight through — zero latency, zero risk).
func isAlreadyFocused(_ win: AXUIElement, winPid: pid_t) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.processIdentifier == winPid else { return false }
    let app = AXUIElementCreateApplication(winPid)
    guard let focused = axCopyElement(app, kAXFocusedWindowAttribute as String) else { return false }
    return CFEqual(focused, win)
}

// Raises+activates, then polls THREE independent readiness signals so we can
// see which leads:
//   • tNs  — NSWorkspace.frontmostApplication == target   (KVO property; may lag)
//   • tAx  — system-wide AX focused app == target          (candidate earlier signal)
//   • tFoc — app's kAXFocusedWindowAttribute == target     (contaminated: we set it)
// We FIRE on the earlier of the two "app is front" signals (Ns or Ax) plus a
// focus confirm, with a short grace so a flaky focus read can't stall us.
struct ActResult {
    var ms: Double?; var reason: String
    var tNs: Double?; var tAx: Double?; var tFoc: Double?
}

func activateAndWait(_ win: AXUIElement, winPid: pid_t, timeoutMs: Int = 400) -> ActResult {
    let app = AXUIElementCreateApplication(winPid)
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    NSRunningApplication(processIdentifier: winPid)?.activate(options: [])

    let start = DispatchTime.now().uptimeNanoseconds
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    var tNs: Double?, tAx: Double?, tFoc: Double?
    var waited = 0
    while waited < timeoutMs {
        let isNs = NSWorkspace.shared.frontmostApplication?.processIdentifier == winPid
        let isAx = axFocusedAppPid() == winPid
        let isFoc = axCopyElement(app, kAXFocusedWindowAttribute as String).map { CFEqual($0, win) } ?? false
        let el = elapsed()
        if isNs, tNs == nil { tNs = el }
        if isAx, tAx == nil { tAx = el }
        if isFoc, tFoc == nil { tFoc = el }
        let isFront = isNs || isAx
        let tFrontFirst = [tNs, tAx].compactMap { $0 }.min()
        if isFront && isFoc {
            let reason = (tAx != nil && (tNs == nil || tAx! < tNs!)) ? "ax-led" : "ns-led"
            return ActResult(ms: el, reason: reason, tNs: tNs, tAx: tAx, tFoc: tFoc)
        }
        if isFront, let tf = tFrontFirst, el - tf > 40 {
            return ActResult(ms: el, reason: "front-only(grace)", tNs: tNs, tAx: tAx, tFoc: tFoc)
        }
        usleep(3000)               // 3ms
        waited += 3
    }
    return ActResult(ms: nil, reason: "timeout", tNs: tNs, tAx: tAx, tFoc: tFoc)
}

// --- re-posting a click ----------------------------------------------------
let postSource = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, at loc: CGPoint, clickState: Int64) {
    guard let ev = CGEvent(mouseEventSource: postSource, mouseType: type,
                           mouseCursorPosition: loc, mouseButton: .left) else { return }
    ev.setIntegerValueField(.mouseEventClickState, value: clickState)
    ev.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)
    ev.post(tap: .cgSessionEventTap)
}

// --- gesture state (guarded by `lock`) -------------------------------------
final class Pending {
    var active = false
    var win: AXUIElement?
    var winPid: pid_t = 0
    var downLoc = CGPoint.zero
    var lastLoc = CGPoint.zero
    var clickState: Int64 = 1
    var isDrag = false
    var upSeen = false
    var activated = false
    var liveDragging = false   // handed off to a live native drag; stop swallowing
    var downTime = DispatchTime.now().uptimeNanoseconds
}
let pending = Pending()
let lock = NSLock()
let worker = DispatchQueue(label: "clickthrough.worker")   // serial: activate then finish

// Called once activation completes AND (for the replay path) once mouse-up is
// seen. Two outcomes:
//   • released before activation  -> replay the buffered gesture, cursor to end
//   • still holding at activation  -> hand off to a LIVE native drag: post the
//     real mouseDown on the now-focused window and stop swallowing, so the rest
//     of the drag (e.g. text selection) tracks natively.
// Runs on the worker (serial) or the up-handler; the lock guards the flags.
func tryFinish() {
    lock.lock()
    guard pending.active, pending.activated, !pending.liveDragging else { lock.unlock(); return }
    let downLoc = pending.downLoc, lastLoc = pending.lastLoc
    let cs = pending.clickState, isDrag = pending.isDrag, upSeen = pending.upSeen
    let total = Double(DispatchTime.now().uptimeNanoseconds - pending.downTime) / 1_000_000

    if !upSeen {
        // Still holding: begin a live native gesture at the true origin, then
        // let the real hardware drag/up events flow straight through.
        pending.liveDragging = true
        lock.unlock()
        post(.leftMouseDown, at: downLoc, clickState: cs)
        log(String(format: "handoff -> LIVE gesture, down@(%.0f,%.0f) native from here (%.1fms)",
                   downLoc.x, downLoc.y, total))
        return
    }

    // Released already: replay the finished gesture in one shot.
    pending.active = false
    lock.unlock()
    if isDrag {
        post(.leftMouseDown, at: downLoc, clickState: cs)
        post(.leftMouseDragged, at: lastLoc, clickState: cs)
        post(.leftMouseUp, at: lastLoc, clickState: cs)
        log(String(format: "replayed DRAG down@(%.0f,%.0f)->up@(%.0f,%.0f)  total %.1fms",
                   downLoc.x, downLoc.y, lastLoc.x, lastLoc.y, total))
    } else {
        post(.leftMouseDown, at: downLoc, clickState: cs)
        post(.leftMouseUp, at: downLoc, clickState: cs)
        log(String(format: "replayed CLICK @(%.0f,%.0f) clickState=%d  total %.1fms",
                   downLoc.x, downLoc.y, cs, total))
    }
    // Leave the cursor at the gesture's end point (lastLoc == up location; for a
    // plain click it equals downLoc). The pointer was frozen through the wait, so
    // it's already here — this just makes it explicit.
    CGWarpMouseCursorPosition(lastLoc)
    CGAssociateMouseAndMouseCursorPosition(1)
}

// --- event tap -------------------------------------------------------------
var sharedTap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    // Ignore our own re-posted events.
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticTag {
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = sharedTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)

    case .leftMouseDown:
        // Stay out of the way of alt-drag's own gestures / menu interactions.
        if event.flags.intersection([.maskAlternate, .maskCommand, .maskControl]).isEmpty == false {
            return Unmanaged.passUnretained(event)
        }
        // A gesture is already in flight (activating or live-dragging). Don't start
        // a second one — overlapping gestures each fire their own AXRaise, which is
        // what raised multiple windows of the same app. Let this click pass through.
        lock.lock(); let busy = pending.active; lock.unlock()
        if busy { return Unmanaged.passUnretained(event) }

        let loc = event.location
        guard let win = windowUnder(loc) else { return Unmanaged.passUnretained(event) }
        let wpid = pid(of: win)
        if isAlreadyFocused(win, winPid: wpid) {
            return Unmanaged.passUnretained(event)     // common case: pass straight through
        }
        // Cross-window / cross-app first click: swallow, activate, will resend.
        let cs = event.getIntegerValueField(.mouseEventClickState)
        lock.lock()
        pending.active = true; pending.win = win; pending.winPid = wpid
        pending.downLoc = loc; pending.lastLoc = loc; pending.clickState = cs
        pending.isDrag = false; pending.upSeen = false; pending.activated = false
        pending.downTime = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        log(String(format: "swallowed first-click on unfocused win (pid %d) @(%.0f,%.0f) — activating…",
                   wpid, loc.x, loc.y))
        worker.async {
            let r = activateAndWait(win, winPid: wpid)
            lock.lock(); pending.activated = true; lock.unlock()
            func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
            let signals = "ns@\(ms(r.tNs)) ax@\(ms(r.tAx)) foc@\(ms(r.tFoc))"
            if let t = r.ms {
                let lead = (r.tNs != nil && r.tAx != nil) ? String(format: "  ns-ax gap=%.1fms", r.tNs! - r.tAx!) : ""
                log(String(format: "activated in %.1fms [%@] (%@)%@", t, r.reason, signals, lead))
            } else {
                log("activation TIMED OUT — click likely LOST (\(signals))")
            }
            tryFinish()
        }
        return nil     // swallow original down

    case .leftMouseDragged:
        lock.lock()
        if pending.liveDragging { lock.unlock(); return Unmanaged.passUnretained(event) } // native drag
        let armed = pending.active && !pending.upSeen
        if armed {
            pending.lastLoc = event.location
            // Only a real drag past the threshold demotes this off the click path;
            // sub-threshold jitter stays a click (avoids the 1px "DRAG" mislabel).
            if hypot(event.location.x - pending.downLoc.x,
                     event.location.y - pending.downLoc.y) > kDragThreshold {
                pending.isDrag = true
            }
        }
        lock.unlock()
        return armed ? nil : Unmanaged.passUnretained(event)

    case .leftMouseUp:
        lock.lock()
        if pending.liveDragging {                       // native gesture in progress
            pending.active = false; pending.liveDragging = false
            lock.unlock()
            log("live gesture ended (native up)")
            return Unmanaged.passUnretained(event)      // let the real up close it
        }
        let armed = pending.active && !pending.upSeen
        if armed { pending.upSeen = true; pending.lastLoc = event.location }
        lock.unlock()
        if armed { worker.async { tryFinish() }; return nil }
        return Unmanaged.passUnretained(event)

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// --- boot ------------------------------------------------------------------
let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: mask, callback: callback, userInfo: nil
) else {
    log("FAILED to create event tap — grant Accessibility to your terminal:")
    log("System Settings > Privacy & Security > Accessibility")
    exit(1)
}
sharedTap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

log("running. Click controls in BACKGROUND windows (no modifiers).")
log("Try: a button/tab in an inactive native app, then web content in an inactive browser.")
log("Ctrl+C to quit.")
CFRunLoopRun()
