// Click-through / drag-through: fixes macOS eating the first click on an inactive
// window. The click that activates a background window is normally discarded
// (AppKit's per-view first-mouse rule, decided in the target process) unless the
// hit view opts into `acceptsFirstMouse:`. We SWALLOW that first click, make the
// window key ourselves, and re-post it so it actuates — and because we swallow
// the original, the re-post is immune to double-actuation on views that DO accept
// first mouse (eaten view: 0->1; accepting view: 1->1).
//
// Architecture (validated in spike/clickthrough2.swift + spike/RESULTS.md):
//   1. SLPS fast focus — the private _SLPSSetFrontProcessWithOptions + make-key
//      event records (the AltTab/yabai mechanism) make the target window key in
//      ~1-2ms, vs 40-200ms for the NSRunningApplication/AX activation race. The
//      symbols are dlsym-guarded; when missing we degrade to the NS/AX race.
//   2. session-fast delivery — after the make-key, wait only for the CG z-order
//      flip under the click point (raise-confirm, bounded; typically 5-15ms,
//      per-app tunable cap), then re-post the down to the session tap and hand
//      the rest of the hardware gesture off live. No NSWorkspace/AX confirmation
//      polling anywhere: those signals lag the real focus flip by 50-70ms.
//      Direct pid delivery is NOT used: pid-posted mouse events arrive without a
//      window-server window binding and AppKit drops them (see spike/RESULTS.md
//      run 3 for the receiver-side proof).
//   3. cursor continuity — while delivery is pending, leftMouseDragged events are
//      mutated to mouseMoved and passed through, so the pointer keeps gliding
//      instead of freezing; no end-of-gesture warp.
//
// Toggles: click-through delivers at mouse-down (both clicks and the drags that
// follow land on the now-key window). Drag-through alone defers everything to
// drag-detection so a plain click stays perfectly native (focus + eaten click,
// zero added latency).
import Cocoa
import ApplicationServices
import CoreServices

/// Stamped on the events we post so our own tap ignores them.
let kClickThroughTag: Int64 = 0x0A17_C71C

// --- SLPS fast focus (private SkyLight/CPS, dlsym-guarded) -------------------
// dlsym (not @_silgen_name) so a future macOS that drops a symbol degrades at
// runtime instead of failing to launch. SkyLight is loaded transitively via
// AppKit, so the global handle usually resolves everything.

private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
private typealias SLPSSetFrontFn     = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private typealias SLPSPostEventFn    = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
private typealias AXGetWindowFn      = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

private func slSym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = dlopen(nil, RTLD_LAZY), let p = dlsym(h, name) { return p }
    if let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let p = dlsym(h, name) { return p }
    return nil
}

private let fnGetProcessForPID = slSym("GetProcessForPID").map { unsafeBitCast($0, to: GetProcessForPIDFn.self) }
private let fnSLPSSetFront     = slSym("_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SLPSSetFrontFn.self) }
private let fnSLPSPostEvent    = slSym("SLPSPostEventRecordTo").map { unsafeBitCast($0, to: SLPSPostEventFn.self) }
private let fnAXGetWindow      = slSym("_AXUIElementGetWindow").map { unsafeBitCast($0, to: AXGetWindowFn.self) }
private let slpsAvailable = fnGetProcessForPID != nil && fnSLPSSetFront != nil && fnSLPSPostEvent != nil

/// _SLPSSetFrontProcessWithOptions "user generated" flag (AltTab's value; matches
/// the CPS SetFrontProcessWithOptions option bit).
private let kCPSUserGenerated: UInt32 = 0x200

/// Byte layout verified against yabai master src/window_manager.c
/// (window_manager_make_key_window): memset 0 over 0xf8 bytes, [0x04]=0xf8,
/// [0x3a]=0x10, window_id at 0x3c (4 bytes, little-endian), 0xff fill over
/// [0x20..0x30), then post with [0x08]=0x01 followed by [0x08]=0x02.
private func makeKeyWindow(psn: inout ProcessSerialNumber, wid: CGWindowID) {
    guard let postEvent = fnSLPSPostEvent else { return }
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: UInt32(wid).littleEndian) { src in
        for i in 0..<4 { bytes[0x3c + i] = src[i] }
    }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    withUnsafeMutablePointer(to: &psn) { psnPtr in
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(psnPtr, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(psnPtr, $0.baseAddress!) }
    }
}

/// Make `wid` (owned by `pid`) the key window near-synchronously. Mirrors yabai's
/// window_manager_focus_window_with_raise (SLPSSetFront -> make_key_window; the
/// cosmetic AXRaise trails on the caller's worker). Returns false when the
/// symbols are missing or the PSN lookup fails, so the caller can fall back.
private func fastFocus(pid: pid_t, wid: CGWindowID) -> Bool {
    guard slpsAvailable, let getPSN = fnGetProcessForPID, let setFront = fnSLPSSetFront else { return false }
    var psn = ProcessSerialNumber()
    guard withUnsafeMutablePointer(to: &psn, { getPSN(pid, $0) }) == noErr else { return false }
    _ = withUnsafeMutablePointer(to: &psn) { setFront($0, wid, kCPSUserGenerated) }
    makeKeyWindow(psn: &psn, wid: wid)
    return true
}

final class ClickThroughEngine {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "dev.tim.AltDrag.clickthrough")
    private let postSource = CGEventSource(stateID: .hidSystemState)
    private let dragThreshold: CGFloat = 4

    // Gesture state (all lock-guarded).
    private var active = false
    private var win: AXUIElement?
    private var winPid: pid_t = 0
    private var wid: CGWindowID = 0
    private var raiseCapMs = 40
    private var downLoc = CGPoint.zero
    private var lastLoc = CGPoint.zero
    private var clickState: Int64 = 1
    private var isDrag = false
    private var upSeen = false
    private var delivered = false        // synthetic down posted
    private var deliveryStarted = false
    private var liveDragging = false     // handed off to a native drag; stop intercepting
    private var ctOn = false             // click-through enabled for this gesture
    private var dtOn = false             // drag-through enabled for this gesture

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func cancel() { lock.lock(); resetLocked(); lock.unlock() }
    private func resetLocked() {
        active = false; win = nil; isDrag = false; upSeen = false
        delivered = false; deliveryStarted = false; liveDragging = false
    }

    /// Absorb the lazy first-call costs (AX connection spin-up, window list,
    /// event source, private-symbol resolution) off the tap thread at startup.
    /// Without this the first gesture's down handler can stall long enough to
    /// trip the tap timeout, which passes the original down through unswallowed
    /// alongside our re-post (stuck-drag / cursor-snap cold-start bugs).
    func prewarm() {
        worker.async { [postSource] in
            _ = slpsAvailable
            var psn = ProcessSerialNumber()
            _ = fnGetProcessForPID?(getpid(), &psn)
            _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            _ = NSWorkspace.shared.frontmostApplication
            if let loc = CGEvent(source: nil)?.location { _ = windowUnder(loc) }
            _ = CGEvent(mouseEventSource: postSource, mouseType: .mouseMoved,
                        mouseCursorPosition: .zero, mouseButton: .left)
        }
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
        guard let top = topWindow(at: loc),
              NSWorkspace.shared.frontmostApplication?.processIdentifier != top.pid
        else { return false }
        // Respect a per-app "Disabled" rule (shared with the move/resize gestures).
        if case .disabled = AppPolicy.shared.route(at: loc) { return false }
        // Genuine cross-app background click: resolve the AX window to raise/focus.
        guard let w = windowUnder(loc) else { return false }

        let bid = NSRunningApplication(processIdentifier: top.pid)?.bundleIdentifier
        lock.lock()
        active = true; win = w; winPid = pid(of: w)
        wid = cgWindowID(of: w) ?? top.wid
        raiseCapMs = AppPolicy.shared.raiseConfirmCapMs(bundleId: bid)
        downLoc = loc; lastLoc = loc
        clickState = event.getIntegerValueField(.mouseEventClickState)
        isDrag = false; upSeen = false; delivered = false; deliveryStarted = false
        liveDragging = false; ctOn = ct; dtOn = dt
        lock.unlock()

        // Click-through: make the window key now and deliver as soon as the raise
        // lands. Drag-only defers to drag-detection so a plain click stays
        // perfectly native (no focus action, no re-post, no latency).
        if ct { startDelivery() }
        return true
    }

    func onDragged(_ event: CGEvent) -> Bool {
        lock.lock()
        guard active, !liveDragging, !upSeen else { lock.unlock(); return false }
        lastLoc = event.location
        var becameDrag = false
        if !isDrag, hypot(event.location.x - downLoc.x, event.location.y - downLoc.y) > dragThreshold {
            isDrag = true; becameDrag = true
        }
        lock.unlock()
        if becameDrag {
            lock.lock(); let dt = dtOn, started = deliveryStarted; lock.unlock()
            if dt && !started { startDelivery() }   // drag-only mode: focus at drag detection
        }
        // Keep the pointer gliding while delivery is pending: pass the motion
        // through as a mouseMoved (carries the cursor, reads as a drag to no one)
        // instead of dropping it, which pinned the pointer and forced a warp.
        event.type = .mouseMoved
        return false
    }

    func onUp(_ event: CGEvent) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        if liveDragging {                       // native gesture: let the real up close it
            resetLocked(); lock.unlock(); return false
        }
        guard !upSeen else { lock.unlock(); return false }
        upSeen = true; lastLoc = event.location
        let started = deliveryStarted
        let dLoc = downLoc, cs = clickState
        if !started { active = false }
        lock.unlock()

        if !started {
            // Drag-only gesture that resolved as a click: reproduce the native
            // (eaten) first click — focus + raise + discard, zero added latency.
            post(.leftMouseDown, at: dLoc, cs: cs)
            post(.leftMouseUp, at: dLoc, cs: cs)
        }
        // Otherwise the worker's deliverDown closes out the finished gesture.
        return true
    }

    // --- delivery ------------------------------------------------------------

    /// Make the target window key, wait (bounded) for the raise to land, then
    /// re-post the down. Fast path: synchronous SLPS make-key (~1-2ms) + a
    /// z-order raise-confirm spin on the worker, cosmetic AXRaise trailing.
    /// Fallback (symbols missing): the NS/AX activation race, feeding the same
    /// delivery funnel.
    private func startDelivery() {
        lock.lock()
        guard active, !deliveryStarted, let w = win else { lock.unlock(); return }
        deliveryStarted = true
        let wpid = winPid, targetWid = wid, loc = downLoc, cap = raiseCapMs
        lock.unlock()

        if fastFocus(pid: wpid, wid: targetWid) {
            worker.async { [weak self] in
                guard let self else { return }
                waitForRaise(targetWid, at: loc, capMs: cap)
                self.deliverDown()
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)   // cosmetic, like yabai
            }
        } else {
            worker.async { [weak self] in
                activateAndWaitForKey(w, winPid: wpid)
                self?.deliverDown()
            }
        }
    }

    /// Runs on the worker once the target is ready: post the down, then either
    /// close out an already-finished gesture or hand off to the live native
    /// gesture. The down is posted under the lock so a concurrently-passing
    /// hardware up can never overtake it.
    private func deliverDown() {
        lock.lock()
        guard active, !delivered else { lock.unlock(); return }
        delivered = true
        let dLoc = downLoc, cs = clickState
        post(.leftMouseDown, at: dLoc, cs: cs)
        if upSeen {
            let lLoc = lastLoc, drag = isDrag
            active = false
            lock.unlock()
            if drag { post(.leftMouseDragged, at: lLoc, cs: cs) }
            post(.leftMouseUp, at: lLoc, cs: cs)
        } else {
            liveDragging = true     // real drags/up flow natively from here
            lock.unlock()
        }
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

/// The topmost normal window under `loc` via CGWindowList (front-to-back,
/// global coords): owning pid + window id. Cheap enough for the every-click
/// down path and avoids an AX round-trip when the click lands on the active app.
private func topWindow(at loc: CGPoint) -> (pid: pid_t, wid: CGWindowID)? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let bDict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bDict as CFDictionary),
              r.contains(loc) else { continue }
        guard let p = w[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (p, (w[kCGWindowNumber as String] as? CGWindowID) ?? 0)
    }
    return nil
}

/// The CGWindowID of an AX window via the private _AXUIElementGetWindow
/// (dlsym-guarded; matches the AX-hit window exactly). Nil when unavailable —
/// the caller falls back to the CGWindowList top window.
private func cgWindowID(of ax: AXUIElement) -> CGWindowID? {
    guard let fn = fnAXGetWindow else { return nil }
    var w: UInt32 = 0
    guard fn(ax, &w) == .success, w != 0 else { return nil }
    return w
}

/// Is `wid` the frontmost layer-0 window AT `loc`? Point-scoped on purpose: the
/// global CGWindowList z-order interleaves displays, so the target can be
/// frontmost on its display without being first in the global list.
private func isFrontmostWindow(_ wid: CGWindowID, at loc: CGPoint) -> Bool {
    guard wid != 0 else { return false }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let bDict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bDict as CFDictionary),
              r.contains(loc) else { continue }
        return (w[kCGWindowNumber as String] as? CGWindowID) == wid
    }
    return false
}

/// Raise-confirm: spin (1ms steps, bounded by `capMs`) until the z-order flip
/// from the make-key lands server-side, so the session-posted down can't
/// hit-test into the OLD frontmost window. Typically passes in 5-15ms; Chromium
/// windows are the slow end (~9-14ms observed).
private func waitForRaise(_ wid: CGWindowID, at loc: CGPoint, capMs: Int) {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, capMs)) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if isFrontmostWindow(wid, at: loc) { return }
        usleep(1000)
    }
}

/// System-wide AX focused app pid — a second "app is active now" signal that
/// flips together with NSWorkspace (fallback-path confirmation only).
private func axFocusedAppPid() -> pid_t? {
    var v: CFTypeRef?
    let sys = AXUIElementCreateSystemWide()
    guard AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success,
          let app = v else { return nil }
    return pid(of: app as! AXUIElement)
}

/// Fallback when the SLPS symbols are unavailable: raise + focus + activate the
/// target window, then block (on the worker) until it's genuinely the key window
/// of the active app, or we hit the timeout. Fires on the earlier of NSWorkspace
/// / AX "front" plus a focus confirm, with a short grace so a flaky focus read
/// can't stall the whole gesture.
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
