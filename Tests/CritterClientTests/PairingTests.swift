import CritterClient
import CritterKit
import Foundation
import os
import Testing

private let pin = String(repeating: "cd", count: 32)
private let target = PairingTarget(
    endpoint: Endpoint(host: "192.168.1.20", port: 47823), fingerprint: pin, code: "K7M2QX9P", macName: "Mac"
)

/// Counts calls, and how many sockets the Mac had open at each.
private final class ApprovalLog: Sendable {
    private let openAtCall = OSAllocatedUnfairLock(initialState: [Int]())
    let mac: FakeMac

    init(_ mac: FakeMac) {
        self.mac = mac
    }

    var calls: [Int] { openAtCall.withLock { $0 } }

    var callback: @Sendable () -> Void {
        { [mac, openAtCall] in
            let open = mac.openSockets
            openAtCall.withLock { $0.append(open) }
        }
    }
}

struct PairingTests {
    @Test func pairSendsPairFirstAndReturnsTheCredentials() async throws {
        let mac = FakeMac()
        async let result = Pairer(transport: mac).pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        let first = try #require(await mac.nextFrame())
        #expect(first == .pair(code: "K7M2QX9P", deviceName: "iPhone"))
        mac.send(.paired(deviceId: "d1", token: "t1", macName: "Mac"))
        mac.send(.welcome(macName: "Mac", version: "1.4.0"))
        mac.send(.snapshot(seq: 1, sentAt: 1, body: emptySnapshot))
        #expect(await result == .paired(deviceId: "d1", token: "t1", macName: "Mac"))
        #expect(mac.connects == [FakeMac.Connect(host: "192.168.1.20", port: 47823, fingerprint: pin)])
        #expect(await eventually { mac.openSockets == 0 })
        #expect(mac.received.count == 1)
    }

    @Test func pairingTargetFromAURI() throws {
        let uri = try #require(PairingURI(string: "critter-pair://192.168.1.20:47823?fp=\(pin)&code=K7M2QX9P&name=Xuan%27s%20MacBook"))
        #expect(PairingTarget(uri: uri) == PairingTarget(
            endpoint: Endpoint(host: "192.168.1.20", port: 47823), fingerprint: pin, code: "K7M2QX9P", macName: "Xuan's MacBook"
        ))
    }

    @Test func awaitingApprovalIsReportedOnceOpen() async throws {
        let mac = FakeMac()
        let approval = ApprovalLog(mac)
        async let result = Pairer(transport: mac).pair(target, deviceName: "iPhone", onAwaitingApproval: approval.callback)
        _ = try #require(await mac.nextFrame())
        mac.send(.denied(reason: .rejected))
        _ = await result
        #expect(approval.calls == [1])

        // Never connected: never awaiting approval.
        let unreachable = FakeMac()
        unreachable.failNextConnects(.unreachable)
        let none = ApprovalLog(unreachable)
        let failed = await Pairer(transport: unreachable).pair(target, deviceName: "iPhone", onAwaitingApproval: none.callback)
        #expect(failed == .failed(.unreachable))
        #expect(none.calls.isEmpty)
    }

    @Test func rejectedOnTheMacFails() async throws {
        let mac = FakeMac()
        async let result = Pairer(transport: mac).pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        _ = try #require(await mac.nextFrame())
        mac.send(.denied(reason: .rejected))
        #expect(await result == .failed(.rejected))
        #expect(await eventually { mac.openSockets == 0 })
    }

    @Test func closeWithoutDeniedIsNoAnswer() async throws {
        let mac = FakeMac()
        async let result = Pairer(transport: mac).pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        _ = try #require(await mac.nextFrame())
        mac.drop(cleanly: true)
        #expect(await result == .failed(.noAnswer))

        // Cut off rather than closed: unreachable.
        let cut = FakeMac()
        async let cutResult = Pairer(transport: cut).pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        _ = try #require(await cut.nextFrame())
        cut.drop(cleanly: false)
        #expect(await cutResult == .failed(.unreachable))
    }

    @Test func timeoutIsNoAnswer() async throws {
        let mac = FakeMac()
        let result = await Pairer(transport: mac, timeout: .milliseconds(50))
            .pair(target, deviceName: "iPhone", onAwaitingApproval: {})
        #expect(result == .failed(.noAnswer))
        #expect(await eventually { mac.openSockets == 0 })
    }

    @Test func pinMismatchIsCertMismatch() async throws {
        let mac = FakeMac()
        mac.failNextConnects(.pinMismatch)
        let approval = ApprovalLog(mac)
        let result = await Pairer(transport: mac).pair(target, deviceName: "iPhone", onAwaitingApproval: approval.callback)
        #expect(result == .failed(.certMismatch))
        #expect(mac.received.isEmpty)
        #expect(approval.calls.isEmpty)
    }

    @Test func failureClassification() {
        // What the Mac said comes first.
        #expect(pairFailure(denied: .badCode, pinMismatch: true, timedOut: true, closedCleanly: true) == .badCode)
        #expect(pairFailure(denied: .rejected, pinMismatch: false, timedOut: false, closedCleanly: false) == .rejected)
        #expect(pairFailure(denied: .protocolMismatch, pinMismatch: false, timedOut: false, closedCleanly: false) == .protocolMismatch)
        #expect(pairFailure(denied: .badToken, pinMismatch: false, timedOut: false, closedCleanly: false) == .protocolMismatch)
        // Then the certificate.
        #expect(pairFailure(denied: nil, pinMismatch: true, timedOut: true, closedCleanly: true) == .certMismatch)
        // Then nobody answering.
        #expect(pairFailure(denied: nil, pinMismatch: false, timedOut: true, closedCleanly: false) == .noAnswer)
        #expect(pairFailure(denied: nil, pinMismatch: false, timedOut: false, closedCleanly: true) == .noAnswer)
        #expect(pairFailure(denied: nil, pinMismatch: false, timedOut: false, closedCleanly: false) == .unreachable)
    }

    @Test func failureTextsAreAndroids() {
        #expect(PairFailure.badCode.text == "这个码不对，或者已经过期了。在 Mac 的「添加手机」里点「重新生成」再试。")
        #expect(PairFailure.rejected.text == "Mac 上点了「拒绝」。要配对的话重新扫码，这次点「允许」。")
        #expect(PairFailure.protocolMismatch.text == "这台 Mac 上的 Critter 版本和手机不一致，把两边都更新到最新再试。")
        #expect(PairFailure.certMismatch.text == "这台 Mac 的证书和二维码里的不一样，已经停下。确认扫的是你自己的 Mac。")
        #expect(PairFailure.noAnswer.text == "Mac 上一直没人点「允许」。回到 Mac 前，重新扫一次码。")
        #expect(PairFailure.unreachable.text == "连不上这台 Mac。确认手机和电脑在同一个 Wi‑Fi，并且 Mac 上开着「允许手机连接」。")
    }
}
