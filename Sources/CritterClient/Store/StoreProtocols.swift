import CritterKit
import Foundation

/// What is kept of a pairing besides its token (which only `PairingStorage` holds, in the keychain).
public struct StoredPairing: Codable, Equatable, Sendable {
    /// The Mac's last good address.
    public var endpoint: Endpoint
    /// The pin: the SHA-256 of the Mac's leaf certificate, lowercase hex.
    public var fingerprint: String
    public var macName: String
    public var deviceId: String

    public init(endpoint: Endpoint, fingerprint: String, macName: String, deviceId: String) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.macName = macName
        self.deviceId = deviceId
    }
}

/// The last snapshot, kept for the next launch.
public struct CachedSnapshot: Codable, Equatable, Sendable {
    public var body: SnapshotBody
    public var receivedAt: Date

    public init(body: SnapshotBody, receivedAt: Date) {
        self.body = body
        self.receivedAt = receivedAt
    }
}

/// Where the pairing and the last snapshot are kept. Called on the main actor: an implementation
/// should not do slow work inline (a snapshot can be over a megabyte).
public protocol PairingStorage: Sendable {
    func load() -> (StoredPairing, Credentials)?
    /// Replaces the pairing and token. The cached snapshot goes too: it is from the pairing replaced, which may
    /// be another Mac.
    func save(_ pairing: StoredPairing, token: String)
    func updateEndpoint(_ endpoint: Endpoint)
    /// Forgets the pairing and the cached snapshot together.
    func clear()
    func loadSnapshot() -> CachedSnapshot?
    func saveSnapshot(_ snapshot: CachedSnapshot)
}

/// The connection to the Mac, as the store drives it: a `BridgeClient`.
public protocol BridgeLink: Sendable {
    func start() async
    func stop() async
    func reconnectNow() async
    func request(_ command: BridgeCommand) async -> CommandResult
}

extension BridgeClient: BridgeLink {}

/// First-time pairing, as the store drives it: a `Pairer`.
public protocol PairingLink: Sendable {
    func pair(
        _ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void
    ) async -> PairResult
}

extension Pairer: PairingLink {}

/// Runs `work` so that the system lets it finish after the app has left the foreground (on iOS, inside
/// a background task). `work` ends by itself within a few seconds.
@MainActor
public protocol BackgroundRunner {
    func run(_ work: @escaping @MainActor () async -> Void)
}

/// Where a pairing attempt is, for the pairing screen.
public enum PairingPhase: Equatable, Sendable {
    /// Reaching the Mac.
    case connecting
    /// The request is with the Mac, waiting for the user to approve it there.
    case awaitingApproval
}
