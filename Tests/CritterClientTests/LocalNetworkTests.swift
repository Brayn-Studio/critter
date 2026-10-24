@testable import CritterClient
import Foundation
import Network
import Testing

// iOS's 本地网络 permission, turned down: what Network and URLSession report then is told from a Mac that is away
// (`LocalNetworkDenial`), so the screens can say so instead of "正在重试" for ever (plan 1 backlog, plan 5 T3).

private let policyDenied = NWError.dns(DNSServiceErrorType(-65570))

struct LocalNetworkDenialTests {
    /// `kDNSServiceErr_PolicyDenied`: Bonjour's answer when the app may not use the local network.
    @Test func policyDeniedIsADenial() {
        #expect(LocalNetworkDenial.policyDenied == -65570)
        #expect(LocalNetworkDenial.isDenied(policyDenied))
        // Other DNS errors, a refused or unreachable port, a TLS failure: the Mac is away, or something else.
        let others: [NWError] = [
            .dns(DNSServiceErrorType(-65554)), .dns(DNSServiceErrorType(-65537)), .posix(.ECONNREFUSED), .posix(.ENETDOWN),
            .posix(.EHOSTUNREACH), .tls(errSSLHandshakeFail),
        ]
        for error in others {
            #expect(!LocalNetworkDenial.isDenied(error), "\(error)")
        }
    }

    /// A connection's path, unsatisfied because the app may not use the local network.
    @Test func aPathDeniedTheLocalNetworkIsADenial() {
        #expect(LocalNetworkDenial.isDenied(NWPath.UnsatisfiedReason.localNetworkDenied))
        for reason in [NWPath.UnsatisfiedReason.notAvailable, .cellularDenied, .wifiDenied, nil] {
            #expect(!LocalNetworkDenial.isDenied(reason), "\(String(describing: reason))")
        }
    }

    /// The browser waits (or fails) with the policy error; ready, or waiting for another reason, says nothing.
    @Test func theBrowserSaysSo() {
        #expect(LocalNetworkDenial.isDenied(NWBrowser.State.waiting(policyDenied)))
        #expect(LocalNetworkDenial.isDenied(NWBrowser.State.failed(policyDenied)))
        #expect(!LocalNetworkDenial.isDenied(NWBrowser.State.ready))
        #expect(!LocalNetworkDenial.isDenied(NWBrowser.State.setup))
        #expect(!LocalNetworkDenial.isDenied(NWBrowser.State.waiting(.dns(DNSServiceErrorType(-65563)))))
    }

    /// A connection that waits or fails with the policy error, or waits on a path denied the local network.
    @Test func aConnectionSaysSo() {
        let refused = NWError.posix(.ECONNREFUSED)
        #expect(LocalNetworkDenial.isDenied(NWConnection.State.waiting(policyDenied), path: nil))
        #expect(LocalNetworkDenial.isDenied(NWConnection.State.failed(policyDenied), path: nil))
        #expect(LocalNetworkDenial.isDenied(NWConnection.State.waiting(.posix(.ENETDOWN)), path: .localNetworkDenied))
        #expect(!LocalNetworkDenial.isDenied(NWConnection.State.waiting(refused), path: nil))
        #expect(!LocalNetworkDenial.isDenied(NWConnection.State.waiting(refused), path: .notAvailable))
        #expect(!LocalNetworkDenial.isDenied(NWConnection.State.ready, path: nil))
        #expect(!LocalNetworkDenial.isDenied(NWConnection.State.preparing, path: .localNetworkDenied))
    }

    /// What URLSession ends a task with: its own error, with Network's underneath (`NSUnderlyingErrorKey`, as many
    /// levels down as it goes). The policy error in Network's DNS domain, or as an `NWError`, is a denial; "not
    /// connected" (-1009) or "network is down" (50) alone are not: they are also what a phone off Wi-Fi gets.
    @Test func aURLSessionErrorSaysSoUnderneath() {
        let dns = NSError(domain: kNWErrorDomainDNS as String, code: -65570)
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: kCFErrorDomainCFNetwork as String, code: -1009, userInfo: [NSUnderlyingErrorKey: dns]),
        ])
        #expect(LocalNetworkDenial.isDenied(dns as any Error))
        #expect(LocalNetworkDenial.isDenied(wrapped as any Error))
        #expect(LocalNetworkDenial.isDenied(policyDenied as any Error))
        let alsoWrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSUnderlyingErrorKey: policyDenied])
        #expect(LocalNetworkDenial.isDenied(alsoWrapped as any Error))

        let notDenied: [any Error] = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: kNWErrorDomainPOSIX as String, code: Int(POSIXErrorCode.ENETDOWN.rawValue)),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: kNWErrorDomainPOSIX as String, code: Int(POSIXErrorCode.ECONNREFUSED.rawValue)),
            ]),
            NSError(domain: "other", code: -65570),
            TransportError.unreachable,
        ]
        for error in notDenied {
            #expect(!LocalNetworkDenial.isDenied(error), "\(error)")
        }
    }
}

struct LocalNetworkAccessTests {
    /// Denied once a refusal was seen; allowed again once a Mac was found or a connection opened. Observers hear each
    /// change, once.
    @Test func itFollowsWhatWasSeen() {
        let access = LocalNetworkAccess()
        let heard = Heard()
        access.observe { heard.add($0) }
        #expect(!access.denied)
        access.saw(policyDenied)
        #expect(access.denied)
        access.saw(NWError.posix(.ECONNREFUSED))
        #expect(access.denied)
        access.sawAllowed()
        #expect(!access.denied)
        access.sawAllowed()
        #expect(heard.values == [true, false])
    }
}

/// Bonjour's resolution of a found service: a connection that waits (refused, no route yet) is tried once more with a
/// new one, then given up; one that waits because the local network is denied is not tried again (plan 1 backlog).
struct BonjourResolveTests {
    @Test func aWaitingServiceIsTriedOnceMore() {
        let refused = NWConnection.State.waiting(.posix(.ECONNREFUSED))
        #expect(BonjourBrowser.step(refused, attempt: 1, path: nil) == .retry)
        #expect(BonjourBrowser.step(refused, attempt: 2, path: nil) == .giveUp(denied: false))
        #expect(BonjourBrowser.maxResolveAttempts == 2)
    }

    @Test func aDeniedServiceIsNotTriedAgain() {
        #expect(BonjourBrowser.step(.waiting(policyDenied), attempt: 1, path: nil) == .giveUp(denied: true))
        #expect(BonjourBrowser.step(.waiting(.posix(.ENETDOWN)), attempt: 1, path: .localNetworkDenied) == .giveUp(denied: true))
        #expect(BonjourBrowser.step(.failed(policyDenied), attempt: 1, path: nil) == .giveUp(denied: true))
    }

    @Test func readyResolvesAndTheRestWaits() {
        #expect(BonjourBrowser.step(.ready, attempt: 1, path: nil) == .resolved)
        #expect(BonjourBrowser.step(.ready, attempt: 2, path: nil) == .resolved)
        #expect(BonjourBrowser.step(.failed(.posix(.ECONNRESET)), attempt: 1, path: nil) == .giveUp(denied: false))
        for state in [NWConnection.State.setup, .preparing, .cancelled] {
            #expect(BonjourBrowser.step(state, attempt: 1, path: nil) == .wait)
        }
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Bool] = []
    var values: [Bool] { lock.withLock { all } }
    func add(_ value: Bool) { lock.withLock { all.append(value) } }
}
