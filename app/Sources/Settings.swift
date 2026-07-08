// Persisted user preferences.
import Foundation
import CoreGraphics

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let modifier = "modifierFlags"
    }

    var enabled: Bool {
        get { d.object(forKey: Key.enabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.enabled) }
    }

    /// The trigger modifier, stored as a device-independent CGEventFlags raw value.
    var modifier: CGEventFlags {
        get {
            if let raw = d.object(forKey: Key.modifier) as? NSNumber {
                return CGEventFlags(rawValue: raw.uint64Value)
            }
            return .maskAlternate   // default: Option, matching Linux alt-drag
        }
        set { d.set(NSNumber(value: newValue.rawValue), forKey: Key.modifier) }
    }
}

/// Selectable trigger modifiers surfaced in the menu.
struct ModifierPreset {
    let name: String
    let flags: CGEventFlags
}

let modifierPresets: [ModifierPreset] = [
    ModifierPreset(name: "Option (⌥)",        flags: .maskAlternate),
    ModifierPreset(name: "Command (⌘)",       flags: .maskCommand),
    ModifierPreset(name: "Control (⌃)",       flags: .maskControl),
    ModifierPreset(name: "Option + Shift (⌥⇧)", flags: [.maskAlternate, .maskShift]),
]
