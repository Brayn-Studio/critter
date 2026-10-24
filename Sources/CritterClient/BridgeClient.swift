import CritterKit
import Foundation

/// One long-lived, certificate-pinned connection to the Mac, made again whenever it ends, with
/// request/result matching (the Android `BridgeClient`, minus pairing: see `Pairer`).
///
/// A round: no credentials -> `.needsRepair("尚未配对")` and the loop ends; otherwise
/// `.connecting`, resolve the address, connect, send `hello` and wait for the Mac: `welcome`
/// -> `.connected`, `denied` -> `.needsRepair` and the loop ends. A connection that ends (or never
/// comes) fails what was waiting on it with "未连接", then `.offline` for the backoff delay, then
/// the next round. At most one socket is open at any time.
public actor BridgeClient {
    private let transport: any BridgeTransport
    private let endpoint: any EndpointResolver
    private let fingerprint: String
    private let credentials: @Sendable () -> Credentials?
    private let app: String
    private let onEvent: @Sendable (BridgeEvent) -> Void
    private let requestTimeout: Duration
    /// How often a connected socket is pinged; `setPingInterval` changes it while running.
    private var pingInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let pingSleep: @Sendable (Duration) async throws -> Void

    private var state = ConnState.idle
    /// What the Mac's latest `welcome` said it runs; kept when the connection ends.
    public private(set) var macVersion: String?
    private var backoff = ReconnectBackoff()
    /// When the current streak of being offline began; a connection clears it.
    private var offlineSince: Date?

    /// Which `start` the loop belongs to; `stop` moves it on. A loop that is no longer current
    /// (stopped, but still finishing a step) changes nothing.
    private var run = 0
    /// The running loop; nil when there is none (stopped, or it ended by itself).
    private var loop: Task<Void, Never>?
    /// The newest loop, also while it is finishing after a `stop`: the next one waits for it, so
    /// its last socket is closed before the next opens.
    private var newestLoop: Task<Void, Never>?

    private struct Link {
        let socket: any BridgeSocket
        let serial: Int
    }

    /// The one open socket.
    private var current: Link?
    private var linkSerial = 0
    /// Whether the Mac has welcomed `current`. Before that, nothing but `hello` may go out on it:
    /// the Mac refuses any other first frame (protocol doc, "Connection flow").
    private var welcomed = false
    private var heartbeat: Task<Void, Never>?

    private enum Reply: Sendable {
        case reply(ServerMessage)
        case notConnected
        case timedOut
    }

    /// A request waiting for its reply, and the link it went out on: only that link's end fails it.
    private struct Waiter {
        let serial: Int
        let continuation: CheckedContinuation<Reply, Never>
        let timer: Task<Void, Never>
    }

    private var waiters: [String: Waiter] = [:]
    private var lastRequestId = 0

    /// The backoff wait under way: ends when the injected `sleep` returns, or sooner.
    private struct Pause {
        let serial: Int
        let continuation: CheckedContinuation<Void, Never>
        let sleeper: Task<Void, Never>
    }

    private var pause: Pause?
    private var pauseSerial = 0
    /// `reconnectNow` while the state is `.offline` but the wait has not begun: that wait is skipped.
    private var skipNextPause = false

    /// - Parameters:
    ///   - fingerprint: the Mac's certificate fingerprint from pairing; every connection pins it.
    ///   - credentials: read before each round; nil means not paired.
    ///   - app: `hello.app`.
    ///   - onEvent: called on the client's actor, in order.
    ///   - requestTimeout: no reply within it means the connection is broken: it is dropped.
    ///   - pingInterval: how often a connected socket is pinged.
    ///   - sleep: waits out the backoff delay between rounds.
    ///   - pingSleep: waits out the heartbeat: the time between pings and the time a pong may take. Must throw
    ///     when its task is cancelled, as `Task.sleep` does.
    public init(
        transport: any BridgeTransport, endpoint: any EndpointResolver, fingerprint: String,
        credentials: @escaping @Sendable () -> Credentials?, app: String,
        onEvent: @escaping @Sendable (BridgeEvent) -> Void,
        requestTimeout: Duration = .seconds(10), pingInterval: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        pingSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.credentials = credentials
        self.app = app
        self.onEvent = onEvent
        self.requestTimeout = requestTimeout
        self.pingInterval = pingInterval
        self.sleep = sleep
        self.pingSleep = pingSleep
    }

    // MARK: - Control

    /// Starts the connection loop; does nothing while it runs.
    public func start() {
        guard loop == nil else { return }
        run += 1
        let mine = run
        let previous = newestLoop
        let task = Task {
            await previous?.value
            await self.runLoop(mine)
        }
        loop = task
        newestLoop = task
    }

    /// Disconnects and ends the loop. A `start` after it begins afresh: the first wait is the
    /// shortest again.
    public func stop() {
        run += 1
        loop?.cancel()
        loop = nil
        if let current { finish(current.serial) }
        endPause()
        skipNextPause = false
        offlineSince = nil
        backoff.reset()
        setState(.idle)
    }

    /// Connects again without waiting: while offline it cuts the backoff wait short (the wait that follows a
    /// failure is still the next step up). Connected, connecting or stopped, it does nothing: it does not drop a
    /// working connection, and the state does not flicker through `.offline`.
    public func reconnectNow() {
        guard case .offline = state else { return }
        if pause != nil { endPause() } else { skipNextPause = true }
    }

    /// Pings every `seconds` from now on, also while connected: the wait for the next ping is replaced by one of
    /// the new length, counted from now, and a pong is due before the ping after it. The setting outlasts the
    /// connection. Not a positive number of seconds: ignored.
    public func setPingInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        let new = Duration.seconds(seconds)
        guard new != pingInterval else { return }
        pingInterval = new
        if welcomed, let current { startHeartbeat(current) }
    }

    // MARK: - Requests

    /// Sends `command` and waits for the Mac's `result`. Not connected (still connecting, too):
    /// "未连接" at once, without sending. No reply within `requestTimeout`: "超时", and the
    /// connection is dropped (and made again) rather than left looking connected.
    public func request(_ command: BridgeCommand) async -> CommandResult {
        let id = nextRequestId()
        switch await exchange(command.message(id: id), id: id) {
        case .reply(.result(_, let ok, let reason, let message)):
            return CommandResult(ok: ok, reason: reason, message: message)
        case .reply:
            // A `skin` reply carries no `result`; it still settles the request it answers.
            return CommandResult(ok: true, reason: nil, message: nil)
        case .notConnected:
            return .failed("未连接")
        case .timedOut:
            return .failed("超时")
        }
    }

    /// Tells the Mac how to push to this phone. Unlike any other request, no reply within `requestTimeout` is not
    /// a broken connection: an older Mac ignores a frame it does not know, so `.noReply` leaves the connection as
    /// it is. A `result` that comes after that is dropped.
    public func registerPush(_ registration: PushRegistration) async -> PushRegistrationReply {
        let id = nextRequestId()
        switch await exchange(.push(id: id, registration: registration), id: id, dropsConnectionOnTimeout: false) {
        case .reply(.result(_, true, _, let message)):
            return .stored(message)
        case .reply(.result(_, false, _, let message)):
            return .rejected(message)
        case .reply:
            return .rejected(nil)
        case .notConnected:
            return .offline
        case .timedOut:
            return .noReply
        }
    }

    /// A skin's manifest from the Mac. nil if the Mac has no such skin, the connection is down
    /// or it does not answer in time (which drops the connection, as in `request`).
    public func requestSkin(_ name: String) async -> JSONValue? {
        let id = nextRequestId()
        guard case .reply(.skin(_, _, let manifest)) = await exchange(.skin(id: id, name: name), id: id) else { return nil }
        return manifest
    }

    private func nextRequestId() -> String {
        lastRequestId += 1
        return "a\(lastRequestId)"
    }

    /// - Parameter dropsConnectionOnTimeout: whether no reply in time ends the connection (it does for
    ///   everything the Mac always answers) or only the wait.
    private func exchange(_ message: ClientMessage, id: String, dropsConnectionOnTimeout: Bool = true) async -> Reply {
        guard welcomed, let link = current else { return .notConnected }
        let text = Self.text(message)
        let timeout = requestTimeout
        // Both run on this actor, so only once the waiter below is in place.
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.timeOut(id, dropsConnection: dropsConnectionOnTimeout)
        }
        Task {
            do {
                try await link.socket.send(text)
            } catch {
                self.settle(id, .notConnected)
            }
        }
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(serial: link.serial, continuation: continuation, timer: timer)
        }
    }

    private func settle(_ id: String, _ reply: Reply) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: reply)
    }

    /// The Mac answers within milliseconds: none in time means the connection is broken (unless `dropsConnection`
    /// is false, for a frame an older Mac does not answer).
    private func timeOut(_ id: String, dropsConnection: Bool) {
        guard let waiter = waiters[id] else { return }
        settle(id, .timedOut)
        if dropsConnection { finish(waiter.serial) }
    }

    // MARK: - Connection loop

    private enum End {
        /// The connection was made and has ended (or the loop was stopped).
        case ended
        case noAddress
        /// No connection to the resolved address.
        case unreachable
        case pinMismatch
        case denied(DenyReason)
    }

    private func isCurrent(_ mine: Int) -> Bool {
        run == mine && !Task.isCancelled
    }

    private func runLoop(_ mine: Int) async {
        defer { if run == mine { loop = nil } }
        var afterFailure = false
        while isCurrent(mine) {
            guard let credentials = credentials() else {
                setState(.needsRepair(reason: "尚未配对"))
                return
            }
            // A `reconnectNow` from before this round is not meant for the wait after it.
            skipNextPause = false
            setState(.connecting)
            let end = await attempt(credentials, mine: mine, afterFailure: afterFailure)
            guard isCurrent(mine) else { return }
            switch end {
            case .denied(let reason):
                setState(.needsRepair(reason: Self.deniedText(reason)))
                return
            case .pinMismatch:
                setState(.needsRepair(reason: "证书指纹与配对时不一致，请重新配对"))
                return
            case .unreachable:
                afterFailure = true
            case .noAddress, .ended:
                afterFailure = false
            }
            let since = offlineSince ?? Date()
            offlineSince = since
            let delay = backoff.nextDelay()
            setState(.offline(retryIn: delay, since: since))
            await wait(delay)
        }
    }

    /// One connection, from finding the Mac to the connection's end.
    private func attempt(_ credentials: Credentials, mine: Int, afterFailure: Bool) async -> End {
        guard let address = await endpoint.resolve(afterFailure: afterFailure) else { return .noAddress }
        guard isCurrent(mine) else { return .ended }
        let socket: any BridgeSocket
        do {
            socket = try await transport.connect(host: address.host, port: address.port, fingerprint: fingerprint)
        } catch TransportError.pinMismatch {
            return .pinMismatch
        } catch {
            return .unreachable
        }
        guard isCurrent(mine) else {
            socket.close()
            return .ended
        }
        linkSerial += 1
        let link = Link(socket: socket, serial: linkSerial)
        current = link
        let end = await converse(over: link, to: address, credentials: credentials, mine: mine)
        finish(link.serial)
        return end
    }

    /// Says `hello`, then handles what the Mac sends until the connection ends.
    private func converse(over link: Link, to address: Endpoint, credentials: Credentials, mine: Int) async -> End {
        let hello = ClientMessage.hello(
            protocolVersion: BridgeProtocol.version, deviceId: credentials.deviceId, token: credentials.token, app: app
        )
        do {
            try await link.socket.send(Self.text(hello))
            while true {
                let text = try await link.socket.receive()
                guard isCurrent(mine), current?.serial == link.serial else { return .ended }
                guard let message = ServerMessage.decode(Data(text.utf8)) else { continue }
                switch message {
                case .welcome(let macName, let version):
                    guard !welcomed else { continue }
                    welcomed = true
                    macVersion = version
                    onEvent(.macVersion(version))
                    backoff.reset()
                    offlineSince = nil
                    setState(.connected(macName: macName))
                    onEvent(.connectedTo(address))
                    startHeartbeat(link)
                case .denied(let reason):
                    return .denied(reason)
                case .snapshot(let seq, let sentAt, let body):
                    if welcomed { onEvent(.snapshot(seq: seq, sentAt: sentAt, body: body)) }
                case .result(let id?, _, _, _), .skin(let id?, _, _):
                    settle(id, .reply(message))
                case .result(nil, _, _, _), .skin(nil, _, _), .paired:
                    continue
                }
            }
        } catch {
            return .ended
        }
    }

    /// Pings every `pingInterval` (read again before each wait, and the wait begun over when it changes); a
    /// ping that fails, or gets no pong before the next one is due (within `requestTimeout`, if that is sooner),
    /// drops the connection.
    private func startHeartbeat(_ link: Link) {
        heartbeat?.cancel()
        let wait = pingSleep
        heartbeat = Task {
            while !Task.isCancelled {
                let interval = pingInterval
                do { try await wait(interval) } catch { return }
                guard !Task.isCancelled else { return }
                let deadline = min(requestTimeout, interval)
                let overdue = Task {
                    try? await wait(deadline)
                    guard !Task.isCancelled else { return }
                    self.finish(link.serial)
                }
                do {
                    try await link.socket.sendPing()
                    overdue.cancel()
                } catch {
                    overdue.cancel()
                    self.finish(link.serial)
                    return
                }
            }
        }
    }

    /// Closes link `serial` if it is still the open one, and fails what is waiting on it.
    private func finish(_ serial: Int) {
        if let current, current.serial == serial {
            self.current = nil
            welcomed = false
            heartbeat?.cancel()
            heartbeat = nil
            current.socket.close()
        }
        for (id, waiter) in waiters where waiter.serial == serial {
            settle(id, .notConnected)
        }
    }

    /// Waits `delay` with the injected `sleep`, unless `reconnectNow` or `stop` ends it first.
    private func wait(_ delay: Duration) async {
        if skipNextPause {
            skipNextPause = false
            return
        }
        pauseSerial += 1
        let serial = pauseSerial
        let sleep = sleep
        // Runs on this actor, so only once the pause below is in place.
        let sleeper = Task {
            try? await sleep(delay)
            self.endPause(serial)
        }
        await withCheckedContinuation { continuation in
            pause = Pause(serial: serial, continuation: continuation, sleeper: sleeper)
        }
    }

    /// Ends the pause under way (only pause `serial`, if given).
    private func endPause(_ serial: Int? = nil) {
        guard let pause, serial == nil || serial == pause.serial else { return }
        self.pause = nil
        pause.sleeper.cancel()
        pause.continuation.resume()
    }

    private func setState(_ new: ConnState) {
        guard new != state else { return }
        state = new
        onEvent(.state(new))
    }

    static func text(_ message: ClientMessage) -> String {
        String(decoding: message.encode(), as: UTF8.self)
    }

    /// What `.needsRepair` says after `denied` (Android `deniedText`); also what a background answer says then.
    static func deniedText(_ reason: DenyReason) -> String {
        switch reason {
        case .badToken: "这台手机已不在电脑的配对列表里，请重新配对"
        case .protocolMismatch: "协议版本不匹配，请更新 Critter"
        case .badCode, .rejected: "配对被拒绝"
        case .unknown: "连接被电脑拒绝"
        }
    }
}
