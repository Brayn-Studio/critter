import Testing
@testable import CritterCore

@Test func privateNetworkTable() {
    for host in ["192.168.1.5", "10.0.0.2", "172.31.255.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "::1",
                 "fe80::1%en0", "fd00::1", "::ffff:192.168.1.5"] {
        #expect(PrivateNetwork.isAllowed(host: host), "\(host)")
    }
    for host in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "2001:db8::1", "::ffff:8.8.8.8", "garbage", ""] {
        #expect(!PrivateNetwork.isAllowed(host: host), "\(host)")
    }
}
