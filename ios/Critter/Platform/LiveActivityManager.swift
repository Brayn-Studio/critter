import ActivityKit
import CritterClient
import CritterKit
import Foundation
import Observation
import os

/// The app's side of the Live Activity (spec §6.6, §8.5, §9):
/// - follows the tokens the system gives (`Activity.pushToStartTokenUpdates`, and each activity's `pushTokenUpdates` and
///   `activityStateUpdates`) and keeps them in `ActivityTokens`; every change goes to the registration
///   (`PushSetup.update`), which is sent to the Mac at once while connected. An activity that ends or is dismissed takes
///   its id and token out of it, and another one still running is registered in its place (from its `pushToken`); a
///   token that comes for an activity no longer running is ignored. The tasks that follow an activity are cancelled
///   when it ends;
/// - starts, updates and ends its own activity as `LocalActivity.step` says (`sync`): it starts one in front while
///   connected, with sessions and none running; updates it in front while connected when the content changed; ends
///   every one at once when the switch is turned off or the phone is unpaired (wherever the app is: the app calls
///   `sync` when the pairing changes). In the background it never touches it otherwise: the Mac pushes it.
/// - ends every one too when a Mac that may still push here was left untold (`PushSetup.macLeftUntold`): that Mac
///   holds their tokens.
/// - keeps one (`LocalActivity.keeper`: the registered one, else the app's own, else the newest). In front -- as of the
///   last `sync` -- it ends any other one, at each `sync` and as soon as another one comes up or a token comes.
///
/// The activity's stale date is 15 minutes after each content, as the Mac sets it. Tokens are logged by their first 8
/// characters and length (category `activity`), like the device token.
///
/// One for the app's life (`shared`). Observable for the settings' line about the system's own switch (`systemAllows`).
@MainActor @Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// After this long without a new content the activity reads "可能不是最新的" (the Mac's `stale-date` too).
    static let staleAfter: TimeInterval = 15 * 60

    /// The tokens the system has given, for the registration.
    @ObservationIgnored private(set) var tokens = ActivityTokens()
    /// The system lets the app have Live Activities (its own setting for the app). Off: as if the switch were off.
    private(set) var systemAllows = LiveActivityManager.systemAllowsAtLaunch
    /// Off for `-critterActivityDemo`, whose made-up activity the app's rules would end or overwrite.
    @ObservationIgnored var followsSnapshots = true

    /// What each running activity shows as far as the app knows: what the app set, or what the Mac's pushes did.
    @ObservationIgnored private var shown: [String: LiveActivityContent] = [:]
    /// The tasks following each activity watched (its token, state and content), cancelled when it ends.
    @ObservationIgnored private var watching: [String: [Task<Void, Never>]] = [:]
    /// When the app first saw each activity (for `LocalActivity.keeper`).
    @ObservationIgnored private var seenAt: [String: Int64] = [:]
    /// The activity the app started itself (`begin`), while it runs.
    @ObservationIgnored private var ownId: String?
    @ObservationIgnored private var started = false
    /// A start failed (the system refused it) while in front: not tried again until the app comes to the front again,
    /// so a refusal is not repeated on every snapshot.
    @ObservationIgnored private var startRefused = false
    @ObservationIgnored private var wasInFront = false

    /// The system's setting as the app starts (`-critterSystemBlocksActivities`, DEBUG: off).
    private static var systemAllowsAtLaunch: Bool {
        #if DEBUG
        if DebugLaunch.current.systemBlocksActivities { return false }
        #endif
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

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
        // All seen at once: `keeper` tells them apart by id.
        let launch = Self.now()
        for activity in Activity<CritterActivity>.activities { watch(activity, seenAt: launch) }
        Task {
            for await token in Activity<CritterActivity>.pushToStartTokenUpdates { startTokenArrived(token) }
        }
        Task {
            for await activity in Activity<CritterActivity>.activityUpdates { watch(activity, seenAt: Self.now()) }
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
    func sync(snapshot: SnapshotBody?, inFront: Bool, live: Bool, enabled: Bool, paired: Bool) {
        if inFront && !wasInFront { startRefused = false }
        wasInFront = inFront
        guard followsSnapshots else { return }
        let current = keepOne(inFront: inFront)
        let step = LocalActivity.step(
            enabled: enabled && systemAllows, paired: paired, inFront: inFront, live: live, snapshot: snapshot,
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
            endAll(because: "switched off or unpaired")
        }
    }

    /// The activity kept (`LocalActivity.keeper`) among those running; in front, every other one is ended (the Mac's
    /// push-to-start next to the app's own start), and its token is not taken from then on.
    @discardableResult
    private func keepOne(inFront: Bool) -> Activity<CritterActivity>? {
        let running = Self.running()
        let kept = LocalActivity.keeper(
            running: running.map { RunningActivity(id: $0.id, seenAt: seenAt[$0.id] ?? 0) }, named: tokens.activityId,
            own: ownId
        )
        if inFront {
            for extra in running where extra.id != kept {
                let id = extra.id
                guard !tokens.hasEnded(id) else { continue }
                Self.log.notice("ending \(id, privacy: .public): \(kept ?? "none", privacy: .public) is the one kept")
                if tokens.activityEnded(id) { PushSetup.shared.update() }
                Task { await Self.end(id) }
            }
        }
        return running.first { $0.id == kept }
    }

    /// A new activity came up or a token came, after a `sync` in front: keep one at once, not at the next snapshot.
    private func keepOneIfInFront() {
        guard followsSnapshots, wasInFront else { return }
        keepOne(inFront: true)
    }

    /// The app's activities that are running (or about to).
    private static func running() -> [Activity<CritterActivity>] {
        Activity<CritterActivity>.activities.filter { isRunning($0.activityState) }
    }

    private static func isRunning(_ state: ActivityState) -> Bool {
        switch state {
        case .active, .stale, .pending: true
        default: false
        }
    }

    /// Ends every Live Activity of the app at once (the switch is off, the phone unpaired, or a Mac left untold holds
    /// their tokens): their tokens are out of the registration from now on, not once the system says they ended.
    func endAll(because reason: String) {
        var changed = false
        for activity in Activity<CritterActivity>.activities {
            let id = activity.id
            Self.log.notice("ending \(id, privacy: .public): \(reason, privacy: .public)")
            if tokens.activityEnded(id) { changed = true }
            Task { await Self.end(id) }
        }
        if changed { PushSetup.shared.update() }
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
            ownId = activity.id
            Self.log.notice("started \(activity.id, privacy: .public): \(Self.describe(content), privacy: .public)")
            watch(activity, seenAt: Self.now())
        } catch {
            startRefused = true
            Self.log.error("starting a Live Activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Follows `activity`'s token, its state and what it shows, once, while it runs. One that has ended already (at
    /// launch, the ones not yet dismissed) is only marked so: its token is never taken.
    private func watch(_ activity: Activity<CritterActivity>, seenAt: Int64) {
        let id = activity.id
        guard watching[id] == nil, !tokens.hasEnded(id) else { return }
        guard Self.isRunning(activity.activityState) else {
            Self.log.notice("\(id, privacy: .public) has ended (\(String(describing: activity.activityState), privacy: .public))")
            if tokens.activityEnded(id) { PushSetup.shared.update() }
            return
        }
        Self.log.notice("watching \(id, privacy: .public) (\(String(describing: activity.activityState), privacy: .public))")
        self.seenAt[id] = seenAt
        if shown[id] == nil { shown[id] = activity.content.state }
        if let token = activity.pushToken { activityTokenArrived(token, id: id) }
        watching[id] = [
            Task {
                for await token in activity.pushTokenUpdates { activityTokenArrived(token, id: id) }
            },
            Task {
                for await state in activity.activityStateUpdates { stateChanged(state, id: id) }
            },
            Task {
                for await content in activity.contentUpdates { shown[id] = content.state }
            },
        ]
        keepOneIfInFront()
    }

    private func startTokenArrived(_ token: Data) {
        guard tokens.startTokenArrived(token) else { return }
        Self.log.notice("push-to-start token \(Self.describe(token), privacy: .public)")
        PushSetup.shared.update()
    }

    /// A token for activity `id`: taken only while it runs (the system may hand one over after it ended).
    private func activityTokenArrived(_ token: Data, id: String) {
        let state = Activity<CritterActivity>.activities.first { $0.id == id }?.activityState
        guard let state, Self.isRunning(state), !tokens.hasEnded(id) else {
            Self.log.notice("activity \(id, privacy: .public) token \(Self.describe(token), privacy: .public) ignored: it is not running")
            return
        }
        if tokens.activityTokenArrived(token, activityId: id) {
            Self.log.notice("activity \(id, privacy: .public) token \(Self.describe(token), privacy: .public)")
            PushSetup.shared.update()
        } else if tokens.activityId != id {
            Self.log.notice("activity \(id, privacy: .public) token \(Self.describe(token), privacy: .public) kept aside: \(self.tokens.activityId ?? "none", privacy: .public) is registered")
        }
        keepOneIfInFront()
    }

    private func stateChanged(_ state: ActivityState, id: String) {
        Self.log.notice("activity \(id, privacy: .public) is \(String(describing: state), privacy: .public)")
        switch state {
        case .ended, .dismissed:
            stopWatching(id)
            var changed = tokens.activityEnded(id)
            // The registered one ended: another one still running is registered in its place, from its token.
            if changed, tokens.activityId == nil { changed = registerRunning() || changed }
            if changed {
                Self.log.notice("registered activity now \(self.tokens.activityId ?? "none", privacy: .public)")
                PushSetup.shared.update()
            }
        default:
            break
        }
    }

    /// No activity is registered: the one kept among those running is, if the system has its token.
    private func registerRunning() -> Bool {
        let running = Self.running().filter { !tokens.hasEnded($0.id) }
        let kept = LocalActivity.keeper(
            running: running.map { RunningActivity(id: $0.id, seenAt: seenAt[$0.id] ?? 0) }, named: nil, own: ownId
        )
        guard let activity = running.first(where: { $0.id == kept }), let token = activity.pushToken else { return false }
        return tokens.activityTokenArrived(token, activityId: activity.id)
    }

    /// Activity `id` ended: what followed it stops, and what was known of it goes.
    private func stopWatching(_ id: String) {
        guard let tasks = watching.removeValue(forKey: id) else { return }
        for task in tasks { task.cancel() }
        shown[id] = nil
        seenAt[id] = nil
        if ownId == id { ownId = nil }
        Self.log.notice("stopped watching \(id, privacy: .public) (\(self.watching.count) still watched)")
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
