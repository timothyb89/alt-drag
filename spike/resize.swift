// alt-drag resize spike — the hard half.
//
// Unlike move, there's no native gesture to remap onto, so this is the
// "reimplementation" path: on Option+right-mouse-down, find the window under
// the cursor via Accessibility, decide which corner to drag from (the quadrant
// the cursor sits in), then drive kAXPosition/kAXSize toward the cursor.
//
// CRITICAL design point (learned the hard way): AX set is a synchronous IPC
// round-trip to the target app's main thread — tens of ms under layout. If we
// applied it per drag event (120Hz+), events backlog and the window crawls
// through every stale point seconds behind the cursor. So: the event-tap
// callback does ONLY cheap work (record the latest cursor); a worker thread
// applies AX toward the NEWEST target, dropping all intermediate points. The
// window then trails by at most one in-flight AX call, regardless of Hz.
//
// Snap-stops against neighboring windows are deliberately NOT here yet — that's
// the next layer once the raw feel is validated.

import Cocoa
import ApplicationServices

// --- resize session state --------------------------------------------------
struct Session {
    var gen: Int         // increments per drag; lets the worker reset latch state
    var win: AXUIElement
    var startCursor: CGPoint
    var startOrigin: CGPoint
    var startSize: CGSize
    var moveLeft: Bool   // dragging left edge? else right edge
    var moveTop: Bool    // dragging top edge? else bottom edge
    var topLimit: CGFloat = -.greatestFiniteMagnitude  // menu-bar hard wall for the top edge
    var snapXs: [CGFloat] = []   // candidate vertical edges (neighbors + screens)
    var snapYs: [CGFloat] = []   // candidate horizontal edges (neighbors + screens)
}
let minSize = CGSize(width: 120, height: 80)

// Latched snapping (matches native feel): the edge tracks the cursor 1:1 until
// it CROSSES a candidate line, then sticks there until the cursor pulls past by
// `release`. No magnetic pull on approach — pixel-precision until contact.
let grab: CGFloat = 2       // stick if we land within this of a line (slow approach)
let release: CGFloat = 14   // must overshoot this far past a stuck line to break free

struct AxisLatch {
    var prevRaw: CGFloat?    // last frame's raw (cursor-derived) edge position
    var stuck: CGFloat?      // line currently latched to, if any

    mutating func resolve(_ raw: CGFloat, _ lines: [CGFloat]) -> CGFloat {
        defer { prevRaw = raw }
        if let s = stuck {
            if abs(raw - s) <= release { return s }   // hold
            stuck = nil                                // overshot -> release, fall through
        }
        // Detect a line the edge just reached or crossed since last frame.
        if let p = prevRaw {
            for line in lines where (min(p, raw) - grab) <= line && line <= (max(p, raw) + grab) {
                stuck = line
                return line
            }
        } else {
            for line in lines where abs(raw - line) <= grab { stuck = line; return line }
        }
        return raw
    }
}

// Candidate edges captured ONCE at drag start (windows don't move mid-resize).
// Combines neighbor-window edges (CGWindowList) with every display's visible
// frame (menu-bar / Dock / screen edges). All share AX's coordinate space:
// top-left origin, global, y-down.
func snapLines(excluding target: CGRect) -> (xs: [CGFloat], ys: [CGFloat]) {
    var xs: [CGFloat] = [], ys: [CGFloat] = []

    // Screen visible-frame edges. NSScreen is bottom-left/y-up (Cocoa); flip to
    // top-left/y-down using the main display's height.
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    for scr in NSScreen.screens {
        let v = scr.visibleFrame
        let topY = mainH - (v.origin.y + v.height)   // menu-bar line on the primary
        xs.append(v.minX); xs.append(v.minX + v.width)
        ys.append(topY);   ys.append(topY + v.height)
    }

    // (menu-bar wall for the top edge is computed separately, see menubarTop)

    // Neighbor-window edges.
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,                    // normal windows only
                  let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bDict as CFDictionary) else { continue }
            // Skip the window being resized (match its start frame).
            if abs(r.minX - target.minX) < 2, abs(r.minY - target.minY) < 2,
               abs(r.width - target.width) < 2, abs(r.height - target.height) < 2 { continue }
            xs.append(r.minX); xs.append(r.maxX)
            ys.append(r.minY); ys.append(r.maxY)
        }
    }
    return (xs, ys)
}

// The menu-bar line (visible-frame top, top-left coords) of the screen the
// window sits on — a hard floor for the top edge, since AX won't place an
// origin above it. Picked by the window's center; falls back to the main screen.
func menubarTop(forWindowAt frame: CGRect) -> CGFloat {
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    let center = CGPoint(x: frame.midX, y: frame.midY)
    for scr in NSScreen.screens {
        let f = scr.frame
        let tl = CGRect(x: f.minX, y: mainH - (f.origin.y + f.height), width: f.width, height: f.height)
        if tl.contains(center) {
            let v = scr.visibleFrame
            return mainH - (v.origin.y + v.height)
        }
    }
    let v = NSScreen.main?.visibleFrame ?? .zero
    return mainH - (v.origin.y + v.height)
}

// Shared state between the event-tap callback and the AX worker thread.
final class Shared {
    let lock = NSLock()
    let wake = DispatchSemaphore(value: 0)   // signaled when target changes
    var session: Session?                    // non-nil while resizing
    var target = CGPoint.zero                // latest cursor position
}
let shared = Shared()
var genCounter = 0   // bumped on each rightMouseDown (main thread only)

func log(_ s: String) { FileHandle.standardError.write(("[alt-resize] " + s + "\n").data(using: .utf8)!) }

// --- AX helpers ------------------------------------------------------------
func axPoint(_ e: AXUIElement, _ attr: String) -> CGPoint? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}
func axSize(_ e: AXUIElement, _ attr: String) -> CGSize? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}
func setAXPoint(_ e: AXUIElement, _ attr: String, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, attr as CFString, v) }
}
func setAXSize(_ e: AXUIElement, _ attr: String, _ s: CGSize) {
    var s = s
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(e, attr as CFString, v) }
}

// Walk up from the element under the cursor to its enclosing window.
func windowUnder(_ cursor: CGPoint) -> AXUIElement? {
    let sys = AXUIElementCreateSystemWide()
    var elt: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(cursor.x), Float(cursor.y), &elt) == .success,
          var cur = elt else { return nil }
    for _ in 0..<25 {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == (kAXWindowRole as String) {
            return cur
        }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
              let p = parent else { return nil }
        cur = (p as! AXUIElement)
    }
    return nil
}

// --- resize math -----------------------------------------------------------
// cursor + session + latch state -> target frame (integer-rounded). Works in
// edges (left/right/top/bottom) so snapping and min-size act on whichever edge
// is moving while the opposite edge stays pinned. hLatch/vLatch persist across
// frames within a drag to give the latched (non-magnetic) snap feel.
func frame(for cursor: CGPoint, _ s: Session,
           _ hLatch: inout AxisLatch, _ vLatch: inout AxisLatch) -> (origin: CGPoint, size: CGSize) {
    let dx = cursor.x - s.startCursor.x
    let dy = cursor.y - s.startCursor.y

    var left = s.startOrigin.x
    var right = s.startOrigin.x + s.startSize.width
    var top = s.startOrigin.y
    var bottom = s.startOrigin.y + s.startSize.height

    // Move only the dragged edge, resolving through its latch.
    if s.moveLeft { left = hLatch.resolve(left + dx, s.snapXs) }
    else          { right = hLatch.resolve(right + dx, s.snapXs) }
    if s.moveTop  { top = vLatch.resolve(top + dy, s.snapYs) }
    else          { bottom = vLatch.resolve(bottom + dy, s.snapYs) }

    // Hard wall: the top edge can't go above the menu bar (AX would clamp the
    // origin but still grow the height, dragging the bottom edge downward).
    if s.moveTop { top = max(top, s.topLimit) }

    // Enforce min size by pushing the moving edge, never the pinned one.
    if right - left < minSize.width {
        if s.moveLeft { left = right - minSize.width } else { right = left + minSize.width }
    }
    if bottom - top < minSize.height {
        if s.moveTop { top = bottom - minSize.height } else { bottom = top + minSize.height }
    }

    return (CGPoint(x: left.rounded(), y: top.rounded()),
            CGSize(width: (right - left).rounded(), height: (bottom - top).rounded()))
}

// --- AX worker thread ------------------------------------------------------
// Applies AX toward the newest target only; drops all intermediate points.
func startWorker() {
    Thread.detachNewThread {
        var last: (origin: CGPoint, size: CGSize)?
        var curGen = -1
        var hLatch = AxisLatch(), vLatch = AxisLatch()
        while true {
            shared.wake.wait()               // sleep until a drag updates target
            shared.lock.lock()
            let s = shared.session
            let cursor = shared.target
            shared.lock.unlock()
            guard let s = s else { continue } // resize ended between signal and wake

            if s.gen != curGen {              // new drag -> fresh latch state
                curGen = s.gen
                hLatch = AxisLatch(); vLatch = AxisLatch()
            }
            let f = frame(for: cursor, s, &hLatch, &vLatch)
            if let l = last, l.origin == f.origin && l.size == f.size { continue } // dedupe

            // Move the origin only when the dragged edge actually shifts it.
            if s.moveLeft || s.moveTop {
                setAXPoint(s.win, kAXPositionAttribute as String, f.origin)
            }
            setAXSize(s.win, kAXSizeAttribute as String, f.size)
            last = f
        }
    }
}

// --- event tap -------------------------------------------------------------
var sharedTap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = sharedTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)

    case .rightMouseDown:
        guard event.flags.contains(.maskAlternate) else { break }  // not our gesture
        let cursor = event.location
        guard let win = windowUnder(cursor),
              let origin = axPoint(win, kAXPositionAttribute as String),
              let size = axSize(win, kAXSizeAttribute as String) else {
            log("no resizable window under cursor")
            break
        }
        let left = cursor.x < origin.x + size.width / 2
        let top  = cursor.y < origin.y + size.height / 2
        let winFrame = CGRect(origin: origin, size: size)
        let lines = snapLines(excluding: winFrame)
        let topLimit = menubarTop(forWindowAt: winFrame)
        genCounter += 1
        shared.lock.lock()
        shared.session = Session(gen: genCounter, win: win, startCursor: cursor, startOrigin: origin,
                                 startSize: size, moveLeft: left, moveTop: top,
                                 topLimit: topLimit, snapXs: lines.xs, snapYs: lines.ys)
        shared.target = cursor
        shared.lock.unlock()
        log("resize start corner=\(top ? "top" : "bottom")-\(left ? "left" : "right") snapLines=\(lines.xs.count)x/\(lines.ys.count)y")
        return nil  // swallow: no context menu

    case .rightMouseDragged:
        // Cheap: record newest cursor, nudge the worker. NO AX here.
        shared.lock.lock()
        let active = shared.session != nil
        if active { shared.target = event.location }
        shared.lock.unlock()
        if active { shared.wake.signal(); return nil }

    case .rightMouseUp:
        shared.lock.lock()
        let active = shared.session != nil
        shared.session = nil
        shared.lock.unlock()
        if active { log("resize end"); return nil }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// --- setup -----------------------------------------------------------------
if !AXIsProcessTrusted() {
    log("Accessibility NOT granted to this process — grant your terminal in")
    log("System Settings > Privacy & Security > Accessibility, then re-run.")
}

let mask: CGEventMask =
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue)

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .defaultTap, eventsOfInterest: mask,
                                  callback: callback, userInfo: nil) else {
    log("FAILED to create event tap — grant Accessibility permission and re-run")
    exit(1)
}
sharedTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
startWorker()
log("running (coalesced). Hold Option and RIGHT-drag inside a window to resize. Ctrl+C to quit.")
CFRunLoopRun()
