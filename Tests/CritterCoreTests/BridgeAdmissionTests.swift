import Foundation
import Testing
@testable import CritterCore

private let policy = BridgeAdmission(
    maxUnauthenticated: 3, maxConnections: 5, firstFrameTimeout: 20, approvalTimeout: 300, idleTimeout: 600
)

@Test func admitsUnauthenticatedUpToTheCap() {
    #expect(policy.admits(open: []))
    #expect(policy.admits(open: [.awaitingFirst, .awaitingFirst]))
    #expect(!policy.admits(open: [.awaitingFirst, .awaitingFirst, .awaitingFirst]))
}

@Test func approvalWaitsAndClosingConnectionsCountAsUnauthenticated() {
    #expect(!policy.admits(open: [.awaitingFirst, .awaitingApproval(deviceName: "Pixel"), .closed]))
}

@Test func pairedConnectionsOnlyCountTowardTheTotal() {
    let ready = Array(repeating: BridgeConnection.Phase.ready(deviceId: "d"), count: 4)
    #expect(policy.admits(open: ready))
    #expect(policy.admits(open: [.ready(deviceId: "a"), .ready(deviceId: "b"), .awaitingFirst, .awaitingFirst]))
    #expect(!policy.admits(open: ready + [.awaitingFirst]))
}

@Test func timeoutsFollowThePhase() {
    #expect(policy.timeout(for: .awaitingFirst) == 20)
    #expect(policy.timeout(for: .awaitingApproval(deviceName: "Pixel")) == 300)
    #expect(policy.timeout(for: .ready(deviceId: "d")) == 600)
    #expect(policy.timeout(for: .closed) == nil)
}

@Test func onlyAPairedPhonesTrafficKeepsItOpen() {
    #expect(policy.trafficExtends(.ready(deviceId: "d")))
    #expect(!policy.trafficExtends(.awaitingFirst))
    #expect(!policy.trafficExtends(.awaitingApproval(deviceName: "Pixel")))
    #expect(!policy.trafficExtends(.closed))
}

@Test func standardPolicyStaysWellInsideTheFileLimit() {
    let standard = BridgeAdmission.standard
    #expect(standard.maxUnauthenticated == 8)
    #expect(standard.maxConnections == 32)
    #expect(standard.maxConnections < 64) // the default soft limit is 256 descriptors
    #expect(standard.firstFrameTimeout >= 15 && standard.firstFrameTimeout <= 30)
    #expect(standard.approvalTimeout == TimeInterval(PairingCode.lifetimeMs / 1000))
    #expect(standard.idleTimeout == 600)
}
