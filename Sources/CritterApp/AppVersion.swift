import Foundation

/// Critter's version as its Info.plist gives it; "0.0.0" outside an app bundle (`swift run`).
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
