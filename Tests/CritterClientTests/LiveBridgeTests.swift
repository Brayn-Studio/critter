import CritterClient
import CritterKit
import Foundation
import Testing

private let environment = ProcessInfo.processInfo.environment

/// Against the real Critter on this Mac, only when `CRITTER_LIVE_URI` holds a pairing URI the
/// Mac approves by itself: run `scripts/dev/client-live-check.sh`, which also unpairs the device
/// whose id the test writes to `CRITTER_LIVE_OUT`.
struct LiveBridgeTests {
    @Test(.enabled(if: environment["CRITTER_LIVE_URI"] != nil, "needs CRITTER_LIVE_URI: run scripts/dev/client-live-check.sh"))
    func pairsConnectsAndGetsASnapshotFromTheRealMac() async throws {
        let uri = try #require(PairingURI(string: environment["CRITTER_LIVE_URI"] ?? ""))
        let target = PairingTarget(uri: uri)
        let transport = URLSessionTransport()

        // The certificate as manual pairing reads it, and a pin it does not match.
        #expect(await CertificateProbe(transport: transport).fingerprint(of: target.endpoint) == uri.fingerprint)
        await #expect(throws: TransportError.pinMismatch) {
            _ = try await transport.connect(host: uri.host, port: uri.port, fingerprint: String(repeating: "0", count: 64))
        }

        let paired = await Pairer(transport: transport)
            .pair(target, deviceName: "critter-bridge-client", onAwaitingApproval: {})
        guard case .paired(let deviceId, let token, let macName) = paired else {
            Issue.record("pairing failed: \(paired)")
            return
        }
        // For the script to unpair the device again, whatever happens next.
        if let out = environment["CRITTER_LIVE_OUT"] {
            try deviceId.write(toFile: out, atomically: true, encoding: .utf8)
        }

        let events = EventLog()
        let client = BridgeClient(
            transport: transport, endpoint: StaticResolver(target.endpoint), fingerprint: uri.fingerprint,
            credentials: { Credentials(deviceId: deviceId, token: token) }, app: "critter-ios/live-check",
            onEvent: events.record
        )
        await client.start()
        let live = await eventually(within: .seconds(10)) {
            events.states.contains(.connected(macName: macName))
                && events.all.contains { if case .snapshot = $0 { true } else { false } }
        }
        #expect(live, "states: \(events.states)")
        #expect(events.all.contains(.connectedTo(target.endpoint)))

        let reply = await client.request(.seen(sessionId: "no-such-session"))
        #expect(reply != .failed("未连接") && reply != .failed("超时"))
        await client.stop()
        print("LiveBridgeTests: paired \(deviceId) with \(macName); seen -> \(reply)")
    }
}
