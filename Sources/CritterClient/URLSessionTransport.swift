import Foundation
import os

/// The real transport: `wss://` over URLSession, pinned to the Mac's self-signed certificate
/// (the approach of `critter-bridge-client`'s `PinningDelegate`).
public final class URLSessionTransport: BridgeTransport {
    /// The largest message accepted. Mac -> phone frames are not capped (a snapshot carries
    /// commands and plans in full and can be larger than 1 MiB): this is far above what a
    /// snapshot needs, so one never ends the connection.
    public static let maxMessageBytes = 64 << 20

    public init() {}

    /// Each connection gets an ephemeral URLSession of its own; it counts as made once the
    /// WebSocket is open. A certificate that is not the pinned one -> `.pinMismatch`; any other
    /// failure before the WebSocket opens -> `.unreachable`.
    public func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket {
        guard let url = Self.url(host: host, port: port) else { throw TransportError.unreachable }
        let socket = URLSessionSocket(url: url, fingerprint: fingerprint)
        do {
            try await socket.open()
        } catch {
            socket.close()
            throw error
        }
        return socket
    }

    /// `wss://<host>:<port>/`; an IPv6 host is bracketed and the `%` of its zone escaped
    /// (`fe80::1%en0` -> `[fe80::1%25en0]`).
    static func url(host: String, port: UInt16) -> URL? {
        let bracketed = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "wss://\(bracketed):\(port)/")
    }
}

/// One WebSocket, with the URLSession that owns it.
final class URLSessionSocket: BridgeSocket {
    let task: URLSessionWebSocketTask
    private let session: URLSession
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

    /// Starts the handshake and returns once the WebSocket is open.
    func open() async throws {
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
/// certificate without a pin), and records the fingerprint it saw.
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
            completionHandler(.performDefaultHandling, nil)
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
