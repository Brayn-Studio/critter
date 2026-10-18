import Foundation

/// Which connections the bridge lets in, and how long each may stay. Any peer on the private
/// network can open one, so connections that haven't proven who they are are few and
/// short-lived: they must not be able to use up the app's file descriptors (and with them the
/// pet's own file watching). Pure: `BridgeServer` applies it.
public struct BridgeAdmission: Equatable, Sendable {
    /// Open connections that are not paired-and-ready (waiting for their first frame or the
    /// user's approval, or closing) at the most.
    public var maxUnauthenticated: Int
    /// Open connections of any kind at the most.
    public var maxConnections: Int
    /// From being accepted to the first frame (`hello`/`pair`); traffic doesn't extend it.
    public var firstFrameTimeout: TimeInterval
    /// From a valid pairing code to the user's answer on the Mac; traffic doesn't extend it.
    public var approvalTimeout: TimeInterval
    /// A ready connection's longest silence: every frame (pings included) starts it over.
    public var idleTimeout: TimeInterval

    public init(
        maxUnauthenticated: Int, maxConnections: Int,
        firstFrameTimeout: TimeInterval, approvalTimeout: TimeInterval, idleTimeout: TimeInterval
    ) {
        self.maxUnauthenticated = maxUnauthenticated
        self.maxConnections = maxConnections
        self.firstFrameTimeout = firstFrameTimeout
        self.approvalTimeout = approvalTimeout
        self.idleTimeout = idleTimeout
    }

    /// The approval wait lasts as long as a pairing code does.
    public static let standard = BridgeAdmission(
        maxUnauthenticated: 8, maxConnections: 32,
        firstFrameTimeout: 20, approvalTimeout: TimeInterval(PairingCode.lifetimeMs / 1000), idleTimeout: 600
    )

    /// Whether one more connection may come in, given the phases of those already open.
    public func admits(open: [BridgeConnection.Phase]) -> Bool {
        let unauthenticated = open.filter { if case .ready = $0 { return false } else { return true } }.count
        return open.count < maxConnections && unauthenticated < maxUnauthenticated
    }

    /// How long a connection may stay in `phase` (nil: it is already closed).
    public func timeout(for phase: BridgeConnection.Phase) -> TimeInterval? {
        switch phase {
        case .awaitingFirst: return firstFrameTimeout
        case .awaitingApproval: return approvalTimeout
        case .ready: return idleTimeout
        case .closed: return nil
        }
    }

    /// Whether a frame in `phase` starts its timeout over; only a paired phone's does.
    public func trafficExtends(_ phase: BridgeConnection.Phase) -> Bool {
        if case .ready = phase { return true }
        return false
    }
}
