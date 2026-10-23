/// Reads a Mac's certificate fingerprint before pairing by hand (no QR code to take it from), so
/// the user can compare it with the one the Mac shows.
public struct CertificateProbe: Sendable {
    private let transport: any BridgeTransport

    public init(transport: any BridgeTransport) {
        self.transport = transport
    }

    /// Only does the handshake and reads the leaf certificate's fingerprint; sends nothing.
    /// nil if the Mac cannot be reached.
    public func fingerprint(of endpoint: Endpoint) async -> String? {
        guard let socket = try? await transport.connect(host: endpoint.host, port: endpoint.port, fingerprint: nil) else {
            return nil
        }
        defer { socket.close() }
        return socket.peerFingerprint
    }
}
