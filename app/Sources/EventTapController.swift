// One session-level CGEventTap handling both gestures:
//   left  + trigger  -> remap flags to Ctrl+Cmd (native move, see architecture)
//   right + trigger  -> AX resize via ResizeEngine (swallow the right events)
import Cocoa

final class EventTapController {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var moving = false
    private let resize = ResizeEngine()

    /// True once the tap is installed and enabled.
    var isRunning: Bool { tap != nil }

    /// Attempt to install the tap. Returns false if creation failed (usually
    /// missing Accessibility permission) so the caller can retry later.
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
        moving = false
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

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard Settings.shared.enabled else { return Unmanaged.passUnretained(event) }
        let trigger = Settings.shared.modifier

        switch type {
        case .leftMouseDown:
            if event.flags.contains(trigger) { moving = true; remapToNativeMove(event, trigger: trigger) }
        case .leftMouseDragged:
            if moving { remapToNativeMove(event, trigger: trigger) }
        case .leftMouseUp:
            if moving { remapToNativeMove(event, trigger: trigger); moving = false }

        case .rightMouseDown:
            if event.flags.contains(trigger), resize.begin(at: event.location) { return nil }
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

// C callback bridges back to the controller via the refcon pointer.
private let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type, event)
}
