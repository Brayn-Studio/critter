import Foundation
import Testing
@testable import CritterCore

@Test func ipAddressTextFromRawBytes() {
    #expect(IPAddress.string(Data([192, 168, 1, 5])) == "192.168.1.5")
    #expect(IPAddress.string(Data([0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [1])) == "fe80::1")
    #expect(IPAddress.string(Data([1, 2, 3])) == nil)
    var addr = in_addr()
    addr.s_addr = UInt32(10 << 24 | 1).bigEndian
    #expect(IPAddress.string(addr) == "10.0.0.1")
}
