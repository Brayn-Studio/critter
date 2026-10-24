import CritterClient
import Testing

// Device bug D2, second fix: a pairing that could not reach the Mac while the app was not active (the 本地网络 prompt
// up, or the user away turning something on) is tried again by itself once the app is active again.

private let target = PairingTarget(
    endpoint: Endpoint(host: "192.168.1.20", port: 47823), fingerprint: String(repeating: "ab", count: 32),
    code: "K7M2QX9P", macName: "Mac"
)
private let other = PairingTarget(
    endpoint: Endpoint(host: "192.168.1.21", port: 47823), fingerprint: String(repeating: "cd", count: 32),
    code: "AAAA2222", macName: "Other Mac"
)

/// Every failure but `unreachable`: the Mac was reached, or the phone stopped by itself.
private let others: [PairFailure] = [.badCode, .rejected, .protocolMismatch, .certMismatch, .noAnswer, .busy, .notSaved]

struct PairingRetryTests {
    /// Only an unreachable Mac that the attempt never reached, with the app not active during the attempt or since it
    /// failed, and only once.
    @Test func onlyAnUnreachableMacWhileAwayIsTriedAgainOnce() {
        #expect(
            PairingRetry.retriesWhenActive(failure: .unreachable, reachedMac: false, wasInactive: true, alreadyRetried: false)
        )
        #expect(
            !PairingRetry.retriesWhenActive(failure: .unreachable, reachedMac: false, wasInactive: false, alreadyRetried: false)
        )
        #expect(
            !PairingRetry.retriesWhenActive(failure: .unreachable, reachedMac: false, wasInactive: true, alreadyRetried: true)
        )
        // The Mac had the code already: a second try would only be told `badCode`.
        #expect(
            !PairingRetry.retriesWhenActive(failure: .unreachable, reachedMac: true, wasInactive: true, alreadyRetried: false)
        )
        for failure in others {
            for reachedMac in [false, true] {
                for wasInactive in [false, true] {
                    for alreadyRetried in [false, true] {
                        #expect(
                            !PairingRetry.retriesWhenActive(
                                failure: failure, reachedMac: reachedMac, wasInactive: wasInactive,
                                alreadyRetried: alreadyRetried
                            ),
                            "\(failure)"
                        )
                    }
                }
            }
        }
    }

    /// The phone locked while walking to the Mac: the connection is cut after the Mac took the code. Not tried again,
    /// in any order of the failure and the scene.
    @Test func aCutAfterTheMacHadTheCodeIsNotTriedAgain() {
        var during = PairingRetry()
        during.started(target)
        _ = during.sceneChanged(active: false)
        #expect(during.failed(.unreachable, reachedMac: true) == nil)
        #expect(during.sceneChanged(active: true) == nil)

        var after = PairingRetry()
        after.started(target)
        #expect(after.failed(.unreachable, reachedMac: true) == nil)
        #expect(after.sceneChanged(active: false) == nil)
        #expect(after.sceneChanged(active: true) == nil)

        var back = PairingRetry()
        back.started(target)
        _ = back.sceneChanged(active: false)
        _ = back.sceneChanged(active: true)
        #expect(back.failed(.unreachable, reachedMac: true) == nil)

        // The next attempt is its own: one that never reached the Mac is tried again.
        var next = PairingRetry()
        next.started(target)
        _ = next.sceneChanged(active: false)
        #expect(next.failed(.unreachable, reachedMac: true) == nil)
        #expect(next.sceneChanged(active: true) == nil)
        next.started(target)
        _ = next.sceneChanged(active: false)
        #expect(next.failed(.unreachable, reachedMac: false) == nil)
        #expect(next.sceneChanged(active: true) == target)
    }

    /// The connection fails while the prompt is up: tried again when it is answered.
    @Test func aFailureWhileInactiveIsTriedAgainWhenActive() {
        var retry = PairingRetry()
        retry.started(target)
        #expect(retry.sceneChanged(active: false) == nil)
        #expect(retry.failed(.unreachable) == nil)
        #expect(retry.sceneChanged(active: true) == target)
    }

    /// The connection fails just before the prompt shows: tried again when it is answered.
    @Test func inactiveRightAfterTheFailureIsTriedAgainWhenActive() {
        var retry = PairingRetry()
        retry.started(target)
        #expect(retry.failed(.unreachable) == nil)
        #expect(retry.sceneChanged(active: false) == nil)
        #expect(retry.sceneChanged(active: true) == target)
    }

    /// The prompt answered before the attempt gives up: tried again as soon as it fails.
    @Test func activeAgainBeforeTheFailureIsTriedAgainAtOnce() {
        var retry = PairingRetry()
        retry.started(target)
        #expect(retry.sceneChanged(active: false) == nil)
        // Still under way: nothing to try again yet.
        #expect(retry.sceneChanged(active: true) == nil)
        #expect(retry.failed(.unreachable) == target)
    }

    /// Not active at all while it ran, or only before it started: it failed for some other reason.
    @Test func inactiveBeforeTheAttemptDoesNotCount() {
        var retry = PairingRetry()
        #expect(retry.sceneChanged(active: false) == nil)
        #expect(retry.sceneChanged(active: true) == nil)
        retry.started(target)
        #expect(retry.failed(.unreachable) == nil)
        #expect(retry.sceneChanged(active: true) == nil)

        // Still inactive when it starts, it was inactive during it.
        var late = PairingRetry()
        _ = late.sceneChanged(active: false)
        late.started(target)
        #expect(late.sceneChanged(active: true) == nil)
        #expect(late.failed(.unreachable) == target)
    }

    /// The same target is tried again by itself once; a new one may be, once more.
    @Test func aTargetIsTriedAgainOnceAndANewOneResetsThat() {
        var retry = PairingRetry()
        retry.started(target)
        _ = retry.sceneChanged(active: false)
        _ = retry.failed(.unreachable)
        #expect(retry.sceneChanged(active: true) == target)
        // Asked again before the screen started it (or it could not start): not twice.
        #expect(retry.sceneChanged(active: true) == nil)

        // The attempt tried again fails as well, in either order: it stays failed.
        retry.started(target)
        _ = retry.sceneChanged(active: false)
        #expect(retry.failed(.unreachable) == nil)
        #expect(retry.sceneChanged(active: true) == nil)
        // Scanned again, the same code: still the same target.
        retry.started(target)
        #expect(retry.failed(.unreachable) == nil)
        _ = retry.sceneChanged(active: false)
        #expect(retry.sceneChanged(active: true) == nil)

        // Another code scanned: tried again by itself once more.
        retry.started(other)
        #expect(retry.failed(.unreachable) == nil)
        _ = retry.sceneChanged(active: false)
        #expect(retry.sceneChanged(active: true) == other)
    }

    /// Any other failure stays on its page, away or not, in either order.
    @Test func otherFailuresAreNotTriedAgain() {
        for failure in others {
            var during = PairingRetry()
            during.started(target)
            _ = during.sceneChanged(active: false)
            #expect(during.failed(failure) == nil, "\(failure)")
            #expect(during.sceneChanged(active: true) == nil, "\(failure)")

            var after = PairingRetry()
            after.started(target)
            #expect(after.failed(failure) == nil, "\(failure)")
            _ = after.sceneChanged(active: false)
            #expect(after.sceneChanged(active: true) == nil, "\(failure)")

            var back = PairingRetry()
            back.started(target)
            _ = back.sceneChanged(active: false)
            _ = back.sceneChanged(active: true)
            #expect(back.failed(failure) == nil, "\(failure)")
        }
    }

    /// The user left the failure page (「重新扫码」), cancelled, or paired: nothing is tried again.
    @Test func nothingIsTriedAgainOnceThePageIsLeft() {
        var left = PairingRetry()
        left.started(target)
        _ = left.failed(.unreachable)
        _ = left.sceneChanged(active: false)
        left.ended()
        #expect(left.sceneChanged(active: true) == nil)
        // Away and back again afterwards: still nothing.
        #expect(left.sceneChanged(active: false) == nil)
        #expect(left.sceneChanged(active: true) == nil)

        var leftWhileAway = PairingRetry()
        leftWhileAway.started(target)
        _ = leftWhileAway.sceneChanged(active: false)
        _ = leftWhileAway.failed(.unreachable)
        leftWhileAway.ended()
        #expect(leftWhileAway.sceneChanged(active: true) == nil)

        var cancelled = PairingRetry()
        cancelled.started(target)
        _ = cancelled.sceneChanged(active: false)
        cancelled.ended()
        #expect(cancelled.sceneChanged(active: true) == nil)
        // A result that comes after that is not this screen's any more.
        #expect(cancelled.failed(.unreachable) == nil)
        #expect(cancelled.sceneChanged(active: false) == nil)
        #expect(cancelled.sceneChanged(active: true) == nil)
    }

    /// Another attempt started after the failure: the failed one is not tried again.
    @Test func anotherAttemptTakesOver() {
        var retry = PairingRetry()
        retry.started(target)
        _ = retry.failed(.unreachable)
        retry.started(other)
        _ = retry.sceneChanged(active: false)
        // The new attempt is under way: nothing to try again, and never the old target.
        #expect(retry.sceneChanged(active: true) == nil)
        #expect(retry.failed(.badCode) == nil)
        _ = retry.sceneChanged(active: false)
        #expect(retry.sceneChanged(active: true) == nil)
    }
}
