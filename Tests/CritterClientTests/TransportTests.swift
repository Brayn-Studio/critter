@testable import CritterClient
import CritterKit
import Foundation
import Network
import Testing

struct TransportTests {
    @Test func transportAcceptsFramesUpTo64MiB() throws {
        #expect(URLSessionTransport.maxMessageBytes == 64 << 20)
        // What each socket's task is set up with (not opened: nothing goes on the network).
        let socket = URLSessionSocket(url: try #require(URL(string: "wss://127.0.0.1:47823/")), fingerprint: nil)
        #expect(socket.task.maximumMessageSize == 64 << 20)
        socket.close()
    }

    @Test func ipv6HostsAreBracketedAndEscaped() {
        #expect(URLSessionTransport.url(host: "fe80::1%en0", port: 47823)?.absoluteString == "wss://[fe80::1%25en0]:47823/")
        #expect(URLSessionTransport.url(host: "192.168.1.20", port: 47823)?.absoluteString == "wss://192.168.1.20:47823/")
    }

    @Test func onlyPrivateNetworkHostsGetAnAddress() {
        // Wherever the host came from (a scanned QR code, a stored address, typed in).
        for host in ["8.8.8.8", "2001:4860:4860::8888", "example.com", "203.0.113.5"] {
            #expect(URLSessionTransport.url(host: host, port: 443) == nil, "\(host)")
        }
        for host in ["10.0.0.2", "172.16.4.1", "192.168.1.20", "127.0.0.1", "100.64.0.1", "fd00::5", "fe80::1%en0", "::1"] {
            #expect(URLSessionTransport.url(host: host, port: 47823) != nil, "\(host)")
        }
    }

    @Test func aPrivateLookingHostThatResolvesElsewhereGetsNoAddress() {
        // Each would pass a check that stops at "%", but the URL would name another host:
        // 10.0.0.1.evil.com, 192.168.1.5.nip.io, evil.com.
        for host in ["10.0.0.1%2Eevil.com", "192.168.1.5%2Enip.io", "192.168.1.5%40@evil.com"] {
            #expect(URLSessionTransport.url(host: host, port: 443) == nil, "\(host)")
        }
        // A zone only on an IPv6 address, and only an interface name.
        for host in ["10.0.0.1%en0", "fe80::1%", "fe80::1%en0%x", "fe80::1%en0/x", "fe80::1%en0@evil.com"] {
            #expect(URLSessionTransport.url(host: host, port: 443) == nil, "\(host)")
        }
        // Brackets around an IPv6 address are fine.
        #expect(URLSessionTransport.url(host: "[fe80::1%en0]", port: 47823)?.absoluteString == "wss://[fe80::1%25en0]:47823/")
    }

    @Test func aCraftedPairingCodeGetsNowhere() async throws {
        let fp = String(repeating: "ab", count: 32)
        let uri = try #require(PairingURI(string: "critter-pair://10.0.0.1%252Eevil.com:443?fp=\(fp)&code=K7M2QX9P&name=n"))
        #expect(uri.host == "10.0.0.1%2Eevil.com")
        let target = PairingTarget(uri: uri)
        // Checked first, so a broken check never reaches the network.
        try #require(URLSessionTransport.url(host: target.endpoint.host, port: target.endpoint.port) == nil)
        let result = await Pairer(transport: URLSessionTransport()).pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        #expect(result == .failed(.unreachable))
    }

    @Test func connectingToAPublicHostFailsWithoutTouchingTheNetwork() async {
        let started = ContinuousClock.now
        await #expect(throws: TransportError.unreachable) {
            _ = try await URLSessionTransport().connect(host: "8.8.8.8", port: 443, fingerprint: String(repeating: "ab", count: 32))
        }
        // Refused before any socket exists: no handshake, no timeout.
        #expect(ContinuousClock.now - started < .milliseconds(200))
    }

    /// A Mac that takes the TCP connection and never answers the TLS handshake (asleep halfway, a captive network):
    /// the connect gives up at its deadline (6 s; half a second here) rather than URLSession's 60 s.
    @Test func aHandshakeThatNeverFinishesIsUnreachableAtTheDeadline() async throws {
        #expect(URLSessionTransport.connectTimeout == .seconds(6))
        let listener = try SilentListener()
        let started = ContinuousClock.now
        await #expect(throws: TransportError.unreachable) {
            _ = try await URLSessionTransport(connectTimeout: .milliseconds(500)).connect(
                host: "127.0.0.1", port: listener.port, fingerprint: String(repeating: "ab", count: 32)
            )
        }
        let took = ContinuousClock.now - started
        #expect(took >= .milliseconds(500))
        #expect(took < .seconds(3))
    }

    /// The pin can only be checked against a certificate: a server-trust challenge with none to read fails a pinned
    /// connection closed (as `.unreachable`: nothing says it is another Mac). Unpinned (the probe), URLSession decides.
    @Test func aPinnedConnectionWithNoCertificateToCheckIsRefused() async throws {
        let url = try #require(URL(string: "wss://127.0.0.1:47823/"))
        let cases: [(String?, URLSession.AuthChallengeDisposition)] = [
            (String(repeating: "ab", count: 32), .cancelAuthenticationChallenge),
            (nil, .performDefaultHandling),
        ]
        for (pin, expected) in cases {
            let socket = URLSessionSocket(url: url, fingerprint: pin)
            defer { socket.close() }
            let delegate = try #require(socket.session.delegate)
            // A server-trust challenge that carries no trust to read a certificate from.
            let space = URLProtectionSpace(
                host: "127.0.0.1", port: 47823, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
            #expect(space.serverTrust == nil)
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
                sender: NoChallengeSender()
            )
            let disposition = await withCheckedContinuation { continuation in
                delegate.urlSession?(socket.session, didReceive: challenge) { disposition, _ in
                    continuation.resume(returning: disposition)
                }
            }
            #expect(disposition == expected, "pin: \(String(describing: pin))")
            #expect(socket.peerFingerprint == nil)
        }
    }

    @Test func discoveredAddressesAreUsableHosts() throws {
        // Network gives resolved addresses the interface they came in on; only a link-local
        // IPv6 address needs it.
        let v4 = try #require(IPv4Address("192.168.1.35%lo0"))
        #expect(BonjourBrowser.address(.ipv4(v4)) == "192.168.1.35")
        #expect(BonjourBrowser.address(.ipv6(try #require(IPv6Address("::ffff:192.168.1.35%lo0")))) == "192.168.1.35")
        #expect(BonjourBrowser.address(.ipv6(try #require(IPv6Address("fe80::1%lo0")))) == "fe80::1%lo0")
        #expect(BonjourBrowser.address(.ipv6(try #require(IPv6Address("fd00::5%lo0")))) == "fd00::5")
        #expect(BonjourBrowser.address(.name("mac.local", nil)) == nil)
    }

    @Test func probeReadsTheLeafFingerprintWithoutPinningOrSending() async {
        let mac = FakeMac()
        let seen = String(repeating: "ef", count: 32)
        mac.peerFingerprint = seen
        let endpoint = Endpoint(host: "192.168.1.20", port: 47823)
        #expect(await CertificateProbe(transport: mac).fingerprint(of: endpoint) == seen)
        #expect(mac.connects == [FakeMac.Connect(host: "192.168.1.20", port: 47823, fingerprint: nil)])
        #expect(mac.received.isEmpty)
        #expect(mac.openSockets == 0)
    }

    @Test func probeOfAnUnreachableMacIsNil() async {
        let mac = FakeMac()
        mac.failNextConnects(.unreachable)
        #expect(await CertificateProbe(transport: mac).fingerprint(of: Endpoint(host: "192.168.1.20", port: 47823)) == nil)
    }
}

/// A TCP port on 127.0.0.1 that takes connections (the kernel completes them into the backlog) and never says a
/// word: a TLS handshake with it never finishes.
private final class SilentListener {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(socket, address, length) == 0 && listen(socket, 8) == 0 && getsockname(socket, address, &length) == 0
            }
        }
        guard bound else {
            close(socket)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(socket)
    }
}

/// A challenge's sender, for a challenge handed straight to a delegate.
private final class NoChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
