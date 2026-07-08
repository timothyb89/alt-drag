// Launch-at-login via the modern SMAppService API (macOS 13+).
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("alt-drag: launch-at-login toggle failed: \(error)")
        }
    }
}
