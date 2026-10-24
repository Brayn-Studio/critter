import CritterClient
import CritterKit
import Foundation
import os
import Testing

private let pin = String(repeating: "ab", count: 32)
private let home = Endpoint(host: "192.168.1.20", port: 47823)
private let moved = Endpoint(host: "192.168.1.77", port: 47823)
private let stored = StoredPairing(endpoint: home, fingerprint: pin, macName: "Mac", deviceId: "d1")
private let connected = ConnState.connected(macName: "Mac")
private let offline = ConnState.offline(retryIn: .seconds(2), since: Date(timeIntervalSince1970: 0))

private func body(_ ids: String...) -> SnapshotBody {
    fixtureBody(ids.map { fixtureSession($0) })
}

/// Waits (at most 2 s) until `condition` holds; it looks at main-actor state.
private func becomes(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    await eventually { await condition() }
}

private func snapshot(_ body: SnapshotBody, seq: Int = 1) -> BridgeEvent {
    .snapshot(seq: seq, sentAt: 1_760_000_000_000, body: body)
}

// MARK: - Fakes

/// What the fakes did, in order, across all of them.
private final class Journal: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// Holds whoever waits on it until it is opened.
private final class Gate: Sendable {
    private struct State {
        var isOpen: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(open: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(isOpen: open))
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { s in
                if !s.isOpen { s.waiters.append(continuation) }
                return s.isOpen
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class FakeClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    /// How far each reading moves the clock on.
    private let step: TimeInterval

    init(_ start: Date, step: TimeInterval = 0) {
        current = OSAllocatedUnfairLock(initialState: start)
        self.step = step
    }

    var now: Date {
        current.withLock { now in
            defer { now += step }
            return now
        }
    }

    func set(_ date: Date) { current.withLock { $0 = date } }
}

private final class FakeStorage: PairingStorage {
    struct Saved: Equatable, Sendable {
        var pairing: StoredPairing
        var token: String
    }

    private struct State {
        var pairing: StoredPairing?
        var token: String?
        var snapshot: CachedSnapshot?
        var saves: [Saved] = []
        var endpointUpdates: [Endpoint] = []
        var clears = 0
        var snapshotSaves: [CachedSnapshot] = []
        var failSaves = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let journal: Journal

    init(journal: Journal, pairing: StoredPairing?, snapshot: CachedSnapshot?) {
        self.journal = journal
        state = OSAllocatedUnfairLock(initialState: State(pairing: pairing, token: pairing == nil ? nil : "t1", snapshot: snapshot))
    }

    var saves: [Saved] { state.withLock { $0.saves } }
    var endpointUpdates: [Endpoint] { state.withLock { $0.endpointUpdates } }
    var clears: Int { state.withLock { $0.clears } }
    var snapshotSaves: [CachedSnapshot] { state.withLock { $0.snapshotSaves } }
    var storedPairing: StoredPairing? { state.withLock { $0.pairing } }
    /// `save` keeps nothing from now on, as when the keychain refuses the token.
    func failSaves() { state.withLock { $0.failSaves = true } }

    func load() -> (StoredPairing, Credentials)? {
        state.withLock { s in
            guard let pairing = s.pairing, let token = s.token else { return nil }
            return (pairing, Credentials(deviceId: pairing.deviceId, token: token))
        }
    }

    func save(_ pairing: StoredPairing, token: String) -> Bool {
        journal.add("save")
        return state.withLock { s in
            guard !s.failSaves else { return false }
            s.pairing = pairing
            s.token = token
            s.saves.append(Saved(pairing: pairing, token: token))
            return true
        }
    }

    func updateEndpoint(_ endpoint: Endpoint) {
        state.withLock { s in
            s.pairing?.endpoint = endpoint
            s.endpointUpdates.append(endpoint)
        }
    }

    func clear() {
        journal.add("clear")
        state.withLock { s in
            s.pairing = nil
            s.token = nil
            s.snapshot = nil
            s.clears += 1
        }
    }

    func loadSnapshot() -> CachedSnapshot? {
        state.withLock { $0.snapshot }
    }

    func saveSnapshot(_ snapshot: CachedSnapshot) {
        state.withLock { s in
            s.snapshot = snapshot
            s.snapshotSaves.append(snapshot)
        }
    }
}

private final class FakeLink: BridgeLink {
    let index: Int
    private let journal: Journal
    private let onEvent: @Sendable (BridgeEvent) -> Void

    private struct State {
        var starts = 0
        var stops = 0
        var reconnects = 0
        var requests: [BridgeCommand] = []
        var pingIntervals: [TimeInterval] = []
        var skins: [String: JSONValue] = [:]
        var skinRequests: [String] = []
        var holdRequests = false
        var reply = CommandResult(ok: true, reason: nil, message: nil)
        var pushes: [PushRegistration] = []
        var pushReply = PushRegistrationReply.stored(nil)
        var holdPushes = false
        var holdStops = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Requests held by `holdRequests()` wait here.
    let release = Gate(open: false)
    /// Push registrations held by `holdPushes()` wait here.
    let releasePushes = Gate(open: false)
    /// Stops held by `holdStops()` wait here.
    let releaseStops = Gate(open: false)

    init(index: Int, journal: Journal, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        self.index = index
        self.journal = journal
        self.onEvent = onEvent
    }

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var reconnects: Int { state.withLock { $0.reconnects } }
    var requests: [BridgeCommand] { state.withLock { $0.requests } }
    var pingIntervals: [TimeInterval] { state.withLock { $0.pingIntervals } }
    var skinRequests: [String] { state.withLock { $0.skinRequests } }
    var pushes: [PushRegistration] { state.withLock { $0.pushes } }

    /// The link reports `event`, as the client does.
    func emit(_ event: BridgeEvent) { onEvent(event) }

    /// From now on a request does not return until `release` is opened.
    func holdRequests() { state.withLock { $0.holdRequests = true } }

    func reply(with result: CommandResult) { state.withLock { $0.reply = result } }

    func replyToPush(with reply: PushRegistrationReply) { state.withLock { $0.pushReply = reply } }

    /// From now on a push registration does not return until `releasePushes` is opened.
    func holdPushes() { state.withLock { $0.holdPushes = true } }

    /// From now on `stop` does not return until `releaseStops` is opened.
    func holdStops() { state.withLock { $0.holdStops = true } }

    /// From now on the Mac has a skin of this name, with this manifest.
    func serve(_ manifest: JSONValue, named name: String) { state.withLock { $0.skins[name] = manifest } }

    func start() async {
        journal.add("start \(index)")
        state.withLock { $0.starts += 1 }
    }

    func stop() async {
        journal.add("stop \(index)")
        let hold = state.withLock { s in
            s.stops += 1
            return s.holdStops
        }
        if hold { await releaseStops.wait() }
    }

    func reconnectNow() async {
        journal.add("reconnectNow \(index)")
        state.withLock { $0.reconnects += 1 }
    }

    func setPingInterval(_ seconds: TimeInterval) async {
        journal.add("ping \(index) \(seconds)")
        state.withLock { $0.pingIntervals.append(seconds) }
    }

    func requestSkin(_ name: String) async -> JSONValue? {
        state.withLock { s in
            s.skinRequests.append(name)
            return s.skins[name]
        }
    }

    func registerPush(_ registration: PushRegistration) async -> PushRegistrationReply {
        journal.add("push \(index) \(registration.token.isEmpty ? "-" : registration.token)")
        let hold = state.withLock { s in
            s.pushes.append(registration)
            return s.holdPushes
        }
        if hold { await releasePushes.wait() }
        return state.withLock { $0.pushReply }
    }

    func request(_ command: BridgeCommand) async -> CommandResult {
        let hold = state.withLock { s in
            s.requests.append(command)
            return s.holdRequests
        }
        if hold { await release.wait() }
        return state.withLock { $0.reply }
    }
}

private final class FakePairer: PairingLink {
    private let journal: Journal
    private let outcome: OSAllocatedUnfairLock<PairResult>
    /// `pair` does not reach the Mac (and does not report waiting for approval) until this is open.
    let reachMac: Gate
    /// The Mac does not answer until this is open.
    let approval: Gate
    /// Whether `pair` gets as far as the Mac (the connection opens). Not, it fails `unreachable` at once.
    private let connects = OSAllocatedUnfairLock(initialState: true)

    init(journal: Journal, outcome: PairResult, slow: Bool) {
        self.journal = journal
        self.outcome = OSAllocatedUnfairLock(initialState: outcome)
        reachMac = Gate(open: !slow)
        approval = Gate(open: !slow)
    }

    func answer(with result: PairResult) { outcome.withLock { $0 = result } }

    /// The Mac cannot be reached: the connection never opens.
    func cannotConnect() { connects.withLock { $0 = false } }

    func pair(
        _ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void
    ) async -> PairResult {
        journal.add("pair \(target.code) \(deviceName)")
        await reachMac.wait()
        guard connects.withLock({ $0 }) else { return .failed(.unreachable) }
        onAwaitingApproval()
        await approval.wait()
        return outcome.withLock { $0 }
    }
}

/// The local network as a pairing waits for it (`LocalNetworkGate`): the wait goes on until the test says what iOS
/// answers -- refused (`refuse()`: the first-run prompt is up, or 本地网络 is off), then allowed (`allow()`) -- or the
/// task is cancelled. Allowed once, every later wait goes on at once.
private final class FakeLocalNetworkGate: LocalNetworkGate {
    private struct State {
        var allowed = false
        var cancelled = false
        var waiter: CheckedContinuation<Bool, Never>?
        /// The last wait's, kept once it has ended (for a late refusal).
        var onRefused: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A pairing waits here.
    var waiting: Bool { state.withLock { $0.waiter != nil } }

    /// iOS refuses the local network: the last wait hears it, also one that has ended.
    func refuse() {
        state.withLock { $0.onRefused }?()
    }

    func allow() {
        let waiter = state.withLock { s in
            s.allowed = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(returning: true)
    }

    func waitUntilUsable(onRefused: @escaping @Sendable () -> Void) async -> Bool {
        state.withLock { s in
            s.onRefused = onRefused
            s.cancelled = false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ended: Bool? = state.withLock { s in
                    if s.allowed { return true }
                    if s.cancelled { return false }
                    s.waiter = continuation
                    return nil
                }
                if let ended { continuation.resume(returning: ended) }
            }
        } onCancel: {
            let waiter = state.withLock { s in
                s.cancelled = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: false)
        }
    }
}

/// The network, changing when the test says so.
private final class FakeNetwork: NetworkWatching {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func changes() -> AsyncStream<Void> { stream }

    /// The network changed (it came back, or moved to another Wi-Fi).
    func fire() { continuation.yield() }
}

/// What the store keeps of its push registration, in memory.
private final class FakePushAcks: PushAckStorage {
    private let state: OSAllocatedUnfairLock<PushAck?>

    init(_ ack: PushAck? = nil) {
        state = OSAllocatedUnfairLock(initialState: ack)
    }

    var saved: PushAck? { state.withLock { $0 } }

    func loadPushAck() -> PushAck? { state.withLock { $0 } }
    func savePushAck(_ ack: PushAck?) { state.withLock { $0 = ack } }
}

/// Runs the work at once, and lets a test wait for it.
@MainActor private final class ImmediateRunner: BackgroundRunner {
    private var tasks: [Task<Void, Never>] = []

    func run(_ work: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await work() })
    }

    /// Returns when everything run so far has finished.
    func finished() async {
        for task in tasks { await task.value }
    }
}

/// A store over fakes; every link it makes is kept.
@MainActor private final class Rig {
    let journal = Journal()
    let clock: FakeClock
    let storage: FakeStorage
    let pairer: FakePairer
    let runner = ImmediateRunner()
    let network = FakeNetwork()
    let pushAcks: FakePushAcks
    /// The store's own waits (the 3 s an unregistration may take).
    let timer = ManualClock()
    private(set) var links: [FakeLink] = []
    /// The Macs left that may still push here (`onUntoldMac`), in order.
    private(set) var untold: [StoredPairing] = []

    init(
        paired: Bool = true, cached: CachedSnapshot? = nil, slowPairing: Bool = false, pushAck: PushAck? = nil,
        clockStep: TimeInterval = 0
    ) {
        clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000), step: clockStep)
        pushAcks = FakePushAcks(pushAck)
        storage = FakeStorage(journal: journal, pairing: paired ? stored : nil, snapshot: cached)
        pairer = FakePairer(journal: journal, outcome: .paired(deviceId: "d2", token: "t2", macName: "New Mac"), slow: slowPairing)
    }

    func makeStore(
        grace: Duration = .seconds(10), localNetworkGate: any LocalNetworkGate = OpenLocalNetworkGate()
    ) -> BridgeStore {
        BridgeStore(
            storage: storage,
            makeLink: { _, onEvent in
                let link = FakeLink(index: self.links.count, journal: self.journal, onEvent: onEvent)
                self.links.append(link)
                return link
            },
            pairer: pairer, background: runner, network: network, localNetworkGate: localNetworkGate,
            backgroundGrace: grace, now: { [clock] in clock.now },
            pushAcks: pushAcks, sleep: timer.sleep,
            onUntoldMac: { pairing in
                self.journal.add("untold \(pairing.macName)")
                self.untold.append(pairing)
            }
        )
    }

    var link: FakeLink { links[0] }
}

private let target = PairingTarget(
    endpoint: Endpoint(host: "192.168.1.30", port: 47824), fingerprint: String(repeating: "cd", count: 32),
    code: "K7M2QX9P", macName: "Pair Mac"
)

private let pushRegistration = PushRegistration(
    token: "aa11", environment: .sandbox, bundleId: "com.braynlabs.critter", key: PushCrypto.makeKey(),
    notifyDone: true, notifyError: true
)

private let answer = BridgeCommand.answer(requestId: "r1", payload: AnswerPayload(decision: "allow"))

/// What this phone registers for push.
private func phonePush(done: Bool = false, notificationsAllowed: Bool = true, activity: Bool = true) -> PushRegistrar {
    PushRegistrar(
        deviceToken: "aa11", environment: .sandbox, bundleId: "com.braynlabs.critter", key: pushRegistration.key,
        notificationsAllowed: notificationsAllowed, notifyDone: done, notifyError: false,
        liveActivity: ActivityRegistration(enabled: activity, startToken: "5a5a")
    )
}

// MARK: - Tests

@MainActor
struct BridgeStoreTests {
    @Test func restoresTheCachedSnapshotAtLaunch() async {
        let cached = CachedSnapshot(body: body("a", "b"), receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rig = Rig(cached: cached)
        let store = rig.makeStore()
        #expect(store.pairing == stored)
        #expect(store.snapshot == cached.body)
        #expect(store.snapshotAt == cached.receivedAt)
        #expect(!store.isLive)
        #expect(!store.canAct)
        #expect(store.conn == .idle)
        #expect(store.pairingPhase == nil)
        // The link is made, but not started.
        #expect(rig.links.count == 1)
        await settle()
        #expect(rig.link.starts == 0)
    }

    @Test func noPairingMeansNothingToShowAtLaunch() async {
        let cached = CachedSnapshot(body: body("a"), receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rig = Rig(paired: false, cached: cached)
        let store = rig.makeStore()
        #expect(store.pairing == nil)
        #expect(store.snapshot == nil)
        #expect(store.snapshotAt == nil)
        #expect(rig.links.isEmpty)
    }

    @Test func activeStartsTheLinkOnlyWhenPaired() async {
        let unpaired = Rig(paired: false)
        let none = unpaired.makeStore()
        none.sceneBecameActive()
        await settle()
        #expect(unpaired.links.isEmpty)
        #expect(unpaired.journal.all.isEmpty)

        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        #expect(await becomes { rig.link.starts == 1 })
    }

    @Test func snapshotsAreShownAndCached() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.state(connected))
        let first = body("a")
        rig.link.emit(snapshot(first))
        #expect(await becomes { store.snapshot == first })
        #expect(store.conn == connected)
        #expect(store.isLive)
        #expect(store.canAct)
        #expect(store.snapshotAt == rig.clock.now)
        #expect(rig.storage.snapshotSaves == [CachedSnapshot(body: first, receivedAt: rig.clock.now)])
        // A later snapshot is stamped with the time it arrived.
        let later = Date(timeIntervalSince1970: 1_800_000_060)
        rig.clock.set(later)
        let second = body("a", "b")
        rig.link.emit(snapshot(second, seq: 2))
        #expect(await becomes { store.snapshot == second })
        #expect(store.snapshotAt == later)
        #expect(rig.storage.snapshotSaves.last == CachedSnapshot(body: second, receivedAt: later))
    }

    @Test func eventsAreAppliedInOrder() async {
        // Every snapshot 30 s after the one before, so that each is written.
        let rig = Rig(clockStep: 30)
        let store = rig.makeStore()
        let bodies = (0..<100).map { body("s\($0)") }
        let link = rig.link
        // From another thread, as the client reports them.
        await Task.detached {
            for (i, snapshotBody) in bodies.enumerated() {
                link.emit(.state(i.isMultiple(of: 2) ? offline : connected))
                link.emit(snapshot(snapshotBody, seq: i))
            }
            link.emit(.state(connected))
        }.value
        #expect(await becomes { store.conn == connected && store.snapshot == bodies.last })
        // Every snapshot was handled, one after the other, in the order sent.
        #expect(rig.storage.snapshotSaves.map(\.body) == bodies)
        #expect(store.snapshot == bodies.last)
        #expect(store.isLive)
    }

    /// Ledger: every snapshot was written, and one can be over a megabyte. As on Android: at most one write every 30
    /// seconds, the newest snapshot; the one held back goes when the app leaves the foreground or the connection ends.
    @Test func snapshotWritesAreThrottledTo30Seconds() async {
        let rig = Rig()
        let store = rig.makeStore()
        let start = rig.clock.now
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        rig.link.emit(.state(connected))
        for (i, seconds) in [0.0, 10, 29, 30, 45].enumerated() {
            rig.clock.set(at(seconds))
            rig.link.emit(snapshot(body("s\(i)"), seq: i))
            #expect(await becomes { store.snapshot == body("s\(i)") })
        }
        // Shown as they come; written: the first, then the newest once 30 s have passed since.
        #expect(rig.storage.snapshotSaves == [
            CachedSnapshot(body: body("s0"), receivedAt: at(0)),
            CachedSnapshot(body: body("s3"), receivedAt: at(30)),
        ])
        rig.clock.set(at(61))
        rig.link.emit(snapshot(body("s5"), seq: 5))
        #expect(await becomes { rig.storage.snapshotSaves.count == 3 })
        #expect(rig.storage.snapshotSaves.last == CachedSnapshot(body: body("s5"), receivedAt: at(61)))
    }

    @Test func backgroundFlushesThePendingSnapshot() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("a")))
        #expect(await becomes { store.snapshot == body("a") })
        let later = rig.clock.now.addingTimeInterval(5)
        rig.clock.set(later)
        rig.link.emit(snapshot(body("b"), seq: 2))
        #expect(await becomes { store.snapshot == body("b") })
        #expect(rig.storage.snapshotSaves.count == 1)

        store.sceneEnteredBackground()
        #expect(rig.storage.snapshotSaves.last == CachedSnapshot(body: body("b"), receivedAt: later))
        #expect(rig.storage.snapshotSaves.count == 2)
        // Nothing more to write.
        store.sceneBecameActive()
        store.sceneEnteredBackground()
        #expect(rig.storage.snapshotSaves.count == 2)
    }

    @Test func aConnectionThatEndsFlushesThePendingSnapshot() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("a")))
        rig.link.emit(snapshot(body("b"), seq: 2))
        #expect(await becomes { store.snapshot == body("b") })
        #expect(rig.storage.snapshotSaves.map(\.body) == [body("a")])
        rig.link.emit(.state(offline))
        #expect(await becomes { rig.storage.snapshotSaves.map(\.body) == [body("a"), body("b")] })
    }

    /// A snapshot held back belongs to its pairing: unpaired or paired with another Mac, it is never written.
    @Test func aHeldBackSnapshotDiesWithItsPairing() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("a")))
        rig.link.emit(snapshot(body("old"), seq: 2))
        #expect(await becomes { store.snapshot == body("old") })
        _ = await store.pair(target, deviceName: "iPhone")
        store.sceneEnteredBackground()
        rig.links[1].emit(.state(connected))
        rig.links[1].emit(.state(offline))
        await settle()
        #expect(rig.storage.snapshotSaves.map(\.body) == [body("a")])
        // The new Mac's first snapshot is written at once.
        rig.links[1].emit(.state(connected))
        rig.links[1].emit(snapshot(body("new")))
        #expect(await becomes { rig.storage.snapshotSaves.map(\.body) == [body("a"), body("new")] })
    }

    @Test func reconnectingIsNotLiveUntilANewSnapshot() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("a")))
        #expect(await becomes { store.canAct })

        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(!store.isLive)
        #expect(!store.canAct)
        // The old snapshot stays on screen, not live.
        #expect(store.snapshot == body("a"))

        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        #expect(!store.canAct)

        rig.link.emit(snapshot(body("a", "b"), seq: 2))
        #expect(await becomes { store.canAct })
        #expect(store.snapshot == body("a", "b"))
    }

    @Test func aNewAddressIsRemembered() async {
        let rig = Rig()
        let store = rig.makeStore()
        // The address it already has: nothing to remember.
        rig.link.emit(.connectedTo(home))
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        #expect(rig.storage.endpointUpdates.isEmpty)

        rig.link.emit(.connectedTo(moved))
        #expect(await becomes { rig.storage.endpointUpdates == [moved] })
        #expect(store.pairing?.endpoint == moved)
        // The same address again is not written again.
        rig.link.emit(.connectedTo(moved))
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(rig.storage.endpointUpdates == [moved])
    }

    // MARK: - The scene

    @Test func backgroundingWaitsForTheAnswerInFlight() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        rig.link.holdRequests()

        let sending = Task { await store.send(answer) }
        #expect(await becomes { rig.link.requests.count == 1 })
        store.sceneEnteredBackground()
        await settle()
        #expect(rig.link.stops == 0)

        rig.link.reply(with: CommandResult(ok: true, reason: nil, message: nil))
        rig.link.release.open()
        #expect(await sending.value == CommandResult(ok: true, reason: nil, message: nil))
        await rig.runner.finished()
        #expect(rig.link.stops == 1)
        // The answer went out and was acknowledged before the connection was closed.
        #expect(rig.journal.all == ["start 0", "stop 0"])
    }

    @Test func backgroundingGivesUpAfterTheGrace() async {
        let rig = Rig()
        let store = rig.makeStore(grace: .milliseconds(50))
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        rig.link.holdRequests()

        let sending = Task { await store.send(answer) }
        #expect(await becomes { rig.link.requests.count == 1 })
        store.sceneEnteredBackground()
        await rig.runner.finished()
        #expect(rig.link.stops == 1)

        // What was still waiting is let go; the link would have failed it.
        rig.link.reply(with: .failed("未连接"))
        rig.link.release.open()
        #expect(await sending.value == .failed("未连接"))
    }

    @Test func backgroundingWithNothingInFlightStopsAtOnce() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        store.sceneEnteredBackground()
        await rig.runner.finished()
        #expect(rig.journal.all == ["start 0", "stop 0"])
    }

    @Test func comingBackWithinTheGraceKeepsTheLink() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        rig.link.holdRequests()

        let sending = Task { await store.send(answer) }
        #expect(await becomes { rig.link.requests.count == 1 })
        store.sceneEnteredBackground()
        store.sceneBecameActive()
        rig.link.release.open()
        _ = await sending.value
        await rig.runner.finished()
        await settle()
        #expect(rig.link.stops == 0)
    }

    @Test func retryStartsAndReconnectsAtOnce() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.retry()
        #expect(await becomes { rig.link.reconnects == 1 })
        #expect(rig.journal.all == ["start 0", "reconnectNow 0"])
        // Without a pairing there is nothing to retry.
        let unpaired = Rig(paired: false)
        unpaired.makeStore().retry()
        await settle()
        #expect(unpaired.journal.all.isEmpty)
    }

    // MARK: - The network, the board's heartbeat, skins

    @Test func aNetworkChangeInTheForegroundReconnects() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        #expect(await becomes { rig.link.starts == 1 })
        rig.network.fire()
        #expect(await becomes { rig.link.reconnects == 1 })
        rig.network.fire()
        #expect(await becomes { rig.link.reconnects == 2 })
        #expect(rig.journal.all == ["start 0", "reconnectNow 0", "reconnectNow 0"])
    }

    @Test func aNetworkChangeInTheBackgroundIsIgnored() async {
        let rig = Rig()
        let store = rig.makeStore()
        // The app has not said where it is yet.
        rig.network.fire()
        await settle()
        #expect(rig.link.reconnects == 0)

        store.sceneBecameActive()
        #expect(await becomes { rig.link.starts == 1 })
        store.sceneEnteredBackground()
        await rig.runner.finished()
        rig.network.fire()
        await settle()
        #expect(rig.link.reconnects == 0)

        // Back in the foreground the next change counts, and only that one.
        store.sceneBecameActive()
        rig.network.fire()
        #expect(await becomes { rig.link.reconnects == 1 })
        await settle()
        #expect(rig.link.reconnects == 1)
    }

    @Test func aNetworkChangeWithNothingPairedDoesNothing() async {
        let rig = Rig(paired: false)
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.network.fire()
        await settle()
        #expect(rig.links.isEmpty)
        #expect(rig.journal.all.isEmpty)
    }

    @Test func boardOpenSetsThePingTo30Seconds() async {
        let rig = Rig()
        let store = rig.makeStore()
        #expect(!store.boardOpen)
        store.boardOpen = true
        #expect(await becomes { rig.link.pingIntervals == [30] })
        // Opened again: nothing new to tell the link.
        store.boardOpen = true
        store.boardOpen = false
        #expect(await becomes { rig.link.pingIntervals == [30, 60] })
        await settle()
        #expect(rig.link.pingIntervals == [30, 60])
    }

    @Test func aNewPairingKeepsTheBoardsPing() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.boardOpen = true
        #expect(await becomes { rig.link.pingIntervals == [30] })
        let result = await store.pair(target, deviceName: "iPhone")
        #expect(result == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.links.count == 2)
        #expect(await becomes { rig.links[1].pingIntervals == [30] })
    }

    @Test func requestSkinReturnsTheManifestBytes() async throws {
        let rig = Rig()
        let store = rig.makeStore()
        let manifest = JSONValue.object(["name": .string("sprig"), "frames": .array([.number(1), .number(2)])])
        rig.link.serve(manifest, named: "sprig")

        // Not connected: nil, and the link is not even asked.
        #expect(await store.requestSkin("sprig") == nil)
        #expect(rig.link.skinRequests.isEmpty)

        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        let data = try #require(await store.requestSkin("sprig"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == manifest)
        // The same bytes for the same manifest, whatever order the dictionary keeps its keys in: the phone
        // compares them to tell whether a skin changed.
        #expect(String(decoding: data, as: UTF8.self) == #"{"frames":[1,2],"name":"sprig"}"#)

        // The Mac has no such skin.
        #expect(await store.requestSkin("nope") == nil)
        #expect(rig.link.skinRequests == ["sprig", "nope"])

        // Offline again: nil.
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(await store.requestSkin("sprig") == nil)
        #expect(rig.link.skinRequests == ["sprig", "nope"])
    }

    // MARK: - Sending

    @Test func sendWhileNotConnectedFails() async {
        let unpaired = Rig(paired: false)
        #expect(await unpaired.makeStore().send(answer) == .failed("未连接"))

        let rig = Rig()
        let store = rig.makeStore()
        #expect(await store.send(answer) == .failed("未连接"))
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(await store.send(answer) == .failed("未连接"))
        #expect(rig.link.requests.isEmpty)
    }

    @Test func sendGoesToTheLinkWhenConnected() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        rig.link.reply(with: CommandResult(ok: false, reason: .resolved, message: nil))
        #expect(await store.send(answer) == CommandResult(ok: false, reason: .resolved, message: nil))
        #expect(rig.link.requests == [answer])
        #expect(await store.send(.seen(sessionId: "s1")) == CommandResult(ok: false, reason: .resolved, message: nil))
        #expect(rig.link.requests == [answer, .seen(sessionId: "s1")])
    }

    @Test func registerPushIsOnlySentWhileConnected() async {
        let unpaired = Rig(paired: false)
        #expect(await unpaired.makeStore().registerPush(pushRegistration) == .offline)

        let rig = Rig()
        let store = rig.makeStore()
        #expect(await store.registerPush(pushRegistration) == .offline)
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(await store.registerPush(pushRegistration) == .offline)
        #expect(rig.link.pushes.isEmpty)

        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        #expect(await store.registerPush(pushRegistration) == .stored(nil))
        rig.link.replyToPush(with: .noReply)
        #expect(await store.registerPush(pushRegistration) == .noReply)
        rig.link.replyToPush(with: .rejected("推送登记无效"))
        #expect(await store.registerPush(pushRegistration) == .rejected("推送登记无效"))
        #expect(rig.link.pushes == [pushRegistration, pushRegistration, pushRegistration])
    }

    @Test func macVersionFollowsTheLinkAndOutlastsTheConnection() async {
        let rig = Rig()
        let store = rig.makeStore()
        #expect(store.macVersion == nil)
        rig.link.emit(.macVersion("1.4.0"))
        rig.link.emit(.state(connected))
        #expect(await becomes { store.macVersion == "1.4.0" })
        // Kept while the connection is down.
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(store.macVersion == "1.4.0")
        rig.link.emit(.macVersion("1.5.0"))
        #expect(await becomes { store.macVersion == "1.5.0" })
        // The version of a Mac that is no longer paired is not kept.
        store.unpair()
        #expect(store.macVersion == nil)
    }

    @Test func aNewPairingForgetsTheOldMacsVersion() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.macVersion("1.4.0"))
        #expect(await becomes { store.macVersion == "1.4.0" })
        _ = await store.pair(target, deviceName: "iPhone")
        #expect(store.macVersion == nil)
    }

    // MARK: - Pairing

    @Test func pairingSuccessReplacesTheOldLink() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("old")))
        #expect(await becomes { store.canAct })

        let result = await store.pair(target, deviceName: "iPhone")
        #expect(result == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))

        let newPairing = StoredPairing(endpoint: target.endpoint, fingerprint: target.fingerprint, macName: "New Mac", deviceId: "d2")
        #expect(store.pairing == newPairing)
        #expect(rig.storage.saves == [FakeStorage.Saved(pairing: newPairing, token: "t2")])
        #expect(rig.links.count == 2)
        #expect(await becomes { rig.links[1].starts == 1 })
        #expect(rig.links[0].stops == 1)
        // The old link is stopped before the new pairing is saved and the new link started.
        #expect(rig.journal.all == ["start 0", "pair K7M2QX9P iPhone", "stop 0", "save", "start 1"])
        // The old Mac's snapshot is gone.
        #expect(store.snapshot == nil)
        #expect(store.snapshotAt == nil)
        #expect(!store.isLive)
        #expect(store.conn == .idle)
        #expect(store.pairingPhase == nil)
    }

    @Test func eventsFromAReplacedLinkAreIgnored() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.emit(.state(connected))
        #expect(await becomes { store.conn == connected })
        _ = await store.pair(target, deviceName: "iPhone")

        // The old link, still winding down, says things; they belong to the Mac that was replaced.
        rig.links[0].emit(.state(connected))
        rig.links[0].emit(snapshot(body("old")))
        rig.links[0].emit(.connectedTo(moved))
        rig.links[1].emit(.state(.connecting))
        #expect(await becomes { store.conn == .connecting })
        #expect(store.snapshot == nil)
        #expect(rig.storage.endpointUpdates.isEmpty)
        #expect(rig.storage.snapshotSaves.isEmpty)

        rig.links[1].emit(snapshot(body("new")))
        #expect(await becomes { store.snapshot == body("new") })
    }

    /// An event the store has been handed but not yet applied belongs to the link it came from: if that link
    /// is dropped first, the event is not applied.
    @Test func anEventWaitingToBeAppliedDiesWithItsLink() async {
        let rig = Rig()
        let store = rig.makeStore()
        await settle()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("late")))
        store.unpair()
        await settle()
        #expect(store.conn == .idle)
        #expect(store.snapshot == nil)
        #expect(!store.isLive)
        #expect(rig.storage.snapshotSaves.isEmpty)
    }

    @Test func pairingFailureKeepsTheOldPairing() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("old")))
        #expect(await becomes { store.canAct })
        rig.pairer.answer(with: .failed(.rejected))

        let result = await store.pair(target, deviceName: "iPhone")
        #expect(result == .failed(.rejected))
        #expect(store.pairing == stored)
        #expect(store.snapshot == body("old"))
        #expect(store.canAct)
        #expect(store.pairingPhase == nil)
        #expect(rig.links.count == 1)
        await settle()
        #expect(rig.link.stops == 0)
        #expect(rig.storage.saves.isEmpty)
    }

    /// Ledger: only the pairing screen kept a second attempt from starting; with notifications there are other ways in.
    @Test func pairIsNotReentrant() async {
        let rig = Rig(slowPairing: true)
        let store = rig.makeStore()
        let first = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { store.pairingPhase == .connecting })

        let other = PairingTarget(endpoint: moved, fingerprint: pin, code: "AAAA2222", macName: "Other Mac")
        #expect(await store.pair(other, deviceName: "iPhone") == .failed(.busy))
        #expect(PairFailure.busy.text == "正在配对")
        // The attempt under way goes on as it was; the second never reached a Mac.
        #expect(store.pairingPhase == .connecting)
        #expect(rig.journal.all.filter { $0.hasPrefix("pair") } == ["pair K7M2QX9P iPhone"])
        rig.pairer.reachMac.open()
        rig.pairer.approval.open()
        #expect(await first.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(store.pairing?.deviceId == "d2")
        #expect(rig.storage.saves.count == 1)
    }

    /// The Mac said yes but the phone could not keep the pairing (the keychain refused the token): the old pairing
    /// stays, on disk and on screen, and its connection comes back (Android does the same).
    @Test func aPairingThatCannotBeSavedKeepsTheOldOne() async {
        var ack = PushAck()
        ack.message = "已登记"
        let rig = Rig(pushAck: ack)
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("old")))
        #expect(await becomes { store.canAct })
        rig.storage.failSaves()

        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.notSaved))
        #expect(store.pairing == stored)
        #expect(rig.storage.storedPairing == stored)
        #expect(store.snapshot == body("old"))
        #expect(store.pairingPhase == nil)
        #expect(store.pushAck == ack)
        // A connection for the old pairing again, started.
        #expect(rig.links.count == 2)
        #expect(await becomes { rig.links[1].starts == 1 })
        rig.links[1].emit(.state(connected))
        rig.links[1].emit(snapshot(body("old", "again")))
        #expect(await becomes { store.snapshot == body("old", "again") && store.canAct })
    }

    @Test func aFirstPairingThatCannotBeSavedLeavesThePhoneUnpaired() async {
        let rig = Rig(paired: false)
        let store = rig.makeStore()
        rig.storage.failSaves()
        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.notSaved))
        #expect(store.pairing == nil)
        #expect(rig.links.isEmpty)
    }

    @Test func pairingPhasesAreReported() async {
        let rig = Rig(paired: false, slowPairing: true)
        let store = rig.makeStore()
        #expect(store.pairingPhase == nil)
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        // Reaching the Mac.
        #expect(await becomes { store.pairingPhase == .connecting })
        await settle()
        #expect(store.pairingPhase == .connecting)
        // The request is with the Mac, waiting for the user there.
        rig.pairer.reachMac.open()
        #expect(await becomes { store.pairingPhase == .awaitingApproval })
        // Approved.
        rig.pairer.approval.open()
        #expect(await pairing.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(store.pairingPhase == nil)
    }

    /// The store says whether the last attempt got as far as the Mac (its connection opened): a failure after that is
    /// not "never reached", whatever it was (the pairing screen does not try again by itself then).
    @Test func theStoreSaysWhetherTheLastAttemptReachedTheMac() async {
        let rig = Rig(paired: false)
        let store = rig.makeStore()
        #expect(!store.lastPairReachedMac)
        // The connection opened, then was cut: the Mac had the request.
        rig.pairer.answer(with: .failed(.unreachable))
        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.unreachable))
        #expect(store.lastPairReachedMac)
        // The next attempt starts afresh: the connection never opens.
        rig.pairer.cannotConnect()
        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.unreachable))
        #expect(!store.lastPairReachedMac)
    }

    /// Cancelled at the gate, the Mac is never tried: not reached.
    @Test func anAttemptCancelledAtTheGateDidNotReachTheMac() async {
        let rig = Rig(paired: false)
        let gate = FakeLocalNetworkGate()
        let store = rig.makeStore(localNetworkGate: gate)
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { gate.waiting })
        pairing.cancel()
        #expect(await pairing.value == .failed(.unreachable))
        #expect(!store.lastPairReachedMac)
    }

    /// The notice that the Mac is being waited for is passed on to the main actor; one that arrives after
    /// the pairing ended leaves no phase behind.
    @Test func aLateApprovalNoticeLeavesNoPhaseBehind() async {
        let rig = Rig(paired: false)
        let store = rig.makeStore()
        _ = await store.pair(target, deviceName: "iPhone")
        await settle()
        #expect(store.pairingPhase == nil)
        rig.pairer.answer(with: .failed(.noAnswer))
        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.noAnswer))
        await settle()
        #expect(store.pairingPhase == nil)
    }

    /// Device bug D2: the pairing's connection is the app's first touch of the local network, so iOS asks for 本地网络
    /// then, and the connection fails while it asks. The pairing waits at the gate first: refused (the prompt is up, or
    /// the permission is off), it says so, and the Mac is tried once the user allows, with no second scan.
    @Test func aPairingWaitsForTheLocalNetwork() async {
        let rig = Rig(paired: false, slowPairing: true)
        let gate = FakeLocalNetworkGate()
        let store = rig.makeStore(localNetworkGate: gate)
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { gate.waiting })
        #expect(store.pairingPhase == .connecting)
        // iOS asks: waiting for the user, without a time limit; the Mac is not tried meanwhile.
        gate.refuse()
        #expect(await becomes { store.pairingPhase == .waitingForLocalNetwork })
        await settle()
        #expect(store.pairingPhase == .waitingForLocalNetwork)
        #expect(store.isPairing)
        #expect(rig.journal.all.isEmpty)
        // Allowed: reaching the Mac.
        gate.allow()
        #expect(await becomes { rig.journal.all == ["pair K7M2QX9P iPhone"] })
        #expect(store.pairingPhase == .connecting)
        rig.pairer.reachMac.open()
        #expect(await becomes { store.pairingPhase == .awaitingApproval })
        rig.pairer.approval.open()
        #expect(await pairing.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(store.pairingPhase == nil)
        #expect(store.pairing?.deviceId == "d2")
    }

    /// 「取消」 while refused: the Mac is never tried, and the store is free for the next attempt.
    @Test func aPairingCancelledAtTheGateNeverTriesTheMac() async {
        let rig = Rig(paired: false)
        let gate = FakeLocalNetworkGate()
        let store = rig.makeStore(localNetworkGate: gate)
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { gate.waiting })
        gate.refuse()
        #expect(await becomes { store.pairingPhase == .waitingForLocalNetwork })
        pairing.cancel()
        #expect(await pairing.value == .failed(.unreachable))
        #expect(store.pairingPhase == nil)
        #expect(!store.isPairing)
        #expect(store.pairing == nil)
        #expect(rig.journal.all.isEmpty)
        // Allowed later: a new attempt goes through.
        gate.allow()
        #expect(await store.pair(target, deviceName: "iPhone") == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
    }

    /// Waiting at the gate is under way: a second scan is turned away.
    @Test func aPairingAtTheGateIsUnderWay() async {
        let rig = Rig(paired: false)
        let gate = FakeLocalNetworkGate()
        let store = rig.makeStore(localNetworkGate: gate)
        let first = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { gate.waiting })
        gate.refuse()
        #expect(await becomes { store.pairingPhase == .waitingForLocalNetwork })
        let other = PairingTarget(endpoint: moved, fingerprint: pin, code: "AAAA2222", macName: "Other Mac")
        #expect(await store.pair(other, deviceName: "iPhone") == .failed(.busy))
        #expect(store.pairingPhase == .waitingForLocalNetwork)
        gate.allow()
        #expect(await first.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.journal.all.filter { $0.hasPrefix("pair") } == ["pair K7M2QX9P iPhone"])
    }

    /// The refusal is passed on to the main actor; one that arrives once the gate has let the pairing through (or the
    /// pairing has ended) leaves the phase as it is.
    @Test func aLateRefusalNoticeLeavesThePhase() async {
        let rig = Rig(paired: false, slowPairing: true)
        let gate = FakeLocalNetworkGate()
        let store = rig.makeStore(localNetworkGate: gate)
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { gate.waiting })
        gate.allow()
        #expect(await becomes { rig.journal.all == ["pair K7M2QX9P iPhone"] })
        gate.refuse()
        await settle()
        #expect(store.pairingPhase == .connecting)
        rig.pairer.reachMac.open()
        rig.pairer.approval.open()
        #expect(await pairing.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        gate.refuse()
        await settle()
        #expect(store.pairingPhase == nil)
    }

    @Test func unpairForgetsEverything() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.sceneBecameActive()
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("a")))
        #expect(await becomes { store.canAct })

        store.unpair()
        #expect(store.pairing == nil)
        #expect(store.snapshot == nil)
        #expect(store.snapshotAt == nil)
        #expect(!store.isLive)
        #expect(!store.canAct)
        #expect(store.conn == .idle)
        #expect(rig.storage.clears == 1)
        #expect(await becomes { rig.link.stops == 1 })
        // The stopped link's last words change nothing.
        rig.link.emit(.state(connected))
        rig.link.emit(snapshot(body("late")))
        await settle()
        #expect(store.conn == .idle)
        #expect(store.snapshot == nil)
        #expect(await store.send(answer) == .failed("未连接"))
        // Nothing left to start.
        store.sceneBecameActive()
        await settle()
        #expect(rig.link.starts == 1)
    }

    // MARK: - Push registration

    /// Connects the store's link: the Mac's version, then `welcome`.
    private func connect(_ link: FakeLink, version: String = "1.5.0") {
        link.emit(.macVersion(version))
        link.emit(.state(connected))
    }

    @Test func registrationChangesAreSentOnce() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.setPush(phonePush())
        #expect(store.pushStatus == "还没登记（要连上 Mac）")
        // Not connected: nothing goes out.
        await settle()
        #expect(rig.link.pushes.isEmpty)
        // After `welcome`: sent, and the Mac's word shown.
        connect(rig.link)
        #expect(await becomes { rig.link.pushes == [phonePush().registration()] })
        #expect(await becomes { store.pushStatus == "已登记" })
        #expect(rig.pushAcks.saved?.stored == phonePush().registration())
        // The next connection: the Mac has it already.
        rig.link.emit(.state(offline))
        connect(rig.link)
        await settle()
        #expect(rig.link.pushes.count == 1)
        // A change while connected goes out at once, once.
        store.setPush(phonePush(done: true))
        #expect(await becomes { rig.link.pushes.count == 2 })
        store.setPush(phonePush(done: true))
        await settle()
        #expect(rig.link.pushes == [phonePush().registration(), phonePush(done: true).registration()])

        // A launch later the confirmation is still there: nothing to send.
        let relaunched = Rig(pushAck: rig.pushAcks.saved)
        let again = relaunched.makeStore()
        again.setPush(phonePush(done: true))
        connect(relaunched.link)
        await settle()
        #expect(relaunched.link.pushes.isEmpty)
        #expect(again.pushStatus == "已登记")

        // A Mac without a push setup is asked again on each connection (it may have one by then), once each.
        let unready = Rig()
        let asking = unready.makeStore()
        unready.link.replyToPush(with: .stored("已登记；这台 Mac 还没配置推送"))
        asking.setPush(phonePush())
        connect(unready.link)
        #expect(await becomes { asking.pushStatus == "已登记；这台 Mac 还没配置推送" })
        await settle()
        #expect(unready.link.pushes.count == 1)
        unready.link.replyToPush(with: .stored("已登记"))
        unready.link.emit(.state(offline))
        connect(unready.link)
        #expect(await becomes { asking.pushStatus == "已登记" })
        #expect(unready.link.pushes.count == 2)
    }

    @Test func everythingOffSendsAnEmptyToken() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.setPush(phonePush())
        connect(rig.link)
        #expect(await becomes { rig.link.pushes.count == 1 })
        // Notifications switched off in the system's settings, and the Live Activity off.
        store.setPush(phonePush(notificationsAllowed: false, activity: false))
        #expect(await becomes { rig.link.pushes.count == 2 })
        #expect(rig.link.pushes.last?.token == "")
        #expect(store.pushStatus == "通知被关掉了，去系统设置打开")
    }

    @Test func anOldMacIsTriedOncePerVersion() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.replyToPush(with: .noReply)
        store.setPush(phonePush())
        connect(rig.link, version: "1.3.0")
        #expect(await becomes { store.pushStatus == "这台 Mac 上的 Critter 版本太旧，收不到推送" })
        // The connection stays, and the next ones to that version do not try again, whatever changes.
        rig.link.emit(.state(offline))
        connect(rig.link, version: "1.3.0")
        store.setPush(phonePush(done: true))
        await settle()
        #expect(rig.link.pushes.count == 1)
        #expect(rig.link.stops == 0)
        // An updated Mac is asked.
        rig.link.replyToPush(with: .stored("已登记"))
        rig.link.emit(.state(offline))
        connect(rig.link, version: "1.5.0")
        #expect(await becomes { store.pushStatus == "已登记" })
        #expect(rig.link.pushes.count == 2)
    }

    @Test func theMacsStatusLineIsShown() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.replyToPush(with: .stored("已登记；这台 Mac 还没配置推送"))
        // Nothing to register with yet.
        #expect(store.pushStatus == "还没登记（要连上 Mac）")
        store.setPush(phonePush())
        connect(rig.link)
        #expect(await becomes { store.pushStatus == "已登记；这台 Mac 还没配置推送" })
        // Refused, in the Mac's words.
        rig.link.replyToPush(with: .rejected("保存失败"))
        store.setPush(phonePush(done: true))
        #expect(await becomes { store.pushStatus == "保存失败" })
    }

    @Test func unpairUnregistersFirstWhenOnline() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.setPush(phonePush())
        connect(rig.link)
        #expect(await becomes { rig.link.pushes.count == 1 })
        #expect(await becomes { store.pushStatus == "已登记" })
        // The Mac takes its time with the unregistration.
        rig.link.holdPushes()
        store.unpair()
        // Unpaired on the phone at once, and nothing of the registration is kept.
        #expect(store.pairing == nil)
        #expect(store.pushStatus == "还没登记（要连上 Mac）")
        #expect(rig.pushAcks.saved == nil)
        // The old connection first takes the registration back (an empty token), then goes -- within 3 s.
        #expect(await becomes { rig.link.pushes.count == 2 })
        #expect(rig.link.pushes.last?.token == "")
        #expect(await rig.timer.waitForSleepers(1))
        #expect(rig.timer.asked == [.seconds(3)])
        rig.timer.advance(by: .seconds(2))
        await settle()
        #expect(rig.link.stops == 0)
        rig.timer.advance(by: .seconds(1))
        #expect(await becomes { rig.link.stops == 1 })
        // Not confirmed: the app hears of it (it changes the push key).
        #expect(await becomes { Array(rig.journal.all.suffix(4)) == ["clear", "push 0 -", "stop 0", "untold Mac"] })
        rig.link.releasePushes.open()

        // A Mac that answers at once: stopped right after.
        let quick = Rig()
        let answered = quick.makeStore()
        answered.setPush(phonePush())
        connect(quick.link)
        #expect(await becomes { quick.link.pushes.count == 1 })
        answered.unpair()
        #expect(await becomes { quick.link.stops == 1 })
        #expect(quick.link.pushes.last?.token == "")

        // Offline there is no one to tell: stopped at once, nothing sent.
        let away = Rig()
        let offlineStore = away.makeStore()
        offlineStore.setPush(phonePush())
        away.link.emit(.state(offline))
        #expect(await becomes { offlineStore.conn == offline })
        offlineStore.unpair()
        #expect(await becomes { away.link.stops == 1 })
        #expect(away.link.pushes.isEmpty)
    }

    @Test func aNewPairingRegistersAfresh() async {
        let rig = Rig()
        let store = rig.makeStore()
        store.setPush(phonePush())
        connect(rig.link)
        #expect(await becomes { rig.link.pushes.count == 1 })
        _ = await store.pair(target, deviceName: "iPhone")
        // The new Mac has nothing of this phone's yet.
        #expect(store.pushStatus == "还没登记（要连上 Mac）")
        connect(rig.links[1])
        #expect(await becomes { rig.links[1].pushes == [phonePush().registration()] })
    }
}

// MARK: - Leaving a Mac (pairing with another, unpairing)

@MainActor
struct BridgeStoreLeavingTests {
    private let other = PairingTarget(endpoint: moved, fingerprint: pin, code: "AAAA2222", macName: "Other Mac")

    private func connect(_ link: FakeLink, version: String = "1.5.0") {
        link.emit(.macVersion(version))
        link.emit(.state(connected))
    }

    /// A store whose Mac has stored this phone's registration.
    private func registered(_ rig: Rig) async -> BridgeStore {
        let store = rig.makeStore()
        store.setPush(phonePush())
        connect(rig.link)
        #expect(await becomes { store.pushStatus == "已登记" })
        return store
    }

    /// Ledger (plan 4 review): the attempt was only marked busy until the Mac said yes, not while the old connection
    /// was being stopped and the new pairing saved; a second `pair` could start in that gap.
    @Test func pairStaysBusyUntilTheOldConnectionHasStopped() async {
        let rig = Rig()
        let store = rig.makeStore()
        rig.link.holdStops()
        let first = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { rig.journal.all.contains("stop 0") })
        #expect(store.pairingPhase == nil)
        #expect(store.isPairing)
        #expect(await store.pair(other, deviceName: "iPhone") == .failed(.busy))
        rig.link.releaseStops.open()
        #expect(await first.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(!store.isPairing)
        #expect(rig.journal.all.filter { $0.hasPrefix("pair") } == ["pair K7M2QX9P iPhone"])
        #expect(rig.storage.saves.count == 1)
        #expect(store.pairing?.deviceId == "d2")
    }

    /// Pairing with another Mac takes the registration back from the old one first (spec §8.8), as unpairing does:
    /// the empty token over the old connection, then it stops, then the new pairing is saved and connects.
    @Test func pairingAgainTakesTheRegistrationBackFromTheOldMac() async {
        let rig = Rig()
        let store = await registered(rig)
        #expect(await store.pair(target, deviceName: "iPhone") == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.link.pushes.count == 2)
        #expect(rig.link.pushes.last == phonePush().unregistration())
        #expect(await becomes { rig.links.count == 2 && rig.links[1].starts == 1 })
        #expect(Array(rig.journal.all.suffix(4)) == ["push 0 -", "stop 0", "save", "start 1"])
        // The old Mac confirmed it: nothing to say about it.
        #expect(rig.untold.isEmpty)
        // The new Mac is asked afresh, with the same key.
        connect(rig.links[1])
        #expect(await becomes { rig.links[1].pushes == [phonePush().registration()] })
    }

    /// The old Mac is out of reach (the reason one pairs again, often): there is no one to take the registration back
    /// from, so the app is told before the new pairing connects; it changes the push key (what the old Mac pushes can
    /// no longer be opened) and the settings say that Mac should revoke this phone.
    @Test func pairingAgainAwayFromTheOldMacTellsTheApp() async {
        let rig = Rig()
        let store = await registered(rig)
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(await store.pair(target, deviceName: "iPhone") == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.link.pushes.count == 1)
        #expect(rig.untold == [stored])
        #expect(await becomes { rig.links.count == 2 && rig.links[1].starts == 1 })
        #expect(Array(rig.journal.all.suffix(4)) == ["stop 0", "save", "untold Mac", "start 1"])
    }

    /// Ledger (plan 4 final fix wave, residual → plan 5; plan 5 T2): pairing again with the same Mac -- the new
    /// certificate's fingerprint is the old pairing's -- after it was merely out of reach (or did not answer in time).
    /// A warning would change the push key for nothing and have the user revoke "this phone" on that Mac, where the old
    /// record and the new pairing now stand under the same name: they could revoke the new one. Nothing is said and the
    /// key stays: the new pairing registers the same token, and the Mac hands the old record's registration over to it
    /// (`DeviceStore.setPush`, plan 4 FI2).
    @Test func pairingAgainToTheSameMacSaysNothing() async {
        let sameMac = PairingTarget(endpoint: moved, fingerprint: stored.fingerprint, code: "K7M2QX9P", macName: "Mac")

        let away = Rig()
        let store = await registered(away)
        away.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(await store.pair(sameMac, deviceName: "iPhone") == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(away.untold.isEmpty)
        #expect(!away.journal.all.contains { $0.hasPrefix("untold") })
        #expect(store.pairing?.fingerprint == stored.fingerprint)
        // The same registration, key and all, goes to the new pairing.
        #expect(await becomes { away.links.count == 2 && away.links[1].starts == 1 })
        connect(away.links[1])
        #expect(await becomes { away.links[1].pushes == [phonePush().registration()] })

        // Connected, but it does not confirm taking the registration back within 3 s: the same.
        let slow = Rig()
        let slowStore = await registered(slow)
        slow.link.holdPushes()
        let pairing = Task { await slowStore.pair(sameMac, deviceName: "iPhone") }
        #expect(await slow.timer.waitForSleepers(1))
        slow.timer.advance(by: .seconds(3))
        #expect(await pairing.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(slow.untold.isEmpty)
        slow.link.releasePushes.open()

        // Another Mac under the same name (another certificate) is still reported.
        let other = Rig()
        let otherStore = await registered(other)
        other.link.emit(.state(offline))
        #expect(await becomes { otherStore.conn == offline })
        let sameName = PairingTarget(endpoint: home, fingerprint: target.fingerprint, code: "K7M2QX9P", macName: "Mac")
        _ = await otherStore.pair(sameName, deviceName: "iPhone")
        #expect(other.untold == [stored])
    }

    /// Connected, but the old Mac does not answer: the new pairing goes on after 3 s, and the app is told.
    @Test func pairingAgainGivesTheOldMac3Seconds() async {
        let rig = Rig()
        let store = await registered(rig)
        rig.link.holdPushes()
        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(await becomes { rig.link.pushes.count == 2 })
        #expect(await rig.timer.waitForSleepers(1))
        #expect(rig.timer.asked == [.seconds(3)])
        rig.timer.advance(by: .seconds(2))
        await settle()
        #expect(rig.link.stops == 0)
        #expect(rig.storage.saves.isEmpty)
        #expect(store.isPairing)
        rig.timer.advance(by: .seconds(1))
        #expect(await pairing.value == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.link.stops == 1)
        #expect(rig.untold == [stored])
        rig.link.releasePushes.open()
    }

    /// A Mac that refuses the empty token keeps what it had.
    @Test func anOldMacThatRefusesIsReported() async {
        let rig = Rig()
        let store = await registered(rig)
        rig.link.replyToPush(with: .rejected("保存失败"))
        _ = await store.pair(target, deviceName: "iPhone")
        #expect(rig.link.pushes.last?.token == "")
        #expect(rig.untold == [stored])
    }

    /// Nothing is said about a Mac that never stored a registration: none was ever confirmed (never connected since the
    /// app said what to register), the app never said what to register, or the Mac does not know the frame.
    @Test func aMacWithoutARegistrationIsLeftQuietly() async {
        let neverConnected = Rig()
        let a = neverConnected.makeStore()
        a.setPush(phonePush())
        _ = await a.pair(target, deviceName: "iPhone")
        #expect(neverConnected.untold.isEmpty)

        let nothingSet = Rig()
        let b = nothingSet.makeStore()
        connect(nothingSet.link)
        #expect(await becomes { b.conn == connected })
        _ = await b.pair(target, deviceName: "iPhone")
        #expect(nothingSet.link.pushes.isEmpty)
        #expect(nothingSet.untold.isEmpty)

        let old = Rig()
        let c = old.makeStore()
        old.link.replyToPush(with: .noReply)
        c.setPush(phonePush())
        connect(old.link, version: "1.3.0")
        #expect(await becomes { c.pushStatus == "这台 Mac 上的 Critter 版本太旧，收不到推送" })
        _ = await c.pair(target, deviceName: "iPhone")
        #expect(old.link.pushes.count == 1)
        #expect(old.untold.isEmpty)
    }

    /// Before the app has said what to register this run, the Mac's stored registration is taken back all the same.
    @Test func whatTheMacStoredIsTakenBackBeforeTheAppHasSaid() async {
        let confirmed = phonePush().record(
            reply: .stored("已登记"), sent: phonePush().registration(), macVersion: "1.5.0", acked: PushAck()
        )
        let rig = Rig(pushAck: confirmed)
        let store = rig.makeStore()
        connect(rig.link)
        #expect(await becomes { store.conn == connected })
        _ = await store.pair(target, deviceName: "iPhone")
        #expect(rig.link.pushes == [phonePush().unregistration()])
        #expect(rig.untold.isEmpty)
    }

    /// The new pairing could not be kept: the old one stays, but its Mac was asked to drop the registration on the way,
    /// so its connection registers afresh when it comes back.
    @Test func aPairingThatCannotBeSavedRegistersTheOldOneAgain() async {
        let rig = Rig()
        let store = await registered(rig)
        rig.storage.failSaves()
        #expect(await store.pair(target, deviceName: "iPhone") == .failed(.notSaved))
        #expect(rig.link.pushes.last?.token == "")
        #expect(store.pairing == stored)
        #expect(rig.links.count == 2)
        connect(rig.links[1])
        #expect(await becomes { rig.links[1].pushes == [phonePush().registration()] })
        #expect(rig.untold.isEmpty)
    }

    /// Unpairing a Mac that cannot be told (offline, or no confirmation within 3 s) is the same hole: the app is told.
    @Test func unpairingAMacThatCannotBeToldTellsTheApp() async {
        let away = Rig()
        let offlineStore = await registered(away)
        away.link.emit(.state(offline))
        #expect(await becomes { offlineStore.conn == offline })
        offlineStore.unpair()
        await away.runner.finished()
        #expect(away.link.pushes.count == 1)
        #expect(away.untold == [stored])

        let slow = Rig()
        let slowStore = await registered(slow)
        slow.link.holdPushes()
        slowStore.unpair()
        #expect(await slow.timer.waitForSleepers(1))
        slow.timer.advance(by: .seconds(3))
        await slow.runner.finished()
        #expect(slow.untold == [stored])
        slow.link.releasePushes.open()

        // Told: nothing to say.
        let quick = Rig()
        let quickStore = await registered(quick)
        quickStore.unpair()
        await quick.runner.finished()
        #expect(quick.link.pushes.last?.token == "")
        #expect(quick.untold.isEmpty)
    }

    /// The Mac turns this phone's token away, as after it revoked this phone or was reset: it deleted the device record
    /// and the push registration with it.
    private func forgotten(_ link: FakeLink, _ store: BridgeStore, reason: DenyReason = .badToken) async {
        link.emit(.denied(reason))
        link.emit(.state(.needsRepair(reason: "这台手机已不在电脑的配对列表里，请重新配对")))
        #expect(await becomes { if case .needsRepair = store.conn { true } else { false } })
    }

    /// Ledger (plan 4 final review, FI1): after the Mac revoked this phone the phone asks to pair again -- most often
    /// with that same Mac. A warning then would rotate the key for nothing and have the user revoke "this phone" on that
    /// Mac: the new pairing. The Mac holds nothing, so nothing is said, and what it had confirmed is forgotten.
    @Test func pairingAgainAfterTheMacForgotThisPhoneSaysNothing() async {
        let rig = Rig()
        let store = await registered(rig)
        await forgotten(rig.link, store)
        #expect(rig.pushAcks.saved == nil)
        #expect(store.pushStatus == PushRegistrar.notRegisteredLine)
        #expect(!store.unpairingLeavesTheMacUntold)
        #expect(await store.pair(target, deviceName: "iPhone") == .paired(deviceId: "d2", token: "t2", macName: "New Mac"))
        #expect(rig.untold.isEmpty)
        #expect(rig.link.pushes.count == 1)
        // The new pairing registers afresh.
        connect(rig.links[1])
        #expect(await becomes { rig.links[1].pushes == [phonePush().registration()] })
    }

    /// The same for unpairing; also when a registration's answer, cut off, comes back only after the Mac turned the
    /// phone away.
    @Test func unpairingAfterTheMacForgotThisPhoneSaysNothing() async {
        let rig = Rig()
        let store = await registered(rig)
        await forgotten(rig.link, store)
        store.unpair()
        await rig.runner.finished()
        #expect(rig.untold.isEmpty)

        let late = Rig()
        let lateStore = late.makeStore()
        late.link.holdPushes()
        late.link.replyToPush(with: .offline)
        lateStore.setPush(phonePush())
        connect(late.link)
        #expect(await becomes { late.link.pushes.count == 1 })
        late.link.emit(.state(offline))
        await forgotten(late.link, lateStore)
        late.link.releasePushes.open()
        await settle()
        lateStore.unpair()
        await late.runner.finished()
        #expect(late.untold.isEmpty)
    }

    /// Only `badToken` says the record is gone. Another denial (another protocol, refused, a reason this build does not
    /// know) or a certificate that changed says nothing of what the Mac holds: leaving it is reported as before.
    @Test func otherRefusalsStillTellTheApp() async {
        for reason in [DenyReason.protocolMismatch, .rejected, .unknown] {
            let rig = Rig()
            let store = await registered(rig)
            await forgotten(rig.link, store, reason: reason)
            #expect(store.unpairingLeavesTheMacUntold)
            _ = await store.pair(target, deviceName: "iPhone")
            #expect(rig.untold == [stored])
        }
        let rig = Rig()
        let store = await registered(rig)
        rig.link.emit(.state(.needsRepair(reason: "证书指纹与配对时不一致，请重新配对")))
        #expect(await becomes { if case .needsRepair = store.conn { true } else { false } })
        store.unpair()
        await rig.runner.finished()
        #expect(rig.untold == [stored])
    }

    /// A Mac that welcomes the phone again after turning it away (its record back) and stores the registration holds
    /// one again.
    @Test func aMacThatWelcomesThePhoneAgainHoldsItsRegistrationAgain() async {
        let rig = Rig()
        let store = await registered(rig)
        await forgotten(rig.link, store)
        connect(rig.link)
        #expect(await becomes { rig.link.pushes.count == 2 && store.pushStatus == "已登记" })
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(store.unpairingLeavesTheMacUntold)
    }

    /// The unpair dialog says up front when the Mac cannot be told: it may hold the registration and the phone is not
    /// connected. Connected (it is asked first), or holding nothing, it says nothing of the kind.
    @Test func theUnpairDialogKnowsWhenTheMacCannotBeTold() async {
        let rig = Rig()
        let store = await registered(rig)
        #expect(!store.unpairingLeavesTheMacUntold)
        rig.link.emit(.state(offline))
        #expect(await becomes { store.conn == offline })
        #expect(store.unpairingLeavesTheMacUntold)

        let never = Rig()
        let neverStore = never.makeStore()
        neverStore.setPush(phonePush())
        never.link.emit(.state(offline))
        #expect(await becomes { neverStore.conn == offline })
        #expect(!neverStore.unpairingLeavesTheMacUntold)

        let unpaired = Rig(paired: false)
        #expect(!unpaired.makeStore().unpairingLeavesTheMacUntold)
    }
}

/// The store over the real `BridgeClient` and `Pairer`, with a `FakeMac` for the network.
@MainActor
struct BridgeStoreWithTheClientTests {
    @Test func theStoreDrivesARealClient() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let storage = FakeStorage(journal: Journal(), pairing: stored, snapshot: nil)
        let runner = ImmediateRunner()
        let store = BridgeStore(
            storage: storage,
            makeLink: { pairing, onEvent in
                BridgeClient(
                    transport: mac, endpoint: StaticResolver(pairing.endpoint), fingerprint: pairing.fingerprint,
                    credentials: { storage.load()?.1 }, app: "critter-ios/test", onEvent: onEvent
                )
            },
            pairer: Pairer(transport: mac), background: runner, network: FakeNetwork()
        )

        // Foreground: connects, says hello first, and is welcomed.
        store.sceneBecameActive()
        #expect(await becomes { store.conn == connected })
        let hello = try #require(await mac.nextFrame())
        #expect(hello == .hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test"))
        #expect(mac.connects == [FakeMac.Connect(host: home.host, port: home.port, fingerprint: pin)])
        #expect(storage.endpointUpdates.isEmpty)
        #expect(await becomes { store.macVersion == "1.4.0" })

        // A snapshot makes it live.
        mac.send(snapshot(body("a")).serverMessage)
        #expect(await becomes { store.canAct })
        #expect(store.snapshot == body("a"))

        // A command goes out and its result comes back.
        let sending = Task { await store.send(.seen(sessionId: "a")) }
        let frame = try #require(await mac.nextFrame())
        guard case .seen(let id?, "a") = frame else {
            Issue.record("expected seen, got \(frame)")
            return
        }
        mac.send(.result(id: id, ok: true, reason: nil, message: nil))
        #expect(await sending.value == CommandResult(ok: true, reason: nil, message: nil))

        // Background: with nothing in flight the connection is closed.
        store.sceneEnteredBackground()
        await runner.finished()
        #expect(await becomes { store.conn == .idle })
        #expect(!store.isLive)
        #expect(await becomes { mac.openSockets == 0 })

        // Back in the foreground it connects again.
        store.sceneBecameActive()
        #expect(await becomes { store.conn == connected })
        #expect(mac.connects.count == 2)
        store.unpair()
        #expect(await becomes { mac.openSockets == 0 })
    }

    /// Pairing with another Mac over the real client: the empty token goes to the old Mac over its own connection (the
    /// pairing's connection is closed by then), and the new pairing says hello once the old Mac has taken it.
    @Test func pairingAgainTakesTheRegistrationBackOverTheOldConnection() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let storage = FakeStorage(journal: Journal(), pairing: stored, snapshot: nil)
        let untold = UntoldMacs()
        let store = BridgeStore(
            storage: storage,
            makeLink: { pairing, onEvent in
                BridgeClient(
                    transport: mac, endpoint: StaticResolver(pairing.endpoint), fingerprint: pairing.fingerprint,
                    credentials: { storage.load()?.1 }, app: "critter-ios/test", onEvent: onEvent
                )
            },
            pairer: Pairer(transport: mac), background: ImmediateRunner(), network: FakeNetwork(),
            onUntoldMac: { untold.macs.append($0) }
        )
        store.setPush(phonePush())
        store.sceneBecameActive()
        #expect(try #require(await mac.nextFrame()) == .hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test"))
        guard case .push(let id, let registration)? = await mac.nextFrame() else {
            Issue.record("expected the registration")
            return
        }
        #expect(registration == phonePush().registration())
        mac.send(.result(id: id, ok: true, reason: nil, message: "已登记"))
        #expect(await becomes { store.pushStatus == "已登记" })

        let pairing = Task { await store.pair(target, deviceName: "iPhone") }
        #expect(try #require(await mac.nextFrame()) == .pair(code: target.code, deviceName: "iPhone"))
        mac.send(.paired(deviceId: "d9", token: "t9", macName: "Pair Mac"))
        guard case .push(let backId, let back)? = await mac.nextFrame() else {
            Issue.record("expected the empty token")
            return
        }
        #expect(back == phonePush().unregistration())
        // Still the old pairing until the old Mac has answered.
        await settle()
        #expect(store.pairing == stored)
        mac.send(.result(id: backId, ok: true, reason: nil, message: nil))
        #expect(await pairing.value == .paired(deviceId: "d9", token: "t9", macName: "Pair Mac"))
        #expect(try #require(await mac.nextFrame()) == .hello(protocolVersion: 1, deviceId: "d9", token: "t9", app: "critter-ios/test"))
        #expect(untold.macs.isEmpty)
        // The new Mac is registered with, and unpairing takes it back from it the same way.
        guard case .push(let newId, let afresh)? = await mac.nextFrame() else {
            Issue.record("expected the new registration")
            return
        }
        #expect(afresh == phonePush().registration())
        mac.send(.result(id: newId, ok: true, reason: nil, message: "已登记"))
        #expect(await becomes { store.pushStatus == "已登记" })
        store.unpair()
        guard case .push(let lastId, let last)? = await mac.nextFrame() else {
            Issue.record("expected the empty token")
            return
        }
        #expect(last.token == "")
        mac.send(.result(id: lastId, ok: true, reason: nil, message: nil))
        #expect(await becomes { mac.openSockets == 0 })
        #expect(untold.macs.isEmpty)
    }

    /// Pairing as the app does it, over the storage the app uses (`DiskPairingStorage`, with the keychain faked): the
    /// next launch is paired with the same Mac, shows the snapshot kept, and says hello with the new credentials.
    @Test func aPairingOnDiskOutlivesARestart() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Pair Mac"
        let folder = StorageFolder()
        defer { folder.remove() }
        let secrets = FakeSecrets()
        func launch(_ storage: DiskPairingStorage) -> BridgeStore {
            BridgeStore(
                storage: storage,
                makeLink: { pairing, onEvent in
                    BridgeClient(
                        transport: mac, endpoint: StaticResolver(pairing.endpoint), fingerprint: pairing.fingerprint,
                        credentials: { storage.load()?.1 }, app: "critter-ios/test", onEvent: onEvent
                    )
                },
                pairer: Pairer(transport: mac), background: ImmediateRunner(), network: FakeNetwork()
            )
        }

        let storage = folder.storage(secrets)
        let first = launch(storage)
        #expect(first.pairing == nil)
        first.sceneBecameActive()
        let pairing = Task { await first.pair(target, deviceName: "iPhone") }
        #expect(try #require(await mac.nextFrame()) == .pair(code: target.code, deviceName: "iPhone"))
        mac.send(.paired(deviceId: "d9", token: "t9", macName: "Pair Mac"))
        mac.send(.welcome(macName: "Pair Mac", version: "1.4.0"))
        #expect(await pairing.value == .paired(deviceId: "d9", token: "t9", macName: "Pair Mac"))
        let hello = ClientMessage.hello(protocolVersion: 1, deviceId: "d9", token: "t9", app: "critter-ios/test")
        #expect(try #require(await mac.nextFrame()) == hello)
        #expect(await becomes { first.conn == .connected(macName: "Pair Mac") })
        mac.send(snapshot(body("a")).serverMessage)
        #expect(await becomes { first.snapshot == body("a") })
        first.sceneEnteredBackground()
        #expect(await becomes { mac.openSockets == 0 })
        storage.waitForSnapshotWrites()

        // The next launch.
        let second = launch(folder.storage(secrets))
        let paired = StoredPairing(endpoint: target.endpoint, fingerprint: target.fingerprint, macName: "Pair Mac", deviceId: "d9")
        #expect(second.pairing == paired)
        #expect(second.snapshot == body("a"))
        #expect(!second.isLive)
        second.sceneBecameActive()
        #expect(try #require(await mac.nextFrame()) == hello)
        #expect(await becomes { second.conn == .connected(macName: "Pair Mac") })
        second.unpair()
        #expect(await becomes { mac.openSockets == 0 })
        #expect(folder.storage(secrets).load() == nil)
    }

    /// The Mac moved (another Wi-Fi, a new DHCP lease) and was found again with Bonjour: from then on, in the same
    /// run, every connection tries the new address first, not the dead one it was paired at.
    @Test func theNextConnectGoesToTheAddressTheMacMovedTo() async throws {
        let mac = FakeMac()
        mac.autoWelcome = "Mac"
        let storage = FakeStorage(journal: Journal(), pairing: stored, snapshot: nil)
        let browser = FakeBrowser([DiscoveredMac(name: "Mac", endpoint: moved)])
        let store = BridgeStore(
            storage: storage,
            makeLink: { pairing, onEvent in
                BridgeClient(
                    transport: mac,
                    // As the app does: the stored address, read before each connection.
                    endpoint: FallbackResolver(
                        lastGood: { storage.load()?.0.endpoint }, macName: pairing.macName, browser: browser
                    ),
                    fingerprint: pairing.fingerprint, credentials: { storage.load()?.1 }, app: "critter-ios/test",
                    onEvent: onEvent, sleep: Sleeper().sleep
                )
            },
            pairer: Pairer(transport: mac), background: ImmediateRunner(), network: FakeNetwork()
        )

        // Nothing answers at the paired address any more; Bonjour finds the Mac at `moved`, which is remembered.
        mac.failNextConnects(.unreachable)
        store.sceneBecameActive()
        #expect(await becomes { store.conn == connected })
        #expect(await becomes { storage.endpointUpdates == [moved] })
        #expect(browser.discoveries == 1)

        // The connection drops: the very next one goes to `moved`, without browsing again.
        mac.drop()
        #expect(await mac.waitForConnects(3))
        #expect(await becomes { store.conn == connected })
        #expect(mac.connects.map { Endpoint(host: $0.host, port: $0.port) } == [home, moved, moved])
        #expect(browser.discoveries == 1)
        store.unpair()
        #expect(await becomes { mac.openSockets == 0 })
    }
}

private extension BridgeEvent {
    var serverMessage: ServerMessage {
        guard case .snapshot(let seq, let sentAt, let body) = self else { fatalError("not a snapshot") }
        return .snapshot(seq: seq, sentAt: sentAt, body: body)
    }
}

/// The Macs the store reported as left without being told (`onUntoldMac`).
@MainActor private final class UntoldMacs {
    var macs: [StoredPairing] = []
}
