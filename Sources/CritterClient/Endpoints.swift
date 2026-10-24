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
/// the network under its name (`namesMatch`), and no other: another Mac running Critter is not the
/// paired one. Its IP may change (another Wi-Fi, a new DHCP lease), its certificate does not: the
/// same pin still holds.
public struct FallbackResolver: EndpointResolver {
    private let lastGood: @Sendable () -> Endpoint?
    private let macName: String
    private let browser: any MacBrowser

    /// - Parameter lastGood: read before each connection (the stored pairing's address), so an
    ///   address the Mac was found at during this run is the next one tried.
    public init(lastGood: @escaping @Sendable () -> Endpoint?, macName: String, browser: any MacBrowser) {
        self.lastGood = lastGood
        self.macName = macName
        self.browser = browser
    }

    public func resolve(afterFailure: Bool) async -> Endpoint? {
        if !afterFailure, let lastGood = lastGood() { return lastGood }
        let found = await browser.discover()
        return found.first { Self.namesMatch($0.name, macName) }?.endpoint
    }

    /// Whether a Bonjour service is the Mac called `macName` (Android `NsdLocator.namesMatch`): the
    /// same name in any case, or that name with what Bonjour adds to a name that is taken (" (2)").
    static func namesMatch(_ serviceName: String, _ macName: String) -> Bool {
        serviceName.compare(macName, options: .caseInsensitive) == .orderedSame
            || (!macName.isEmpty && serviceName.range(of: "\(macName) (", options: [.caseInsensitive, .anchored]) != nil)
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
    private let access: LocalNetworkAccess

    /// - Parameters:
    ///   - window: how long to browse; what was found and resolved by then is the result.
    ///   - access: told when the local network is denied (the browser or a resolution says so), and when a Mac was
    ///     found.
    public init(window: Duration = .seconds(3), access: LocalNetworkAccess = .shared) {
        self.window = window
        self.access = access
    }

    /// Each service found is resolved to an IP address and port by a plain TCP connection
    /// (no TLS), cancelled as soon as it is up. Only addresses on private networks are kept. A
    /// resolution that waits is tried once more with a new connection (`step`).
    public func discover() async -> [DiscoveredMac] {
        let search = BonjourSearch(access: access)
        search.start()
        try? await Task.sleep(for: window)
        return search.finish()
    }

    /// How many connections resolve one service, at most.
    static let maxResolveAttempts = 2
    /// How long after a resolution waits the next one starts.
    static let retryDelay: DispatchTimeInterval = .milliseconds(300)

    /// What a service's resolving connection comes to.
    enum ResolveStep: Equatable {
        /// Not there yet.
        case wait
        /// Ready: its address is the Mac's.
        case resolved
        /// It waits (refused, no route yet): a new connection, once.
        case retry
        /// No address from it; `denied` when the local network is denied, which no retry changes.
        case giveUp(denied: Bool)
    }

    /// The step for connection number `attempt` (from 1) in `state`, its path unsatisfied for `path`. Pure.
    static func step(_ state: NWConnection.State, attempt: Int, path: NWPath.UnsatisfiedReason?) -> ResolveStep {
        switch state {
        case .ready:
            return .resolved
        case .waiting:
            if LocalNetworkDenial.isDenied(state, path: path) { return .giveUp(denied: true) }
            return attempt < maxResolveAttempts ? .retry : .giveUp(denied: false)
        case .failed:
            return .giveUp(denied: LocalNetworkDenial.isDenied(state, path: path))
        default:
            return .wait
        }
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
        /// The connection resolving each service, and which attempt it is (`BonjourBrowser.step`). A service given up
        /// stays here, so it is not tried again in this search.
        var resolving: [String: (connection: NWConnection, attempt: Int)] = [:]
        var found: [String: Endpoint] = [:]
        var done = false
    }

    private let queue = DispatchQueue(label: "local.critter.client.bonjour")
    private let browser = NWBrowser(for: .bonjour(type: BridgeProtocol.bonjourType, domain: nil), using: .tcp)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let access: LocalNetworkAccess

    init(access: LocalNetworkAccess) {
        self.access = access
    }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results { self?.resolve(result.endpoint) }
        }
        // Denied the local network, the browser waits with the policy error (and finds nothing).
        browser.stateUpdateHandler = { [access] update in
            if LocalNetworkDenial.isDenied(update) { access.sawDenied() }
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
            return (s.resolving.values.map(\.connection), macs)
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
            s.resolving[name] = (connection, 1)
            return true
        }
        guard isNew else { return }
        start(connection, for: name, service: service, attempt: 1)
    }

    private func start(_ connection: NWConnection, for name: String, service: NWEndpoint, attempt: Int) {
        // Weak: `state` keeps the connection until `finish`, and neither handler may keep its owner.
        connection.stateUpdateHandler = { [weak self, weak connection] update in
            guard let self, let connection else { return }
            switch BonjourBrowser.step(update, attempt: attempt, path: connection.currentPath?.unsatisfiedReason) {
            case .wait:
                break
            case .resolved:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    self.resolved(name, host: host, port: port.rawValue)
                }
                connection.cancel()
            case .retry:
                connection.cancel()
                self.queue.asyncAfter(deadline: .now() + BonjourBrowser.retryDelay) { [weak self] in
                    self?.retry(name, service: service, attempt: attempt + 1)
                }
            case .giveUp(let denied):
                if denied { self.access.sawDenied() }
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    /// Connection number `attempt` for `name`, unless the search is over or the service was resolved meanwhile.
    private func retry(_ name: String, service: NWEndpoint, attempt: Int) {
        let connection = NWConnection(to: service, using: .tcp)
        let goes = state.withLock { s in
            guard !s.done, s.found[name] == nil else { return false }
            s.resolving[name] = (connection, attempt)
            return true
        }
        guard goes else { return }
        start(connection, for: name, service: service, attempt: attempt)
    }

    private func resolved(_ name: String, host: NWEndpoint.Host, port: UInt16) {
        guard let address = BonjourBrowser.address(host), PrivateNetwork.isAllowed(host: address) else { return }
        let fresh = state.withLock { s in
            guard !s.done else { return false }
            s.found[name] = Endpoint(host: address, port: port)
            return true
        }
        // A Mac was reached on the local network: whatever was refused before is not any more.
        if fresh { access.sawAllowed() }
    }
}
