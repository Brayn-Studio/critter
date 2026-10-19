import Darwin
import Foundation

/// The Mac's address for the pairing QR code.
public enum LANAddress {
    /// An IPv4 address of one of the Mac's network interfaces.
    public struct Interface: Equatable, Sendable {
        public var name: String
        public var address: String
        public var isUp: Bool
        public var isRunning: Bool
        public var isLoopback: Bool

        public init(name: String, address: String, isUp: Bool, isRunning: Bool, isLoopback: Bool) {
            self.name = name
            self.address = address
            self.isUp = isUp
            self.isRunning = isRunning
            self.isLoopback = isLoopback
        }
    }

    /// The first private IPv4 address of an active interface, Wi-Fi/Ethernet (`en*`) first and
    /// link-local last.
    public static func current(interfaces: [Interface] = systemInterfaces()) -> String? {
        var best: (rank: Int, address: String)?
        for entry in interfaces {
            guard entry.isUp, entry.isRunning, !entry.isLoopback, PrivateNetwork.isAllowed(host: entry.address) else { continue }
            let rank = entry.address.hasPrefix("169.254.") ? 3 : entry.name == "en0" ? 0 : entry.name.hasPrefix("en") ? 1 : 2
            if best == nil || rank < best!.rank { best = (rank, entry.address) }
        }
        return best?.address
    }

    /// The Mac's IPv4 interface addresses, in `getifaddrs` order.
    public static func systemInterfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var interfaces: [Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard let address = IPAddress.string(addr) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            interfaces.append(Interface(
                name: String(cString: entry.pointee.ifa_name), address: address,
                isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0, isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return interfaces
    }
}
