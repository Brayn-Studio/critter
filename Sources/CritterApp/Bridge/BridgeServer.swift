import CritterCore
import Foundation
import Network

/// The bridge's network side: a TLS WebSocket listener (Network.framework) on the first free
/// port of `BridgeProtocol.portRange`, advertised over Bonjour, with one `BridgeConnection`
/// state machine per phone. It only moves frames: what they mean is the state machine's
/// business, and pairing decisions are the controller's (`Callbacks`). Who gets in and for
/// how long is `BridgeAdmission`'s.
///
/// Everything runs on `queue` (the bridge queue) and only there, apart from the listener's own
/// events, which hop onto it -- that confinement is what makes the `@unchecked Sendable` sound.
final class BridgeServer: @unchecked Sendable {
    /// What the server reports back, always on `queue`.
    struct Callbacks {
        /// A connection gave a valid pairing code and now waits for `approvePairing` or
        /// `rejectPairing` with this `client` number.
        var pairRequested: (_ client: Int, _ deviceName: String) -> Void
        /// A paired phone's connection became ready or sent something (pings included).
        var deviceActive: (_ deviceId: String) -> Void
        /// Whether phones can reach the listener changed (`isListening`).
        var listeningChanged: (_ listening: Bool) -> Void
        /// The listener broke after it had started; the server has stopped.
        var failed: () -> Void
    }

    /// How long `start` waits for one port's listener to settle.
    private static let bindTimeout: TimeInterval = 3

    private let queue: DispatchQueue
    /// `start` waits on the bridge queue for the listener's state, so the listener reports on a
    /// queue of its own.
    private let listenerQueue = DispatchQueue(label: "local.critter.pet.bridge.listener", qos: .utility)
    private let serviceName: String
    private let makeConnection: () -> BridgeConnection
    /// Numbers clients. The controller owns the count, so a number is never reused by a later
    /// server: a late answer meant for an old server's client can't reach a new one's.
    private let nextClientNumber: () -> Int
    private let callbacks: Callbacks
    private let admission = BridgeAdmission.standard

    private var listener: NWListener?
    /// The listener is ready, so phones can connect. It can also be kept while still
    /// waiting -- for the Local Network permission, or for a network -- and become ready later.
    private(set) var isListening = false
    private var clients: [Int: Client] = [:]

    /// Confined to `queue` like the server itself.
    private final class Client: @unchecked Sendable {
        let number: Int
        let connection: NWConnection
        let machine: BridgeConnection
        /// Closes the connection when its phase's `BridgeAdmission` timeout runs out.
        let deadline: DispatchSourceTimer
        /// The phase `deadline` was last set for.
        var deadlinePhase: BridgeConnection.Phase = .awaitingFirst
        /// The last `seq` sent: snapshots are numbered per connection, from 1.
        var seq = 0
        /// The body of the last snapshot sent, so an unchanged one isn't sent again.
        var lastSnapshot: SnapshotBody?
        var askedForApproval = false
        var closing = false

        init(number: Int, connection: NWConnection, machine: BridgeConnection, deadline: DispatchSourceTimer) {
            self.number = number
            self.connection = connection
            self.machine = machine
            self.deadline = deadline
        }

        var deviceId: String? {
            if case .ready(let id) = machine.phase { return id }
            return nil
        }

        /// What counts against `BridgeAdmission`: a connection on its way out still holds its socket.
        var admissionPhase: BridgeConnection.Phase { closing ? .closed : machine.phase }
    }

    init(
        queue: DispatchQueue, serviceName: String, makeConnection: @escaping () -> BridgeConnection,
        nextClientNumber: @escaping () -> Int, callbacks: Callbacks
    ) {
        self.queue = queue
        self.serviceName = serviceName
        self.makeConnection = makeConnection
        self.nextClientNumber = nextClientNumber
        self.callbacks = callbacks
    }

    /// Whether any phone is paired and connected (snapshots are only built for them).
    var hasReadyClients: Bool {
        clients.values.contains { !$0.closing && $0.deviceId != nil }
    }

    // MARK: - Listening

    /// Listens on the first port of `BridgeProtocol.portRange` that isn't taken and returns it;
    /// `isListening` then tells whether it is reachable yet. Blocks the bridge queue while
    /// binding (at most a few seconds per port).
    func start(identity: SecIdentity) throws -> UInt16 {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        var lastError: Error = NWError.posix(.EADDRINUSE)
        for port in BridgeProtocol.portRange {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { continue }
            let listener: NWListener
            do {
                listener = try NWListener(using: Self.parameters(identity: identity), on: endpointPort)
            } catch {
                lastError = error
                continue
            }
            listener.service = NWListener.Service(name: serviceName, type: BridgeProtocol.bonjourType)
            let outcome = bind(listener)
            if case .failed(let error) = outcome {
                lastError = error
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                continue
            }
            self.listener = listener
            if case .ready = outcome { isListening = true }
            return port
        }
        throw lastError
    }

    /// Stops listening and drops every connection.
    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isListening = false
        for client in clients.values {
            client.deadline.cancel()
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        clients = [:]
    }

    /// Starts `listener` and waits until it is listening, has failed, or is waiting (or still
    /// silent after `bindTimeout`) -- the last two are kept, since a listener waiting for the
    /// Local Network permission or a network becomes ready by itself. Only a taken port is a
    /// reason to move on to the next one.
    private func bind(_ listener: NWListener) -> BindOutcome.Result {
        let settled = DispatchSemaphore(value: 0)
        let outcome = BindOutcome()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if outcome.settle(.ready) { settled.signal() }
            case .waiting(let error):
                if outcome.settle(Self.isPortTaken(error) ? .failed(error) : .pending) { settled.signal() }
            case .failed(let error):
                if outcome.settle(.failed(error)) { settled.signal() }
            default:
                break
            }
            // Every change also goes to the bridge queue, where it only counts for the
            // listener that was kept (it runs after `start` returns).
            guard let self, let listener else { return }
            self.queue.async { self.listenerStateChanged(listener, state) }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.queue.async { self.accept(connection, from: listener) }
        }
        listener.start(queue: listenerQueue)
        if settled.wait(timeout: .now() + Self.bindTimeout) == .timedOut {
            _ = outcome.settle(.pending)
        }
        return outcome.result ?? .pending
    }

    private func listenerStateChanged(_ changed: NWListener, _ state: NWListener.State) {
        guard changed === listener else { return }
        switch state {
        case .ready:
            setListening(true)
        case .waiting(let error):
            DiagnosticLog.shared.log("bridge listener waiting: \(error)")
            setListening(false)
        case .failed(let error):
            DiagnosticLog.shared.log("bridge listener failed: \(error)")
            stop()
            callbacks.failed()
        default:
            break
        }
    }

    private func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        callbacks.listeningChanged(listening)
    }

    private static func isPortTaken(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    private static func parameters(identity: SecIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = BridgeProtocol.maxFrameBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    // MARK: - Connections

    /// Cancelled right away: a connection from outside the private networks, one beyond
    /// `BridgeAdmission`'s caps, and one that arrives from a listener since stopped.
    private func accept(_ connection: NWConnection, from origin: NWListener) {
        guard origin === listener, let host = Self.host(of: connection.endpoint), PrivateNetwork.isAllowed(host: host),
              admission.admits(open: clients.values.map(\.admissionPhase))
        else {
            connection.cancel()
            return
        }
        let number = nextClientNumber()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        let client = Client(number: number, connection: connection, machine: makeConnection(), deadline: deadline)
        clients[number] = client
        deadline.setEventHandler { [weak self] in self?.close(number) }
        deadline.schedule(deadline: .now() + (admission.timeout(for: .awaitingFirst) ?? 0))
        deadline.resume()
        // A started connection must be cancelled once it's no longer needed -- a failed one
        // too -- and is only forgotten when that has happened.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: self?.abandon(number)
            case .cancelled: self?.forget(number)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: client)
    }

    private func receive(on client: Client) {
        client.connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, self.clients[client.number] === client, !client.closing else { return }
            guard error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            else {
                self.close(client.number)
                return
            }
            switch metadata.opcode {
            case .text, .binary:
                self.perform(client.machine.receive(content ?? Data()), on: client)
            case .close:
                self.close(client.number)
            default:
                break // ping (answered by `autoReplyPing`), pong, continuation
            }
            guard !client.closing else { return }
            self.resetDeadline(client, traffic: true)
            if let deviceId = client.deviceId { self.callbacks.deviceActive(deviceId) }
            self.receive(on: client)
        }
    }

    /// A new phase gets its own timeout; within a phase, only a paired phone's traffic
    /// starts it over (pings can't keep an unauthenticated connection open).
    private func resetDeadline(_ client: Client, traffic: Bool) {
        let phase = client.machine.phase
        guard phase != client.deadlinePhase || (traffic && admission.trafficExtends(phase)) else { return }
        client.deadlinePhase = phase
        guard let timeout = admission.timeout(for: phase) else { return }
        client.deadline.schedule(deadline: .now() + timeout)
    }

    private func perform(_ outputs: [BridgeConnection.Output], on client: Client) {
        for output in outputs {
            switch output {
            case .send(let message): send(message, to: client)
            case .close: close(client.number)
            }
        }
        if case .awaitingApproval(let deviceName) = client.machine.phase, !client.askedForApproval {
            client.askedForApproval = true
            callbacks.pairRequested(client.number, deviceName)
        }
    }

    private func send(_ message: ServerMessage, to client: Client) {
        guard !client.closing else { return }
        var frame = message
        if case .snapshot(_, let sentAt, let body) = message {
            guard body != client.lastSnapshot else { return }
            client.lastSnapshot = body
            client.seq += 1
            frame = .snapshot(seq: client.seq, sentAt: sentAt, body: body)
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        let number = client.number
        client.connection.send(content: frame.encode(), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close(number) }
        })
    }

    /// Sends a WebSocket close after whatever is already queued, then cancels the connection
    /// (forcibly, if the peer doesn't take the close within two seconds).
    private func close(_ number: Int) {
        guard let client = clients[number], !client.closing else { return }
        client.closing = true
        client.deadline.cancel()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = client.connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 2) { connection.forceCancel() }
    }

    /// The connection failed (a refused TLS handshake, a reset): nothing more can be sent, so
    /// it is just cancelled.
    private func abandon(_ number: Int) {
        guard let client = clients[number] else { return }
        client.closing = true
        client.deadline.cancel()
        client.connection.cancel()
    }

    private func forget(_ number: Int) {
        guard let client = clients.removeValue(forKey: number) else { return }
        client.deadline.cancel()
    }

    // MARK: - Driven by the controller

    /// Sends `snapshot` to every paired connection whose last snapshot differs.
    func broadcast(_ snapshot: ServerMessage) {
        for client in clients.values.sorted(by: { $0.number < $1.number }) {
            perform(client.machine.broadcast(snapshot), on: client)
        }
    }

    func isAwaitingApproval(_ number: Int) -> Bool {
        guard let client = clients[number], !client.closing, case .awaitingApproval = client.machine.phase else { return false }
        return true
    }

    func approvePairing(_ number: Int, deviceId: String, token: String) {
        guard let client = clients[number] else { return }
        perform(client.machine.approvePairing(deviceId: deviceId, token: token), on: client)
        guard !client.closing else { return }
        resetDeadline(client, traffic: false)
        if let deviceId = client.deviceId { callbacks.deviceActive(deviceId) }
    }

    func rejectPairing(_ number: Int) {
        guard let client = clients[number] else { return }
        perform(client.machine.rejectPairing(), on: client)
    }

    /// Closes every connection of a device (it was just revoked).
    func disconnect(deviceId: String) {
        for client in clients.values where client.deviceId == deviceId {
            close(client.number)
        }
    }

    /// The peer's address as text, for `PrivateNetwork.isAllowed`.
    private static func host(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return IPAddress.string(address.rawValue)
        case .ipv6(let address): return IPAddress.string(address.rawValue)
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}

/// The first report that settles `bind`, set from the listener's queue and read on the bridge
/// queue after the semaphore.
private final class BindOutcome: @unchecked Sendable {
    enum Result {
        case ready
        /// Waiting, or nothing reported in time: kept, it may still become ready.
        case pending
        case failed(Error)
    }

    private let lock = NSLock()
    private var settled: Result?

    /// Records the outcome unless one already was; returns whether this call did.
    func settle(_ result: Result) -> Bool {
        lock.withLock {
            guard settled == nil else { return false }
            settled = result
            return true
        }
    }

    var result: Result? { lock.withLock { settled } }
}
