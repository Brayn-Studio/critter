import CritterKit
import Foundation
import os

/// The real transport: `wss://` over URLSession, pinned to the Mac's self-signed certificate
/// (the approach of `critter-bridge-client`'s `PinningDelegate`).
public final class URLSessionTransport: BridgeTransport {
    /// The largest message accepted. Mac -> phone frames are not capped (a snapshot carries
    /// commands and plans in full and can be larger than 1 MiB): this is far above what a
    /// snapshot needs, so one never ends the connection.
    public static let maxMessageBytes = 64 << 20

    /// How long a connection may take to open (TCP, TLS, the WebSocket upgrade). On a LAN that is
    /// well under a second; without it URLSession waits 60 s for a Mac that took the connection and
    /// never answered. It bounds the opening only: an open WebSocket, idle or waiting for the Mac to
    /// approve a pairing, is not timed.
    public static let connectTimeout: Duration = .seconds(6)

    private let connectTimeout: Duration

    public init(connectTimeout: Duration = URLSessionTransport.connectTimeout) {
        self.connectTimeout = connectTimeout
    }

    /// Each connection gets an ephemeral URLSession of its own; it counts as made once the
    /// WebSocket is open. A host `url(host:port:)` refuses -> `.unreachable` at once, without
    /// touching the network. A certificate that is not the pinned one -> `.pinMismatch`; no
    /// certificate to check the pin against, not open within `connectTimeout`, or any other
    /// failure before the WebSocket opens -> `.unreachable`.
    public func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket {
        guard let url = Self.url(host: host, port: port) else { throw TransportError.unreachable }
        let socket = URLSessionSocket(url: url, fingerprint: fingerprint)
        do {
            try await socket.open(within: connectTimeout)
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// `wss://<host>:<port>/` for an IP address on a private network (`PrivateNetwork`), else nil.
    /// Every pairing, connection and probe comes through here, wherever the host came from (a
    /// scanned QR code, a stored address, typing).
    ///
    /// The host must be an IP literal: IPv4, or IPv6 (brackets optional) with at most a zone made of
    /// `A-Z a-z 0-9 . _ ~ -` (`fe80::1%en0` -> `[fe80::1%25en0]`). `PrivateNetwork` ignores what
    /// follows a `%`, so `10.0.0.1%2Eevil.com` would pass it while the URL named
    /// `10.0.0.1.evil.com`. The zone is therefore checked here, and the host the URL ends up naming
    /// must be the host that was checked.
    static func url(host: String, port: UInt16) -> URL? {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard hasInterfaceZoneAtMost(host), PrivateNetwork.isAllowed(host: host) else { return nil }
        let bracketed = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        guard let url = URL(string: "wss://\(bracketed):\(port)/"),
              let named = url.host(percentEncoded: false), named == host, PrivateNetwork.isAllowed(host: named)
        else { return nil }
        return url
    }

    /// No `%`, or an IPv6 address followed by `%` and a non-empty interface name.
    private static func hasInterfaceZoneAtMost(_ host: String) -> Bool {
        guard let percent = host.firstIndex(of: "%") else { return true }
        let zone = host[host.index(after: percent)...]
        return host[..<percent].contains(":") && !zone.isEmpty
            && zone.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._~-".contains($0)) }
    }
}

/// One WebSocket, with the URLSession that owns it.
final class URLSessionSocket: BridgeSocket {
    let task: URLSessionWebSocketTask
    let session: URLSession
    private let events: SocketEvents

    /// Sets the task up without starting it (`open` does).
    init(url: URL, fingerprint: String?) {
        let events = SocketEvents()
        self.events = events
        session = URLSession(
            configuration: .ephemeral, delegate: PinningDelegate(fingerprint: fingerprint, events: events), delegateQueue: nil
        )
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = URLSessionTransport.maxMessageBytes
    }

    var peerFingerprint: String? { events.peerFingerprint }

    /// Starts the handshake and returns once the WebSocket is open; not open within `deadline` ->
    /// it throws (`.unreachable`) and the caller closes the socket.
    func open(within deadline: Duration) async throws {
        let timer = Task { [events] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            events.openTimedOut()
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                events.whenOpen(continuation)
                task.resume()
            }
        } onCancel: {
            close()
        }
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw ended()
        }
    }

    func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw ended()
        }
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: self.ended())
                }
            }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        events.didFinish()
    }

    /// How the connection ended: cleanly if a WebSocket close came.
    private func ended() -> TransportError {
        .closed(cleanly: events.closedCleanly || task.closeCode != .invalid)
    }
}

/// What the session's delegate saw, for the socket to read.
private final class SocketEvents: Sendable {
    private struct State {
        var peerFingerprint: String?
        var pinMismatch = false
        var opened = false
        var finished = false
        var closedCleanly = false
        var openWaiter: CheckedContinuation<Void, any Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var peerFingerprint: String? { state.withLock { $0.peerFingerprint } }
    var closedCleanly: Bool { state.withLock { $0.closedCleanly } }

    func sawCertificate(_ fingerprint: String, pinMismatch: Bool) {
        state.withLock {
            $0.peerFingerprint = fingerprint
            $0.pinMismatch = pinMismatch
        }
    }

    /// Resumes `continuation` once the WebSocket is open, or with the error that kept it shut.
    func whenOpen(_ continuation: CheckedContinuation<Void, any Error>) {
        let now: Result<Void, TransportError>? = state.withLock { s in
            if s.opened { return .success(()) }
            if s.finished { return .failure(s.pinMismatch ? .pinMismatch : .unreachable) }
            s.openWaiter = continuation
            return nil
        }
        if let now { continuation.resume(with: now) }
    }

    func didOpen() {
        let waiter = state.withLock { s in
            s.opened = true
            defer { s.openWaiter = nil }
            return s.openWaiter
        }
        waiter?.resume()
    }

    func didClose() {
        state.withLock { $0.closedCleanly = true }
    }

    /// The deadline for opening has passed: an open still waiting fails as if the task had ended.
    /// Once the WebSocket is open this does nothing.
    func openTimedOut() {
        let (waiter, error): (CheckedContinuation<Void, any Error>?, TransportError) = state.withLock { s in
            guard !s.opened else { return (nil, .unreachable) }
            s.finished = true
            defer { s.openWaiter = nil }
            return (s.openWaiter, s.pinMismatch ? .pinMismatch : .unreachable)
        }
        waiter?.resume(throwing: error)
    }

    /// The task is over (or was closed): an open still waiting fails.
    func didFinish() {
        let (waiter, error) = state.withLock { s in
            s.finished = true
            defer { s.openWaiter = nil }
            return (s.openWaiter, s.pinMismatch ? TransportError.pinMismatch : .unreachable)
        }
        waiter?.resume(throwing: error)
    }
}

/// Trusts the server only if its leaf certificate's SHA-256 is the pinned fingerprint (any
/// certificate without a pin), and records the fingerprint it saw. A pinned connection fails
/// closed: a challenge with no certificate to check the pin against is refused too.
private final class PinningDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let fingerprint: String?
    let events: SocketEvents

    init(fingerprint: String?, events: SocketEvents) {
        self.fingerprint = fingerprint
        self.events = events
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else {
            // Refused as unreachable, not as a mismatch: nothing says the Mac's certificate changed.
            completionHandler(fingerprint == nil ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let mismatch = fingerprint.map { !PinnedCertificate.matches(der: der, fingerprint: $0) } ?? false
        events.sawCertificate(PinnedCertificate.fingerprint(der: der), pinMismatch: mismatch)
        if mismatch {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        events.didOpen()
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        events.didClose()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        events.didFinish()
    }
}
