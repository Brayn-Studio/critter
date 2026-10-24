#if DEBUG
import ActivityKit
import CritterKit
import Foundation
import os
import UIKit

/// `-critterActivityScript <step>@<seconds>[,…]` (see `DebugLaunch`): things the system and the Mac do to the app's
/// Live Activities, at those times after launch, for `LiveActivityManager`'s rules to answer (category `activity`):
/// - `dup`: another activity comes up next to the app's own, as the Mac's push-to-start would bring one (started here
///   with a push token, waiting content);
/// - `endNamed`: the activity the registration names ends, as if the user dismissed it;
/// - `hold`: the app's own rules stand aside (`followsSnapshots` off: no start, update or ending of extra ones), as
///   while it is in the background -- where an activity cannot be requested, so `dup` cannot make one there;
/// - `follow`: the rules are back; the next `sync` (the scene coming to the front, a snapshot) applies them.
///
/// The app keeps running in the background meanwhile (a background task), so a step can happen while another app is
/// in front (`xcrun simctl launch <device> com.apple.Preferences`).
enum ActivityScript {
    enum Action: String {
        case dup, endNamed, hold, follow
    }

    struct Step: Equatable {
        var action: Action
        var at: Double
    }

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "activity")

    static func steps(_ argument: String) -> [Step] {
        argument.split(separator: ",").compactMap { step in
            let parts = step.split(separator: "@")
            guard parts.count == 2, let action = Action(rawValue: String(parts[0])), let at = Double(parts[1]) else {
                return nil
            }
            return Step(action: action, at: at)
        }
    }

    @MainActor
    static func run(_ steps: [Step]) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "activity script")
        defer { UIApplication.shared.endBackgroundTask(task) }
        var elapsed = 0.0
        for step in steps.sorted(by: { $0.at < $1.at }) {
            try? await Task.sleep(for: .seconds(max(0, step.at - elapsed)))
            elapsed = step.at
            switch step.action {
            case .dup:
                let content = ActivityDemo.content(.waiting, now: Date())
                do {
                    let activity = try Activity.request(
                        attributes: CritterActivity(),
                        content: .init(state: content, staleDate: Date(timeIntervalSinceNow: 15 * 60)), pushType: .token
                    )
                    say("dup at \(step.at) s: started \(activity.id) next to the app's own")
                } catch {
                    say("dup at \(step.at) s: starting failed: \(error)")
                }
            case .hold:
                LiveActivityManager.shared.followsSnapshots = false
                say("hold at \(step.at) s: the app's rules stand aside")
            case .follow:
                LiveActivityManager.shared.followsSnapshots = true
                say("follow at \(step.at) s: the app's rules are back")
            case .endNamed:
                let named = LiveActivityManager.shared.tokens.activityId
                say("endNamed at \(step.at) s: ending \(named ?? "none")")
                for activity in Activity<CritterActivity>.activities where activity.id == named {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        // A moment for what the steps set off.
        try? await Task.sleep(for: .seconds(4))
    }

    private static func say(_ line: String) {
        log.notice("script: \(line, privacy: .public)")
    }
}
#endif
