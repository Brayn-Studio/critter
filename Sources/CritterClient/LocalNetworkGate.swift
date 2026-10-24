import CritterKit
import Foundation
import Network
import os

/// Waits until the local network can be tried before a pairing connects.
public protocol LocalNetworkGate: Sendable {
    /// Returns once the local network is allowed, or says nothing about the permission. While it is refused (the
    /// first-run prompt is up, or 本地网络 is off) it calls `onRefused` once and keeps waiting; cancellation ends the
    /// wait. Returns false when it ended by cancellation.
    func waitUntilUsable(onRefused: @escaping @Sendable () -> Void) async -> Bool
}

/// Never waits: the local network is tried at once (the default; tests, and wherever there is no such permission).
public struct OpenLocalNetworkGate: LocalNetworkGate {
    public init() {}

    public func waitUntilUsable(onRefused: @escaping @Sendable () -> Void) async -> Bool {
        true
    }
}

/// Asks a Bonjour browser for the bridge (`_critter._tcp`, as `BonjourBrowser`) whether the local network may be used
/// (Apple TN3179). Otherwise the pairing connection is the app's first touch of the local network: it is what makes iOS
/// show the 本地网络 prompt, and it fails (or runs out its time) while the prompt is up. Allowed, it goes on at once;
/// refused, it waits, for as long as it takes, for the browser to be let browse (the user allows in the prompt, or turns
/// 本地网络 on in Settings and comes back); another error, or nothing decisive within `grace`, goes on too, and the
/// connection fails as it would have (`step`). What the browser sees goes to `LocalNetworkAccess`.
public struct BonjourLocalNetworkGate: LocalNetworkGate {
    private let grace: Duration
    private let access: LocalNetworkAccess

    /// - Parameters:
    ///   - grace: how long the browser has to say anything decisive before the pairing goes on.
    ///   - access: told what the browser sees (`LocalNetworkAccess.saw`).
    public init(grace: Duration = .seconds(2), access: LocalNetworkAccess = .shared) {
        self.grace = grace
        self.access = access
    }

    public func waitUntilUsable(onRefused: @escaping @Sendable () -> Void) async -> Bool {
        let wait = LocalNetworkWait(access: access, onRefused: onRefused)
        let timer = Task { [grace] in
            guard (try? await Task.sleep(for: grace)) != nil else { return }
            wait.graceOver()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await wait.run()
        } onCancel: {
            wait.cancel()
        }
    }

    /// How long after a browser fails a new one starts (a failed browser never becomes ready).
    static let restartDelay: DispatchTimeInterval = .seconds(1)

    /// What a pairing waiting for the local network does next.
    enum Step: Equatable {
        /// Nothing decisive yet.
        case wait
        /// Refused: the prompt is up, or 本地网络 is off. Wait, now without a time limit, for `.ready`.
        case refused
        /// Connect: allowed, nothing said about the permission, or nothing decisive within the grace.
        case proceed
    }

    /// The step for the browser's latest `state`, after a refusal (`refused`) or not, with the grace over or not. Pure.
    static func step(_ state: NWBrowser.State, refused: Bool, graceOver: Bool) -> Step {
        if LocalNetworkDenial.isAllowed(state) { return .proceed }
        if LocalNetworkDenial.isDenied(state) { return .refused }
        // Refused once: only `.ready` (or cancellation) ends the wait.
        if refused { return .wait }
        switch state {
        case .waiting, .failed: return .proceed
        default: return graceOver ? .proceed : .wait
        }
    }
}

/// One `waitUntilUsable`: its browser, what it has seen, and the pairing waiting for it.
private final class LocalNetworkWait: Sendable {
    private struct State {
        var latest = NWBrowser.State.setup
        var refused = false
        var graceOver = false
        /// How it ended (usable, or cancelled); nil while it waits.
        var outcome: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
        var browser: NWBrowser?
    }

    private let queue = DispatchQueue(label: "local.critter.client.local-network")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let access: LocalNetworkAccess
    private let onRefused: @Sendable () -> Void

    init(access: LocalNetworkAccess, onRefused: @escaping @Sendable () -> Void) {
        self.access = access
        self.onRefused = onRefused
    }

    /// Browses until it is decided; at once if it already is (cancelled before it started).
    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            let ended: Bool? = state.withLock { s in
                if s.outcome == nil { s.waiter = continuation }
                return s.outcome
            }
            if let ended {
                continuation.resume(returning: ended)
            } else {
                queue.async { self.browse() }
            }
        }
    }

    func graceOver() {
        decide { $0.graceOver = true }
    }

    func cancel() {
        finish(false)
    }

    /// A browser for the bridge's service, replacing the last one (which failed); none once it is decided. On `queue`,
    /// as is every browser's start and cancel.
    private func browse() {
        let browser = NWBrowser(for: .bonjour(type: BridgeProtocol.bonjourType, domain: nil), using: .tcp)
        let (goes, old): (Bool, NWBrowser?) = state.withLock { s in
            guard s.outcome == nil else { return (false, nil) }
            defer { s.browser = browser }
            return (true, s.browser)
        }
        guard goes else { return }
        old?.stateUpdateHandler = nil
        old?.cancel()
        browser.stateUpdateHandler = { [weak self] update in self?.saw(update) }
        browser.start(queue: queue)
    }

    private func saw(_ update: NWBrowser.State) {
        access.saw(update)
        decide { $0.latest = update }
        if case .failed = update {
            queue.asyncAfter(deadline: .now() + BonjourLocalNetworkGate.restartDelay) { [weak self] in self?.browse() }
        }
    }

    private func decide(_ change: @Sendable (inout State) -> Void) {
        let (step, firstRefusal): (BonjourLocalNetworkGate.Step?, Bool) = state.withLock { s in
            guard s.outcome == nil else { return (nil, false) }
            change(&s)
            let step = BonjourLocalNetworkGate.step(s.latest, refused: s.refused, graceOver: s.graceOver)
            let first = step == .refused && !s.refused
            if step == .refused { s.refused = true }
            return (step, first)
        }
        if firstRefusal { onRefused() }
        if step == .proceed { finish(true) }
    }

    private func finish(_ usable: Bool) {
        let (waiter, browser): (CheckedContinuation<Bool, Never>?, NWBrowser?) = state.withLock { s in
            guard s.outcome == nil else { return (nil, nil) }
            s.outcome = usable
            defer {
                s.waiter = nil
                s.browser = nil
            }
            return (s.waiter, s.browser)
        }
        if let browser { queue.async { browser.cancel() } }
        waiter?.resume(returning: usable)
    }
}
