// Detects (never writes) the two global defaults the app depends on, plus
// Accessibility trust. Per the "guide, don't auto-set" decision, the app only
// reports status and offers copy-to-clipboard fix commands.
import Cocoa
import ApplicationServices

struct Prerequisite {
    let title: String
    let isSatisfied: Bool
    let fixCommand: String?   // shell command to copy, if fixable that way
    let opensSettings: Bool   // if true, the fix is a Settings deep link instead
}

enum Prerequisites {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility once (system shows its own dialog).
    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static var nativeDragEnabled: Bool {
        let g = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (g?["NSWindowShouldDragOnGesture"] as? NSNumber)?.boolValue == true
    }

    static var tilingAcceleratorDisabled: Bool {
        let wm = UserDefaults(suiteName: "com.apple.WindowManager")
        // Satisfied only when explicitly false (default/unset is on -> too eager).
        return (wm?.object(forKey: "EnableTilingOptionAccelerator") as? NSNumber)?.boolValue == false
    }

    static func all() -> [Prerequisite] {
        [
            Prerequisite(title: "Accessibility access",
                         isSatisfied: accessibilityTrusted,
                         fixCommand: nil, opensSettings: true),
            Prerequisite(title: "Native drag gesture enabled",
                         isSatisfied: nativeDragEnabled,
                         fixCommand: "defaults write -g NSWindowShouldDragOnGesture -bool true",
                         opensSettings: false),
            Prerequisite(title: "Forced-tiling accelerator disabled",
                         isSatisfied: tilingAcceleratorDisabled,
                         fixCommand: "defaults write com.apple.WindowManager EnableTilingOptionAccelerator -bool false && killall WindowManager",
                         opensSettings: false),
        ]
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
