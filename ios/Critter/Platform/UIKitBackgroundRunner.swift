import CritterClient
import UIKit

/// Runs work inside a UIKit background task, so the system lets it finish after the app has left the foreground.
@MainActor
final class UIKitBackgroundRunner: BackgroundRunner {
    func run(_ work: @escaping @MainActor () async -> Void) {
        let task = BackgroundTask(name: "Critter: answers in flight")
        Task { @MainActor in
            await work()
            task.end()
        }
    }
}

/// One `beginBackgroundTask`, ended once: when the work is done, or when the system's time runs out (`onExpire` is told
/// first, to cut the work short).
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String, onExpire: (@MainActor () -> Void)? = nil) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire?()
                self?.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
