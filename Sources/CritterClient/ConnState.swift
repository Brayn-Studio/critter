import CritterKit
import Foundation

/// What a paired phone says `hello` with.
public struct Credentials: Equatable, Sendable {
    public var deviceId: String
    public var token: String

    public init(deviceId: String, token: String) {
        self.deviceId = deviceId
        self.token = token
    }
}

public enum ConnState: Equatable, Sendable {
    case idle
    case connecting
    /// Pairing: the request is with the Mac, waiting for the user to approve it there.
    case awaitingApproval
    case connected(macName: String)
    /// Disconnected; the next attempt is in `retryIn`. `since` is when this streak of being
    /// offline began (a connection clears it).
    case offline(retryIn: Duration, since: Date)
    /// Retrying cannot help (wrong certificate, unknown token, refused): pair again.
    case needsRepair(reason: String)
}

/// What a `BridgeClient` reports, in order.
public enum BridgeEvent: Equatable, Sendable {
    case state(ConnState)
    case snapshot(seq: Int, sentAt: Int64, body: SnapshotBody)
    /// The address a connection was made to, once the Mac has welcomed it.
    case connectedTo(Endpoint)
    /// What the Mac's `welcome` said it runs (before the `.connected` state it comes with).
    case macVersion(String)
}

/// The Mac's `result` for a command, or why there is none.
public struct CommandResult: Equatable, Sendable {
    public var ok: Bool
    public var reason: ResultReason?
    public var message: String?

    public init(ok: Bool, reason: ResultReason?, message: String?) {
        self.ok = ok
        self.reason = reason
        self.message = message
    }

    /// Not carried out, for a reason the phone itself knows ("未连接", "超时").
    public static func failed(_ message: String) -> CommandResult {
        CommandResult(ok: false, reason: nil, message: message)
    }
}

/// What came of registering for push with the Mac.
public enum PushRegistrationReply: Equatable, Sendable {
    /// The Mac keeps the registration.
    case stored
    /// The Mac answered no, with its words if it had any.
    case rejected(String?)
    /// Nothing came back in time: an older Mac that does not know the frame. The connection is as it was.
    case noReply
    /// Not connected, or the connection went while the registration was on its way.
    case offline
}
