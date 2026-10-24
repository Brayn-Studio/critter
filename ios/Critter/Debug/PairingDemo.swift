#if DEBUG
import CritterClient
import CritterKit
import Foundation

/// `-critterPairing <demo>` (see `DebugLaunch`): the pairing screen in one of its states, on fakes. The pairer never
/// touches the network; it reaches the Mac, waits, fails or pairs as the demo says. The Macs on the network and their
/// certificates are fakes too.
enum PairingDemo: Equatable {
    /// The scanner (in the simulator: no camera).
    case scan
    /// The manual page, reached by tapping 「手动输入」 a second after launch.
    case manual(Manual)
    /// A link from outside, waiting for the user's yes.
    case confirm
    /// An attempt started at once from a link, going as `outcome` says.
    case attempt(Outcome)

    enum Manual: Equatable {
        /// Two Macs found, the first one chosen, the code typed.
        case found
        /// None found yet: "正在寻找…".
        case searching
        /// 「连接」 tapped: the fingerprint is read and the trust dialog asks.
        case trust
        /// 「连接」 tapped and the Mac could not be reached.
        case probeFailed
    }

    enum Outcome: Equatable {
        /// Still reaching the Mac, until cancelled.
        case connecting
        /// The request is with the Mac, until cancelled.
        case awaiting
        /// Fails with this reason, after waiting `after` seconds at the Mac (at once for 0).
        case failed(PairFailure, after: Double)
        /// The Mac says yes after `after` seconds.
        case paired(after: Double)
    }

    /// `scan`, `manual`, `manual-searching`, `manual-trust`, `manual-probe-failed`, `confirm`, `connecting`,
    /// `awaiting`, `failed:<reason>[@<seconds>]` (reasons `badCode`, `rejected`, `protocol`, `cert`, `noAnswer`,
    /// `unreachable`), `paired@<seconds>`.
    init?(argument: String) {
        func seconds(_ text: Substring?) -> Double { text.flatMap { Double($0) } ?? 0 }
        switch argument {
        case "scan": self = .scan
        case "manual": self = .manual(.found)
        case "manual-searching": self = .manual(.searching)
        case "manual-trust": self = .manual(.trust)
        case "manual-probe-failed": self = .manual(.probeFailed)
        case "confirm": self = .confirm
        case "connecting": self = .attempt(.connecting)
        case "awaiting": self = .attempt(.awaiting)
        default:
            let parts = argument.split(separator: "@", maxSplits: 1)
            let head = parts.first ?? ""
            if head == "paired" {
                self = .attempt(.paired(after: seconds(parts.dropFirst().first)))
                return
            }
            guard head.hasPrefix("failed:") else { return nil }
            let reasons: [String: PairFailure] = [
                "badCode": .badCode, "rejected": .rejected, "protocol": .protocolMismatch, "cert": .certMismatch,
                "noAnswer": .noAnswer, "unreachable": .unreachable,
            ]
            guard let why = reasons[String(head.dropFirst("failed:".count))] else { return nil }
            self = .attempt(.failed(why, after: seconds(parts.dropFirst().first)))
        }
    }

    /// The link the app starts with: a confirmed one for an attempt, one from outside to confirm.
    var launchLink: IncomingPairLink? {
        switch self {
        case .confirm: IncomingPairLink(uri: PairingDemoFakes.uri, confirmed: false)
        case .attempt: IncomingPairLink(uri: PairingDemoFakes.uri, confirmed: true)
        case .scan, .manual: nil
        }
    }

    /// The fake network: the two Macs (none while `searching`), a certificate read in half a second (none for
    /// `probeFailed`).
    var network: PairingNetwork {
        let macs = self == .manual(.searching) ? [] : PairingDemoFakes.macs
        let fingerprint = self == .manual(.probeFailed) ? nil : PairingDemoFakes.fingerprint
        return PairingNetwork(browser: FakeBrowser(macs: macs)) { _ in
            try? await Task.sleep(for: .milliseconds(500))
            return fingerprint
        }
    }

    var pairer: DemoPairer {
        if case .attempt(let outcome) = self { return DemoPairer(outcome: outcome) }
        // The manual page's 「信任并配对」, or a confirmed link: the Mac waits for 「允许」.
        return DemoPairer(outcome: .awaiting)
    }
}

/// The fakes' values: the mockups' "MacBook Pro" and "Mac mini", a code in the pairing alphabet.
enum PairingDemoFakes {
    static let macs = [
        DiscoveredMac(name: "MacBook Pro", endpoint: Endpoint(host: "192.168.1.23", port: BridgeProtocol.defaultPort)),
        DiscoveredMac(name: "Mac mini", endpoint: Endpoint(host: "192.168.1.40", port: BridgeProtocol.defaultPort)),
    ]
    static let fingerprint = "3f9a2c417be0d5c8" + String(repeating: "0a1b2c3d", count: 6)
    static let code = "4829H735"
    static let uri = PairingURI(
        host: "192.168.1.23", port: BridgeProtocol.defaultPort, fingerprint: fingerprint, code: code, name: "MacBook Pro"
    )
}

/// Finds `macs` after a moment; nothing takes three seconds, like a Bonjour search that finds nothing.
private struct FakeBrowser: MacBrowser {
    let macs: [DiscoveredMac]

    func discover() async -> [DiscoveredMac] {
        try? await Task.sleep(for: macs.isEmpty ? .seconds(3) : .milliseconds(300))
        return macs
    }
}

/// A pairer that does what the demo says. Cancelled while waiting, it fails as the real one does (its connection
/// closed).
struct DemoPairer: PairingLink {
    let outcome: PairingDemo.Outcome

    func pair(
        _ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void
    ) async -> PairResult {
        switch outcome {
        case .connecting:
            try? await Task.sleep(for: .seconds(3600))
            return .failed(.unreachable)
        case .awaiting:
            onAwaitingApproval()
            try? await Task.sleep(for: .seconds(3600))
            return .failed(.unreachable)
        case .failed(let why, let after):
            if after > 0 {
                onAwaitingApproval()
                try? await Task.sleep(for: .seconds(after))
            }
            return .failed(why)
        case .paired(let after):
            onAwaitingApproval()
            try? await Task.sleep(for: .seconds(after))
            if Task.isCancelled { return .failed(.unreachable) }
            return .paired(deviceId: "fixture", token: "fixture", macName: target.macName)
        }
    }
}

/// Not paired, and saves nothing: every launch starts unpaired. A demo that pairs is paired for the rest of the run
/// only (the store keeps the pairing in memory).
struct UnpairedStorage: PairingStorage {
    func load() -> (StoredPairing, Credentials)? { nil }
    func save(_ pairing: StoredPairing, token: String) {}
    func updateEndpoint(_ endpoint: Endpoint) {}
    func clear() {}
    func loadSnapshot() -> CachedSnapshot? { nil }
    func saveSnapshot(_ snapshot: CachedSnapshot) {}
}
#endif
