@testable import CritterClient
import CritterKit
import Foundation
import os
import Testing

/// Ledger (plan 1 backlog, plan 5 T3): the real transport's decisions -- the pin, when a connection counts as open, and
/// how it ended -- had only the live check against a real Mac. Here they run against `LoopbackMac`: a TLS WebSocket
/// listener on 127.0.0.1 with a self-signed certificate of its own, as the Mac's bridge is.
@Suite(
    .enabled(if: LoopbackMac.canRun, "needs macOS 15 (a certificate in memory only) and /usr/bin/openssl"),
    .timeLimit(.minutes(1))
)
struct PinnedSocketTests {
    private let transport = URLSessionTransport(connectTimeout: .seconds(5), access: LocalNetworkAccess())

    private func connect(_ mac: LoopbackMac, pin: String?) async throws -> any BridgeSocket {
        try await transport.connect(host: "127.0.0.1", port: mac.port, fingerprint: pin)
    }

    /// The certificate pinned at pairing: the WebSocket opens, frames go both ways, pings get their pongs (the Mac's
    /// listener answers them by itself, `autoReplyPing`), and the socket says which certificate it saw.
    @Test func thePinnedCertificateOpens() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let socket = try await connect(mac, pin: mac.fingerprint)
        defer { socket.close() }
        #expect(socket.peerFingerprint == mac.fingerprint)
        try await within("send") { try await socket.send("hello") }
        #expect(try await within("receive") { try await socket.receive() } == "hello")
        // A pong is read only while a `receive` waits, as `BridgeClient`'s receive loop always has one.
        let next = Task { try await socket.receive() }
        try await within("ping") { try await socket.sendPing() }
        try await within("ping again") { try await socket.sendPing() }
        try await within("send again") { try await socket.send("again") }
        #expect(try await within("receive again") { try await next.value } == "again")
    }

    /// Any other certificate (another Mac at the address, or a reset one): `.pinMismatch`, and nothing is opened. The
    /// pin is the whole lowercase hex: one digit off, or the same in capitals, is another pin.
    @Test func anotherCertificateIsAPinMismatch() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        var oneOff = Array(mac.fingerprint)
        oneOff[63] = oneOff[63] == "0" ? "1" : "0"
        for pin in [String(repeating: "ab", count: 32), String(oneOff), mac.fingerprint.uppercased()] {
            await #expect(throws: TransportError.pinMismatch, "\(pin)") {
                _ = try await connect(mac, pin: pin)
            }
        }
    }

    /// Pairing by hand reads the certificate first (no pin), sending nothing.
    @Test func theProbeReadsTheCertificate() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let probe = CertificateProbe(transport: transport)
        #expect(await probe.fingerprint(of: Endpoint(host: "127.0.0.1", port: mac.port)) == mac.fingerprint)
    }

    /// The Mac ends the connection with a WebSocket close (it stops, or turns the phone away): a clean end.
    @Test func aCloseFromTheMacIsClean() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let socket = try await connect(mac, pin: mac.fingerprint)
        defer { socket.close() }
        try await within { try await socket.send("close") }
        await #expect(throws: TransportError.closed(cleanly: true)) {
            _ = try await within { try await socket.receive() }
        }
    }

    /// The connection goes without a close frame (the Mac quit, slept, the network went): not clean.
    @Test func aDroppedConnectionIsNotClean() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let socket = try await connect(mac, pin: mac.fingerprint)
        defer { socket.close() }
        try await within { try await socket.send("drop") }
        await #expect(throws: TransportError.closed(cleanly: false)) {
            _ = try await within { try await socket.receive() }
        }
    }

    /// The phone closes the socket itself (leaving the foreground, unpairing): a `receive` waiting on it ends.
    @Test func closingTheSocketEndsAWaitingReceive() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let socket = try await connect(mac, pin: mac.fingerprint)
        let receiving = Task { try await socket.receive() }
        try await Task.sleep(for: .milliseconds(100))
        socket.close()
        await #expect(throws: TransportError.self) {
            _ = try await within { try await receiving.value }
        }
        await #expect(throws: TransportError.self) {
            try await within { try await socket.send("after") }
        }
    }

    /// Nothing listening at the address any more: `.unreachable`, at once rather than at the deadline.
    @Test func noMacListeningIsUnreachable() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let port = mac.port
        mac.stop()
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        await #expect(throws: TransportError.unreachable) {
            _ = try await transport.connect(host: "127.0.0.1", port: port, fingerprint: mac.fingerprint)
        }
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    /// An opened connection says the local network is usable: a refusal seen before is over.
    @Test func anOpenedConnectionSaysTheLocalNetworkIsAllowed() async throws {
        let mac = try await LoopbackMac()
        // Alive (and listening) to the end of the test: ARC may let it go after its last use.
        defer { mac.stop() }
        let access = LocalNetworkAccess()
        access.sawDenied()
        let socket = try await URLSessionTransport(connectTimeout: .seconds(5), access: access)
            .connect(host: "127.0.0.1", port: mac.port, fingerprint: mac.fingerprint)
        defer { socket.close() }
        #expect(!access.denied)
    }
}

private struct TimedOut: Error {
    var what = ""
}

/// `work`'s result, or `TimedOut` after `limit`: a socket call that never returns fails its test instead of holding up
/// the run (the call is left behind).
private func within<T: Sendable>(
    _ what: String = "", limit: Duration = .seconds(5), _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let done = OSAllocatedUnfairLock(initialState: false)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            let first = done.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(with: result) }
        }
        Task {
            try? await Task.sleep(for: limit)
            finish(.failure(TimedOut(what: what)))
        }
        Task {
            do { finish(.success(try await work())) } catch { finish(.failure(error)) }
        }
    }
}
