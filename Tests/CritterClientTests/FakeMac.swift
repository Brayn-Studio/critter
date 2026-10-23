import CritterClient
import CritterKit
import Foundation
import os
import Testing

/// A stand-in for the Mac behind `BridgeTransport`, without a network: every socket is a pair of
/// in-memory queues. Records each `connect`, can make the next ones fail, and counts how many
/// sockets are open at once. The test side reads what the phone sent (`nextFrame`) and talks to
/// the phone over the newest open socket (`send`, `sendRaw`, `drop`).
final class FakeMac: BridgeTransport {
    struct Connect: Equatable, Sendable {
        var host: String
        var port: UInt16
        var fingerprint: String?
    }

    private struct State {
        var connects: [Connect] = []
        var failures: [TransportError] = []
        var sockets: [FakeSocket] = []
        var open = 0
        var maxOpen = 0
        var received: [ClientMessage] = []
        var read = 0
        var pingError: TransportError?
        var pingHangs = false
        var peerFingerprint: String?
        var autoWelcome: String?
        var connectDelay: Duration?
        var finishedConnects = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: Test side

    var connects: [Connect] { state.withLock { $0.connects } }
    /// How many `connect` calls have returned or thrown.
    var finishedConnects: Int { state.withLock { $0.finishedConnects } }
    /// Sockets open right now.
    var openSockets: Int { state.withLock { $0.open } }
    /// The most sockets that were ever open at the same time.
    var maxOpenSockets: Int { state.withLock { $0.maxOpen } }
    /// Every frame the phone sent, on any socket, in order.
    var received: [ClientMessage] { state.withLock { $0.received } }

    /// What `sendPing` throws on every socket (nil: the pong comes at once).
    var pingError: TransportError? {
        get { state.withLock { $0.pingError } }
        set { state.withLock { $0.pingError = newValue } }
    }

    /// While set, a ping gets no pong: `sendPing` waits until the socket ends.
    var pingHangs: Bool {
        get { state.withLock { $0.pingHangs } }
        set { state.withLock { $0.pingHangs = newValue } }
    }

    /// The certificate fingerprint sockets opened from now on report.
    var peerFingerprint: String? {
        get { state.withLock { $0.peerFingerprint } }
        set { state.withLock { $0.peerFingerprint = newValue } }
    }

    /// While set, the Mac answers every `hello` with a `welcome` from a Mac of this name, on the
    /// socket the hello came over.
    var autoWelcome: String? {
        get { state.withLock { $0.autoWelcome } }
        set { state.withLock { $0.autoWelcome = newValue } }
    }

    /// While set, a connect takes this long, cancelled or not (as a TLS handshake under way would).
    var connectDelay: Duration? {
        get { state.withLock { $0.connectDelay } }
        set { state.withLock { $0.connectDelay = newValue } }
    }

    /// The next `times` connects throw `error` (after being recorded).
    func failNextConnects(_ error: TransportError, times: Int = 1) {
        state.withLock { $0.failures += Array(repeating: error, count: times) }
    }

    /// The next frame the phone sent that the test has not read yet; nil if none comes within 2 s.
    func nextFrame() async -> ClientMessage? {
        guard await eventually({ self.state.withLock { $0.read < $0.received.count } }) else { return nil }
        return state.withLock { s in
            defer { s.read += 1 }
            return s.received[s.read]
        }
    }

    /// Waits (at most 2 s) until the phone has connected `count` times in all.
    func waitForConnects(_ count: Int) async -> Bool {
        await eventually { self.connects.count >= count }
    }

    /// Sends `message` to the phone over the newest open socket.
    func send(_ message: ServerMessage) {
        sendRaw(String(decoding: message.encode(), as: UTF8.self))
    }

    func sendRaw(_ text: String) {
        newestOpen()?.deliver(text)
    }

    /// Ends the newest open socket from the Mac's side.
    func drop(cleanly: Bool = false) {
        newestOpen()?.end(.closed(cleanly: cleanly))
    }

    private func newestOpen() -> FakeSocket? {
        state.withLock { $0.sockets.last { !$0.isClosed } }
    }

    // MARK: BridgeTransport

    func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket {
        let delay = state.withLock { s in
            s.connects.append(Connect(host: host, port: port, fingerprint: fingerprint))
            return s.connectDelay
        }
        if let delay {
            // Not a child task: the caller's cancellation does not cut it short.
            await Task { try? await Task.sleep(for: delay) }.value
        }
        return try state.withLock { s in
            s.finishedConnects += 1
            if !s.failures.isEmpty { throw s.failures.removeFirst() }
            let socket = FakeSocket(mac: self, peerFingerprint: s.peerFingerprint)
            s.sockets.append(socket)
            s.open += 1
            s.maxOpen = max(s.maxOpen, s.open)
            return socket
        }
    }

    // MARK: Called by the sockets

    fileprivate func phoneSent(_ text: String, on socket: FakeSocket) {
        guard let message = ClientMessage.decode(Data(text.utf8)) else {
            Issue.record("the phone sent a frame the Mac cannot decode: \(text)")
            return
        }
        let welcome = state.withLock { s in
            s.received.append(message)
            return s.autoWelcome
        }
        if case .hello = message, let welcome {
            socket.deliver(String(decoding: ServerMessage.welcome(macName: welcome, version: "1.4.0").encode(), as: UTF8.self))
        }
    }

    fileprivate func socketEnded() {
        state.withLock { $0.open -= 1 }
    }

    fileprivate var pingBehaviour: (error: TransportError?, hangs: Bool) {
        state.withLock { ($0.pingError, $0.pingHangs) }
    }
}

/// The phone's end of one `FakeMac` connection.
final class FakeSocket: BridgeSocket {
    private struct State {
        var toPhone: [String] = []
        var receiver: CheckedContinuation<String, any Error>?
        var pingWaiters: [CheckedContinuation<Void, any Error>] = []
        var ended: TransportError?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let mac: FakeMac
    let peerFingerprint: String?

    fileprivate init(mac: FakeMac, peerFingerprint: String?) {
        self.mac = mac
        self.peerFingerprint = peerFingerprint
    }

    var isClosed: Bool { state.withLock { $0.ended != nil } }

    func send(_ text: String) async throws {
        if let ended = state.withLock({ $0.ended }) { throw ended }
        mac.phoneSent(text, on: self)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let now: Result<String, any Error>? = state.withLock { s in
                if !s.toPhone.isEmpty { return .success(s.toPhone.removeFirst()) }
                if let ended = s.ended { return .failure(ended) }
                s.receiver = continuation
                return nil
            }
            if let now { continuation.resume(with: now) }
        }
    }

    func sendPing() async throws {
        let (error, hangs) = mac.pingBehaviour
        if let error { throw error }
        guard hangs else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let ended: TransportError? = state.withLock { s in
                if let ended = s.ended { return ended }
                s.pingWaiters.append(continuation)
                return nil
            }
            if let ended { continuation.resume(throwing: ended) }
        }
    }

    func close() {
        end(.closed(cleanly: false))
    }

    /// A frame from the Mac.
    fileprivate func deliver(_ text: String) {
        let receiver: CheckedContinuation<String, any Error>? = state.withLock { s in
            guard s.ended == nil else { return nil }
            if let receiver = s.receiver {
                s.receiver = nil
                return receiver
            }
            s.toPhone.append(text)
            return nil
        }
        receiver?.resume(returning: text)
    }

    /// Ends the connection (once): what is waiting on it throws `error`.
    fileprivate func end(_ error: TransportError) {
        let waiting: (CheckedContinuation<String, any Error>?, [CheckedContinuation<Void, any Error>])? = state.withLock { s in
            guard s.ended == nil else { return nil }
            s.ended = error
            defer { s.receiver = nil; s.pingWaiters = [] }
            return (s.receiver, s.pingWaiters)
        }
        guard let (receiver, pings) = waiting else { return }
        mac.socketEnded()
        receiver?.resume(throwing: error)
        pings.forEach { $0.resume(throwing: error) }
    }
}

/// Every event a client reported, in order (recorded synchronously, so the order is kept).
final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock(initialState: [BridgeEvent]())

    var record: @Sendable (BridgeEvent) -> Void {
        { [events] event in events.withLock { $0.append(event) } }
    }

    var all: [BridgeEvent] { events.withLock { $0 } }

    var states: [ConnState] {
        all.compactMap { if case .state(let state) = $0 { state } else { nil } }
    }

    /// The `since` of every `.offline` state, in order.
    var offlineSince: [Date] {
        states.compactMap { if case .offline(_, let since) = $0 { since } else { nil } }
    }

    /// Waits (at most 2 s) until `condition` holds for the events so far.
    func waitFor(_ condition: @escaping ([BridgeEvent]) -> Bool) async -> Bool {
        await eventually { condition(self.all) }
    }

    /// Waits (at most 2 s) until the latest state is `state`.
    func waitForState(_ state: ConnState) async -> Bool {
        await eventually { self.states.last == state }
    }
}

/// The client's backoff sleep: records every delay asked for, then returns at once, after a
/// short real pause, or not until cancelled.
final class Sleeper: Sendable {
    enum Mode: Sendable {
        case returnAtOnce
        case after(Duration)
        case hold
    }

    private let mode: Mode
    private let calls = OSAllocatedUnfairLock(initialState: [Duration]())

    init(_ mode: Mode = .returnAtOnce) {
        self.mode = mode
    }

    var delays: [Duration] { calls.withLock { $0 } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [calls, mode] delay in
            calls.withLock { $0.append(delay) }
            switch mode {
            case .returnAtOnce: return
            case .after(let pause): try await Task.sleep(for: pause)
            case .hold: try await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func waitForDelays(_ count: Int) async -> Bool {
        await eventually { self.delays.count >= count }
    }
}

/// Always the same address; records each `afterFailure` it was asked with.
final class FixedResolver: EndpointResolver {
    let endpoint: Endpoint
    private let asked = OSAllocatedUnfairLock(initialState: [Bool]())

    init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    var afterFailure: [Bool] { asked.withLock { $0 } }

    func resolve(afterFailure: Bool) async -> Endpoint? {
        asked.withLock { $0.append(afterFailure) }
        return endpoint
    }
}

/// Finds what it was given, and counts how often it was asked.
final class FakeBrowser: MacBrowser {
    let macs: [DiscoveredMac]
    private let asked = OSAllocatedUnfairLock(initialState: 0)

    init(_ macs: [DiscoveredMac]) {
        self.macs = macs
    }

    var discoveries: Int { asked.withLock { $0 } }

    func discover() async -> [DiscoveredMac] {
        asked.withLock { $0 += 1 }
        return macs
    }
}

/// Polls `condition` every 2 ms until it holds or `limit` has passed; whether it held.
func eventually(within limit: Duration = .seconds(2), _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Lets anything already under way happen (for checking that something did *not* happen).
func settle() async {
    try? await Task.sleep(for: .milliseconds(100))
}

extension ClientMessage {
    /// The correlation id of a command frame.
    var commandId: String? {
        switch self {
        case .answer(let id, _, _), .seen(let id, _), .say(let id, _, _), .interrupt(let id, _), .skin(let id, _): id
        case .hello, .pair: nil
        }
    }
}

let emptySnapshot = SnapshotBody(
    sessions: [], pending: [],
    prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 0.6, mergeThreshold: 5, soundTheme: "pixel")
)
