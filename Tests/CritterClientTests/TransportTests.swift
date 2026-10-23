@testable import CritterClient
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
