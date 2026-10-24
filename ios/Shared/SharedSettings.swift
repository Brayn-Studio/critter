import Foundation

/// The keys of the settings the app and its extensions share, in the App Group's defaults (`SharedContainer.defaults`).
/// The app writes them (`PhoneSettings`); an extension reads them by the same keys, never a copied literal.
enum SharedSettings {
    /// The Live Activity on the lock screen and in the Dynamic Island (spec §8.5). On by default.
    static let liveActivity = "critter.settings.liveActivity"
    /// Alert when a session is done, or has failed (spec §8.7). Off by default.
    static let notifyDone = "critter.settings.notifyDone"
    static let notifyError = "critter.settings.notifyError"
}
