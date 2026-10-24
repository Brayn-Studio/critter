import ActivityKit
import CritterClient
import CritterKit
import Foundation
import os

/// The app's side of the Live Activity (spec §6.6, §8.5, §9):
/// - follows the tokens the system gives (`Activity.pushToStartTokenUpdates`, and each activity's `pushTokenUpdates` and
///   `activityStateUpdates`) and keeps them in `ActivityTokens`; every change goes to the registration
///   (`PushSetup.update`), which is sent to the Mac at once while connected. An activity that ends or is dismissed takes
///   its id and token out of it;
/// - starts, updates and ends its own activity as `LocalActivity.step` says (`sync`): it starts one in front while
///   connected, with sessions and none running; updates it in front while connected when the content changed; ends
///   every one at once when the switch is turned off. In the background it never touches it: the Mac pushes it. In
///   front it keeps one: any other one running (one the Mac push-started next to the app's own) is ended.
///
/// The activity's stale date is 15 minutes after each content, as the Mac sets it. Tokens are logged by their first 8
/// characters and length (category `activity`), like the device token.
///
/// One for the app's life (`shared`).
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// After this long without a new content the activity reads "可能不是最新的" (the Mac's `stale-date` too).
    static let staleAfter: TimeInterval = 15 * 60

    /// The tokens the system has given, for the registration.
    private(set) var tokens = ActivityTokens()
    /// The system lets the app have Live Activities (its own setting for the app). Off: as if the switch were off.
    private(set) var systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled
    /// Off for `-critterActivityDemo`, whose made-up activity the app's rules would end or overwrite.
    var followsSnapshots = true

    /// What each running activity shows as far as the app knows: what the app set, or what the Mac's pushes did.
    private var shown: [String: LiveActivityContent] = [:]
    private var watched: Set<String> = []
    private var started = false
    /// A start failed (the system refused it) while in front: not tried again until the app comes to the front again,
    /// so a refusal is not repeated on every snapshot.
    private var startRefused = false
    private var wasInFront = false

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "activity")

    private init() {}

    /// The registration's Live Activity part: the switch (and the system's setting) and the tokens there are.
    func registration(enabled: Bool) -> ActivityRegistration {
        tokens.registration(enabled: enabled && systemAllows)
    }

    /// Reads the tokens and activities there are already (synchronously, so the first registration has them), then
    /// follows the system's. Once per launch.
    func start() {
        guard !started else { return }
        started = true
        Self.log.notice("live activities \(self.systemAllows ? "allowed" : "not allowed", privacy: .public); \(Activity<CritterActivity>.activities.count) running")
        if let token = Activity<CritterActivity>.pushToStartToken { startTokenArrived(token) }
        for activity in Activity<CritterActivity>.activities { watch(activity) }
        Task {
            for await token in Activity<CritterActivity>.pushToStartTokenUpdates { startTokenArrived(token) }
        }
        Task {
            for await activity in Activity<CritterActivity>.activityUpdates { watch(activity) }
        }
        Task {
            for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard allowed != systemAllows else { continue }
                systemAllows = allowed
                Self.log.notice("live activities \(allowed ? "allowed" : "not allowed", privacy: .public) by the system")
                PushSetup.shared.update()
            }
        }
    }

    /// Does what `LocalActivity.step` says for the app as it is now (call it when the snapshot, the connection, the
    /// scene or the switch changes).
    func sync(snapshot: SnapshotBody?, inFront: Bool, live: Bool, enabled: Bool) {
        if inFront && !wasInFront { startRefused = false }
        wasInFront = inFront
        guard followsSnapshots else { return }
        let running = Activity<CritterActivity>.activities.filter {
            switch $0.activityState {
            case .active, .stale, .pending: true
            default: false
            }
        }
        // One activity: the one the registration names, else the latest. Another one (the Mac's push-to-start next to
        // the app's own start, both on connecting) is ended -- in front only, as its starts and updates are.
        let current = running.first { $0.id == tokens.activityId } ?? running.last
        for extra in running where inFront && extra.id != current?.id {
            let id = extra.id
            Self.log.notice("ending \(id, privacy: .public): another one is running")
            Task { await Self.end(id) }
        }
        let step = LocalActivity.step(
            enabled: enabled && systemAllows, inFront: inFront, live: live, snapshot: snapshot,
            shown: current.map { shown[$0.id] ?? $0.content.state }, now: Self.now()
        )
        switch step {
        case .none:
            break
        case .start(let content):
            guard !startRefused else { return }
            begin(content)
        case .update(let content):
            guard let id = current?.id else { return }
            shown[id] = content
            Self.log.notice("updating \(id, privacy: .public): \(Self.describe(content), privacy: .public)")
            let next = ActivityContent(state: content, staleDate: Self.staleDate())
            Task { await Self.update(id, to: next) }
        case .endAll:
            endAll()
        }
    }

    /// Ends every Live Activity of the app at once (the switch is off).
    func endAll() {
        for activity in Activity<CritterActivity>.activities {
            let id = activity.id
            Self.log.notice("ending \(id, privacy: .public): switched off")
            Task { await Self.end(id) }
        }
    }

    /// Ends activity `id` at once (found again here: an `Activity` does not cross actors).
    private nonisolated static func end(_ id: String) async {
        for activity in Activity<CritterActivity>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private nonisolated static func update(_ id: String, to content: ActivityContent<LiveActivityContent>) async {
        for activity in Activity<CritterActivity>.activities where activity.id == id {
            await activity.update(content)
        }
    }

    // MARK: -

    private func begin(_ content: LiveActivityContent) {
        do {
            let activity = try Activity.request(
                attributes: CritterActivity(), content: ActivityContent(state: content, staleDate: Self.staleDate()),
                pushType: .token
            )
            shown[activity.id] = content
            Self.log.notice("started \(activity.id, privacy: .public): \(Self.describe(content), privacy: .public)")
            watch(activity)
        } catch {
            startRefused = true
            Self.log.error("starting a Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Follows `activity`'s token, its state and what it shows, once.
    private func watch(_ activity: Activity<CritterActivity>) {
        let id = activity.id
        guard watched.insert(id).inserted else { return }
        Self.log.notice("watching \(id, privacy: .public) (\(String(describing: activity.activityState), privacy: .public))")
        if shown[id] == nil { shown[id] = activity.content.state }
        if let token = activity.pushToken { activityTokenArrived(token, id: id) }
        Task {
            for await token in activity.pushTokenUpdates { activityTokenArrived(token, id: id) }
        }
        Task {
            for await state in activity.activityStateUpdates { stateChanged(state, id: id) }
        }
        Task {
            for await content in activity.contentUpdates { shown[id] = content.state }
        }
    }

    private func startTokenArrived(_ token: Data) {
        guard tokens.startTokenArrived(token) else { return }
        Self.log.notice("push-to-start token \(Self.describe(token), privacy: .public)")
        PushSetup.shared.update()
    }

    private func activityTokenArrived(_ token: Data, id: String) {
        guard tokens.activityTokenArrived(token, activityId: id) else { return }
        Self.log.notice("activity \(id, privacy: .public) token \(Self.describe(token), privacy: .public)")
        PushSetup.shared.update()
    }

    private func stateChanged(_ state: ActivityState, id: String) {
        Self.log.notice("activity \(id, privacy: .public) is \(String(describing: state), privacy: .public)")
        switch state {
        case .ended, .dismissed:
            shown[id] = nil
            if tokens.activityEnded(id) { PushSetup.shared.update() }
        default:
            break
        }
    }

    private static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func staleDate() -> Date {
        Date(timeIntervalSinceNow: staleAfter)
    }

    /// A token as the log has it: its first 8 hex characters and its length.
    private static func describe(_ token: Data) -> String {
        "\(ActivityTokens.hex(token).prefix(8))… (\(token.count) bytes)"
    }

    private static func describe(_ content: LiveActivityContent) -> String {
        let counts = content.counts.map { "\($0.state.rawValue) \($0.count)" }.joined(separator: ", ")
        return "\(content.total) sessions [\(counts)], lead \(content.lead.map { "\($0.skin) \($0.state.rawValue)" } ?? "none")"
    }
}
