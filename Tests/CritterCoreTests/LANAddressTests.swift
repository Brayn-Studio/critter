import Foundation
import Testing
@testable import CritterCore

private func interface(
    _ name: String, _ address: String, up: Bool = true, running: Bool = true, loopback: Bool = false
) -> LANAddress.Interface {
    LANAddress.Interface(name: name, address: address, isUp: up, isRunning: running, isLoopback: loopback)
}

/// The pairing QR code's address: a private IPv4 address of an active, non-loopback interface;
/// `en0` first, then other `en*`, then anything else, link-local last; the first listed wins a tie.
@Test func prefersAPrivateIPv4OnAnActiveInterface() {
    #expect(LANAddress.current(interfaces: []) == nil)
    #expect(LANAddress.current(interfaces: [interface("lo0", "127.0.0.1", loopback: true)]) == nil)
    #expect(LANAddress.current(interfaces: [interface("en0", "8.8.8.8")]) == nil)                       // not private
    #expect(LANAddress.current(interfaces: [interface("en0", "192.168.1.5", up: false)]) == nil)
    #expect(LANAddress.current(interfaces: [interface("en0", "192.168.1.5", running: false)]) == nil)

    let all = [
        interface("lo0", "127.0.0.1", loopback: true),
        interface("bridge0", "169.254.3.4"),
        interface("utun3", "10.8.0.2"),
        interface("en5", "172.16.0.9"),
        interface("en7", "172.16.0.10"),
        interface("en0", "8.8.4.4"),
        interface("en0", "192.168.1.5"),
        interface("en0", "192.168.1.6"),
    ]
    #expect(LANAddress.current(interfaces: all) == "192.168.1.5")
    #expect(LANAddress.current(interfaces: Array(all.prefix(6))) == "172.16.0.9")
    #expect(LANAddress.current(interfaces: Array(all.prefix(3))) == "10.8.0.2")
    #expect(LANAddress.current(interfaces: Array(all.prefix(2))) == "169.254.3.4")
}
