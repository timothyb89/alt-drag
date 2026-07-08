// The menu-bar item and its menu. Rebuilt each time it opens so prerequisite
// status and toggles reflect live state.
import Cocoa

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap: EventTapController
    private let onToggleEnabled: (Bool) -> Void

    init(tap: EventTapController, onToggleEnabled: @escaping (Bool) -> Void) {
        self.tap = tap
        self.onToggleEnabled = onToggleEnabled
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: "Alt-Drag")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Alt-Drag", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabled)

        // Trigger submenu (radio).
        let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        let current = Settings.shared.modifier
        for (i, preset) in modifierPresets.enumerated() {
            let mi = NSMenuItem(title: preset.name, action: #selector(selectModifier(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = (preset.flags == current) ? .on : .off
            triggerMenu.addItem(mi)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let setupHeader = NSMenuItem(title: "Setup", action: nil, keyEquivalent: "")
        setupHeader.isEnabled = false
        menu.addItem(setupHeader)

        for (i, pre) in Prerequisites.all().enumerated() {
            let mark = pre.isSatisfied ? "✓" : "✗"
            let suffix = pre.isSatisfied ? "" : (pre.opensSettings ? " — open Settings…" : " — copy fix command")
            let mi = NSMenuItem(title: "\(mark) \(pre.title)\(suffix)",
                                action: pre.isSatisfied ? nil : #selector(fixPrerequisite(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.isEnabled = !pre.isSatisfied
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Alt-Drag", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        let newValue = !Settings.shared.enabled
        Settings.shared.enabled = newValue
        onToggleEnabled(newValue)
    }

    @objc private func selectModifier(_ sender: NSMenuItem) {
        Settings.shared.modifier = modifierPresets[sender.tag].flags
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func fixPrerequisite(_ sender: NSMenuItem) {
        let pre = Prerequisites.all()[sender.tag]
        if pre.opensSettings {
            Prerequisites.promptForAccessibility()
            Prerequisites.openAccessibilitySettings()
        } else if let cmd = pre.fixCommand {
            Prerequisites.copyToClipboard(cmd)
            let alert = NSAlert()
            alert.messageText = "Command copied"
            alert.informativeText = "Paste this into Terminal and run it:\n\n\(cmd)\n\n"
                + "(This app doesn't change system settings on its own.)"
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
