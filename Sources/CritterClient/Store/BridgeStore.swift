import CritterKit
import Foundation
import Observation
import os

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
/// - Push: once the app has said what to register (`setPush`), each connection hands it to the Mac after `welcome`
///   when `PushRegistrar` says so; `pushStatus` is what the settings show.
/// - The last snapshot is kept for the next launch at most every 30 seconds (`snapshotWriteInterval`), the newest one;
///   one held back is kept when the app leaves the foreground or the connection ends (Android does the same). It
///   belongs to its pairing: unpaired or paired again, it is dropped.
/// - One pairing attempt at a time: `pair` while one is under way (`isPairing`, from the attempt's start until the new
///   pairing is saved and connecting) returns `.busy` at once.
/// - Leaving a Mac (pairing with another, unpairing) takes its push registration back over its connection first (an
///   empty token, at most `unregisterWait`). A Mac that may still push here and did not confirm (out of reach, silent
///   for 3 s, refused) is reported to the app (`onUntoldMac`), which changes the push key and says so in the settings.
///   A Mac that turned this phone's token away (`denied badToken`: it revoked this phone or was reset, and deleted its
///   device record with the registration) holds nothing: what it confirmed is forgotten, and it is left quietly. Other
///   denials (another protocol, refused) and a certificate that changed say nothing of the record: those are reported.
///   Pairing again with the same Mac (the new pairing's certificate fingerprint is the old one's) is not leaving it:
///   the new pairing registers the same token, and that Mac hands the old record's registration over to it, so nothing
///   is reported.
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
    /// Where a pairing attempt is while it waits for the local network or the Mac; nil once the Mac has answered.
    public private(set) var pairingPhase: PairingPhase?
    /// A `pair` call is under way, from its start until it has returned: past the Mac's answer, while the old
    /// connection is stopped and the new pairing saved.
    public private(set) var isPairing = false
    /// What the paired Mac's latest `welcome` said it runs (e.g. "1.4.0"); kept while the connection is down,
    /// nil until the Mac has welcomed this pairing.
    public private(set) var macVersion: String?

    /// What the phone registers for push, as the app last set it (`setPush`); nil until then, and nothing is
    /// registered.
    public private(set) var push: PushRegistrar?
    /// What the paired Mac last confirmed of it.
    public private(set) var pushAck: PushAck

    /// The settings' line about push (spec §8.8): registered (in the Mac's words), the Mac too old, not registered
    /// yet, or notifications switched off.
    public var pushStatus: String {
        push?.status(acked: pushAck, macVersion: macVersion) ?? PushRegistrar.notRegisteredLine
    }

    /// Whether the Mac can be told something and what is on screen is up to date: connected, and a
    /// snapshot has come since.
    public var canAct: Bool {
        if case .connected = conn { isLive } else { false }
    }

    @ObservationIgnored private let storage: any PairingStorage
    @ObservationIgnored private let makeLink: @MainActor (StoredPairing, @escaping @Sendable (BridgeEvent) -> Void) -> any BridgeLink
    @ObservationIgnored private let pairer: any PairingLink
    @ObservationIgnored private let localNetworkGate: any LocalNetworkGate
    @ObservationIgnored private let background: any BackgroundRunner
    @ObservationIgnored private let backgroundGrace: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pushAcks: any PushAckStorage
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let onUntoldMac: @MainActor (StoredPairing) -> Void
    @ObservationIgnored private var networkPump: Task<Void, Never>?

    /// How long an unpairing waits for the Mac to take the push registration back.
    public static let unregisterWait: Duration = .seconds(3)

    /// At most how often the last snapshot is written for the next launch, in seconds.
    public static let snapshotWriteInterval: TimeInterval = 30

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
    /// The attempt under way waits at `localNetworkGate`.
    @ObservationIgnored private var atLocalNetworkGate = false
    /// A push registration on its way to the Mac.
    @ObservationIgnored private var pushSending = false
    /// What went to the Mac on the current connection: the same registration goes once per connection.
    @ObservationIgnored private var pushSentOnConnection: PushRegistration?
    /// A registration with a token went to this pairing's Mac and the answer was cut off: it may have stored it.
    @ObservationIgnored private var pushCutOff = false
    /// This pairing's Mac turned its token away (`denied badToken`) since it last welcomed it: it no longer lists this
    /// phone, so it has no registration to push with (whatever a cut-off answer left in `pushCutOff`).
    @ObservationIgnored private var macForgotThisPhone = false
    /// When the snapshot written last arrived; nil until one is written for this pairing.
    @ObservationIgnored private var lastSnapshotWrite: Date?
    /// The newest snapshot not written yet, held back by `snapshotWriteInterval`.
    @ObservationIgnored private var heldBackSnapshot: CachedSnapshot?

    /// - Parameters:
    ///   - makeLink: makes the connection for a pairing; it reports its events to the closure it is given.
    ///     Called when the store is created (if paired) and when pairing succeeds; the link is not started.
    ///   - network: tells when the network changed; the store reconnects at once, in the foreground.
    ///   - localNetworkGate: waited on before a pairing reaches the Mac, while iOS asks for or refuses 本地网络; by
    ///     default nothing is waited for.
    ///   - backgroundGrace: how long a move to the background waits for answers on their way.
    ///   - now: stamps the snapshots.
    ///   - pushAcks: keeps what the Mac confirmed of the push registration.
    ///   - sleep: waits out `unregisterWait`.
    ///   - onUntoldMac: a Mac this phone left may still push here (see the type's notes); called on the main actor, when
    ///     pairing again before the new pairing connects.
    public init(
        storage: any PairingStorage,
        makeLink: @escaping @MainActor (StoredPairing, @escaping @Sendable (BridgeEvent) -> Void) -> any BridgeLink,
        pairer: any PairingLink, background: any BackgroundRunner,
        network: any NetworkWatching = NWPathNetworkWatcher(),
        localNetworkGate: any LocalNetworkGate = OpenLocalNetworkGate(),
        backgroundGrace: Duration = .seconds(10), now: @escaping () -> Date = Date.init,
        pushAcks: any PushAckStorage = MemoryPushAckStorage(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onUntoldMac: @escaping @MainActor (StoredPairing) -> Void = { _ in }
    ) {
        self.storage = storage
        self.makeLink = makeLink
        self.pairer = pairer
        self.localNetworkGate = localNetworkGate
        self.background = background
        self.backgroundGrace = backgroundGrace
        self.now = now
        self.pushAcks = pushAcks
        self.sleep = sleep
        self.onUntoldMac = onUntoldMac
        pushAck = PushAck()
        if let (pairing, _) = storage.load() {
            self.pairing = pairing
            pushAck = pushAcks.loadPushAck() ?? PushAck()
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
        writeHeldBackSnapshot()
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

    /// What the phone registers for push changed (a device token, a switch, a Live Activity token): connected, it goes
    /// to the Mac at once if `PushRegistrar` says so; otherwise on the next connection.
    public func setPush(_ registrar: PushRegistrar) {
        guard registrar != push else { return }
        push = registrar
        registerPushIfNeeded()
    }

    /// Hands the registration to the Mac if it needs it: connected (after `welcome`), not already on its way, and not
    /// sent on this connection already. Another change that came meanwhile is sent after the reply.
    private func registerPushIfNeeded() {
        guard case .connected = conn, !pushSending, let registrar = push, let connectionId = connection?.id,
              registrar.shouldSend(acked: pushAck, macVersion: macVersion)
        else { return }
        let sent = registrar.registration()
        guard sent != pushSentOnConnection else { return }
        pushSentOnConnection = sent
        pushSending = true
        let version = macVersion
        Task {
            let reply = await registerPush(sent)
            pushSending = false
            // From a link that was replaced meanwhile (unpaired, paired again): not this pairing's.
            guard connection?.id == connectionId else { return }
            switch reply {
            case .stored: pushCutOff = false
            case .offline where !sent.token.isEmpty: pushCutOff = true
            default: break
            }
            let next = registrar.record(reply: reply, sent: sent, macVersion: version, acked: pushAck)
            if next != pushAck {
                pushAck = next
                pushAcks.savePushAck(next)
            }
            registerPushIfNeeded()
        }
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
    /// nothing changes. While an attempt is under way another is turned away at once (`.busy`), and the one under way
    /// goes on. A pairing the phone cannot keep (`.notSaved`: the keychain refused its token) leaves the old one in
    /// place, and the old one's connection comes back. The Mac being replaced is first asked to take the push
    /// registration back over its connection (at most `unregisterWait`); one that may still push here and did not
    /// confirm is reported (`onUntoldMac`) before the new pairing connects -- unless it is the same Mac (the same
    /// certificate fingerprint), which takes the registration over from the old record itself. The attempt counts as
    /// under way (`isPairing`) until all of that is done.
    ///
    /// Before the Mac is tried, `localNetworkGate` is waited on: while iOS asks for 本地网络 or refuses it the phase is
    /// `waitingForLocalNetwork`, for as long as it takes; cancelled there, the attempt fails as a cancelled connection
    /// does (`unreachable`) and the Mac is never tried.
    public func pair(_ target: PairingTarget, deviceName: String) async -> PairResult {
        guard !isPairing else { return .failed(.busy) }
        isPairing = true
        defer { isPairing = false }
        pairAttempt += 1
        let attempt = pairAttempt
        pairingPhase = .connecting
        atLocalNetworkGate = true
        let usable = await localNetworkGate.waitUntilUsable { [weak self] in
            Task { @MainActor in self?.markWaitingForLocalNetwork(attempt) }
        }
        atLocalNetworkGate = false
        let result: PairResult
        if usable {
            pairingPhase = .connecting
            result = await pairer.pair(target, deviceName: deviceName) { [weak self] in
                Task { @MainActor in self?.markAwaitingApproval(attempt) }
            }
        } else {
            result = .failed(.unreachable)
        }
        pairAttempt += 1
        pairingPhase = nil
        guard case .paired(let deviceId, let token, let macName) = result else { return result }

        // The Mac being left: its registration taken back over its connection, before that stops.
        let left = pairing.map(leaving)
        var told = true
        if let old = detachConnection() {
            // No connection any more: nothing is live while the old one is being stopped.
            conn = .idle
            isLive = false
            told = await leave(old, takingBack: left?.unregistration).value
        }
        let new = StoredPairing(endpoint: target.endpoint, fingerprint: target.fingerprint, macName: macName, deviceId: deviceId)
        guard storage.save(new, token: token) else {
            // The old pairing stays (unpaired meanwhile: nothing to bring back). Its Mac was asked to drop the
            // registration on the way, so it registers afresh when it connects again.
            if left?.unregistration != nil { forgetPushAck() }
            if let pairing, connection == nil { connect(to: pairing) }
            return .failed(.notSaved)
        }
        // The same Mac again (its certificate is the old pairing's) is not left: the new pairing registers the same
        // token and the Mac hands the old record's registration over to it, so there is nothing to warn about and no
        // key to change.
        if let left, left.pairing.fingerprint != new.fingerprint, left.mayStillPush(told: told) { onUntoldMac(left.pairing) }
        pairing = new
        clearLiveState()
        forgetPushAck()
        connect(to: new)
        return result
    }

    /// Makes `pairing`'s connection the store's, and starts it unless the app is in the background.
    private func connect(to pairing: StoredPairing) {
        let connection = makeConnection(for: pairing)
        self.connection = connection
        if boardOpen { applyPingInterval() }
        if sceneActive != false {
            callLink { await connection.link.start() }
        }
    }

    /// Hears from the pairer, off the main actor, that the Mac is being waited for.
    private func markAwaitingApproval(_ attempt: Int) {
        if pairAttempt == attempt, pairingPhase != nil { pairingPhase = .awaitingApproval }
    }

    /// Hears from the gate, off the main actor, that the local network is refused; late (the gate has let the attempt
    /// through, or it ended), it changes nothing.
    private func markWaitingForLocalNetwork(_ attempt: Int) {
        if pairAttempt == attempt, atLocalNetworkGate { pairingPhase = .waitingForLocalNetwork }
    }

    /// Forgets the Mac: stops the connection, deletes the pairing and the cached snapshot. Connected, the connection
    /// first takes the push registration back (an empty token), waiting at most `unregisterWait` for the Mac, so that it
    /// stops pushing (spec §8.8); the phone is unpaired at once all the same. A Mac that may still push here and did not
    /// confirm (offline, silent, refused) is reported (`onUntoldMac`).
    public func unpair() {
        let left = pairing.map(leaving)
        if let old = detachConnection() {
            let call = leave(old, takingBack: left?.unregistration)
            if let left, left.unregistration != nil || left.mayHold {
                // Let the system give it the time even if the app leaves the foreground meanwhile.
                let report = onUntoldMac
                background.run {
                    let told = await call.value
                    if left.mayStillPush(told: told) { report(left.pairing) }
                }
            }
        } else if let left, left.mayStillPush(told: false) {
            onUntoldMac(left.pairing)
        }
        storage.clear()
        pairing = nil
        clearLiveState()
        forgetPushAck()
    }

    /// A new pairing, or none: nothing is confirmed by its Mac yet.
    private func forgetPushAck() {
        pushAck = PushAck()
        pushAcks.savePushAck(nil)
        pushSentOnConnection = nil
        pushCutOff = false
        macForgotThisPhone = false
    }

    /// Whether unpairing now would leave a Mac that may go on pushing here without telling it: it may hold this phone's
    /// registration and there is no connection to take it back over (the unpair dialog says so up front). Connected, the
    /// Mac is asked first, and only one that then does not confirm is reported (`onUntoldMac`).
    public var unpairingLeavesTheMacUntold: Bool {
        guard let pairing else { return false }
        let left = leaving(pairing)
        return left.mayHold && left.unregistration == nil
    }

    /// What leaving a Mac means for its push registration (spec §8.8).
    private struct Leaving {
        let pairing: StoredPairing
        /// The empty token to send over its connection: it may have a registration and is connected. Nil: nothing to
        /// send (nothing to take back, or no connection to take it back over).
        let unregistration: PushRegistration?
        /// It may hold a registration it can push with: it stored one with a token, or one went and the answer was cut
        /// off -- and it has not turned this phone's token away since.
        let mayHold: Bool

        /// Whether it may go on pushing here: it may hold a registration, and did not confirm taking it back.
        func mayStillPush(told: Bool) -> Bool {
            mayHold && !(unregistration != nil && told)
        }
    }

    /// Leaving `pairing`, the paired Mac, as things are now.
    private func leaving(_ pairing: StoredPairing) -> Leaving {
        let takeBack = PushRegistrar.takingBack(push, acked: pushAck, macVersion: macVersion)
        let connected = if case .connected = conn { true } else { false }
        return Leaving(
            pairing: pairing, unregistration: connected ? takeBack : nil,
            mayHold: !macForgotThisPhone && takeBack != nil && (pushAck.holdsRegistration || pushCutOff)
        )
    }

    /// Stops `link`, the connection to a Mac being left, once it has taken `unregistration` over (waiting at most
    /// `unregisterWait` for the Mac). Whether the Mac confirmed it; true when there was nothing to send.
    private func leave(_ link: any BridgeLink, takingBack unregistration: PushRegistration?) -> Task<Bool, Never> {
        let wait = Self.unregisterWait
        let sleep = sleep
        return callLink {
            var told = true
            if let unregistration {
                let reply = await Self.firstOf({ await link.registerPush(unregistration) }, orAfter: wait, sleep: sleep)
                if case .stored? = reply { told = true } else { told = false }
            }
            await link.stop()
            return told
        }
    }

    /// Runs `work` and returns what it gave when it has finished, or nil once `limit` has passed, whichever comes first
    /// (`work` goes on).
    private static func firstOf<T: Sendable>(
        _ work: @escaping @Sendable () async -> T, orAfter limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> T? {
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let finish: @Sendable (T?) -> Void = { value in
                let first = done.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            let timer = Task {
                try? await sleep(limit)
                finish(nil)
            }
            Task {
                let value = await work()
                timer.cancel()
                finish(value)
            }
        }
    }

    /// Nothing is known of any Mac: no snapshot (and none held back to write), no connection.
    private func clearLiveState() {
        macVersion = nil
        snapshot = nil
        snapshotAt = nil
        isLive = false
        conn = .idle
        heldBackSnapshot = nil
        lastSnapshotWrite = nil
    }

    // MARK: - The snapshot cache

    /// Writes `snapshot` for the next launch now, or holds it back if one was written less than
    /// `snapshotWriteInterval` before it (a clock set back writes at once).
    private func keep(_ snapshot: CachedSnapshot) {
        if let last = lastSnapshotWrite {
            let since = snapshot.receivedAt.timeIntervalSince(last)
            if since >= 0, since < Self.snapshotWriteInterval {
                heldBackSnapshot = snapshot
                return
            }
        }
        write(snapshot)
    }

    private func writeHeldBackSnapshot() {
        if let heldBackSnapshot { write(heldBackSnapshot) }
    }

    private func write(_ snapshot: CachedSnapshot) {
        storage.saveSnapshot(snapshot)
        lastSnapshotWrite = snapshot.receivedAt
        heldBackSnapshot = nil
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
    private func callLink<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = lastLinkCall
        let call = Task { @MainActor in
            await previous?.value
            return await work()
        }
        lastLinkCall = Task { _ = await call.value }
        return call
    }

    private func apply(_ event: BridgeEvent, from id: Int) {
        guard connection?.id == id else { return }
        switch event {
        case .state(let state):
            conn = state
            if case .connected = state {
                // `welcome` came (and the Mac's version before it): a new connection, the registration may be due.
                pushSentOnConnection = nil
                macForgotThisPhone = false
                registerPushIfNeeded()
            } else {
                isLive = false
                // The connection ended: what was held back is the latest there is for a while.
                writeHeldBackSnapshot()
            }
        case .snapshot(_, _, let body):
            let receivedAt = now()
            snapshot = body
            snapshotAt = receivedAt
            isLive = true
            keep(CachedSnapshot(body: body, receivedAt: receivedAt))
        case .macVersion(let version):
            macVersion = version
        case .denied(.badToken):
            // The Mac revoked this phone (or was reset): its device record went, and the push registration with it.
            // Leaving it now has nothing to take back, and nothing to warn about.
            forgetPushAck()
            macForgotThisPhone = true
        case .denied:
            // Another protocol, refused: the Mac may still list this phone, with its registration.
            break
        case .connectedTo(let endpoint):
            guard var current = pairing, current.endpoint != endpoint else { return }
            current.endpoint = endpoint
            pairing = current
            storage.updateEndpoint(endpoint)
        }
    }
}
