// alt-space overlay spike — keyboard-driven, alt-tab-style workspace switcher.
//
// Interaction (mirrors Cmd-Tab):
//   * Hold the trigger modifier (Option by default). Bare Option does nothing.
//   * While held, press Tab / Right to move the selection to the next space,
//     Shift+Tab / Left for the previous. The first such press opens the overlay.
//   * Release the trigger to commit; Escape cancels.
//
// Two commit models, toggled with --live:
//   * default (commit-on-release): the overlay only moves a highlight; the
//     actual switch happens once, on release.
//   * --live: each selection move switches the real space immediately (the live
//     desktop IS the preview); release just dismisses.
//
// Placeholder rendering only: a numbered card per space, current one tinted,
// selected one ringed, empty interior where a cached preview could go later.
//
// Needs Accessibility for the launching terminal (event tap + posting swipes).

import Cocoa
import CoreGraphics

// MARK: - Config

func argValue(_ name: String) -> Double? {
    for a in CommandLine.arguments where a.hasPrefix(name + "=") {
        return Double(a.dropFirst(name.count + 1))
    }
    return nil
}

let liveMode = CommandLine.arguments.contains("--live")
let ungated = CommandLine.arguments.contains("--ungated")   // don't require the modifier for swipe
let debug = CommandLine.arguments.contains("--debug")       // log raw swipe progress/velocity
// The swipe `progress` value that maps to the full desktop range — i.e. swipe
// sensitivity. Smaller = less physical travel to cross all desktops. The raw
// max extent is ~2 (a full, uncomfortable trackpad swipe); ~0.5–1 feels good.
// This should be user-configurable in the real app. Override with --full=<value>.
let fullSwipe = argValue("--full") ?? 0.75
// MTActuator actuation pattern for the per-space detent (see haptictest to
// find the firmest). Falls back to NSHapticFeedbackManager if MTActuator is
// unavailable. Override with --hapticid=<n>.
let hapticID = Int32(argValue("--hapticid") ?? 6)
let mtHaptics = haptic_init()
let triggerFlag: CGEventFlags = .maskAlternate   // Option
let kVK_Tab: Int64 = 48, kVK_Left: Int64 = 123, kVK_Right: Int64 = 124, kVK_Escape: Int64 = 53

func log(_ s: String) { FileHandle.standardError.write(("[overlay] " + s + "\n").data(using: .utf8)!) }

// MARK: - Space model

struct Spaces {
    var count: Int
    var current: Int   // index the display was on when the overlay opened
}

func readSpaces() -> Spaces? {
    var info = SpaceInfo()
    guard space_info(SpaceTargetCursor, &info) else { return nil }
    return Spaces(count: Int(info.spaceCount), current: Int(info.currentIndex))
}

func screenUnderCursor() -> NSScreen {
    let loc = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) } ?? (NSScreen.main ?? NSScreen.screens[0])
}

// MARK: - Overlay view

final class OverlayView: NSView {
    var count = 0
    var current = 0
    var selected = 0
    var cursor: CGFloat = -1   // continuous scrub position (fractional index); <0 hides it

    private let card = NSSize(width: 150, height: 96)
    private let gap: CGFloat = 18
    private let pad: CGFloat = 28
    private let cardsBottom: CGFloat = 50   // pad + caption room

    override var isFlipped: Bool { false }

    private var startX: CGFloat {
        let totalW = CGFloat(count) * card.width + CGFloat(max(0, count - 1)) * gap
        return (bounds.width - totalW) / 2
    }
    // Center x of a (possibly fractional) card index.
    private func centerX(_ idx: CGFloat) -> CGFloat {
        startX + idx * (card.width + gap) + card.width / 2
    }

    override func draw(_ dirty: NSRect) {
        // container
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
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }

        // live scrub indicator: a track spanning the cards with a knob at the
        // continuous cursor position (distinct from the snapped selection).
        if cursor >= 0 && count > 0 {
            let trackY = cardsBottom + card.height + 14
            let x0 = centerX(0), x1 = centerX(CGFloat(count - 1))
            let track = NSBezierPath()
            track.move(to: NSPoint(x: x0, y: trackY))
            track.line(to: NSPoint(x: x1, y: trackY))
            track.lineWidth = 2
            NSColor(white: 0.4, alpha: 1).setStroke()
            track.stroke()

            let kx = centerX(cursor)
            let r: CGFloat = 7
            let knob = NSBezierPath(ovalIn: NSRect(x: kx - r, y: trackY - r, width: 2 * r, height: 2 * r))
            NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.0, alpha: 1).setFill()
            knob.fill()
        }

        // caption
        let cap = (liveMode ? "live switch" : "commit on release") as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ]
        let capSize = cap.size(withAttributes: capAttrs)
        cap.draw(at: NSPoint(x: bounds.midX - capSize.width / 2, y: pad - 4), withAttributes: capAttrs)
    }
}

// MARK: - Controller

final class Controller {
    private var panel: NSPanel?
    private let view = OverlayView()

    private var active = false
    private var spaces = Spaces(count: 0, current: 0)
    private var selected = 0

    // Open the overlay for the display under the cursor.
    func open() {
        guard let s = readSpaces(), s.count > 1 else { return }
        spaces = s
        selected = s.current
        active = true

        let screen = screenUnderCursor()
        let w: CGFloat = min(screen.frame.width - 80, CGFloat(s.count) * 168 + 56 + 40)
        let h: CGFloat = 96 + 28 * 2 + 22 + 24   // extra room for the scrub track
        let frame = NSRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.midY - h / 2,
            width: w, height: h)

        let p = panel ?? makePanel()
        p.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.count = s.count
        view.current = s.current
        view.selected = selected
        view.cursor = CGFloat(selected)
        view.needsDisplay = true
        p.orderFrontRegardless()
        panel = p
        log("open — \(s.count) spaces, on \(s.current + 1)")
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
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

    // Move selection one step; wraps at the ends. In live mode, switch the real
    // space each step (a wrap is a multi-step jump the other way, since macOS
    // spaces don't themselves wrap).
    func move(right: Bool) {
        if !active { open() }
        guard active else { return }
        let n = spaces.count
        let target = ((selected + (right ? 1 : -1)) % n + n) % n
        step(to: target)
    }

    private func step(to target: Int) {
        let delta = target - selected
        guard delta != 0 else { return }
        selected = target
        view.selected = selected
        view.cursor = CGFloat(selected)
        view.needsDisplay = true
        if liveMode {
            space_switch_steps(delta > 0, UInt32(abs(delta)))
            view.current = selected   // the live desktop moved with us
            view.needsDisplay = true
        }
    }

    // Commit: in commit mode, jump from the origin to the selection in one shot.
    func commit() {
        defer { dismiss() }
        guard active else { return }
        if !liveMode {
            let delta = selected - spaces.current
            if delta != 0 { space_switch_steps(delta > 0, UInt32(abs(delta))) }
        }
        log("commit — space \(selected + 1)")
    }

    func cancel() {
        defer { dismiss() }
        guard active else { return }
        // In live mode we've already moved; snap back to where we started.
        if liveMode {
            let delta = selected - spaces.current
            if delta != 0 { space_switch_steps(delta < 0, UInt32(abs(delta))) }
        }
        log("cancel")
    }

    // --- Trackpad swipe path ------------------------------------------------
    // A physical swipe is transient (you can't "hold" it), so it switches
    // immediately (live) and the overlay lingers briefly after release.
    // Absolute mapping: the swipe's `progress` is normalized against a full
    // swipe and spread across the whole desktop range, so one motion can land
    // on any desktop. The switch happens per space crossed (with a haptic
    // tick); the continuous cursor tracks the exact scrub position.
    private var dismissGen = 0
    private var swipeOrigin = 0   // selection index when the gesture began

    // Returns whether we're handling this gesture (false => let the OS have it,
    // e.g. a single-space display).
    func swipeBegin() -> Bool {
        dismissGen += 1            // cancel any pending linger-dismiss
        if !active { open() }
        swipeOrigin = selected
        return active
    }

    func swipeUpdate(progress: Double) {
        guard active else { return }
        let span = Double(spaces.count - 1)
        let scaled = progress / fullSwipe * span            // spaces from origin
        let pos = max(0, min(span, Double(swipeOrigin) + scaled))
        view.cursor = CGFloat(pos)
        view.needsDisplay = true
        stepTowards(Int(pos.rounded()))
    }

    // Quick flick that produced no measurable progress: nudge one space.
    func swipeFling(right: Bool) {
        guard active, selected == swipeOrigin else { return }
        stepTowards(max(0, min(spaces.count - 1, selected + (right ? 1 : -1))))
    }

    // Walk to `target` one space at a time, switching + a haptic tick per stop.
    private func stepTowards(_ target: Int) {
        guard target != selected else { return }
        let right = target > selected
        while selected != target {
            selected += right ? 1 : -1
            space_switch(right)
            if mtHaptics {
                haptic_fire(hapticID)
            } else {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
        view.selected = selected
        view.current = selected
        view.needsDisplay = true
    }

    func swipeEnd() {
        guard active else { return }
        dismissGen += 1
        let gen = dismissGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.dismissGen == gen else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        active = false
        view.cursor = -1
        panel?.orderOut(nil)
    }

    var isActive: Bool { active }
}

// MARK: - Event tap

let controller = Controller()
var triggerDown = false
var sharedTap: CFMachPort?

// Real-trackpad-swipe interception state.
var gestureActive = false

// CGS event types (not in the CGEventType enum): 29 = gesture, 30 = dock control.
let kCGSEventGesture: UInt32 = 29
let kCGSEventDockControl: UInt32 = 30

// Handle a CGS gesture / dock-control event. Drives the overlay from the real
// 3-finger horizontal swipe and swallows it so the OS doesn't also switch.
func handleGesture(_ raw: UInt32, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    // Our own synthetic swipes must pass through to reach the WindowServer.
    if event_is_synthetic(event) { return Unmanaged.passUnretained(event) }

    var ev = DockSwipeEvent()
    if raw == kCGSEventDockControl && dock_swipe_classify(event, &ev) {
        if debug && ev.phase != DockSwipeNone {
            log("swipe phase=\(ev.phase.rawValue) progress=\(ev.progress) vx=\(ev.velocityX)")
        }
        switch ev.phase {
        case DockSwipeBegan:
            // Gate: only claim the swipe while the trigger modifier is held.
            guard ungated || triggerDown else { return Unmanaged.passUnretained(event) }
            gestureActive = controller.swipeBegin()
            return gestureActive ? nil : Unmanaged.passUnretained(event)
        case DockSwipeChanged:
            guard gestureActive else { return Unmanaged.passUnretained(event) }
            controller.swipeUpdate(progress: ev.progress)
            return nil
        case DockSwipeEnded:
            guard gestureActive else { return Unmanaged.passUnretained(event) }
            if ev.velocityX != 0 { controller.swipeFling(right: ev.velocityX > 0) }
            controller.swipeEnd()
            gestureActive = false
            return nil
        case DockSwipeCancelled:
            if gestureActive { controller.swipeEnd(); gestureActive = false }
            return nil
        default:
            break
        }
    }
    // Real companion gesture events (type 29) or non-horizontal dock events:
    // swallow while tracking to suppress the native switch, else pass through.
    return gestureActive ? nil : Unmanaged.passUnretained(event)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let raw = type.rawValue
    if raw == kCGSEventGesture || raw == kCGSEventDockControl {
        return handleGesture(raw, event)
    }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = sharedTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)

    case .flagsChanged:
        let nowDown = event.flags.contains(triggerFlag)
        if triggerDown && !nowDown {           // trigger released
            if controller.isActive { controller.commit() }
        }
        triggerDown = nowDown

    case .keyDown:
        guard triggerDown else { break }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let shift = event.flags.contains(.maskShift)
        switch code {
        // Tab is always ours (Option+Tab isn't a text-nav combo) and opens the
        // overlay on first press.
        case kVK_Tab: controller.move(right: !shift); return nil
        // Arrows are only captured once the overlay is open, so Option+arrow
        // word-navigation keeps working normally beforehand.
        case kVK_Right where controller.isActive: controller.move(right: true);  return nil
        case kVK_Left  where controller.isActive: controller.move(right: false); return nil
        case kVK_Escape where controller.isActive: controller.cancel(); return nil
        default: break
        }

    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Boot

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let mask: CGEventMask =
    CGEventMask(1) << CGEventType.keyDown.rawValue |
    CGEventMask(1) << CGEventType.flagsChanged.rawValue |
    CGEventMask(1) << kCGSEventGesture |
    CGEventMask(1) << kCGSEventDockControl

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: .defaultTap, eventsOfInterest: mask,
    callback: callback, userInfo: nil) else {
    log("FAILED to create event tap — grant Accessibility to your terminal.")
    exit(1)
}
sharedTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

log("running (\(liveMode ? "live" : "commit-on-release"))\(ungated ? " [ungated]" : "")\(debug ? " [debug]" : "") haptics=\(mtHaptics ? "MTActuator id \(hapticID)" : "NSHaptic fallback"). Keyboard: hold Option, Tab to open + scrub, release to switch. Trackpad: hold Option + 3-finger swipe between spaces (instant, haptic per stop). Ctrl+C to quit.")
app.run()
