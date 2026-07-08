// AX-based move fallback for apps that ignore the native Ctrl+Cmd drag gesture.
// Same coalescing discipline as ResizeEngine: the event tap records the newest
// cursor; a worker thread drives kAXPosition toward it, dropping intermediate
// points. No snapping (that's the price of the fallback vs the native path).
import Cocoa
import ApplicationServices

final class MoveEngine {
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var win: AXUIElement?
    private var startOrigin = CGPoint.zero
    private var startCursor = CGPoint.zero
    private var target = CGPoint.zero
    private var active = false

    init() { startWorker() }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    func begin(at cursor: CGPoint) -> Bool {
        guard let w = windowUnder(cursor),
              let origin = axPoint(w, kAXPositionAttribute as String) else { return false }
        lock.lock()
        win = w; startOrigin = origin; startCursor = cursor; target = cursor; active = true
        lock.unlock()
        return true
    }

    func update(_ cursor: CGPoint) {
        lock.lock()
        let a = active
        if a { target = cursor }
        lock.unlock()
        if a { wake.signal() }
    }

    func end() {
        lock.lock(); active = false; win = nil; lock.unlock()
    }

    private func startWorker() {
        Thread.detachNewThread { [self] in
            var last: CGPoint?
            while true {
                wake.wait()
                lock.lock()
                let a = active, w = win, so = startOrigin, sc = startCursor, t = target
                lock.unlock()
                guard a, let w = w else { continue }
                let np = CGPoint(x: (so.x + (t.x - sc.x)).rounded(),
                                 y: (so.y + (t.y - sc.y)).rounded())
                if let l = last, l == np { continue }
                setAXPoint(w, kAXPositionAttribute as String, np)
                last = np
            }
        }
    }
}
