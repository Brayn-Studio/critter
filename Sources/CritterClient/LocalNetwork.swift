import Foundation
import Network
import os

/// Whether what Network or URLSession reported says the app may not use the local network: iOS's 本地网络 permission,
/// turned down by the user (or later off in Settings). A Mac on the same Wi-Fi then looks exactly like one that is
/// away, so this is how the screens can tell (Apple TN3179):
/// - Bonjour (`NWBrowser`, and the connection resolving a service it found) waits or fails with
///   `kDNSServiceErr_PolicyDenied` (-65570), Network's DNS error;
/// - a connection waits with its path unsatisfied for `.localNetworkDenied`;
/// - URLSession ends the task with its own error, the one Network gave it underneath (`NSUnderlyingErrorKey`, in
///   Network's DNS error domain).
///
/// "Not connected" (-1009) or "network is down" (`ENETDOWN`) alone are not taken as a denial: a phone off Wi-Fi gets
/// them too. A connection the policy kept shut may report only those; the Bonjour lookup that follows a failed
/// connection (`FallbackResolver`), or the one the failure page starts, says it plainly. Pure.
public enum LocalNetworkDenial {
    /// `kDNSServiceErr_PolicyDenied` (dns_sd.h).
    public static let policyDenied: DNSServiceErrorType = -65570

    /// What the screens say when it is denied, and their button, which opens the app's page in Settings.
    public static let line = "没有本地网络权限，连不上 Mac。在设置里打开 Critter 的「本地网络」。"
    public static let action = "去设置"

    public static func isDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDenied }
        return false
    }

    public static func isDenied(_ reason: NWPath.UnsatisfiedReason?) -> Bool {
        reason == .localNetworkDenied
    }

    public static func isDenied(_ state: NWBrowser.State) -> Bool {
        switch state {
        case .waiting(let error), .failed(let error): isDenied(error)
        default: false
        }
    }

    /// A browser that reached `.ready` was let browse: the local network is allowed. Denied, it waits with the policy
    /// error, and goes on to `.ready` once the user allows (the switch turned on in Settings; on an iPhone the first-run
    /// prompt did not show as a refusal at all). Pure.
    public static func isAllowed(_ state: NWBrowser.State) -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// Whether a browse window that ended says the local network is allowed: it ran its whole time (`ranOut`; one cut
    /// short, by a cancelled task, saw too little) and no refusal came while it ran (`sawDenial`: the browser's, or a
    /// resolving connection's). Pure.
    public static func isAllowed(afterWindowSawDenial sawDenial: Bool, ranOut: Bool) -> Bool {
        ranOut && !sawDenial
    }

    /// A connection's state, with the reason its path is unsatisfied (`currentPath?.unsatisfiedReason`).
    public static func isDenied(_ state: NWConnection.State, path: NWPath.UnsatisfiedReason?) -> Bool {
        switch state {
        case .waiting(let error), .failed(let error): isDenied(error) || isDenied(path)
        default: false
        }
    }

    /// Any error, as URLSession (or Network) hands it: an `NWError`, or an `NSError` in Network's DNS domain with the
    /// policy code, itself or underneath.
    public static func isDenied(_ error: any Error) -> Bool {
        var next: (any Error)? = error
        // A few levels at most: URLSession wraps CFNetwork's error, which wraps Network's.
        for _ in 0..<8 {
            guard let current = next else { return false }
            if let network = current as? NWError { return isDenied(network) }
            let ns = current as NSError
            if ns.domain == (kNWErrorDomainDNS as String), ns.code == Int(policyDenied) { return true }
            next = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return false
    }
}

/// What the app has seen of its access to the local network, for the screens to say so with 「去设置」. Denied once a
/// Bonjour lookup or a connection was refused for it (`LocalNetworkDenial`); allowed again once a Mac was found, a
/// connection opened, a Bonjour browser was let browse (`.ready`) or a browse window ended without any refusal -- so
/// the permission given while the Mac is away (or answered slowly to the first-run prompt) is noticed too. Fed by
/// `BonjourBrowser`, `BonjourLocalNetworkGate` and `URLSessionTransport` (`shared`, unless they are given another).
public final class LocalNetworkAccess: Sendable {
    public static let shared = LocalNetworkAccess()

    private struct State {
        var denied = false
        var observers: [@Sendable (Bool) -> Void] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Whether the last word was a refusal.
    public var denied: Bool { state.withLock { $0.denied } }

    /// Calls `onChange` with each change from now on (on whatever thread saw it).
    public func observe(_ onChange: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.observers.append(onChange) }
    }

    /// A failure: a denial if it says so; anything else says nothing about the permission.
    public func saw(_ error: any Error) {
        if LocalNetworkDenial.isDenied(error) { set(true) }
    }

    /// A refusal seen another way (a browser's or a connection's state).
    public func sawDenied() { set(true) }

    /// A Bonjour browser's state: a refusal, or `.ready` (it is let browse); anything else says nothing.
    public func saw(_ state: NWBrowser.State) {
        if LocalNetworkDenial.isDenied(state) {
            set(true)
        } else if LocalNetworkDenial.isAllowed(state) {
            set(false)
        }
    }

    /// A Bonjour browse window ended (`LocalNetworkDenial.isAllowed(afterWindowSawDenial:ranOut:)`): allowed again if
    /// it ran out without a refusal; otherwise it says nothing.
    public func browseWindowEnded(sawDenial: Bool, ranOut: Bool) {
        if LocalNetworkDenial.isAllowed(afterWindowSawDenial: sawDenial, ranOut: ranOut) { set(false) }
    }

    /// A Mac was found, or a connection opened.
    public func sawAllowed() { set(false) }

    private func set(_ denied: Bool) {
        let observers: [@Sendable (Bool) -> Void] = state.withLock { s in
            guard s.denied != denied else { return [] }
            s.denied = denied
            return s.observers
        }
        observers.forEach { $0(denied) }
    }
}
