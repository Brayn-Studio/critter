import CritterKit
import Foundation
import Observation

/// What the phone app knows and does about its Mac: the pairing, the connection's state, the latest
/// snapshot, and the commands it sends. The app creates one and keeps it for as long as it runs.
///
/// - The connection's events arrive in one `AsyncStream` per link and are applied here one after the
///   other, in order. Events of a link that was replaced or dropped are ignored.
/// - The connection exists only while the app is in the foreground: `sceneBecameActive` starts it,
///   `sceneEnteredBackground` stops it once the answers still on their way have been acknowledged (but
///   not later than `backgroundGrace`).
/// - A link the store replaces or drops is always `stop()`ped: the client's own loop keeps it alive
///   until then.
/// - A change of the network (Wi-Fi back, another network) while the app is in the foreground connects at once,
///   cutting a backoff wait short; in the background it is ignored.
@MainActor @Observable
public final class BridgeStore {
    /// The paired Mac; nil until the phone is paired.
    public private(set) var pairing: StoredPairing?
    public private(set) var conn: ConnState = .idle
    /// The latest snapshot: from the current connection, or a cached one (see `isLive`).
    public private(set) var snapshot: SnapshotBody?
    /// When `snapshot` was received.
    public private(set) var snapshotAt: Date?
    /// Whether `snapshot` came over the current connection (not from the cache or an earlier connection).
    public private(set) var isLive = false
    /// Set while a pairing is under way.
    public private(set) var pairingPhase: PairingPhase?
    /// What the paired Mac's latest `welcome` said it runs (e.g. "1.4.0"); kept while the connection is down,
    /// nil until the Mac has welcomed this pairing.
    public private(set) var macVersion: String?

    /// Whether the Mac can be told something and what is on screen is up to date: connected, and a
    /// snapshot has come since.
    public var canAct: Bool {
        if case .connected = conn { isLive } else { false }
    }

    @ObservationIgnored private let storage: any PairingStorage
    @ObservationIgnored private let makeLink: @MainActor (StoredPairing, @escaping @Sendable (BridgeEvent) -> Void) -> any BridgeLink
    @ObservationIgnored private let pairer: any PairingLink
    @ObservationIgnored private let background: any BackgroundRunner
    @ObservationIgnored private let backgroundGrace: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var networkPump: Task<Void, Never>?

    /// How often the Mac is pinged while the board is shut and while it is open, in seconds (spec §8.3).
    public static let restPingInterval: TimeInterval = 60
    public static let boardPingInterval: TimeInterval = 30

    /// Whether the board is on screen. Set it when the board opens and shuts: the connection pings every 30
    /// seconds while it is open (the phone sits on a charger, and a dead connection should show quickly), every
    /// 60 otherwise. A new pairing's connection starts with the same.
    @ObservationIgnored public var boardOpen = false {
        didSet {
            if boardOpen != oldValue { applyPingInterval() }
        }
    }

    /// The link to the paired Mac and what listens to it.
    private struct Connection {
        let id: Int
        let link: any BridgeLink
        let events: AsyncStream<BridgeEvent>.Continuation
        let pump: Task<Void, Never>
    }

    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var connectionCount = 0
    /// The last of the link calls made so far: the next one waits for it.
    @ObservationIgnored private var lastLinkCall: Task<Void, Never>?
    /// Whether the app is in the foreground; nil until the app has said.
    @ObservationIgnored private var sceneActive: Bool?
    /// Counts scene changes: a background shutdown that finds it changed has been overtaken.
    @ObservationIgnored private var sceneChanges = 0
    /// Commands sent and not answered yet.
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var drainWaiters: [DrainWaiter] = []
    @ObservationIgnored private var pairAttempt = 0

    /// - Parameters:
    ///   - makeLink: makes the connection for a pairing; it reports its events to the closure it is given.
    ///     Called when the store is created (if paired) and when pairing succeeds; the link is not started.
    ///   - network: tells when the network changed; the store reconnects at once, in the foreground.
    ///   - backgroundGrace: how long a move to the background waits for answers on their way.
    ///   - now: stamps the snapshots.
    public init(
        storage: any PairingStorage,
        makeLink: @escaping @MainActor (StoredPairing, @escaping @Sendable (BridgeEvent) -> Void) -> any BridgeLink,
        pairer: any PairingLink, background: any BackgroundRunner,
        network: any NetworkWatching = NWPathNetworkWatcher(),
        backgroundGrace: Duration = .seconds(10), now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.makeLink = makeLink
        self.pairer = pairer
        self.background = background
        self.backgroundGrace = backgroundGrace
        self.now = now
        if let (pairing, _) = storage.load() {
            self.pairing = pairing
            if let cached = storage.loadSnapshot() {
                snapshot = cached.body
                snapshotAt = cached.receivedAt
            }
            connection = makeConnection(for: pairing)
        }
        networkPump = Task { [weak self] in
            for await _ in network.changes() {
                guard let self else { return }
                self.networkChanged()
            }
        }
    }

    deinit {
        networkPump?.cancel()
    }

    // MARK: - The scene

    public func sceneBecameActive() {
        sceneActive = true
        sceneChanges += 1
        guard let link = connection?.link else { return }
        callLink { await link.start() }
    }

    /// Stops the connection once the answers on their way have been acknowledged, within `backgroundGrace`.
    public func sceneEnteredBackground() {
        sceneActive = false
        sceneChanges += 1
        guard connection != nil else { return }
        let change = sceneChanges
        background.run { [weak self] in
            await self?.stopAfterInFlight(since: change)
        }
    }

    /// Connects again now, whatever the state: starts the connection if it is not running and cuts a
    /// backoff wait short.
    public func retry() {
        guard let link = connection?.link else { return }
        callLink {
            await link.start()
            await link.reconnectNow()
        }
    }

    /// The network changed: in the foreground, connect again now (a link that is connected ignores it). In the
    /// background there is no connection to mend, and `sceneBecameActive` makes a new one.
    private func networkChanged() {
        guard sceneActive == true, let link = connection?.link else { return }
        callLink { await link.reconnectNow() }
    }

    /// Tells the link how often to ping, for `boardOpen`.
    private func applyPingInterval() {
        guard let link = connection?.link else { return }
        let seconds = boardOpen ? Self.boardPingInterval : Self.restPingInterval
        callLink { await link.setPingInterval(seconds) }
    }

    private func stopAfterInFlight(since change: Int) async {
        await waitForInFlight()
        // Back in the foreground meanwhile: the connection stays.
        guard sceneChanges == change, let link = connection?.link else { return }
        await callLink { await link.stop() }.value
    }

    /// Returns when nothing is in flight, or `backgroundGrace` has passed.
    private func waitForInFlight() async {
        guard inFlight > 0 else { return }
        let waiter = DrainWaiter()
        drainWaiters.append(waiter)
        await waiter.wait(upTo: backgroundGrace)
        drainWaiters.removeAll { $0 === waiter }
    }

    /// Waits for the commands in flight to be answered, or for the grace to pass.
    @MainActor private final class DrainWaiter {
        private var continuation: CheckedContinuation<Void, Never>?
        private var timer: Task<Void, Never>?

        func wait(upTo grace: Duration) async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timer = Task { @MainActor in
                    try? await Task.sleep(for: grace)
                    self.finish()
                }
            }
        }

        func finish() {
            timer?.cancel()
            timer = nil
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Commands

    /// Sends `command` to the Mac and waits for its result. Not paired, or not connected: "未连接".
    public func send(_ command: BridgeCommand) async -> CommandResult {
        guard let link = connection?.link, case .connected = conn else { return .failed("未连接") }
        inFlight += 1
        defer { commandFinished() }
        return await link.request(command)
    }

    /// Tells the Mac how to push to this phone. Only while connected: otherwise `.offline`, and nothing is sent.
    /// An older Mac never answers; after `.noReply` the connection is as it was.
    public func registerPush(_ registration: PushRegistration) async -> PushRegistrationReply {
        guard let link = connection?.link, case .connected = conn else { return .offline }
        inFlight += 1
        defer { commandFinished() }
        return await link.registerPush(registration)
    }

    /// A command in flight has been answered.
    private func commandFinished() {
        inFlight -= 1
        if inFlight == 0 { drainWaiters.forEach { $0.finish() } }
    }

    /// A skin's manifest from the Mac, as JSON (keys in a fixed order, so the same manifest is the same bytes). nil
    /// if the phone is not connected, the Mac has no such skin, or it does not answer.
    public func requestSkin(_ name: String) async -> Data? {
        guard let link = connection?.link, case .connected = conn else { return nil }
        guard let manifest = await link.requestSkin(name) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(manifest)
    }

    // MARK: - Pairing

    /// Pairs with the Mac in `target`. On success the old pairing (if any) and its connection are replaced
    /// by the new, and the new connection is started (unless the app is in the background); on failure
    /// nothing changes.
    public func pair(_ target: PairingTarget, deviceName: String) async -> PairResult {
        pairAttempt += 1
        let attempt = pairAttempt
        pairingPhase = .connecting
        let result = await pairer.pair(target, deviceName: deviceName) { [weak self] in
            Task { @MainActor in self?.markAwaitingApproval(attempt) }
        }
        pairAttempt += 1
        pairingPhase = nil
        guard case .paired(let deviceId, let token, let macName) = result else { return result }

        if let old = detachConnection() {
            // No connection any more: nothing is live while the old one is being stopped.
            conn = .idle
            isLive = false
            await callLink { await old.stop() }.value
        }
        let new = StoredPairing(endpoint: target.endpoint, fingerprint: target.fingerprint, macName: macName, deviceId: deviceId)
        storage.save(new, token: token)
        pairing = new
        clearLiveState()
        let connection = makeConnection(for: new)
        self.connection = connection
        if boardOpen { applyPingInterval() }
        if sceneActive != false {
            callLink { await connection.link.start() }
        }
        return result
    }

    /// Hears from the pairer, off the main actor, that the Mac is being waited for.
    private func markAwaitingApproval(_ attempt: Int) {
        if pairAttempt == attempt, pairingPhase != nil { pairingPhase = .awaitingApproval }
    }

    /// Forgets the Mac: stops the connection, deletes the pairing and the cached snapshot.
    public func unpair() {
        if let old = detachConnection() {
            callLink { await old.stop() }
        }
        storage.clear()
        pairing = nil
        clearLiveState()
    }

    /// Nothing is known of any Mac: no snapshot, no connection.
    private func clearLiveState() {
        macVersion = nil
        snapshot = nil
        snapshotAt = nil
        isLive = false
        conn = .idle
    }

    // MARK: - The link

    private func makeConnection(for pairing: StoredPairing) -> Connection {
        connectionCount += 1
        let id = connectionCount
        let (stream, events) = AsyncStream.makeStream(of: BridgeEvent.self)
        let link = makeLink(pairing) { events.yield($0) }
        let pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event, from: id)
            }
        }
        return Connection(id: id, link: link, events: events, pump: pump)
    }

    /// Lets go of the connection without stopping its link: the caller does that.
    private func detachConnection() -> (any BridgeLink)? {
        guard let connection else { return nil }
        self.connection = nil
        connection.events.finish()
        connection.pump.cancel()
        return connection.link
    }

    /// Runs `work` on the link after every call made before it has finished.
    @discardableResult
    private func callLink(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lastLinkCall
        let call = Task { @MainActor in
            await previous?.value
            await work()
        }
        lastLinkCall = call
        return call
    }

    private func apply(_ event: BridgeEvent, from id: Int) {
        guard connection?.id == id else { return }
        switch event {
        case .state(let state):
            conn = state
            if case .connected = state {} else { isLive = false }
        case .snapshot(_, _, let body):
            let receivedAt = now()
            snapshot = body
            snapshotAt = receivedAt
            isLive = true
            storage.saveSnapshot(CachedSnapshot(body: body, receivedAt: receivedAt))
        case .macVersion(let version):
            macVersion = version
        case .connectedTo(let endpoint):
            guard var current = pairing, current.endpoint != endpoint else { return }
            current.endpoint = endpoint
            pairing = current
            storage.updateEndpoint(endpoint)
        }
    }
}
