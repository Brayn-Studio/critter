import Foundation

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
