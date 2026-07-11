// The menu-bar item and its menu. Rebuilt each time it opens so prerequisite
// status and toggles reflect live state.
import Cocoa

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tap: EventTapController
    private let onChanged: () -> Void

    init(tap: EventTapController, onChanged: @escaping () -> Void) {
        self.tap = tap
        self.onChanged = onChanged
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
        buildClickThroughSection(into: menu)

        menu.addItem(.separator())
        buildWorkspaceSection(into: menu)

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

        menu.addItem(buildAppRulesItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Alt-Drag", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        onChanged()
    }

    @objc private func selectModifier(_ sender: NSMenuItem) {
        Settings.shared.modifier = modifierPresets[sender.tag].flags
    }

    // --- Click-through / drag-through ----------------------------------------
    private func buildClickThroughSection(into menu: NSMenu) {
        let header = NSMenuItem(title: "Click-Through", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let click = NSMenuItem(title: "Click-Through (fix eaten first click)",
                               action: #selector(toggleClickThrough), keyEquivalent: "")
        click.target = self
        click.state = Settings.shared.clickThroughEnabled ? .on : .off
        menu.addItem(click)

        let drag = NSMenuItem(title: "Drag-Through (live background drag)",
                              action: #selector(toggleDragThrough), keyEquivalent: "")
        drag.target = self
        drag.state = Settings.shared.dragThroughEnabled ? .on : .off
        menu.addItem(drag)
    }

    @objc private func toggleClickThrough() { Settings.shared.clickThroughEnabled.toggle() }
    @objc private func toggleDragThrough() { Settings.shared.dragThroughEnabled.toggle() }

    // --- Workspace switcher --------------------------------------------------
    private func buildWorkspaceSection(into menu: NSMenu) {
        let header = NSMenuItem(title: "Workspace Switch", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let toggle = NSMenuItem(title: "Instant Switch Gesture",
                                action: #selector(toggleWorkspace), keyEquivalent: "")
        toggle.target = self
        toggle.state = Settings.shared.workspaceEnabled ? .on : .off
        menu.addItem(toggle)

        // Sensitivity (radio).
        let sensItem = NSMenuItem(title: "Swipe Sensitivity", action: nil, keyEquivalent: "")
        let sensMenu = NSMenu()
        let currentFull = Settings.shared.workspaceSensitivity
        for (i, preset) in sensitivityPresets.enumerated() {
            let mi = NSMenuItem(title: preset.name, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = (preset.full == currentFull) ? .on : .off
            sensMenu.addItem(mi)
        }
        sensItem.submenu = sensMenu
        sensItem.isEnabled = Settings.shared.workspaceEnabled
        menu.addItem(sensItem)

        let haptics = NSMenuItem(title: "Haptic Feedback",
                                 action: #selector(toggleHaptics), keyEquivalent: "")
        haptics.target = self
        haptics.state = Settings.shared.workspaceHaptics ? .on : .off
        haptics.isEnabled = Settings.shared.workspaceEnabled
        menu.addItem(haptics)
    }

    @objc private func toggleWorkspace() {
        Settings.shared.workspaceEnabled.toggle()
        onChanged()
    }
    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        Settings.shared.workspaceSensitivity = sensitivityPresets[sender.tag].full
    }
    @objc private func toggleHaptics() {
        Settings.shared.workspaceHaptics.toggle()
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

    // --- App Rules -----------------------------------------------------------
    private func buildAppRulesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "App Rules", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let overrides = Settings.shared.overrides

        if overrides.isEmpty {
            let none = NSMenuItem(title: "No rules", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for bid in overrides.keys.sorted(by: { displayName($0) < displayName($1) }) {
                submenu.addItem(ruleItem(bundleId: bid, override: overrides[bid]!))
            }
        }

        // Add a rule for the frontmost app (the one you were just using).
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier, bid != Bundle.main.bundleIdentifier,
           overrides[bid] == nil {
            submenu.addItem(.separator())
            let add = NSMenuItem(title: "Add rule for \(front.localizedName ?? bid)…",
                                 action: nil, keyEquivalent: "")
            let addSub = NSMenu()
            let fb = NSMenuItem(title: "Fallback (AX move)", action: #selector(addFrontFallback), keyEquivalent: "")
            fb.target = self
            let dis = NSMenuItem(title: "Disabled (ignore app)", action: #selector(addFrontDisabled), keyEquivalent: "")
            dis.target = self
            addSub.addItem(fb); addSub.addItem(dis)
            add.submenu = addSub
            submenu.addItem(add)
        }

        item.submenu = submenu
        return item
    }

    private func ruleItem(bundleId bid: String, override o: AppOverride) -> NSMenuItem {
        let title = displayName(bid) + (o.auto ? " (auto)" : "")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let fb = NSMenuItem(title: "Fallback (AX move)", action: #selector(setRuleFallback(_:)), keyEquivalent: "")
        fb.target = self; fb.representedObject = bid; fb.state = o.state == .fallback ? .on : .off
        let dis = NSMenuItem(title: "Disabled (ignore app)", action: #selector(setRuleDisabled(_:)), keyEquivalent: "")
        dis.target = self; dis.representedObject = bid; dis.state = o.state == .disabled ? .on : .off
        let del = NSMenuItem(title: "Remove rule", action: #selector(removeRule(_:)), keyEquivalent: "")
        del.target = self; del.representedObject = bid
        sub.addItem(fb); sub.addItem(dis); sub.addItem(.separator()); sub.addItem(del)
        item.submenu = sub
        return item
    }

    private func displayName(_ bid: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName ?? bid
    }

    @objc private func setRuleFallback(_ s: NSMenuItem) {
        if let bid = s.representedObject as? String { Settings.shared.setOverride(bid, .fallback) }
    }
    @objc private func setRuleDisabled(_ s: NSMenuItem) {
        if let bid = s.representedObject as? String { Settings.shared.setOverride(bid, .disabled) }
    }
    @objc private func removeRule(_ s: NSMenuItem) {
        if let bid = s.representedObject as? String { Settings.shared.removeOverride(bid) }
    }
    @objc private func addFrontFallback() { addFrontmost(.fallback) }
    @objc private func addFrontDisabled() { addFrontmost(.disabled) }
    private func addFrontmost(_ state: AppOverride.State) {
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            Settings.shared.setOverride(bid, state)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
