import CritterCore
import Foundation

/// Pushes to the iPhones that registered (spec 6.3-6.6): `BridgeController` hands it every snapshot it assembles
/// while push is active, and the device list whenever it changes. `PushFanout` decides what each device gets;
/// `PushSender` sends it. A token APNs says is gone is dropped from the registry.
///
/// Push is active only when the bridge is switched on, the APNs setup works and at least one iPhone registered
/// (`PushCoordinatorRules.isActive`). Otherwise it does nothing at all: the setup is not even read until a device
/// has registered, no snapshot is assembled for it, no timer runs and nothing is sent.
///
/// Everything runs on the bridge queue; the main thread only reads `status()`.
final class PushCoordinator: @unchecked Sendable {
    /// What the settings and `app.json` show.
    struct Status: Equatable, Sendable {
        /// `isActive`: `app.json`'s `pushReachable`.
        var active = false
        /// Devices with a push registration, for any app.
        var registeredDevices = 0
        var lastSentAt: Date?
        /// APNs refused the setup (nothing is sent until it changes).
        var blockedReason: String?
        /// Why the last push that failed failed, until one goes through.
        var lastFailure: String?
    }

    /// Fired timers come a little after the deadline, never before.
    private static let timerSlack: TimeInterval = 0.05

    private let queue: DispatchQueue
    private let registry: DeviceRegistry
    private let loadSetup: () -> APNsSetup
    private let log: (String) -> Void
    private let fanout: PushFanout
    /// Called after the registry was written (a dead token dropped, an activity's token forgotten, a start kept),
    /// to refresh the device list. Not after a write that failed: that would ask for the same write again.
    var onRegistryChanged: (() -> Void)?
    /// The ids of the devices connected to the bridge now, read on the bridge queue before each snapshot or deadline
    /// is handed to the fan-out: no push-to-start for a connected phone, whose app starts its own Live Activity.
    var connectedDevices: () -> Set<String> = { [] }

    // Bridge queue only.
    private var bridgeOn = false
    /// Read when first needed (a device registered while the bridge is on), and again after `configChanged()`.
    private var setup: APNsSetup?
    private var signer: APNsToken?
    /// Made for the first push.
    private var sender: PushSender?
    /// Bumped by `configChanged()`: a reply to a push made with the old setup does not block the new one.
    private var setupGeneration = 0
    /// The one-shot Live Activity timer: when it is due, and a generation that cancels it.
    private var timerDeadline: Int64?
    private var timerGeneration = 0
    /// The deadline the timer last fired for: if the planners still give it, it is not set again.
    private var firedDeadline: Int64?

    private let lock = NSLock()
    private var published = Status()

    /// - Parameter loadSetup: reads the settings' APNs setup (a file read); called only when a device has registered.
    init(queue: DispatchQueue, registry: DeviceRegistry, loadSetup: @escaping () -> APNsSetup, log: @escaping (String) -> Void) {
        self.queue = queue
        self.registry = registry
        self.loadSetup = loadSetup
        self.log = log
        fanout = PushFanout(log: log)
    }

    /// From any thread.
    func status() -> Status {
        lock.withLock { published }
    }

    // MARK: - Bridge queue

    var isActive: Bool {
        // No registration, no setup read.
        guard bridgeOn, fanout.registeredDevices > 0 else { return false }
        let ready = setupIsReady()
        return PushCoordinatorRules.isActive(
            bridgeOn: bridgeOn, configReady: ready, blocked: sender?.blockedReason != nil, reachableDevices: fanout.reachableDevices
        )
    }

    /// The bridge was switched on or off. Switched on, every device starts over; switched off, every Live
    /// Activity is ended (best effort) and the timer goes.
    func bridgeSwitched(on: Bool) {
        guard on != bridgeOn else { return }
        if on {
            bridgeOn = true
            // Read again when next needed: the files may have changed while it was off.
            setup = nil
            signer = nil
            fanout.bundleId = nil
            fanout.startOver()
        } else {
            if isActive {
                send(fanout.endAll(now: Self.nowMs()))
                keepRegistryEdits()
            }
            bridgeOn = false
            cancelTimer()
        }
        publish()
    }

    /// The registry's list changed (pairing, a registration, a revoke, `lastSeen`).
    func devicesChanged(_ records: [DeviceRecord]) {
        fanout.sync(records)
        keepRegistryEdits()
        publish()
        reschedule()
    }

    /// The settings' APNs setup changed: it is read again, APNs gets another try after a 403, and every
    /// device starts over.
    func configChanged() {
        setup = nil
        signer = nil
        fanout.bundleId = nil
        setupGeneration += 1
        sender?.configChanged()
        fanout.startOver()
        firedDeadline = nil
        publish()
        reschedule()
    }

    /// A snapshot `BridgeController` assembled while push is active.
    func snapshotChanged(_ body: SnapshotBody) {
        guard isActive else { return }
        fanout.connectedDevices = connectedDevices()
        send(fanout.snapshot(body, now: Self.nowMs()))
        keepRegistryEdits()
        reschedule()
    }

    /// The device is being unpaired: its Live Activity is ended (best effort) while its registration is still
    /// known, before the registry forgets it.
    func deviceRevoked(_ deviceId: String) {
        // Asked before the device goes: it may be the only one.
        let active = isActive
        let pushes = fanout.remove(deviceId, now: Self.nowMs())
        if active { send(pushes) }
        keepRegistryEdits()
        publish()
        reschedule()
    }

    /// "重置配对": every Live Activity is ended (best effort) before the registry forgets the devices.
    func allDevicesRevoked() {
        if isActive { send(fanout.endAll(now: Self.nowMs())) }
        fanout.sync([])
        // Every record goes: nothing of theirs to keep.
        _ = fanout.takeRegistryEdits()
        publish()
        reschedule()
    }

    /// Whether the Mac can push to a phone with this registration now, for the `result` of its `push` frame (spec
    /// 8.8): the setup works (it is read if it has not been yet: a device has just registered), APNs has not refused
    /// it, and the registration is for the app the setup names.
    func canPush(to registration: PushRegistration) -> Bool {
        guard bridgeOn, setupIsReady() else { return false }
        return PushCoordinatorRules.pushReady(registration, bundleId: fanout.bundleId, blocked: sender?.blockedReason != nil)
    }

    /// The settings' "发送测试通知": a test notification for every registered device. False if there is
    /// nothing to send it with or to.
    @discardableResult
    func sendTest() -> Bool {
        guard bridgeOn, setupIsReady() else { return false }
        let pushes = fanout.test()
        send(pushes)
        return !pushes.isEmpty
    }

    // MARK: -

    /// Reads the setup if it has not been yet. True when it can sign pushes.
    private func setupIsReady() -> Bool {
        if setup == nil {
            var loaded = loadSetup()
            signer = nil
            fanout.bundleId = nil
            if case .ready(let config, let pem) = loaded {
                if let token = try? APNsToken(config: config, pem: pem) {
                    signer = token
                    fanout.bundleId = config.bundleId
                } else {
                    loaded = .problem(APNsSetup.unreadableKey)
                }
            }
            setup = loaded
            switch loaded {
            case .notConfigured: log("push: not set up")
            case .ready(let config, _): log("push: set up for \(config.bundleId)")
            case .problem(let reason): log("push: setup unusable: \(reason)")
            }
        }
        return signer != nil
    }

    private func send(_ pushes: [OutgoingPush]) {
        guard !pushes.isEmpty, case .ready(let config, _)? = setup, let signer else { return }
        let sender = sender ?? makeSender()
        let generation = setupGeneration
        for push in pushes {
            sender.send(push, config: config, signer: signer) { [weak self] outcome in
                self?.delivered(outcome, push: push, generation: generation)
            }
        }
    }

    /// Writes what the fan-out needs kept to `devices.json` -- Live Activity tokens it ended, starts waiting for
    /// their token, tokens APNs says are gone -- and reads the devices again if that changed them.
    private func keepRegistryEdits() {
        PushRegistryEdits.keep(fanout.takeRegistryEdits(), in: registry, log: log) { onRegistryChanged?() }
    }

    private func makeSender() -> PushSender {
        let made = PushSender(queue: queue, log: log)
        sender = made
        return made
    }

    private func delivered(_ outcome: APNsOutcome, push: OutgoingPush, generation: Int) {
        // A gone token, or a push-to-start that went nowhere (which then holds no start off).
        fanout.delivered(outcome, to: push.target)
        if case .configError = outcome, generation != setupGeneration {
            // APNs's answer to a push made with the setup before: the new one is not blocked by it.
            sender?.configChanged()
        }
        // Into devices.json now, not with the next snapshot: Critter may quit before one comes.
        keepRegistryEdits()
        publish()
        reschedule()
    }

    private func publish() {
        let status = Status(
            active: isActive, registeredDevices: fanout.registeredDevices, lastSentAt: sender?.lastSentAt,
            blockedReason: sender?.blockedReason, lastFailure: sender?.lastFailure
        )
        lock.withLock { published = status }
    }

    // MARK: - The Live Activity timer

    /// Sets the one-shot timer for the planners' next deadline -- there is one only while an activity exists or a
    /// throttled update waits -- replacing any earlier one.
    private func reschedule() {
        let next = isActive ? fanout.nextDeadline() : nil
        guard next != timerDeadline else { return }
        cancelTimer()
        // A deadline that already fired and is still given would fire again at once, and again.
        guard let next, next != firedDeadline else { return }
        timerDeadline = next
        let generation = timerGeneration
        let delay = max(0, Double(next - Self.nowMs()) / 1000) + Self.timerSlack
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == timerGeneration else { return }
            timerDeadline = nil
            firedDeadline = next
            // The timer's clock and the wall clock can differ by a little: the deadline counts as reached.
            if isActive {
                fanout.connectedDevices = connectedDevices()
                send(fanout.deadline(now: max(Self.nowMs(), next)))
                keepRegistryEdits()
            }
            reschedule()
        }
    }

    private func cancelTimer() {
        timerGeneration += 1
        timerDeadline = nil
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
