import ClawdCore
import Foundation
import Observation

/// The user's settings (spec §8), persisted in UserDefaults (readable with
/// `defaults read local.clawd.pet`). The settings window binds to these properties
/// directly; every change is saved immediately and reported through `onChange`, so it
/// takes effect live (the app delegate routes it to the pet, the hot key or the login item).
@MainActor
@Observable
final class SettingsStore {
    enum Change {
        case petScale, sounds, mergeThreshold, hotKey, launchAtLogin
    }

    static let scaleRange: ClosedRange<Double> = 0.5...2.0
    static let scaleStep = 0.25
    static let mergeThresholdRange: ClosedRange<Int> = 2...10

    private enum Key {
        static let petScale = "petScale"
        static let soundEnabled = "soundEnabled"
        static let soundOnWaiting = "soundOnWaiting"
        static let soundOnDone = "soundOnDone"
        static let soundOnError = "soundOnError"
        /// Same key the pet has read since before the settings window existed.
        static let mergeThreshold = "mergeThreshold"
        static let hotKey = "hotKey"
        static let launchAtLogin = "launchAtLogin"
    }

    /// Clawd's size: 0.5…2.0 in steps of 0.25, 1.0 ("中") by default.
    var petScale: Double {
        didSet {
            let fixed = Self.snapScale(petScale)
            guard fixed == petScale else { petScale = fixed; return }
            save(petScale, Key.petScale, changed: petScale != oldValue, .petScale)
        }
    }
    var soundEnabled: Bool {
        didSet { save(soundEnabled, Key.soundEnabled, changed: soundEnabled != oldValue, .sounds) }
    }
    var soundOnWaiting: Bool {
        didSet { save(soundOnWaiting, Key.soundOnWaiting, changed: soundOnWaiting != oldValue, .sounds) }
    }
    var soundOnDone: Bool {
        didSet { save(soundOnDone, Key.soundOnDone, changed: soundOnDone != oldValue, .sounds) }
    }
    var soundOnError: Bool {
        didSet { save(soundOnError, Key.soundOnError, changed: soundOnError != oldValue, .sounds) }
    }
    /// Above this many sessions the flock merges into a pile (2…10, default 4).
    var mergeThreshold: Int {
        didSet {
            let fixed = Self.clampThreshold(mergeThreshold)
            guard fixed == mergeThreshold else { mergeThreshold = fixed; return }
            save(mergeThreshold, Key.mergeThreshold, changed: mergeThreshold != oldValue, .mergeThreshold)
        }
    }
    /// The global show/hide shortcut (default ⌃⌥C), stored as a JSON string.
    var hotKey: HotKeySpec {
        didSet {
            guard hotKey != oldValue else { return }
            defaults.set(Self.encode(hotKey), forKey: Key.hotKey)
            onChange?(.hotKey)
        }
    }
    var launchAtLogin: Bool {
        didSet { save(launchAtLogin, Key.launchAtLogin, changed: launchAtLogin != oldValue, .launchAtLogin) }
    }

    /// Not persisted: registering `hotKey` failed (another app holds that combination).
    var hotKeyUnavailable = false
    /// Not persisted: the settings window is waiting for a new combination. The current
    /// hot key is unregistered meanwhile, so pressing it can be recorded too.
    var isRecordingHotKey = false {
        didSet {
            if isRecordingHotKey != oldValue { onChange?(.hotKey) }
        }
    }

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String) -> Bool {
            defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        petScale = Self.snapScale(defaults.object(forKey: Key.petScale) == nil ? 1.0 : defaults.double(forKey: Key.petScale))
        soundEnabled = bool(Key.soundEnabled)
        soundOnWaiting = bool(Key.soundOnWaiting)
        soundOnDone = bool(Key.soundOnDone)
        soundOnError = bool(Key.soundOnError)
        mergeThreshold = Self.clampThreshold(defaults.object(forKey: Key.mergeThreshold) == nil ? 4 : defaults.integer(forKey: Key.mergeThreshold))
        hotKey = defaults.string(forKey: Key.hotKey).flatMap(Self.decode) ?? .default
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }

    /// Whether entering `state` should make a sound: the master switch and that state's
    /// own switch are both on.
    func soundAllowed(for state: PetState) -> Bool {
        guard soundEnabled else { return false }
        switch state {
        case .waiting: return soundOnWaiting
        case .done: return soundOnDone
        case .error: return soundOnError
        case .idle, .running: return false
        }
    }

    /// Debug-only (`clawd://debug-set?<key>=<value>`): sets a setting exactly as the
    /// settings window would, for verifying without a display. Launch at login is left out
    /// on purpose. Returns false for an unknown key or a malformed value.
    func applyDebugValue(_ value: String, forKey key: String) -> Bool {
        func flag() -> Bool? { ["1", "true", "yes"].contains(value) ? true : ["0", "false", "no"].contains(value) ? false : nil }
        switch key {
        case Key.petScale:
            guard let scale = Double(value) else { return false }
            petScale = scale
        case Key.mergeThreshold:
            guard let threshold = Int(value) else { return false }
            mergeThreshold = threshold
        case Key.soundEnabled, Key.soundOnWaiting, Key.soundOnDone, Key.soundOnError:
            guard let on = flag() else { return false }
            switch key {
            case Key.soundEnabled: soundEnabled = on
            case Key.soundOnWaiting: soundOnWaiting = on
            case Key.soundOnDone: soundOnDone = on
            default: soundOnError = on
            }
        case Key.hotKey:
            // "<keyCode>,<Carbon modifier mask>", e.g. "35,0x1a00" for ⌃⌥⇧P.
            let parts = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let code = UInt32(parts[0]), let mask = Self.parseMask(parts[1]) else { return false }
            hotKey = HotKeySpec(keyCode: code, modifiers: mask)
        default:
            return false
        }
        return true
    }

    // MARK: - Helpers

    private func save(_ value: Any, _ key: String, changed: Bool, _ change: Change) {
        guard changed else { return }
        defaults.set(value, forKey: key)
        onChange?(change)
    }

    private static func snapScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1.0 }
        let snapped = (scale / scaleStep).rounded() * scaleStep
        return min(max(snapped, scaleRange.lowerBound), scaleRange.upperBound)
    }

    private static func clampThreshold(_ threshold: Int) -> Int {
        min(max(threshold, mergeThresholdRange.lowerBound), mergeThresholdRange.upperBound)
    }

    private static func encode(_ spec: HotKeySpec) -> String {
        guard let data = try? JSONEncoder().encode(spec) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ text: String) -> HotKeySpec? {
        try? JSONDecoder().decode(HotKeySpec.self, from: Data(text.utf8))
    }

    private static func parseMask(_ text: String) -> UInt32? {
        text.hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
    }
}
