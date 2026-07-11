// Click-through / drag-through: fixes macOS eating the first click on an inactive
// window. The click that activates a background window is normally discarded
// (AppKit's per-view first-mouse rule, decided in the target process) unless the
// hit view opts into `acceptsFirstMouse:`. We SWALLOW that first click, activate
// the window ourselves, and re-post it so it actuates — and because we swallow
// the original, the re-post is immune to double-actuation on views that DO accept
// first mouse (eaten view: 0->1; accepting view: 1->1).
//
// Two independently-toggled behaviours share this machinery. We can't tell at
// mouse-down whether a gesture is a click or a drag, so we always intercept, then
// route on resolution:
//   • Click-through: a background click resolving as a CLICK is re-posted after
//     activation so it actuates (~one activation-latency late).
//   • Drag-through: a background click resolving as a DRAG hands off to a LIVE
//     native drag (e.g. text selection) once the window is focused.
// When a behaviour is OFF, its resolution path reproduces native macOS behaviour
// instead (first click focuses + is eaten; no re-post, no added latency).
//
// See spike/clickthrough.swift for the exploration that established: activation
// (app becoming frontmost) is a ~50ms floor that can't be hurried or masked for
// clicks; drags hide it because pointer tracking is decoupled from key-window
// state. `NSWorkspace.frontmostApplication` and the system-wide AX focused app
// flip together, so there's no ordering slack to exploit.
import Cocoa
import ApplicationServices

/// Stamped on the events we post so our own tap ignores them.
let kClickThroughTag: Int64 = 0x0A17_C71C

final class ClickThroughEngine {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "dev.tim.AltDrag.clickthrough")
    private let postSource = CGEventSource(stateID: .hidSystemState)
    private let dragThreshold: CGFloat = 4

    // Gesture state (all lock-guarded).
    private var active = false
    private var win: AXUIElement?
    private var winPid: pid_t = 0
    private var downLoc = CGPoint.zero
    private var lastLoc = CGPoint.zero
    private var clickState: Int64 = 1
    private var isDrag = false
    private var upSeen = false
    private var activated = false
    private var activationStarted = false
    private var liveDragging = false     // handed off to a native drag; stop swallowing
    private var ctOn = false             // click-through enabled for this gesture
    private var dtOn = false             // drag-through enabled for this gesture

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func cancel() { lock.lock(); resetLocked(); lock.unlock() }
    private func resetLocked() {
        active = false; win = nil; isDrag = false; upSeen = false
        activated = false; activationStarted = false; liveDragging = false
    }

    // --- tap entry points (return true = event swallowed) -------------------

    func onDown(_ event: CGEvent) -> Bool {
        let ct = Settings.shared.clickThroughEnabled
        let dt = Settings.shared.dragThroughEnabled
        guard ct || dt else { return false }

        lock.lock(); let busy = active; lock.unlock()
        if busy { return false }        // don't start a second, overlapping gesture

        let loc = event.location
        // Cheap pre-check via CGWindowList: a click on the already-active app is a
        // normal click — pass it straight through without paying for an AX hit-test.
        guard let ownerPid = topWindowOwnerPid(at: loc),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ownerPid
        else { return false }
        // Respect a per-app "Disabled" rule (shared with the move/resize gestures).
        if case .disabled = AppPolicy.shared.route(at: loc) { return false }
        // Genuine cross-app background click: resolve the AX window to raise/focus.
        guard let w = windowUnder(loc) else { return false }

        lock.lock()
        active = true; win = w; winPid = pid(of: w)
        downLoc = loc; lastLoc = loc
        clickState = event.getIntegerValueField(.mouseEventClickState)
        isDrag = false; upSeen = false; activated = false; activationStarted = false
        liveDragging = false; ctOn = ct; dtOn = dt
        lock.unlock()

        // Click-through wants actuation, so warm activation now (it overlaps the
        // press). Drag-only defers activation to drag-detection so that a plain
        // click can stay perfectly native (no activation, no re-post, no latency).
        if ct { startActivation() }
        return true
    }

    func onDragged(_ event: CGEvent) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        if liveDragging { lock.unlock(); return false }   // native drag is flowing
        guard !upSeen else { lock.unlock(); return false }
        lastLoc = event.location
        var becameDrag = false
        if !isDrag, hypot(event.location.x - downLoc.x, event.location.y - downLoc.y) > dragThreshold {
            isDrag = true; becameDrag = true
        }
        lock.unlock()
        if becameDrag { onBecameDrag() }
        return true
    }

    func onUp(_ event: CGEvent) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        if liveDragging {                       // native gesture: let the real up close it
            resetLocked(); lock.unlock(); return false
        }
        guard !upSeen else { lock.unlock(); return false }
        upSeen = true; lastLoc = event.location
        lock.unlock()
        worker.async { [weak self] in self?.tryFinish() }
        return true
    }

    // --- routing ------------------------------------------------------------

    private func onBecameDrag() {
        lock.lock(); let dt = dtOn, started = activationStarted; lock.unlock()
        if dt {
            if !started { startActivation() }   // lazy activation (drag-only mode)
            worker.async { [weak self] in self?.tryFinish() }
        } else {
            replayNativePassthrough()           // drag-through OFF: native (eaten) drag
        }
    }

    private func startActivation() {
        lock.lock()
        guard active, !activationStarted, let w = win else { lock.unlock(); return }
        activationStarted = true
        let wpid = winPid
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            activateAndWaitForKey(w, winPid: wpid)
            self.lock.lock(); self.activated = true; self.lock.unlock()
            self.tryFinish()
        }
    }

    /// Runs on the worker; fires once the active path is ready. Called from both
    /// the activation completion and the up handler — the lock serialises them.
    private func tryFinish() {
        lock.lock()
        guard active, !liveDragging else { lock.unlock(); return }
        let dragNow = isDrag, up = upSeen, ready = activated
        let dLoc = downLoc, lLoc = lastLoc, cs = clickState

        // Drag + drag-through: hand off to a live native drag while still held.
        if dragNow && dtOn {
            guard ready else { lock.unlock(); return }
            liveDragging = true
            lock.unlock()
            post(.leftMouseDown, at: dLoc, cs: cs)   // real down on the now-focused window
            return
        }

        // Click resolution (needs mouse-up).
        guard up else { lock.unlock(); return }
        if ctOn {
            guard ready else { lock.unlock(); return }
            active = false
            lock.unlock()
            if dragNow {                             // a drag that finished before activation
                post(.leftMouseDown, at: dLoc, cs: cs)
                post(.leftMouseDragged, at: lLoc, cs: cs)
                post(.leftMouseUp, at: lLoc, cs: cs)
            } else {
                post(.leftMouseDown, at: dLoc, cs: cs)
                post(.leftMouseUp, at: dLoc, cs: cs)
            }
            CGWarpMouseCursorPosition(lLoc)          // leave the pointer at the gesture end
            CGAssociateMouseAndMouseCursorPosition(1)
        } else {
            // Click-through OFF: reproduce a native (eaten) click. No activation was
            // started, so re-posting the down lets the OS do its normal first-click
            // (focus + raise + discard) with zero added latency.
            active = false
            lock.unlock()
            post(.leftMouseDown, at: dLoc, cs: cs)
            post(.leftMouseUp, at: dLoc, cs: cs)
        }
    }

    /// Drag-through OFF: re-post the down so the OS handles it natively (eaten
    /// first-click), then let the remaining real drag/up events flow through.
    private func replayNativePassthrough() {
        lock.lock()
        guard active else { lock.unlock(); return }
        liveDragging = true
        let dLoc = downLoc, cs = clickState
        lock.unlock()
        post(.leftMouseDown, at: dLoc, cs: cs)
    }

    private func post(_ type: CGEventType, at loc: CGPoint, cs: Int64) {
        guard let ev = CGEvent(mouseEventSource: postSource, mouseType: type,
                               mouseCursorPosition: loc, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: cs)
        ev.setIntegerValueField(.eventSourceUserData, value: kClickThroughTag)
        ev.post(tap: .cgSessionEventTap)
    }
}

// --- helpers ---------------------------------------------------------------

private func pid(of e: AXUIElement) -> pid_t {
    var p: pid_t = 0
    AXUIElementGetPid(e, &p)
    return p
}

/// The owning pid of the topmost normal window under `loc`, via CGWindowList
/// (front-to-back, global coords). Cheap enough for the every-click down path and
/// avoids an AX round-trip when the click lands on the already-active app.
private func topWindowOwnerPid(at loc: CGPoint) -> pid_t? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let bDict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bDict as CFDictionary),
              r.contains(loc) else { continue }
        return w[kCGWindowOwnerPID as String] as? pid_t
    }
    return nil
}

/// System-wide AX focused app pid — a second "app is active now" signal that, per
/// the spike, flips together with NSWorkspace (no slack, but a useful fallback
/// when one of the two momentarily fails to confirm).
private func axFocusedAppPid() -> pid_t? {
    var v: CFTypeRef?
    let sys = AXUIElementCreateSystemWide()
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success,
          let app = v else { return nil }
    return pid(of: app as! AXUIElement)
}

/// Raise + focus + activate the target window, then block (on the caller's worker
/// thread) until it's genuinely the key window of the active app, or we hit the
/// timeout. Fires on the earlier of NSWorkspace / AX "front" plus a focus confirm,
/// with a short grace so a flaky focus read can't stall the whole gesture.
private func activateAndWaitForKey(_ win: AXUIElement, winPid: pid_t, timeoutMs: Int = 400) {
    let app = AXUIElementCreateApplication(winPid)
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    NSRunningApplication(processIdentifier: winPid)?.activate(options: [])

    var waited = 0
    var frontSince: Int?
    while waited < timeoutMs {
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == winPid
                   || axFocusedAppPid() == winPid
        var focused = false
        var fw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &fw) == .success,
           let fw = fw { focused = CFEqual(fw, win) }
        if isFront {
            if focused { return }
            if let s = frontSince, waited - s > 40 { return }   // grace: front but focus unconfirmed
            if frontSince == nil { frontSince = waited }
        }
        usleep(3000)
        waited += 3
    }
}
