// Decides, per drag, whether to use the native gesture remap or the AX move
// fallback, and learns which apps never honor the native gesture.
//
// Learning rule (reconciles "keep Chrome native" with "auto-learn offenders"):
// an app is only auto-denylisted once it has accumulated failures AND zero
// successes — i.e. it appears to NEVER move via the native gesture. An app that
// works even sometimes (Chrome from its title bar) keeps native; its one
// unsupported surface (vertical tab bar) just keeps leaking, as chosen.
import Cocoa

final class AppPolicy {
    static let shared = AppPolicy()

    enum Route {
        case disabled          // ignore the app entirely (gestures pass through)
        case fallback(String?) // use the AX move fallback
        case native(String?)   // use the Ctrl+Cmd remap; probe & learn
    }

    // Known offenders that never honor the gesture — treated as a default
    // fallback rule (unless the user has set their own override) so they never
    // leak even once.
    private let seeded: [String: AppOverride.State] = [
        "com.apple.systempreferences": .fallback,   // System Settings (Catalyst)
    ]

    private let lock = NSLock()
    private var counts: [String: (succ: Int, fail: Int)] = [:]
    private let failThreshold = 2

    func route(at loc: CGPoint) -> Route {
        guard let bid = bundleId(under: loc) else { return .native(nil) }
        // User/learned overrides win; then seeded defaults; then native.
        let state = Settings.shared.overrides[bid]?.state ?? seeded[bid]
        switch state {
        case .disabled: return .disabled
        case .fallback: return .fallback(bid)
        case nil:       return .native(bid)
        }
    }

    /// Record the outcome of a native-gesture drag (did the window actually
    /// move?). Only apps with no existing rule can be auto-learned; a manual
    /// rule is never overwritten. Note: once an app has a fallback rule it takes
    /// the AX path and is no longer probed, so there's no auto-un-learning —
    /// removal is done by the user via the App Rules menu.
    func record(bundleId: String?, moved: Bool) {
        guard let bid = bundleId, Settings.shared.overrides[bid] == nil else { return }
        lock.lock()
        var c = counts[bid] ?? (0, 0)
        if moved { c.succ += 1 } else { c.fail += 1 }
        counts[bid] = c
        let succ = c.succ, fail = c.fail
        lock.unlock()

        if !moved, fail >= failThreshold, succ == 0 {
            Settings.shared.setOverride(bid, .fallback, auto: true)
            NSLog("alt-drag: learned native-gesture offender \(bid) -> AX move fallback")
        }
    }

    // Topmost normal window under the point -> owning app's bundle id.
    // CGWindowList (front-to-back, top-left/global coords) matches the cursor
    // coordinate space and is cheap enough for the mouse-down path.
    private func bundleId(under loc: CGPoint) -> String? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bDict as CFDictionary),
                  r.contains(loc) else { continue }
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t {
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            return nil
        }
        return nil
    }
}
