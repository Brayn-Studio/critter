import Foundation

/// One open WebSocket to the Mac, carrying text frames (`docs/critter-bridge-protocol.md`).
public protocol BridgeSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text message; throws `TransportError` once the connection has ended.
    func receive() async throws -> String
    /// A WebSocket ping; returns when its pong arrives, throws if the connection fails first.
    func sendPing() async throws
    /// Ends the connection; a `receive` waiting on it throws.
    func close()
    /// SHA-256 (64 lowercase hex digits) of the leaf certificate seen during the TLS handshake.
    var peerFingerprint: String? { get }
}

/// Opens sockets to the Mac.
public protocol BridgeTransport: Sendable {
    /// With a `fingerprint`, the Mac's leaf certificate must have exactly that SHA-256, or this
    /// throws `.pinMismatch`. nil accepts any certificate (only for `CertificateProbe`).
    func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket
}

public enum TransportError: Error, Equatable, Sendable {
    /// The Mac's certificate is not the pinned one.
    case pinMismatch
    /// No connection was made.
    case unreachable
    /// An open connection ended: `cleanly` with a WebSocket close, otherwise by an error.
    case closed(cleanly: Bool)
}
