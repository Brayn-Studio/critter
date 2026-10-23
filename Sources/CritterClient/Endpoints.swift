import CritterKit
import Foundation
import Network
import os

/// Where the Mac's bridge listens.
public struct Endpoint: Equatable, Sendable, Codable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Finds the Mac before each connection attempt.
public protocol EndpointResolver: Sendable {
    /// `afterFailure`: the previous attempt could not connect to the address this resolved.
    func resolve(afterFailure: Bool) async -> Endpoint?
}

/// Always the same address.
public struct StaticResolver: EndpointResolver {
    private let endpoint: Endpoint

    public init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    public func resolve(afterFailure: Bool) async -> Endpoint? {
        endpoint
    }
}

/// The paired Mac's last good address; when that fails (or there is none), the Mac found on
/// the network under its name, else the first Mac found. Its IP may change (another Wi-Fi, a
/// new DHCP lease), its certificate does not: the same pin still holds.
public struct FallbackResolver: EndpointResolver {
    private let lastGood: Endpoint?
    private let macName: String
    private let browser: any MacBrowser

    public init(lastGood: Endpoint?, macName: String, browser: any MacBrowser) {
        self.lastGood = lastGood
        self.macName = macName
        self.browser = browser
    }

    public func resolve(afterFailure: Bool) async -> Endpoint? {
        if !afterFailure, let lastGood { return lastGood }
        let found = await browser.discover()
        return (found.first { $0.name == macName } ?? found.first)?.endpoint
    }
}

/// A Mac advertising the bridge on the local network.
public struct DiscoveredMac: Equatable, Sendable {
    /// The Bonjour service name: the Mac's name, as in `welcome.macName`.
    public var name: String
    public var endpoint: Endpoint

    public init(name: String, endpoint: Endpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

public protocol MacBrowser: Sendable {
    func discover() async -> [DiscoveredMac]
}

/// Finds Macs advertising the bridge (`_critter._tcp`) with Bonjour.
public struct BonjourBrowser: MacBrowser {
    private let window: Duration

    /// - Parameter window: how long to browse; what was found and resolved by then is the result.
    public init(window: Duration = .seconds(3)) {
        self.window = window
    }

    /// Each service found is resolved to an IP address and port by a plain TCP connection
    /// (no TLS), cancelled as soon as it is up. Only addresses on private networks are kept.
    public func discover() async -> [DiscoveredMac] {
        let search = BonjourSearch()
        search.start()
        try? await Task.sleep(for: window)
        return search.finish()
    }

    /// A resolved address as a host to connect to: `192.168.1.20`, `fe80::1%en0`. Network adds the
    /// interface it came in on (`192.168.1.20%en0`); only a link-local IPv6 address keeps it. An
    /// IPv4-mapped IPv6 address becomes plain IPv4.
    static func address(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return IPv4Address(address.rawValue).map { "\($0)" }
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return IPv4Address(mapped.rawValue).map { "\($0)" } }
            if address.isLinkLocal { return "\(address)" }
            return IPv6Address(address.rawValue).map { "\($0)" }
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// One `discover`: the browser, the connections resolving what it found, and the results.
private final class BonjourSearch: Sendable {
    private struct State {
        /// Service names in the order they were first seen.
        var order: [String] = []
        var resolving: [String: NWConnection] = [:]
        var found: [String: Endpoint] = [:]
        var done = false
    }

    private let queue = DispatchQueue(label: "local.critter.client.bonjour")
    private let browser = NWBrowser(for: .bonjour(type: BridgeProtocol.bonjourType, domain: nil), using: .tcp)
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results { self?.resolve(result.endpoint) }
        }
        browser.start(queue: queue)
    }

    /// Stops browsing and resolving; the Macs resolved so far.
    func finish() -> [DiscoveredMac] {
        browser.cancel()
        let (connections, macs) = state.withLock { s in
            s.done = true
            defer { s.resolving = [:] }
            let macs = s.order.compactMap { name in s.found[name].map { DiscoveredMac(name: name, endpoint: $0) } }
            return (Array(s.resolving.values), macs)
        }
        connections.forEach { $0.cancel() }
        return macs
    }

    private func resolve(_ service: NWEndpoint) {
        guard case .service(let name, _, _, _) = service else { return }
        let connection = NWConnection(to: service, using: .tcp)
        let isNew = state.withLock { s in
            guard !s.done, s.resolving[name] == nil, s.found[name] == nil else { return false }
            if !s.order.contains(name) { s.order.append(name) }
            s.resolving[name] = connection
            return true
        }
        guard isNew else { return }
        // Weak: `state` keeps the connection until `finish`, and neither handler may keep its owner.
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            switch update {
            case .ready:
                if case .hostPort(let host, let port)? = connection?.currentPath?.remoteEndpoint {
                    self?.resolved(name, host: host, port: port.rawValue)
                }
                connection?.cancel()
            case .waiting, .failed:
                connection?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func resolved(_ name: String, host: NWEndpoint.Host, port: UInt16) {
        guard let address = BonjourBrowser.address(host), PrivateNetwork.isAllowed(host: address) else { return }
        state.withLock { s in
            guard !s.done else { return }
            s.found[name] = Endpoint(host: address, port: port)
        }
    }
}
