import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = EventTapController()
    private var menuBar: MenuBarController!
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.migrateIfNeeded()
        menuBar = MenuBarController(tap: tap, onToggleEnabled: { [weak self] enabled in
            self?.applyEnabledState(enabled)
        })

        if !Prerequisites.accessibilityTrusted {
            Prerequisites.promptForAccessibility()
        }
        applyEnabledState(Settings.shared.enabled)
    }

    /// Start or stop the tap to match the enabled setting. Starting can fail if
    /// Accessibility isn't granted yet, so we poll until it succeeds.
    private func applyEnabledState(_ enabled: Bool) {
        if enabled {
            if !tap.start() { startRetryLoop() }
        } else {
            tap.stop()
            stopRetryLoop()
        }
    }

    private func startRetryLoop() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !Settings.shared.enabled { self.stopRetryLoop(); return }
            if self.tap.start() { self.stopRetryLoop() }
        }
    }

    private func stopRetryLoop() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
    }
}
