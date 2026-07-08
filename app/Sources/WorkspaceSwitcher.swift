// Instant workspace switching, gated behind the trigger modifier.
//
// While the modifier is held, a 3-finger horizontal swipe (or modifier+Tab)
// opens an overlay of the current display's spaces and scrubs between them,
// switching instantly (no OS slide animation) with a haptic detent per space.
// Releasing the modifier closes the overlay. See spike/ for the derivation.
//
// Mechanism (spacecore.c): read space state via read-only CGS; switch by
// synthesizing a high-velocity Dock swipe; intercept the real swipe via CGS
// gesture events, distinguishing it from our own posts by source pid.
import Cocoa
import CoreGraphics

// Virtual key codes.
private let kVKTab: Int64 = 48
private let kVKLeft: Int64 = 123
private let kVKRight: Int64 = 124
private let kVKEscape: Int64 = 53

// CGS event types (absent from the CGEventType enum).
private let kCGSEventGesture: UInt32 = 29
private let kCGSEventDockControl: UInt32 = 30

private let hapticActuationID: Int32 = 1

// MARK: - Overlay view

/// Placeholder rendering: a numbered card per space (current tinted, selected
/// ringed) and a live scrub cursor. A cached space preview could later fill the
/// empty card interior.
final class SpaceOverlayView: NSView {
    var count = 0
    var current = 0
    var selected = 0
    var cursor: CGFloat = -1   // continuous scrub position; <0 hides it

    private let card = NSSize(width: 150, height: 96)
    private let gap: CGFloat = 18
    private let pad: CGFloat = 28
    private let cardsBottom: CGFloat = 40

    override var isFlipped: Bool { false }

    private var startX: CGFloat {
        let totalW = CGFloat(count) * card.width + CGFloat(max(0, count - 1)) * gap
        return (bounds.width - totalW) / 2
    }
    private func centerX(_ idx: CGFloat) -> CGFloat {
        startX + idx * (card.width + gap) + card.width / 2
    }

    override func draw(_ dirty: NSRect) {
        let container = bounds.insetBy(dx: 6, dy: 6)
        NSColor(white: 0.12, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: container, xRadius: 20, yRadius: 20).fill()

        for i in 0..<count {
            let rect = NSRect(x: startX + CGFloat(i) * (card.width + gap), y: cardsBottom,
                              width: card.width, height: card.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            if i == current {
                NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.55, alpha: 1).setFill()
            } else {
                NSColor(white: 0.22, alpha: 1).setFill()
            }
            path.fill()
            if i == selected {
                NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.0, alpha: 1).setStroke()
                path.lineWidth = 4
                path.stroke()
            }
            let label = "Space \(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attrs)
        }

        if cursor >= 0 && count > 0 {
            let trackY = cardsBottom + card.height + 14
            let track = NSBezierPath()
            track.move(to: NSPoint(x: centerX(0), y: trackY))
            track.line(to: NSPoint(x: centerX(CGFloat(count - 1)), y: trackY))
            track.lineWidth = 2
            NSColor(white: 0.4, alpha: 1).setStroke()
            track.stroke()

            let kx = centerX(cursor), r: CGFloat = 7
            NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: kx - r, y: trackY - r, width: 2 * r, height: 2 * r)).fill()
        }
    }
}

// MARK: - Overlay controller

/// Owns the overlay panel and the selection/switch logic. All methods run on
/// the main thread (driven from the event tap on the main run loop).
final class SpaceOverlayController {
    private var panel: NSPanel?
    private let view = SpaceOverlayView()
    private let mtHaptics: Bool

    private var active = false
    private var count = 0
    private var selected = 0
    private var swipeOrigin = 0

    var isActive: Bool { active }

    init(mtHaptics: Bool) { self.mtHaptics = mtHaptics }

    // Open for the display under the cursor. No-op (stays inactive) if the
    // display has a single space.
    func open() {
        var info = SpaceInfo()
        guard space_info(SpaceTargetCursor, &info), info.spaceCount > 1 else { return }
        count = Int(info.spaceCount)
        selected = Int(info.currentIndex)
        active = true

        let screen = screenUnderCursor()
        let w = min(screen.frame.width - 80, CGFloat(count) * 168 + 96)
        let h: CGFloat = 96 + 40 + 28 + 24
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.midY - h / 2,
                           width: w, height: h)

        let p = panel ?? makePanel()
        p.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.count = count
        view.current = selected
        view.selected = selected
        view.cursor = CGFloat(selected)
        view.needsDisplay = true
        p.orderFrontRegardless()
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = view
        return p
    }

    // --- Keyboard: discrete step, wraps at the ends -------------------------
    func move(right: Bool) {
        if !active { open() }
        guard active else { return }
        let target = ((selected + (right ? 1 : -1)) % count + count) % count
        stepTo(target)
    }

    // --- Trackpad: absolute, count-normalized scrub -------------------------
    func swipeBegin() -> Bool {
        if !active { open() }
        swipeOrigin = selected
        return active
    }

    func swipeUpdate(progress: Double) {
        guard active else { return }
        let span = Double(count - 1)
        let scaled = progress / Settings.shared.workspaceSensitivity * span
        let pos = max(0, min(span, Double(swipeOrigin) + scaled))
        view.cursor = CGFloat(pos)
        view.needsDisplay = true
        stepTo(Int(pos.rounded()))
    }

    func swipeFling(right: Bool) {
        guard active, selected == swipeOrigin else { return }
        stepTo(max(0, min(count - 1, selected + (right ? 1 : -1))))
    }

    // Walk to `target` one space at a time, switching + haptic per stop.
    private func stepTo(_ target: Int) {
        guard target != selected else { return }
        let right = target > selected
        while selected != target {
            selected += right ? 1 : -1
            space_switch(right)
            if Settings.shared.workspaceHaptics {
                if mtHaptics {
                    haptic_fire(hapticActuationID)
                } else {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
        view.selected = selected
        view.current = selected
        view.cursor = CGFloat(selected)
        view.needsDisplay = true
    }

    func close() {
        active = false
        view.cursor = -1
        panel?.orderOut(nil)
    }
}

private func screenUnderCursor() -> NSScreen {
    let loc = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        ?? (NSScreen.main ?? NSScreen.screens[0])
}

// MARK: - Switcher (event tap + routing)

final class WorkspaceSwitcher {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let controller: SpaceOverlayController

    private var triggerDown = false
    private var gestureActive = false

    var isRunning: Bool { tap != nil }

    init() { controller = SpaceOverlayController(mtHaptics: haptic_init()) }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            CGEventMask(1) << CGEventType.keyDown.rawValue |
            CGEventMask(1) << CGEventType.flagsChanged.rawValue |
            CGEventMask(1) << kCGSEventGesture |
            CGEventMask(1) << kCGSEventDockControl

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: wsTapCallback, userInfo: refcon) else {
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
        controller.close()
        triggerDown = false
        gestureActive = false
        tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let raw = type.rawValue
        if raw == kCGSEventGesture || raw == kCGSEventDockControl {
            return handleGesture(raw, event)
        }

        let modifier = Settings.shared.modifier
        switch type {
        case .flagsChanged:
            let nowDown = event.flags.contains(modifier)
            if triggerDown && !nowDown { controller.close() }   // release ends the session
            triggerDown = nowDown

        case .keyDown:
            // Keyboard path is disabled when the modifier is Command, so it
            // doesn't hijack Cmd+Tab (the app switcher).
            guard triggerDown, modifier != .maskCommand else { break }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let shift = event.flags.contains(.maskShift)
            switch code {
            case kVKTab: controller.move(right: !shift); return nil
            case kVKRight where controller.isActive: controller.move(right: true);  return nil
            case kVKLeft  where controller.isActive: controller.move(right: false); return nil
            case kVKEscape where controller.isActive: controller.close(); return nil
            default: break
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // Drive the overlay from the real 3-finger horizontal swipe and swallow it
    // so the OS doesn't also switch. The session stays open until the modifier
    // is released (handled in flagsChanged).
    private func handleGesture(_ raw: UInt32, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own synthetic swipes must reach the WindowServer.
        if event_is_synthetic(event) { return Unmanaged.passUnretained(event) }

        var ev = DockSwipeEvent()
        if raw == kCGSEventDockControl && dock_swipe_classify(event, &ev) {
            switch ev.phase {
            case DockSwipeBegan:
                guard triggerDown else { return Unmanaged.passUnretained(event) }  // gate
                gestureActive = controller.swipeBegin()
                return gestureActive ? nil : Unmanaged.passUnretained(event)
            case DockSwipeChanged:
                guard gestureActive else { return Unmanaged.passUnretained(event) }
                controller.swipeUpdate(progress: ev.progress)
                return nil
            case DockSwipeEnded:
                guard gestureActive else { return Unmanaged.passUnretained(event) }
                if ev.velocityX != 0 { controller.swipeFling(right: ev.velocityX > 0) }
                gestureActive = false
                return nil
            case DockSwipeCancelled:
                gestureActive = false
                return nil
            default:
                break
            }
        }
        // Companion gesture events / non-horizontal dock events: swallow while
        // tracking to suppress the native switch, else pass through.
        return gestureActive ? nil : Unmanaged.passUnretained(event)
    }
}

private let wsTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let switcher = Unmanaged<WorkspaceSwitcher>.fromOpaque(refcon).takeUnretainedValue()
    return switcher.handle(type, event)
}
