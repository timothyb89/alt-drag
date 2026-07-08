// One session-level CGEventTap handling both gestures:
//   left  + trigger  -> native move (Ctrl+Cmd remap) OR AX move fallback
//   right + trigger  -> AX resize via ResizeEngine (swallow the right events)
//
// For left drags, AppPolicy decides native vs fallback per app. On the native
// path we run a lightweight background probe (did the window actually move?) so
// AppPolicy can learn apps that never honor the gesture.
import Cocoa
import ApplicationServices

private enum LeftGesture { case none, native, axMove }

final class EventTapController {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var leftGesture: LeftGesture = .none
    private let resize = ResizeEngine()
    private let move = MoveEngine()

    // Gesture-support probe. Main-thread fields vs probeQueue-only fields are
    // kept strictly separate so no locking is needed (probeQueue is serial).
    private let probeQueue = DispatchQueue(label: "dev.tim.AltDrag.probe")
    private var pendingBundleId: String?        // main thread only
    private var pendingStart = CGPoint.zero      // main thread only
    private var probeWin: AXUIElement?           // probeQueue only
    private var probePos0: CGPoint?              // probeQueue only

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: eventTapCallback, userInfo: refcon) else {
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        runLoopSource = src
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        leftGesture = .none
        move.end()
        resize.end()
        tap = nil
        runLoopSource = nil
    }

    // Rewrite the trigger modifier into the Ctrl+Cmd native-move gesture.
    private func remapToNativeMove(_ event: CGEvent, trigger: CGEventFlags) {
        var f = event.flags
        f.subtract(trigger)
        f.formUnion([.maskControl, .maskCommand])
        event.flags = f
    }

    // --- probe: was the native gesture actually honored? -------------------
    private func beginProbe(bundleId: String?, at cursor: CGPoint) {
        pendingBundleId = bundleId
        pendingStart = cursor
        probeQueue.async {
            self.probeWin = windowUnder(cursor)
            self.probePos0 = self.probeWin.flatMap { axPoint($0, kAXPositionAttribute as String) }
        }
    }

    private func finishProbe(at cursor: CGPoint) {
        let bid = pendingBundleId
        let start = pendingStart
        pendingBundleId = nil
        let dragged = hypot(cursor.x - start.x, cursor.y - start.y) >= 8   // ignore clicks
        probeQueue.async {
            let win = self.probeWin; let pos0 = self.probePos0
            self.probeWin = nil; self.probePos0 = nil
            guard dragged, let win = win, let pos0 = pos0 else { return }
            let pos1 = axPoint(win, kAXPositionAttribute as String) ?? pos0
            let moved = hypot(pos1.x - pos0.x, pos1.y - pos0.y) > 2
            AppPolicy.shared.record(bundleId: bid, moved: moved)
        }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Settings.shared.enabled else { return Unmanaged.passUnretained(event) }
        let trigger = Settings.shared.modifier

        switch type {
        case .leftMouseDown:
            guard event.flags.contains(trigger) else { break }
            let loc = event.location
            switch AppPolicy.shared.route(at: loc) {
            case .disabled:
                break                                // pass through untouched
            case .fallback(let bid):
                if move.begin(at: loc) {
                    leftGesture = .axMove
                    return nil                       // swallow: no Ctrl-click leak
                }
                // No AX window found — fall back to native so the drag isn't dead.
                leftGesture = .native
                remapToNativeMove(event, trigger: trigger)
                beginProbe(bundleId: bid, at: loc)
            case .native(let bid):
                leftGesture = .native
                remapToNativeMove(event, trigger: trigger)
                beginProbe(bundleId: bid, at: loc)
            }

        case .leftMouseDragged:
            switch leftGesture {
            case .native: remapToNativeMove(event, trigger: trigger)
            case .axMove: move.update(event.location); return nil
            case .none:   break
            }

        case .leftMouseUp:
            switch leftGesture {
            case .native:
                remapToNativeMove(event, trigger: trigger)
                finishProbe(at: event.location)
                leftGesture = .none
            case .axMove:
                move.end()
                leftGesture = .none
                return nil
            case .none:
                break
            }

        case .rightMouseDown:
            guard event.flags.contains(trigger) else { break }
            if case .disabled = AppPolicy.shared.route(at: event.location) { break }
            if resize.begin(at: event.location) { return nil }
        case .rightMouseDragged:
            if resize.isActive { resize.update(event.location); return nil }
        case .rightMouseUp:
            if resize.isActive { resize.end(); return nil }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type, event)
}
