import Foundation

/// Where a push goes: which device, and which of its tokens.
public struct PushTarget: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The device token: notifications and withdrawals.
        case device
        /// The push-to-start token: a new Live Activity.
        case activityStart
        /// The running Live Activity's token: its updates and its end.
        case activity
    }

    public var deviceId: String
    public var kind: Kind
    /// Lowercase hex, as the phone registered it.
    public var token: String
    public var environment: PushEnvironment

    public init(deviceId: String, kind: Kind, token: String, environment: PushEnvironment) {
        self.deviceId = deviceId
        self.kind = kind
        self.token = token
        self.environment = environment
    }
}

/// One push to send, and where.
public struct OutgoingPush: Equatable, Sendable {
    public var target: PushTarget
    public var message: APNsMessage

    public init(target: PushTarget, message: APNsMessage) {
        self.target = target
        self.message = message
    }
}

/// What to do about a token APNs says is gone.
public enum GoneToken: Equatable, Sendable {
    /// The device token: forget the whole registration (`DeviceRegistry.dropPushToken`).
    case dropRegistration
    /// The Live Activity's token: forget it (`DeviceRegistry.setActivity(nil, nil)`).
    case clearActivity
    /// Nothing to change in the registry: the token is no longer the device's, or it was a push-to-start
    /// token (which is just not used again).
    case ignore
}

/// A change the fan-out needs kept in `devices.json`; the caller makes it (`takeRegistryEdits()`).
public enum RegistryEdit: Equatable, Sendable {
    public var deviceId: String {
        switch self {
        case .clearActivity(let id), .unconfirmedActivityStart(let id, _), .dropRegistration(let id): return id
        }
    }

    /// The Mac ended the device's Live Activity, or APNs said its token is gone: the token is forgotten
    /// (`DeviceRegistry.setActivity(nil, nil)`).
    case clearActivity(deviceId: String)
    /// When the Mac push-to-started an activity whose token has not come, or nil
    /// (`DeviceRegistry.setUnconfirmedActivityStart`).
    case unconfirmedActivityStart(deviceId: String, at: Int64?)
    /// APNs said the device token is gone: the whole registration goes (`DeviceRegistry.dropPushToken`).
    case dropRegistration(deviceId: String)
}

/// Turns each snapshot into the pushes every registered iPhone gets: its notifications (`PushTracker`) and its
/// Live Activity (`LiveActivityPlanner`), one of each per device. Pure: the caller passes the time, sends what
/// comes back, and sets a one-shot timer for `nextDeadline()`.
///
/// A device seen for the first time, or whose pushes now go elsewhere, starts over: its next snapshot only
/// records (`PushCoordinatorRules.startsOver`). `startOver()` does that for all of them.
///
/// Not thread-safe: one caller (the bridge queue).
public final class PushFanout {
    private struct Device {
        var registration: PushRegistration
        let tracker: PushTracker
        let planner: LiveActivityPlanner
        /// A push-to-start token APNs refused: no start with it until the phone registers another.
        var refusedStartToken: String?
        /// The record's `unconfirmedActivityStart` as last seen or asked for.
        var keptStart: Int64?
    }

    /// The app the setup pushes to (its bundle id), nil without a setup: only devices registered for it get
    /// anything.
    public var bundleId: String?

    /// The devices connected to the bridge right now (the caller sets it before each `snapshot` and `deadline`). A
    /// connected phone's app is in front and starts its own Live Activity, so the Mac does not push-to-start one for
    /// it -- two would start together. Its activity is updated and ended as any other.
    public var connectedDevices: Set<String> = []

    private var devices: [String: Device] = [:]
    /// What the last snapshot said, for the Live Activity work done at a deadline.
    private var lastSnapshot: SnapshotBody?
    /// The last Live Activity push's `aps.timestamp` (seconds) per device: each one is later than the last.
    private var lastTimestamp: [String: Int64] = [:]
    private var edits: [RegistryEdit] = []
    private let log: (String) -> Void

    /// `log` hears about pushes that could not be made; it is never given text from a session.
    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: - Devices

    /// Takes in the registry's list: new registrations are added, changed ones replace the old (starting over
    /// when their pushes now go elsewhere), and devices without one any more are forgotten. A token two
    /// records share (a file from before the registry kept them apart) goes to the later pairing only.
    public func sync(_ records: [DeviceRecord]) {
        var next: [String: Device] = [:]
        var taken: Set<String> = []
        for record in records.reversed() {
            guard let registration = record.push, !registration.isEmpty else { continue }
            let tokens = PushCoordinatorRules.tokens(of: registration)
            guard tokens.isDisjoint(with: taken) else { continue }
            taken.formUnion(tokens)
            if var device = devices[record.id], !PushCoordinatorRules.startsOver(from: device.registration, to: registration) {
                device.registration = registration
                device.tracker.prefs = PushCoordinatorRules.prefs(registration)
                if device.refusedStartToken != registration.activity?.startToken { device.refusedStartToken = nil }
                device.keptStart = record.unconfirmedActivityStart
                next[record.id] = device
            } else {
                // Seen for the first time (the Mac has just started): a start still waiting for its token holds the
                // next one off. Pushes that now go elsewhere start from nothing.
                let restored = devices[record.id] == nil ? record.unconfirmedActivityStart : nil
                next[record.id] = Device(
                    registration: registration, tracker: PushTracker(prefs: PushCoordinatorRules.prefs(registration)),
                    planner: LiveActivityPlanner(unconfirmedStartAt: restored), refusedStartToken: nil,
                    keptStart: record.unconfirmedActivityStart
                )
            }
        }
        devices = next
        lastTimestamp = lastTimestamp.filter { next[$0.key] != nil }
        noteStarts()
    }

    /// The changes to keep in `devices.json` since the last call: Live Activity tokens the Mac ended, and starts
    /// waiting for their token.
    public func takeRegistryEdits() -> [RegistryEdit] {
        defer { edits = [] }
        return edits
    }

    /// Every device's next snapshot only records: the Mac has just started, the setup just changed, or the
    /// bridge was just switched on.
    public func startOver() {
        for device in devices.values { device.tracker.reset() }
    }

    public func registration(_ deviceId: String) -> PushRegistration? {
        devices[deviceId]?.registration
    }

    /// How many devices have a registration, for any app.
    public var registeredDevices: Int { devices.count }

    /// How many devices pushes can go to now.
    public var reachableDevices: Int {
        devices.values.filter { PushCoordinatorRules.canPush($0.registration, bundleId: bundleId) }.count
    }

    // MARK: - Pushes

    /// Everything to send for a new snapshot: per device, withdrawals first, then new notifications, then the
    /// Live Activity.
    public func snapshot(_ body: SnapshotBody, now: Int64) -> [OutgoingPush] {
        lastSnapshot = body
        let sessions = Dictionary(body.sessions.map { ($0.id, $0) }) { first, _ in first }
        var pushes: [OutgoingPush] = []
        for (id, device) in reachable() {
            let registration = device.registration
            let toDevice = PushTarget(deviceId: id, kind: .device, token: registration.token, environment: registration.environment)
            let plan = device.tracker.next(body)
            for message in PushContent.withdraw(ids: plan.withdraw + plan.withdrawWaiting + plan.withdrawResults) {
                pushes.append(OutgoingPush(target: toDevice, message: message))
            }
            let key = registration.key
            for request in plan.post {
                append(to: &pushes, toDevice, "a request") {
                    try PushContent.request(request, session: sessions[request.sessionId], key: key)
                }
            }
            for session in plan.waitingNotices {
                append(to: &pushes, toDevice, "a waiting notice") { try PushContent.waitingNotice(session, key: key) }
            }
            for (session, state) in plan.results {
                append(to: &pushes, toDevice, "a result") { try PushContent.result(session, state: state, key: key) }
            }
            pushes += activity(id, device, body, now: now)
        }
        noteStarts()
        return pushes
    }

    /// The Live Activity work that was waiting for `now` (`nextDeadline()`), on the last snapshot.
    public func deadline(now: Int64) -> [OutgoingPush] {
        guard let body = lastSnapshot else { return [] }
        let pushes = reachable()
            .filter { _, device in device.planner.nextDeadline().map { $0 <= now } ?? false }
            .flatMap { id, device in activity(id, device, body, now: now) }
        noteStarts()
        return pushes
    }

    /// The earliest time a planner has something to do without a new snapshot; nil if none does.
    public func nextDeadline() -> Int64? {
        reachable().compactMap { $0.1.planner.nextDeadline() }.min()
    }

    /// A device is unpaired: its Live Activity is ended (if it has one the Mac knows how to reach), then the
    /// device is forgotten.
    public func remove(_ deviceId: String, now: Int64) -> [OutgoingPush] {
        defer {
            lastTimestamp[deviceId] = nil
            // Its record goes too: nothing to keep for it.
            edits.removeAll { $0.deviceId == deviceId }
        }
        guard let device = devices.removeValue(forKey: deviceId),
              PushCoordinatorRules.canPush(device.registration, bundleId: bundleId) else { return [] }
        return end(deviceId, device, now: now)
    }

    /// The bridge is switched off: every Live Activity is ended. The devices stay.
    public func endAll(now: Int64) -> [OutgoingPush] {
        let pushes = reachable().flatMap { id, device in end(id, device, now: now) }
        noteStarts()
        return pushes
    }

    /// The settings' "发送测试通知": one test notification for every device.
    public func test() -> [OutgoingPush] {
        var pushes: [OutgoingPush] = []
        for (id, device) in reachable() {
            let registration = device.registration
            let target = PushTarget(deviceId: id, kind: .device, token: registration.token, environment: registration.environment)
            append(to: &pushes, target, "a test") { try PushContent.test(key: registration.key) }
        }
        return pushes
    }

    /// What became of a push to `target` (`PushSender`'s outcome). A gone token is forgotten here at once and asked
    /// to be forgotten in the registry; a push-to-start that went nowhere lets go of the start waiting for its
    /// token. Either way the edits are there to keep straight away (`takeRegistryEdits()`), not with the next
    /// snapshot.
    public func delivered(_ outcome: APNsOutcome, to target: PushTarget) {
        let device = target.deviceId.prefix(8)
        let token = target.token.prefix(8)
        switch outcome {
        case .dropToken:
            switch tokenGone(target) {
            case .dropRegistration:
                log("push: device \(device)'s token \(token)… is gone; its registration is dropped")
                devices[target.deviceId] = nil
                lastTimestamp[target.deviceId] = nil
                edits.removeAll { $0.deviceId == target.deviceId }
                edits.append(.dropRegistration(deviceId: target.deviceId))
            case .clearActivity:
                log("push: device \(device)'s Live Activity token \(token)… is gone")
                devices[target.deviceId]?.registration.activity?.activityId = nil
                devices[target.deviceId]?.registration.activity?.activityToken = nil
                edits.append(.clearActivity(deviceId: target.deviceId))
            case .ignore:
                log("push: a \(target.kind.rawValue) token \(token)… of device \(device) is gone")
            }
        case .configError, .rejected:
            guard target.kind == .activityStart, let planner = devices[target.deviceId]?.planner,
                  devices[target.deviceId]?.registration.activity?.startToken == target.token else { return }
            planner.startNotDelivered()
            noteStarts()
        case .sent, .retry:
            break
        }
    }

    /// APNs said `target`'s token is gone. A device that has registered another token since keeps it.
    public func tokenGone(_ target: PushTarget) -> GoneToken {
        guard let device = devices[target.deviceId] else { return .ignore }
        let registration = device.registration
        switch target.kind {
        case .device:
            return registration.token == target.token ? .dropRegistration : .ignore
        case .activity:
            return registration.activity?.activityToken == target.token ? .clearActivity : .ignore
        case .activityStart:
            if registration.activity?.startToken == target.token {
                devices[target.deviceId]?.refusedStartToken = target.token
                // No activity came of that start.
                device.planner.startWasRefused()
                noteStarts()
            }
            return .ignore
        }
    }

    // MARK: -

    /// The devices pushes can go to, in a fixed order.
    private func reachable() -> [(String, Device)] {
        devices.filter { PushCoordinatorRules.canPush($0.value.registration, bundleId: bundleId) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private func activity(_ id: String, _ device: Device, _ body: SnapshotBody, now: Int64) -> [OutgoingPush] {
        let activity = device.registration.activity
        // Connected: the app starts its own (spec §8.5), so no push-to-start meanwhile.
        let startToken = connectedDevices.contains(id)
            ? nil : activity?.startToken.flatMap { $0.isEmpty || $0 == device.refusedStartToken ? nil : $0 }
        let actions = device.planner.next(
            content: device.planner.content(from: body), now: now, activityEnabled: activity?.enabled ?? false,
            hasStartToken: startToken != nil, activityToken: activity?.activityToken
        )
        return pushes(for: actions, id, device, startToken: startToken, now: now)
    }

    private func end(_ id: String, _ device: Device, now: Int64) -> [OutgoingPush] {
        let content = lastSnapshot.map { device.planner.content(from: $0) }
            ?? LiveActivityContent(counts: [], lead: nil, back: [], total: 0, fiveHour: nil, sevenDay: nil, updatedAt: now)
        let actions = device.planner.next(
            content: content, now: now, activityEnabled: false, hasStartToken: false,
            activityToken: device.registration.activity?.activityToken
        )
        return pushes(for: actions, id, device, startToken: nil, now: now)
    }

    private func pushes(
        for actions: [LiveActivityAction], _ id: String, _ device: Device, startToken: String?, now: Int64
    ) -> [OutgoingPush] {
        let environment = device.registration.environment
        var pushes: [OutgoingPush] = []
        for action in actions {
            let target: PushTarget
            switch action {
            case .start:
                guard let startToken else { continue }
                target = PushTarget(deviceId: id, kind: .activityStart, token: startToken, environment: environment)
            case .update, .end:
                guard let token = device.registration.activity?.activityToken else { continue }
                target = PushTarget(deviceId: id, kind: .activity, token: token, environment: environment)
            }
            // Later than the last one sent to this device, even within the same second.
            let timestamp = lastTimestamp[id].map { max(now / 1000, $0 + 1) } ?? now / 1000
            lastTimestamp[id] = timestamp
            append(to: &pushes, target, "a Live Activity push") {
                try PushContent.liveActivity(action, now: now, timestamp: timestamp)
            }
            if case .end = action {
                // Ended: its token is forgotten, here and in the registry.
                devices[id]?.registration.activity?.activityId = nil
                devices[id]?.registration.activity?.activityToken = nil
                edits.append(.clearActivity(deviceId: id))
            }
        }
        return pushes
    }

    /// Asks for the planners' starts that wait for a token to be kept, where they changed.
    private func noteStarts() {
        for (id, device) in devices where device.planner.unconfirmedStartAt != device.keptStart {
            devices[id]?.keptStart = device.planner.unconfirmedStartAt
            edits.append(.unconfirmedActivityStart(deviceId: id, at: device.planner.unconfirmedStartAt))
        }
    }

    private func append(to pushes: inout [OutgoingPush], _ target: PushTarget, _ what: String, _ make: () throws -> APNsMessage) {
        do {
            pushes.append(OutgoingPush(target: target, message: try make()))
        } catch {
            // The error is about sizes and sealing; it carries no text from the session.
            log("push: could not make \(what): \(error)")
        }
    }
}
