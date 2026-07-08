import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = EventTapController()
    private let switcher = WorkspaceSwitcher()
    private var menuBar: MenuBarController!
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.migrateIfNeeded()
        menuBar = MenuBarController(tap: tap, onChanged: { [weak self] in
            self?.sync()
        })

        if !Prerequisites.accessibilityTrusted {
            Prerequisites.promptForAccessibility()
        }
        sync()
    }

    /// Start/stop each tap to match its enabled setting. Starting can fail until
    /// Accessibility is granted, so we poll until every enabled tap is running.
    private func sync() {
        if allEnabledRunning() { stopRetryLoop() } else { startRetryLoop() }
    }

    /// Attempts to bring both taps in line with settings; returns whether every
    /// enabled tap is now running.
    @discardableResult
    private func allEnabledRunning() -> Bool {
        var ok = true
        if Settings.shared.enabled { ok = tap.start() && ok } else { tap.stop() }
        if Settings.shared.workspaceEnabled { ok = switcher.start() && ok } else { switcher.stop() }
        return ok
    }

    private func startRetryLoop() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.allEnabledRunning() { self.stopRetryLoop() }
        }
    }

    private func stopRetryLoop() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        switcher.stop()
    }
}
