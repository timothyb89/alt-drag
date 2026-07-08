// Right-drag resize, ported from the validated spike.
//
// AX set is a synchronous IPC round-trip (tens of ms under layout), so the
// event-tap thread only records the newest cursor; a worker thread applies AX
// toward that newest target, dropping intermediate points (coalescing).
// Snapping is LATCHED, not magnetic: an edge tracks 1:1, sticks when it crosses
// a candidate line, and releases only after overshooting by `release` px.
import Cocoa
import ApplicationServices

private let minSize = CGSize(width: 120, height: 80)
private let grab: CGFloat = 2       // tiny landing assist (macOS itself has ~none)
private let release: CGFloat = 14   // overshoot needed to break a latched edge

private struct Session {
    var gen: Int
    var win: AXUIElement
    var startCursor: CGPoint
    var startOrigin: CGPoint
    var startSize: CGSize
    var moveLeft: Bool
    var moveTop: Bool
    var topLimit: CGFloat           // menu-bar hard wall for the top edge
    var snapXs: [CGFloat]
    var snapYs: [CGFloat]
}

private struct AxisLatch {
    var prevRaw: CGFloat?
    var stuck: CGFloat?
    mutating func resolve(_ raw: CGFloat, _ lines: [CGFloat]) -> CGFloat {
        defer { prevRaw = raw }
        if let s = stuck {
            if abs(raw - s) <= release { return s }
            stuck = nil
        }
        if let p = prevRaw {
            for line in lines where (min(p, raw) - grab) <= line && line <= (max(p, raw) + grab) {
                stuck = line; return line
            }
        } else {
            for line in lines where abs(raw - line) <= grab { stuck = line; return line }
        }
        return raw
    }
}

final class ResizeEngine {
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var session: Session?
    private var target = CGPoint.zero
    private var gen = 0

    init() { startWorker() }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    /// Returns false if there's no resizable window under the cursor (so the
    /// caller lets the normal right-click through).
    func begin(at cursor: CGPoint) -> Bool {
        guard let win = windowUnder(cursor),
              let origin = axPoint(win, kAXPositionAttribute as String),
              let size = axSize(win, kAXSizeAttribute as String) else { return false }
        let left = cursor.x < origin.x + size.width / 2
        let top  = cursor.y < origin.y + size.height / 2
        let winFrame = CGRect(origin: origin, size: size)
        let lines = snapLines(excluding: winFrame)
        let limit = menubarTop(forWindowAt: winFrame)
        lock.lock()
        gen += 1
        session = Session(gen: gen, win: win, startCursor: cursor, startOrigin: origin,
                          startSize: size, moveLeft: left, moveTop: top,
                          topLimit: limit, snapXs: lines.xs, snapYs: lines.ys)
        target = cursor
        lock.unlock()
        return true
    }

    func update(_ cursor: CGPoint) {
        lock.lock()
        let active = session != nil
        if active { target = cursor }
        lock.unlock()
        if active { wake.signal() }
    }

    func end() { lock.lock(); session = nil; lock.unlock() }

    private func startWorker() {
        Thread.detachNewThread { [self] in
            var last: (origin: CGPoint, size: CGSize)?
            var curGen = -1
            var hLatch = AxisLatch(), vLatch = AxisLatch()
            while true {
                wake.wait()
                lock.lock(); let s = session; let cursor = target; lock.unlock()
                guard let s = s else { continue }
                if s.gen != curGen { curGen = s.gen; hLatch = AxisLatch(); vLatch = AxisLatch() }

                let f = frame(cursor, s, &hLatch, &vLatch)
                if let l = last, l.origin == f.origin, l.size == f.size { continue }
                if s.moveLeft || s.moveTop {
                    setAXPoint(s.win, kAXPositionAttribute as String, f.origin)
                }
                setAXSize(s.win, kAXSizeAttribute as String, f.size)
                last = f
            }
        }
    }
}

// --- pure geometry ---------------------------------------------------------
private func frame(_ cursor: CGPoint, _ s: Session,
                   _ hLatch: inout AxisLatch, _ vLatch: inout AxisLatch) -> (origin: CGPoint, size: CGSize) {
    let dx = cursor.x - s.startCursor.x
    let dy = cursor.y - s.startCursor.y
    var left = s.startOrigin.x
    var right = s.startOrigin.x + s.startSize.width
    var top = s.startOrigin.y
    var bottom = s.startOrigin.y + s.startSize.height

    if s.moveLeft { left = hLatch.resolve(left + dx, s.snapXs) }
    else          { right = hLatch.resolve(right + dx, s.snapXs) }
    if s.moveTop  { top = vLatch.resolve(top + dy, s.snapYs) }
    else          { bottom = vLatch.resolve(bottom + dy, s.snapYs) }

    if s.moveTop { top = max(top, s.topLimit) }   // hard menu-bar wall

    if right - left < minSize.width {
        if s.moveLeft { left = right - minSize.width } else { right = left + minSize.width }
    }
    if bottom - top < minSize.height {
        if s.moveTop { top = bottom - minSize.height } else { bottom = top + minSize.height }
    }
    return (CGPoint(x: left.rounded(), y: top.rounded()),
            CGSize(width: (right - left).rounded(), height: (bottom - top).rounded()))
}

// --- snap candidates -------------------------------------------------------
private func snapLines(excluding target: CGRect) -> (xs: [CGFloat], ys: [CGFloat]) {
    var xs: [CGFloat] = [], ys: [CGFloat] = []
    let mainH = CGDisplayBounds(CGMainDisplayID()).height
    for scr in NSScreen.screens {
        let v = scr.visibleFrame
        let topY = mainH - (v.origin.y + v.height)
        xs.append(v.minX); xs.append(v.minX + v.width)
        ys.append(topY);   ys.append(topY + v.height)
    }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bDict as CFDictionary) else { continue }
            if abs(r.minX - target.minX) < 2, abs(r.minY - target.minY) < 2,
               abs(r.width - target.width) < 2, abs(r.height - target.height) < 2 { continue }
            xs.append(r.minX); xs.append(r.maxX)
            ys.append(r.minY); ys.append(r.maxY)
        }
    }
    return (xs, ys)
}

private func menubarTop(forWindowAt frame: CGRect) -> CGFloat {
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
// (AX helpers moved to AXUtil.swift)
