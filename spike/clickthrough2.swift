// alt-drag click-through spike #2 — latency experiments on top of the baseline
// established in spike/clickthrough.swift.
//
// The baseline proved swallow+activate+resend fixes the eaten first-click, but it
// has two perceived-latency problems:
//   1. cursor FREEZE — while activation is pending, leftMouseDragged is swallowed
//      (return nil), which pins the pointer for the 30–200ms activation wait.
//   2. click-AFTER-raise — the replayed click posts to .cgSessionEventTap, which
//      routes through window-server z-order hit-testing, so the target window must
//      be raised+key BEFORE the click can land. The click is perceived as late.
//
// This spike adds three independent, toggleable experiments (see spike/EXPERIMENTS.md):
//
//   --focus=slps|nsax   (default nsax)  Experiment 1: SLPS private-API fast focus
//       nsax  — the baseline NSRunningApplication.activate + AX raise + polling race.
//       slps  — _SLPSSetFrontProcessWithOptions + make-key-window event records
//               (the mechanism AltTab / yabai use) to make the window key ~synchronously.
//
//   --post=pid|session  (default session)  Experiment 2: deliver click before raise
//       session — baseline: swallow, wait for activation, replay to .cgSessionEventTap.
//       pid     — invert: post the mousedown straight to the target pid
//                 (CGEventPostToPid, fields 91/92 set to the hit-tested window id),
//                 raise trailing async as a cosmetic step.
//                 FIRST-RUN FINDING (RESULTS.md): fields 91/92 fixed the ROUTING, but
//                 AppKit applies the first-mouse rule at DISPATCH time from the app's
//                 active state — a down posted at ~1ms while activation confirmed at
//                 60-190ms was discarded app-side in every app. So delivery is now
//                 SEQUENCED: with slps available we synchronously fastFocus (~1-2ms)
//                 BEFORE posting — the make-key records precede our mousedown in the
//                 target's event queue, so by dispatch time the app is active and
//                 first-mouse no longer applies; event-queue ordering does the
//                 sequencing, no polling wait. With slps missing or --focus=nsax, we
//                 fire the nsax activators and post the down only once a front signal
//                 confirms (drag/up posts queue behind on the serial worker).
//
//   --primer            (default off)  Chromium probe from EXPERIMENTS.md: with
//       --post=pid, post a throwaway click at (-1,-1) to the pid ~5ms before the real
//       down, to satisfy renderer-side user-activation gating. Only try this if
//       Chrome still ignores clicks after the slps-first sequencing.
//
//   --cursor=move|freeze (default freeze)  Experiment 3: cursor continuity
//       freeze  — baseline: swallow drags (return nil) → the pointer is pinned, then
//                 warped to the gesture end.
//       move    — mutate the swallowed leftMouseDragged into a mouseMoved and let it
//                 through, so the cursor keeps gliding; no end-of-gesture warp.
//
// Defaults (nsax / session / freeze) reproduce the baseline behaviour EXACTLY, so an
// A/B run against spike/clickthrough is a flag change only. Log-line format and the
// timing instrumentation (`activated in X ms [reason] (ns@ ax@ foc@ raise@)`) match
// the baseline so results are directly comparable, with two additions after run 1:
//   raise@ — CGWindowList z-order signal: when the target wid became the frontmost
//            layer-0 window. Separates "window raised" (visible) from "app active"
//            (what first-mouse cares about); the ns/ax polls lag the real flip.
//   after-up — session replays fire on mouse-up, so `total` includes the physical
//            button-hold; `after-up` is the real added latency (mouseup -> replay).
//
// SIP stays fully enabled. The private SLPS / AX symbols are resolved with dlsym and
// guarded: if any is missing (e.g. a future macOS), --focus=slps degrades to the
// NS/AX path automatically.
//
// Simplifications vs. a shippable version (same as the baseline): drags in session
// mode are buffered/replayed at mouse-up; no per-app opt-out; minimal window filtering.

import Cocoa
import ApplicationServices
import CoreServices   // ProcessSerialNumber, OSStatus/noErr

func log(_ s: String) { FileHandle.standardError.write(("[clickthrough] " + s + "\n").data(using: .utf8)!) }

// --- mode flags ------------------------------------------------------------
enum FocusMode:  String { case slps, nsax }
enum PostMode:   String { case pid, session }
enum CursorMode: String { case move, freeze }

struct Config {
    var focus:  FocusMode  = .nsax     // default == baseline
    var post:   PostMode   = .session  // default == baseline
    var cursor: CursorMode = .freeze   // default == baseline
    var primer = false                 // Chromium user-activation probe (pid mode only)
}
var cfg = Config()

func printUsage() {
    log("usage: clickthrough2 [--focus=slps|nsax] [--post=pid|session] [--cursor=move|freeze] [--primer]")
    log("  --focus   slps  = _SLPSSetFrontProcessWithOptions fast-focus (Experiment 1)")
    log("            nsax  = NSRunningApplication.activate + AX raise (baseline)   [default]")
    log("  --post    pid   = CGEventPostToPid delivery, fields 91/92 (Experiment 2);")
    log("                    sequenced AFTER a sync slps make-key (~1-2ms) when available,")
    log("                    else after the nsax front signal confirms")
    log("            session = replay to .cgSessionEventTap after activation (baseline) [default]")
    log("  --cursor  move  = mutate swallowed drag -> mouseMoved, keep gliding (Experiment 3)")
    log("            freeze = swallow drag, pin pointer, warp at end (baseline)     [default]")
    log("  --primer        = with --post=pid, post a throwaway click @(-1,-1) to the pid")
    log("                    ~5ms before the real down (Chromium user-activation probe)")
    log("  defaults reproduce spike/clickthrough exactly, for A/B comparison.")
    log("  requires Accessibility: System Settings > Privacy & Security > Accessibility")
    log("  (grant it to the terminal / process running this binary).")
}

func parseArgs() -> Config {
    var c = Config()
    for arg in CommandLine.arguments.dropFirst() {
        if arg == "-h" || arg == "--help" { printUsage(); exit(0) }
        if arg == "--primer" { c.primer = true; continue }
        let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { log("ignoring unrecognized arg: \(arg)"); continue }
        let (k, v) = (parts[0], parts[1])
        switch k {
        case "--focus":  if let m = FocusMode(rawValue: v)  { c.focus = m }  else { log("bad --focus=\(v)"); exit(2) }
        case "--post":   if let m = PostMode(rawValue: v)   { c.post = m }   else { log("bad --post=\(v)");  exit(2) }
        case "--cursor": if let m = CursorMode(rawValue: v) { c.cursor = m } else { log("bad --cursor=\(v)"); exit(2) }
        default: log("ignoring unrecognized flag: \(k)")
        }
    }
    return c
}

// --- constants -------------------------------------------------------------
// Sentinel stamped on events WE post, so our own tap ignores them (same value the
// baseline spike and the shipped engine use). pid-posted events don't re-enter the
// session tap anyway, so on the --post=pid path this is belt-and-braces.
let kSyntheticTag: Int64 = 0x0A17_C71C

// Movement past this (points) demotes a click to a drag; below it is jitter.
let kDragThreshold: CGFloat = 4

// _SLPSSetFrontProcessWithOptions "user generated" flag. Not #define'd in yabai's
// extern.h; 0x200 is the established value used by AltTab's SLPS wrapper (and matches
// the CPS SetFrontProcessWithOptions option bit). See EXPERIMENTS.md.
let kCPSUserGenerated: UInt32 = 0x200

// --- private-symbol resolution (dlsym-guarded) -----------------------------
// SkyLight is normally already loaded transitively via AppKit, so the global handle
// (dlopen(nil)) resolves the SLPS symbols without an explicit -framework flag; we
// dlopen SkyLight explicitly only as a fallback. If anything is missing we degrade
// gracefully (SLPS -> NS/AX, _AXUIElementGetWindow -> CGWindowList).
let globalImageHandle = dlopen(nil, RTLD_LAZY)
let skylightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

func sym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = globalImageHandle, let p = dlsym(h, name) { return p }
    if let h = skylightHandle,    let p = dlsym(h, name) { return p }
    return nil
}

typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
typealias SLPSSetFrontFn     = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
typealias SLPSPostEventFn    = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
typealias AXGetWindowFn      = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

let fnGetProcessForPID = sym("GetProcessForPID").map { unsafeBitCast($0, to: GetProcessForPIDFn.self) }
let fnSLPSSetFront     = sym("_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SLPSSetFrontFn.self) }
let fnSLPSPostEvent    = sym("SLPSPostEventRecordTo").map { unsafeBitCast($0, to: SLPSPostEventFn.self) }
let fnAXGetWindow      = sym("_AXUIElementGetWindow").map { unsafeBitCast($0, to: AXGetWindowFn.self) }

let slpsAvailable = fnGetProcessForPID != nil && fnSLPSSetFront != nil && fnSLPSPostEvent != nil

// --- Experiment 1: SLPS fast focus -----------------------------------------
// Byte layout verified against yabai master src/window_manager.c
// (window_manager_make_key_window): memset 0 over 0xf8 bytes, [0x04]=0xf8,
// [0x3a]=0x10, window_id at 0x3c (4 bytes, native/little-endian), 0xff fill over
// [0x20..0x30), then post with [0x08]=0x01 followed by [0x08]=0x02. Offsets match
// EXPERIMENTS.md exactly — no discrepancy.
func makeKeyWindow(psn: inout ProcessSerialNumber, wid: CGWindowID) {
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

/// Make `wid` (owned by `pid`) the key window near-synchronously. Returns false if
/// the private symbols are missing or the PSN lookup fails, so the caller can fall
/// back to the NS/AX path. Mirrors yabai's window_manager_focus_window_with_raise
/// (SLPSSetFront -> make_key_window -> AXRaise); the AXRaise is done by the caller.
@discardableResult
func fastFocus(pid: pid_t, wid: CGWindowID) -> Bool {
    guard slpsAvailable, let getPSN = fnGetProcessForPID, let setFront = fnSLPSSetFront else { return false }
    var psn = ProcessSerialNumber()
    let ok = withUnsafeMutablePointer(to: &psn) { getPSN(pid, $0) }
    guard ok == noErr else { return false }
    _ = withUnsafeMutablePointer(to: &psn) { setFront($0, wid, kCPSUserGenerated) }
    makeKeyWindow(psn: &psn, wid: wid)
    return true
}

// --- AX helpers (unchanged from baseline) ----------------------------------
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

let systemWide = AXUIElementCreateSystemWide()
func axFocusedAppPid() -> pid_t? {
    axCopyElement(systemWide, kAXFocusedApplicationAttribute as String).map { pid(of: $0) }
}

func isAlreadyFocused(_ win: AXUIElement, winPid: pid_t) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.processIdentifier == winPid else { return false }
    let app = AXUIElementCreateApplication(winPid)
    guard let focused = axCopyElement(app, kAXFocusedWindowAttribute as String) else { return false }
    return CFEqual(focused, win)
}

/// The CGWindowID for the AX window we resolved. Prefer the private
/// _AXUIElementGetWindow (exact, matches the AX-hit window even when occluded —
/// what Experiment 2's fields 91/92 need); fall back to the topmost on-screen
/// layer-0 window under the point via CGWindowList (public) if the symbol is missing.
func cgWindowID(of ax: AXUIElement, fallbackAt loc: CGPoint) -> CGWindowID {
    if let fn = fnAXGetWindow {
        var wid: UInt32 = 0
        if fn(ax, &wid) == .success, wid != 0 { return wid }
    }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return 0 }
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let bDict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bDict as CFDictionary),
              r.contains(loc) else { continue }
        return (w[kCGWindowNumber as String] as? CGWindowID) ?? 0
    }
    return 0
}

// --- activation (baseline instrumentation, + SLPS mode) --------------------
/// Is `wid` currently the frontmost layer-0 (normal) window on screen? A CG-side
/// z-order signal: the NSWorkspace/AX polls lag the real focus flip (slps runs logged
/// 55-76ms "ns-led" that were visually instant), so this separates "window raised"
/// (the visible slow part) from "app active" (what first-mouse cares about, ~1ms
/// with slps).
func isFrontmostWindow(_ wid: CGWindowID) -> Bool {
    guard wid != 0 else { return false }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {   // front-to-back: first layer-0 entry is the frontmost normal window
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        return (w[kCGWindowNumber as String] as? CGWindowID) == wid
    }
    return false
}

// Polls FOUR readiness signals so we can see which leads:
//   • tNs    — NSWorkspace.frontmostApplication == target
//   • tAx    — system-wide AX focused app == target
//   • tFoc   — app's kAXFocusedWindowAttribute == target
//   • tRaise — target wid is the frontmost layer-0 window (CGWindowList z-order)
// In --focus=slps mode the actual focus is driven synchronously by SLPS; the poll
// then just measures how quickly the public signals confirm it. `skipFocus` skips the
// focus actions entirely (pid+slps fast path already made the window key in the tap
// callback) and only performs the cosmetic AXRaise + confirmation polling. `onFront`
// fires ONCE, the first time a front signal (ns or ax) confirms — the pid+nsax path
// uses it to post the deferred mousedown at the earliest safe moment.
struct ActResult {
    var ms: Double?; var reason: String
    var tNs: Double?; var tAx: Double?; var tFoc: Double?; var tRaise: Double?
}

func activateAndWait(_ win: AXUIElement, winPid: pid_t, wid: CGWindowID,
                     mode: FocusMode, skipFocus: Bool = false,
                     onFront: (() -> Void)? = nil, timeoutMs: Int = 400) -> ActResult {
    let app = AXUIElementCreateApplication(winPid)

    if skipFocus {
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)   // cosmetic raise only
    } else {
        switch mode {
        case .nsax:
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: winPid)?.activate(options: [])
        case .slps:
            if fastFocus(pid: winPid, wid: wid) {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)   // cosmetic raise (post make-key, like yabai)
            } else {
                // Symbols missing / PSN lookup failed: degrade to the NS/AX path.
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                NSRunningApplication(processIdentifier: winPid)?.activate(options: [])
            }
        }
    }

    let start = DispatchTime.now().uptimeNanoseconds
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    var tNs: Double?, tAx: Double?, tFoc: Double?, tRaise: Double?
    var firedFront = false
    var waited = 0
    while waited < timeoutMs {
        let isNs = NSWorkspace.shared.frontmostApplication?.processIdentifier == winPid
        let isAx = axFocusedAppPid() == winPid
        let isFoc = axCopyElement(app, kAXFocusedWindowAttribute as String).map { CFEqual($0, win) } ?? false
        if tRaise == nil, isFrontmostWindow(wid) { tRaise = elapsed() }
        let el = elapsed()
        if isNs, tNs == nil { tNs = el }
        if isAx, tAx == nil { tAx = el }
        if isFoc, tFoc == nil { tFoc = el }
        let isFront = isNs || isAx
        if isFront && !firedFront { firedFront = true; onFront?() }
        let tFrontFirst = [tNs, tAx].compactMap { $0 }.min()
        if isFront && isFoc {
            let reason = (tAx != nil && (tNs == nil || tAx! < tNs!)) ? "ax-led" : "ns-led"
            return ActResult(ms: el, reason: reason, tNs: tNs, tAx: tAx, tFoc: tFoc, tRaise: tRaise)
        }
        if isFront, let tf = tFrontFirst, el - tf > 40 {
            return ActResult(ms: el, reason: "front-only(grace)", tNs: tNs, tAx: tAx, tFoc: tFoc, tRaise: tRaise)
        }
        usleep(3000)               // 3ms
        waited += 3
    }
    return ActResult(ms: nil, reason: "timeout", tNs: tNs, tAx: tAx, tFoc: tFoc, tRaise: tRaise)
}

// --- posting a click (session tap OR direct to pid) ------------------------
let postSource = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, at loc: CGPoint, clickState: Int64, toPid: pid_t = 0, wid: CGWindowID = 0) {
    guard let ev = CGEvent(mouseEventSource: postSource, mouseType: type,
                           mouseCursorPosition: loc, mouseButton: .left) else { return }
    ev.setIntegerValueField(.mouseEventClickState, value: clickState)
    ev.setIntegerValueField(.eventSourceUserData, value: kSyntheticTag)
    switch cfg.post {
    case .session:
        ev.post(tap: .cgSessionEventTap)
    case .pid:
        // Experiment 2: pin the target window (fields 91/92) so AppKit routes to the
        // hit-tested window even if it's occluded / the app is inactive, then deliver
        // straight into the app's own sendEvent, bypassing window-server z-order routing.
        if wid != 0 {
            ev.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))                        // field 91
            ev.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))  // field 92
        }
        ev.postToPid(toPid)
    }
}

/// Chromium user-activation-gate probe (--primer, pid mode only): a throwaway click
/// at (-1,-1) delivered to the pid just before the real down, so renderer-side input
/// filtering sees a preceding "user" interaction. Off-window coords -> no actuation.
/// Sleeps ~5ms so the primer lands ahead of the real down (rare event; blocking the
/// caller briefly is acceptable, and it preserves ordering with the pid-post stream).
func postPrimer(toPid wpid: pid_t, wid: CGWindowID) {
    let loc = CGPoint(x: -1, y: -1)
    post(.leftMouseDown, at: loc, clickState: 1, toPid: wpid, wid: wid)
    post(.leftMouseUp, at: loc, clickState: 1, toPid: wpid, wid: wid)
    log(String(format: "posted PRIMER click @(-1,-1) -> pid %d (user-activation probe)", wpid))
    usleep(5000)
}

// --- gesture state (guarded by `lock`) -------------------------------------
final class Pending {
    var active = false
    var win: AXUIElement?
    var winPid: pid_t = 0
    var wid: CGWindowID = 0
    var downLoc = CGPoint.zero
    var lastLoc = CGPoint.zero
    var clickState: Int64 = 1
    var isDrag = false
    var upSeen = false
    var activated = false
    var liveDragging = false   // handed off to a live native drag; stop swallowing
    var downPosted = false     // pid mode: has the down been delivered to the pid yet?
    var downTime = DispatchTime.now().uptimeNanoseconds
    var upTime = DispatchTime.now().uptimeNanoseconds   // physical mouseup (for after-up metric)
}
let pending = Pending()
let lock = NSLock()
let worker = DispatchQueue(label: "clickthrough.worker")   // serial: activate then finish

// Session-mode replay/handoff (Experiment 2 OFF). In --post=pid mode delivery already
// happened directly in the tap handlers, so this is a no-op.
func tryFinish() {
    if cfg.post == .pid { return }
    lock.lock()
    guard pending.active, pending.activated, !pending.liveDragging else { lock.unlock(); return }
    let downLoc = pending.downLoc, lastLoc = pending.lastLoc
    let cs = pending.clickState, isDrag = pending.isDrag, upSeen = pending.upSeen
    let wpid = pending.winPid, wid = pending.wid
    let now = DispatchTime.now().uptimeNanoseconds
    let total = Double(now - pending.downTime) / 1_000_000
    // `total` includes the user's physical button-hold time (replay fires on mouse-up),
    // so it reads 100-200ms even with single-digit activation. `afterUp` is the part
    // we actually add: physical mouseup -> replay post.
    let afterUp = Double(now - pending.upTime) / 1_000_000

    if !upSeen {
        // Still holding: begin a live native gesture at the true origin, then let the
        // real hardware drag/up events flow straight through.
        pending.liveDragging = true
        lock.unlock()
        post(.leftMouseDown, at: downLoc, clickState: cs, toPid: wpid, wid: wid)
        log(String(format: "handoff -> LIVE gesture, down@(%.0f,%.0f) native from here (%.1fms)",
                   downLoc.x, downLoc.y, total))
        return
    }

    // Released already: replay the finished gesture in one shot.
    pending.active = false
    lock.unlock()
    if isDrag {
        post(.leftMouseDown, at: downLoc, clickState: cs, toPid: wpid, wid: wid)
        post(.leftMouseDragged, at: lastLoc, clickState: cs, toPid: wpid, wid: wid)
        post(.leftMouseUp, at: lastLoc, clickState: cs, toPid: wpid, wid: wid)
        log(String(format: "replayed DRAG down@(%.0f,%.0f)->up@(%.0f,%.0f)  total %.1fms (after-up %.1fms)",
                   downLoc.x, downLoc.y, lastLoc.x, lastLoc.y, total, afterUp))
    } else {
        post(.leftMouseDown, at: downLoc, clickState: cs, toPid: wpid, wid: wid)
        post(.leftMouseUp, at: downLoc, clickState: cs, toPid: wpid, wid: wid)
        log(String(format: "replayed CLICK @(%.0f,%.0f) clickState=%d  total %.1fms (after-up %.1fms)",
                   downLoc.x, downLoc.y, cs, total, afterUp))
    }
    // Experiment 3: only warp when freezing. In --cursor=move the pointer glided with
    // the mutated mouseMoved stream and is already at lastLoc.
    if cfg.cursor == .freeze {
        CGWarpMouseCursorPosition(lastLoc)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
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
        lock.lock(); let busy = pending.active; lock.unlock()
        if busy { return Unmanaged.passUnretained(event) }

        let loc = event.location
        guard let win = windowUnder(loc) else { return Unmanaged.passUnretained(event) }
        let wpid = pid(of: win)
        if isAlreadyFocused(win, winPid: wpid) {
            return Unmanaged.passUnretained(event)     // common case: pass straight through
        }
        let wid = cgWindowID(of: win, fallbackAt: loc)
        let cs = event.getIntegerValueField(.mouseEventClickState)
        lock.lock()
        pending.active = true; pending.win = win; pending.winPid = wpid; pending.wid = wid
        pending.downLoc = loc; pending.lastLoc = loc; pending.clickState = cs
        pending.isDrag = false; pending.upSeen = false; pending.activated = false
        pending.liveDragging = false; pending.downPosted = false
        pending.downTime = DispatchTime.now().uptimeNanoseconds
        let startT = pending.downTime
        lock.unlock()
        log(String(format: "swallowed first-click on unfocused win (pid %d, wid %u) @(%.0f,%.0f) — activating [focus=%@ post=%@ cursor=%@%@]…",
                   wpid, wid, loc.x, loc.y, cfg.focus.rawValue, cfg.post.rawValue, cfg.cursor.rawValue,
                   cfg.primer ? " primer" : ""))

        // Experiment 2, sequenced delivery. First-mouse is applied at dispatch time
        // from the app's active state (proved by the first run), so the app must be
        // active BEFORE the down is dispatched:
        //   slps fast path — synchronously make the window key (~1-2ms, rare event, in
        //   the tap callback so ordering with the drag/up pid-posts is preserved),
        //   THEN post. The make-key records precede our mousedown in the target's
        //   event queue, so no polling wait is needed.
        //   nsax fallback (symbols missing or forced) — fire the activators and post
        //   the down from activateAndWait's onFront, the first time a front signal
        //   confirms. Drag/up posts queue behind on the serial worker until then.
        var downPostedNow = false
        if cfg.post == .pid && cfg.focus == .slps && slpsAvailable {
            if cfg.primer { postPrimer(toPid: wpid, wid: wid) }
            fastFocus(pid: wpid, wid: wid)
            post(.leftMouseDown, at: loc, clickState: cs, toPid: wpid, wid: wid)
            downPostedNow = true
            lock.lock(); pending.downPosted = true; lock.unlock()
            let dms = Double(DispatchTime.now().uptimeNanoseconds - startT) / 1_000_000
            log(String(format: "posted mousedown -> pid %d (wid %u) directly (deliver %.1fms, after slps make-key)",
                       wpid, wid, dms))
        }
        let deferredDown = (cfg.post == .pid && !downPostedNow)
        if deferredDown && cfg.focus == .slps {   // requested slps but symbols missing
            log("pid delivery deferred: SLPS symbols MISSING — waiting for nsax front signal")
        }

        worker.async {
            let onFront: (() -> Void)? = !deferredDown ? nil : {
                if cfg.primer { postPrimer(toPid: wpid, wid: wid) }
                post(.leftMouseDown, at: loc, clickState: cs, toPid: wpid, wid: wid)
                lock.lock(); pending.downPosted = true; lock.unlock()
                let dms = Double(DispatchTime.now().uptimeNanoseconds - startT) / 1_000_000
                log(String(format: "posted mousedown -> pid %d (wid %u) directly (deliver %.1fms, waited for nsax activation)",
                           wpid, wid, dms))
            }
            let r = activateAndWait(win, winPid: wpid, wid: wid, mode: cfg.focus,
                                    skipFocus: downPostedNow, onFront: onFront)
            lock.lock(); pending.activated = true; lock.unlock()
            func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
            let signals = "ns@\(ms(r.tNs)) ax@\(ms(r.tAx)) foc@\(ms(r.tFoc)) raise@\(ms(r.tRaise))"
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
        var wpid: pid_t = 0, wid: CGWindowID = 0, cs: Int64 = 1, downPosted = false
        if armed {
            pending.lastLoc = event.location
            // Only a real drag past the threshold demotes off the click path; sub-threshold
            // jitter stays a click (avoids the 1px "DRAG" mislabel).
            if hypot(event.location.x - pending.downLoc.x,
                     event.location.y - pending.downLoc.y) > kDragThreshold {
                pending.isDrag = true
            }
            wpid = pending.winPid; wid = pending.wid; cs = pending.clickState
            downPosted = pending.downPosted
        }
        lock.unlock()
        if !armed { return Unmanaged.passUnretained(event) }

        // Experiment 2 + 3: feed live drag motion straight to the target pid so the
        // drag reaches the (now-key) window with no handoff discontinuity. If the down
        // is still deferred (nsax sequencing), queue the drag on the serial worker so
        // it lands AFTER the down (the worker is busy inside activateAndWait, whose
        // onFront posts the down before it returns).
        if cfg.post == .pid {
            if downPosted {
                post(.leftMouseDragged, at: event.location, clickState: cs, toPid: wpid, wid: wid)
            } else {
                let dragLoc = event.location
                worker.async { post(.leftMouseDragged, at: dragLoc, clickState: cs, toPid: wpid, wid: wid) }
            }
        }
        // Experiment 3: keep the cursor gliding — mutate the swallowed drag into a
        // mouseMoved and let it through, instead of dropping it (which pinned the
        // pointer). We return the SAME event we were handed, mutated in place, so
        // passUnretained is correct (matches the callback's pass-through convention).
        if cfg.cursor == .move {
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        }
        return nil     // freeze (baseline): drop the motion, pin the pointer

    case .leftMouseUp:
        lock.lock()
        if pending.liveDragging {                       // native gesture in progress
            pending.active = false; pending.liveDragging = false
            lock.unlock()
            log("live gesture ended (native up)")
            return Unmanaged.passUnretained(event)      // let the real up close it
        }
        let armed = pending.active && !pending.upSeen
        if armed { pending.upSeen = true; pending.lastLoc = event.location
                   pending.upTime = DispatchTime.now().uptimeNanoseconds }
        lock.unlock()
        if !armed { return Unmanaged.passUnretained(event) }

        if cfg.post == .pid {
            lock.lock()
            let wpid = pending.winPid, wid = pending.wid, cs = pending.clickState
            let up = pending.lastLoc, isDrag = pending.isDrag
            let dLoc = pending.downLoc, downT = pending.downTime
            let posted = pending.downPosted
            if posted { pending.active = false }
            lock.unlock()
            if posted {
                // Down already delivered (slps fast path, or nsax front confirmed):
                // post the up directly from the tap thread — ordering is safe.
                post(.leftMouseUp, at: up, clickState: cs, toPid: wpid, wid: wid)
                let total = Double(DispatchTime.now().uptimeNanoseconds - downT) / 1_000_000
                log(String(format: "posted mouseup -> pid %d (wid %u) — %@ delivered direct, total %.1fms",
                           wpid, wid, isDrag ? "DRAG" : "CLICK", total))
            } else {
                // Down still deferred (nsax sequencing): queue the up on the serial
                // worker so it lands after the onFront-posted down. pending.active
                // stays true until the worker finishes, so no new gesture overlaps.
                worker.async {
                    lock.lock()
                    let postedNow = pending.downPosted
                    pending.active = false
                    lock.unlock()
                    if !postedNow {
                        // Activation never confirmed (timeout): best-effort late down —
                        // almost certainly eaten as first-mouse, but don't drop the pair.
                        post(.leftMouseDown, at: dLoc, clickState: cs, toPid: wpid, wid: wid)
                        log("posted LATE mousedown -> pid \(wpid) (activation never confirmed) — click likely eaten")
                    }
                    post(.leftMouseUp, at: up, clickState: cs, toPid: wpid, wid: wid)
                    let total = Double(DispatchTime.now().uptimeNanoseconds - downT) / 1_000_000
                    log(String(format: "posted mouseup -> pid %d (wid %u) — %@ delivered direct, total %.1fms",
                               wpid, wid, isDrag ? "DRAG" : "CLICK", total))
                }
            }
            if cfg.cursor == .freeze {
                CGWarpMouseCursorPosition(up)           // baseline: pointer was pinned, snap it to end
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            return nil
        }

        worker.async { tryFinish() }
        return nil

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// --- boot ------------------------------------------------------------------
cfg = parseArgs()

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

printUsage()
log("modes: focus=\(cfg.focus.rawValue) post=\(cfg.post.rawValue) cursor=\(cfg.cursor.rawValue)"
    + " primer=\(cfg.primer ? "on" : "off")  (defaults reproduce the baseline)")
if cfg.primer && cfg.post != .pid {
    log("NOTE: --primer has no effect without --post=pid.")
}
log("SLPS symbols: \(slpsAvailable ? "resolved" : "MISSING")"
    + (fnAXGetWindow != nil ? ", _AXUIElementGetWindow resolved" : ", _AXUIElementGetWindow MISSING (CGWindowList fallback)"))
if cfg.focus == .slps && !slpsAvailable {
    log("WARNING: --focus=slps requested but SLPS symbols are missing — falling back to NS/AX.")
}
log("running. Click controls in BACKGROUND windows (no modifiers).")
log("Try: a button/tab in an inactive native app, then web content in an inactive browser.")
log("Ctrl+C to quit.")
CFRunLoopRun()
