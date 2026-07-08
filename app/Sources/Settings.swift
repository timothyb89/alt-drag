// Persisted user preferences.
import Foundation
import CoreGraphics

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let modifier = "modifierFlags"
        static let overrides = "appOverrides"
        static let legacyLearned = "learnedOffenders"
    }

    /// Per-app override rules, keyed by bundle identifier.
    var overrides: [String: AppOverride] {
        get {
            guard let data = d.data(forKey: Key.overrides),
                  let dict = try? JSONDecoder().decode([String: AppOverride].self, from: data)
            else { return [:] }
            return dict
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.overrides) }
    }

    func setOverride(_ bundleId: String, _ state: AppOverride.State, auto: Bool = false) {
        var o = overrides
        o[bundleId] = AppOverride(state: state, auto: auto)
        overrides = o
    }

    func removeOverride(_ bundleId: String) {
        var o = overrides
        o[bundleId] = nil
        overrides = o
    }

    /// One-time migration of the old learned-offenders set into override rules.
    func migrateIfNeeded() {
        guard let legacy = d.stringArray(forKey: Key.legacyLearned), !legacy.isEmpty else { return }
        var o = overrides
        for bid in legacy where o[bid] == nil { o[bid] = AppOverride(state: .fallback, auto: true) }
        overrides = o
        d.removeObject(forKey: Key.legacyLearned)
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

/// A per-app rule: either ignore the app entirely, or force the AX move
/// fallback. `auto` marks rules created by gesture-support learning (vs by the
/// user), for display only.
struct AppOverride: Codable, Equatable {
    enum State: String, Codable { case disabled, fallback }
    var state: State
    var auto: Bool
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
