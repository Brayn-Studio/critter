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

/// One `beginBackgroundTask`, ended once: when the work is done, or when the system's time runs out. Then `onExpire`
/// runs first, synchronously, before the task is ended: the system suspends the app right after, so whatever must not
/// be lost (cutting the work short, a notification to post) happens in it, not after an `await`.
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid
    private var onExpire: (@MainActor () -> Void)?

    init(name: String, onExpire: (@MainActor () -> Void)? = nil) {
        self.onExpire = onExpire
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    /// The time ran out (the system's expiration handler; DEBUG builds can force it): `onExpire`, then the end.
    func expire() {
        guard id != .invalid else { return }
        let onExpire = onExpire
        self.onExpire = nil
        onExpire?()
        end()
    }

    func end() {
        guard id != .invalid else { return }
        onExpire = nil
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
