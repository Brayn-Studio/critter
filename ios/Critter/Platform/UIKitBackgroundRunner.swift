import CritterClient
import UIKit

/// Runs work inside a UIKit background task, so the system lets it finish after the app has left the foreground.
@MainActor
final class UIKitBackgroundRunner: BackgroundRunner {
    func run(_ work: @escaping @MainActor () async -> Void) {
        let task = BackgroundTask()
        Task { @MainActor in
            await work()
            task.end()
        }
    }
}

/// One `beginBackgroundTask`, ended once: when the work is done, or when the system's time runs out.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Critter: answers in flight") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
