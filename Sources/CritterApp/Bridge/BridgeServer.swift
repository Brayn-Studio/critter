import CritterCore
import Foundation
import Network

/// The bridge's network side: a TLS WebSocket listener (Network.framework) on the first free
/// port of `BridgeProtocol.portRange`, advertised over Bonjour, with one `BridgeConnection`
/// state machine per phone. It only moves frames: what they mean is the state machine's
/// business, and pairing decisions are the controller's (`Callbacks`).
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
        /// The listener broke after it had started; the server has stopped.
        var failed: () -> Void
    }

    /// A connection that sends nothing at all (not even a ping) for this long is closed.
    static let idleTimeout: TimeInterval = 600
    /// How long `start` waits for one port to be bound.
    private static let bindTimeout: TimeInterval = 3

    private let queue: DispatchQueue
    /// `start` waits on the bridge queue for the listener's state, so the listener reports on a
    /// queue of its own.
    private let listenerQueue = DispatchQueue(label: "local.critter.pet.bridge.listener", qos: .utility)
    private let serviceName: String
    private let makeConnection: () -> BridgeConnection
    private let callbacks: Callbacks

    private var listener: NWListener?
    private var clients: [Int: Client] = [:]
    private var lastClientNumber = 0

    /// Confined to `queue` like the server itself.
    private final class Client: @unchecked Sendable {
        let number: Int
        let connection: NWConnection
        let machine: BridgeConnection
        let idleTimer: DispatchSourceTimer
        /// The last `seq` sent: snapshots are numbered per connection, from 1.
        var seq = 0
        /// The body of the last snapshot sent, so an unchanged one isn't sent again.
        var lastSnapshot: SnapshotBody?
        var askedForApproval = false
        var closing = false

        init(number: Int, connection: NWConnection, machine: BridgeConnection, idleTimer: DispatchSourceTimer) {
            self.number = number
            self.connection = connection
            self.machine = machine
            self.idleTimer = idleTimer
        }

        var deviceId: String? {
            if case .ready(let id) = machine.phase { return id }
            return nil
        }
    }

    init(queue: DispatchQueue, serviceName: String, makeConnection: @escaping () -> BridgeConnection, callbacks: Callbacks) {
        self.queue = queue
        self.serviceName = serviceName
        self.makeConnection = makeConnection
        self.callbacks = callbacks
    }

    /// Whether any phone is paired and connected (snapshots are only built for them).
    var hasReadyClients: Bool {
        clients.values.contains { !$0.closing && $0.deviceId != nil }
    }

    // MARK: - Listening

    /// Listens on the first port of `BridgeProtocol.portRange` that can be bound and returns
    /// it. Blocks the bridge queue while binding (at most a few seconds per port).
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
            if let error = bind(listener) {
                lastError = error
                continue
            }
            self.listener = listener
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
        for client in clients.values {
            client.idleTimer.cancel()
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        clients = [:]
    }

    /// Starts `listener` and waits until it is listening (nil) or has failed (the error).
    private func bind(_ listener: NWListener) -> Error? {
        let settled = DispatchSemaphore(value: 0)
        let outcome = BindOutcome()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                if outcome.settle(nil) { settled.signal() }
            case .failed(let error):
                if outcome.settle(error) {
                    settled.signal()
                } else if let self, let listener {
                    // Broke later (after `start` returned).
                    self.queue.async { self.listenerFailed(listener, error) }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.queue.async { self.accept(connection, from: listener) }
        }
        listener.start(queue: listenerQueue)
        if settled.wait(timeout: .now() + Self.bindTimeout) == .timedOut, outcome.settle(NWError.posix(.ETIMEDOUT)) {
            listener.stateUpdateHandler = nil
            listener.cancel()
            return NWError.posix(.ETIMEDOUT)
        }
        guard let error = outcome.error else { return nil }
        listener.stateUpdateHandler = nil
        listener.cancel()
        return error
    }

    private func listenerFailed(_ failed: NWListener, _ error: NWError) {
        guard failed === listener else { return }
        DiagnosticLog.shared.log("bridge listener failed: \(error)")
        stop()
        callbacks.failed()
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

    /// Every connection from outside the private networks is cancelled right away, as is
    /// one that arrives from a listener that has since been stopped.
    private func accept(_ connection: NWConnection, from origin: NWListener) {
        guard origin === listener, let host = Self.host(of: connection.endpoint), PrivateNetwork.isAllowed(host: host) else {
            connection.cancel()
            return
        }
        lastClientNumber += 1
        let number = lastClientNumber
        let idleTimer = DispatchSource.makeTimerSource(queue: queue)
        let client = Client(number: number, connection: connection, machine: makeConnection(), idleTimer: idleTimer)
        clients[number] = client
        idleTimer.setEventHandler { [weak self] in self?.close(number) }
        idleTimer.schedule(deadline: .now() + Self.idleTimeout)
        idleTimer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.forget(number)
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
            client.idleTimer.schedule(deadline: .now() + Self.idleTimeout)
            switch metadata.opcode {
            case .text, .binary:
                self.perform(client.machine.receive(content ?? Data()), on: client)
            case .close:
                self.close(client.number)
            default:
                break // ping (answered by `autoReplyPing`), pong, continuation
            }
            guard !client.closing else { return }
            if let deviceId = client.deviceId { self.callbacks.deviceActive(deviceId) }
            self.receive(on: client)
        }
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
        client.idleTimer.cancel()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = client.connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 2) { connection.forceCancel() }
    }

    private func forget(_ number: Int) {
        guard let client = clients.removeValue(forKey: number) else { return }
        client.idleTimer.cancel()
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
        case .ipv4(let address): return numeric(AF_INET, address.rawValue)
        case .ipv6(let address): return numeric(AF_INET6, address.rawValue)
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    private static func numeric(_ family: Int32, _ raw: Data) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { bytes in
            inet_ntop(family, bytes.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The first of a listener's ready/failed reports while `bind` waits, set from the listener's
/// queue and read on the bridge queue after the semaphore.
private final class BindOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var result: Error?

    /// Records the outcome unless one already was; returns whether this call did.
    func settle(_ error: Error?) -> Bool {
        lock.withLock {
            guard !settled else { return false }
            settled = true
            result = error
            return true
        }
    }

    var error: Error? { lock.withLock { result } }
}
