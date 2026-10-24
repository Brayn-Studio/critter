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

    init(_ start: Date) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }
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

    func load() -> (StoredPairing, Credentials)? {
        state.withLock { s in
            guard let pairing = s.pairing, let token = s.token else { return nil }
            return (pairing, Credentials(deviceId: pairing.deviceId, token: token))
        }
    }

    func save(_ pairing: StoredPairing, token: String) {
        journal.add("save")
        state.withLock { s in
            s.pairing = pairing
            s.token = token
            s.saves.append(Saved(pairing: pairing, token: token))
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Requests held by `holdRequests()` wait here.
    let release = Gate(open: false)

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

    /// The link reports `event`, as the client does.
    func emit(_ event: BridgeEvent) { onEvent(event) }

    /// From now on a request does not return until `release` is opened.
    func holdRequests() { state.withLock { $0.holdRequests = true } }

    func reply(with result: CommandResult) { state.withLock { $0.reply = result } }

    /// From now on the Mac has a skin of this name, with this manifest.
    func serve(_ manifest: JSONValue, named name: String) { state.withLock { $0.skins[name] = manifest } }

    func start() async {
        journal.add("start \(index)")
        state.withLock { $0.starts += 1 }
    }

    func stop() async {
        journal.add("stop \(index)")
        state.withLock { $0.stops += 1 }
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

    init(journal: Journal, outcome: PairResult, slow: Bool) {
        self.journal = journal
        self.outcome = OSAllocatedUnfairLock(initialState: outcome)
        reachMac = Gate(open: !slow)
        approval = Gate(open: !slow)
    }

    func answer(with result: PairResult) { outcome.withLock { $0 = result } }

    func pair(
        _ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void
    ) async -> PairResult {
        journal.add("pair \(target.code) \(deviceName)")
        await reachMac.wait()
        onAwaitingApproval()
        await approval.wait()
        return outcome.withLock { $0 }
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
    let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
    let storage: FakeStorage
    let pairer: FakePairer
    let runner = ImmediateRunner()
    let network = FakeNetwork()
    private(set) var links: [FakeLink] = []

    init(paired: Bool = true, cached: CachedSnapshot? = nil, slowPairing: Bool = false) {
        storage = FakeStorage(journal: journal, pairing: paired ? stored : nil, snapshot: cached)
        pairer = FakePairer(journal: journal, outcome: .paired(deviceId: "d2", token: "t2", macName: "New Mac"), slow: slowPairing)
    }

    func makeStore(grace: Duration = .seconds(10)) -> BridgeStore {
        BridgeStore(
            storage: storage,
            makeLink: { _, onEvent in
                let link = FakeLink(index: self.links.count, journal: self.journal, onEvent: onEvent)
                self.links.append(link)
                return link
            },
            pairer: pairer, background: runner, network: network, backgroundGrace: grace, now: { [clock] in clock.now }
        )
    }

    var link: FakeLink { links[0] }
}

private let target = PairingTarget(
    endpoint: Endpoint(host: "192.168.1.30", port: 47824), fingerprint: String(repeating: "cd", count: 32),
    code: "K7M2QX9P", macName: "Pair Mac"
)

private let answer = BridgeCommand.answer(requestId: "r1", payload: AnswerPayload(decision: "allow"))

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
        let rig = Rig()
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
