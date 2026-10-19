import Darwin
import Foundation

/// Numeric text for raw IP addresses, as `inet_ntop` writes it.
public enum IPAddress {
    /// A 4-byte (IPv4) or 16-byte (IPv6) address in network byte order; nil for any other size.
    public static func string(_ raw: Data) -> String? {
        let family: Int32
        switch raw.count {
        case 4: family = AF_INET
        case 16: family = AF_INET6
        default: return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = raw.withUnsafeBytes { bytes in
            inet_ntop(family, bytes.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func string(_ addr: in_addr) -> String? {
        withUnsafeBytes(of: addr) { string(Data($0)) }
    }
}
