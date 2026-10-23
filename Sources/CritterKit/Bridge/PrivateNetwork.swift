import Foundation

/// Whether a peer address is on a private / local network. The bridge refuses everything else.
public enum PrivateNetwork {
    public static func isAllowed(host: String) -> Bool {
        var h = host
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }

        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            return allowedV4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return true }   // ::1
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }                  // fe80::/10
        if b[0] & 0xfe == 0xfc { return true }                                // fc00::/7
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {  // ::ffff:a.b.c.d
            return allowedV4(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        return false
    }

    private static func allowedV4(_ a: UInt32) -> Bool {
        let first = a >> 24
        switch first {
        case 10, 127: return true
        case 172: return (a >> 20) & 0xf == 1                 // 172.16/12
        case 192: return (a >> 16) & 0xff == 168
        case 169: return (a >> 16) & 0xff == 254
        case 100: return (a >> 16) & 0xc0 == 0x40             // 100.64/10
        default: return false
        }
    }
}
