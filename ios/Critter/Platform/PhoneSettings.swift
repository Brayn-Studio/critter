import Foundation
import Observation
import UIKit

/// The phone's own settings (Android `SettingsStore`), kept in `UserDefaults` under `critter.settings.*`; the
/// defaults are Android's (the Live Activity, which Android does not have, is on). The ones the extensions read too
/// (the Live Activity, the done and error alerts) are in the App Group's defaults (`SharedContainer.defaults`), the
/// rest in the app's own.
///
/// One for the app's life (`CritterApp` makes it), handed down through the environment.
@MainActor @Observable
final class PhoneSettings {
    /// A bundled skin shown for every session; nil follows the Mac (spec §8.8).
    var forcedSkin: String? {
        didSet { save(forcedSkin, Key.forcedSkin) }
    }

    /// Reduce motion by hand; the system's "减少动态效果" counts as well (`motionReduced`).
    var reduceMotion: Bool {
        didSet { save(reduceMotion, Key.reduceMotion) }
    }

    /// Open the board by itself while charging in landscape (spec §8.6).
    var boardAutoOpen: Bool {
        didSet { save(boardAutoOpen, Key.boardAutoOpen) }
    }

    /// Which board is shown: the enlarged Critters, or the pro dashboard. Remembered.
    var boardCritterMode: Bool {
        didSet { save(boardCritterMode, Key.boardCritterMode) }
    }

    /// The board's screen brightness, 0.1...1 (the settings slider's range; a stored value outside it is clamped
    /// when read back).
    var boardBrightness: Double {
        didSet { save(boardBrightness, Key.boardBrightness) }
    }

    /// Sounds on the board when a session just needs you, finished or failed (spec §8.7). Off by default.
    var boardSounds: Bool {
        didSet { save(boardSounds, Key.boardSounds) }
    }

    /// The Live Activity on the lock screen and in the Dynamic Island (spec §8.5). On by default.
    var liveActivity: Bool {
        didSet { shared.set(liveActivity, forKey: Key.liveActivity) }
    }

    /// Alert when a session is done, or has failed (spec §8.7). Off by default, as on Android.
    var notifyDone: Bool {
        didSet { shared.set(notifyDone, forKey: Key.notifyDone) }
    }

    var notifyError: Bool {
        didSet { shared.set(notifyError, forKey: Key.notifyError) }
    }

    /// The first-run guide has been gone through (or skipped to its end): it does not come up by itself again (spec
    /// §8.8). The settings' 「重新走一遍引导」 opens it by hand.
    var onboardingDone: Bool {
        didSet { save(onboardingDone, Key.onboardingDone) }
    }

    /// The day the opening (Critters popping up on the home screen) last played, "yyyy-MM-dd" in the phone's time
    /// zone: it plays once a day.
    var openingShownOn: String? {
        didSet { save(openingShownOn, Key.openingShownOn) }
    }

    /// The system's "减少动态效果", followed as it changes.
    private(set) var systemReduceMotion = UIAccessibility.isReduceMotionEnabled

    /// Reduce motion is on: the app's switch or the system's.
    var motionReduced: Bool { reduceMotion || systemReduceMotion }

    @ObservationIgnored private let defaults: UserDefaults
    /// The App Group's: what the extensions read too.
    @ObservationIgnored private let shared: UserDefaults

    private enum Key {
        static let forcedSkin = "critter.settings.forcedSkin"
        static let reduceMotion = "critter.settings.reduceMotion"
        static let boardAutoOpen = "critter.settings.boardAutoOpen"
        static let boardCritterMode = "critter.settings.boardCritterMode"
        static let boardBrightness = "critter.settings.boardBrightness"
        static let boardSounds = "critter.settings.boardSounds"
        static let openingShownOn = "critter.settings.openingShownOn"
        static let onboardingDone = "critter.settings.onboardingDone"
        // The ones the extensions read too: their keys are shared (`SharedSettings`).
        static let liveActivity = SharedSettings.liveActivity
        static let notifyDone = SharedSettings.notifyDone
        static let notifyError = SharedSettings.notifyError
    }

    init(defaults: UserDefaults = .standard, shared: UserDefaults = SharedContainer.defaults) {
        self.defaults = defaults
        self.shared = shared
        forcedSkin = defaults.string(forKey: Key.forcedSkin).flatMap { $0.isEmpty ? nil : $0 }
        reduceMotion = defaults.object(forKey: Key.reduceMotion) as? Bool ?? false
        boardAutoOpen = defaults.object(forKey: Key.boardAutoOpen) as? Bool ?? true
        boardCritterMode = defaults.object(forKey: Key.boardCritterMode) as? Bool ?? true
        boardBrightness = Self.clampBrightness(defaults.object(forKey: Key.boardBrightness) as? Double ?? 0.3)
        boardSounds = defaults.object(forKey: Key.boardSounds) as? Bool ?? false
        openingShownOn = defaults.string(forKey: Key.openingShownOn)
        onboardingDone = defaults.object(forKey: Key.onboardingDone) as? Bool ?? false
        liveActivity = shared.object(forKey: Key.liveActivity) as? Bool ?? true
        notifyDone = shared.object(forKey: Key.notifyDone) as? Bool ?? false
        notifyError = shared.object(forKey: Key.notifyError) as? Bool ?? false
        // The settings live as long as the app: the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemReduceMotion = UIAccessibility.isReduceMotionEnabled }
        }
    }

    /// "yyyy-MM-dd" for `date` in the phone's time zone, as `openingShownOn` keeps it.
    static func day(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func clampBrightness(_ value: Double) -> Double {
        value.isNaN ? 0.3 : min(max(value, 0.1), 1)
    }

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func save(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func save(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
