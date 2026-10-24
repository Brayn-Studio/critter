@testable import CritterClient
import CritterKit
import Foundation
import Network
import os
import Security

/// A stand-in for the Mac's bridge on 127.0.0.1: a TLS WebSocket listener (Network.framework, as the Mac's
/// `BridgeServer`) with a self-signed certificate made for the test run by `/usr/bin/openssl` (as the Mac's
/// `BridgeIdentity`) and imported into memory only, never a keychain. Nothing leaves the loopback interface.
///
/// What it does with a text frame it gets: `close` -> a WebSocket close frame (a clean end); `drop` -> the connection
/// is cancelled without one; anything else comes back as it came.
final class LoopbackMac: @unchecked Sendable {
    /// SHA-256 of the certificate, lowercase hex: what a phone pins.
    let fingerprint: String
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.critter.loopback-mac")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = 0

    /// Whether this Mac can make a certificate without touching a keychain (`kSecImportToMemoryOnly`, macOS 15).
    static var canRun: Bool {
        if #available(macOS 15.0, *) { return FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") }
        return false
    }

    /// How many connections it took.
    var acceptedCount: Int { lock.withLock { accepted } }

    init() async throws {
        let (identity, fingerprint) = try Self.identity()
        self.fingerprint = fingerprint
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw Failure.identity }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        port = try await Self.start(listener, on: queue)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    deinit {
        stop()
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock {
            defer { connections = [] }
            return connections
        }
        open.forEach { $0.cancel() }
    }

    private enum Failure: Error { case openssl(Int32), identity, listener }

    private static func start(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
        // Taken as the handler is set: a listener reports `.ready` once, and the handlers run on `queue`.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let once: @Sendable (Result<UInt16, any Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: once(.success(listener?.port?.rawValue ?? 0))
                case .waiting, .failed, .cancelled: once(.failure(Failure.listener))
                default: break
                }
            }
            listener.start(queue: queue)
            // Never waits for ever: a listener that is not up in 5 s fails the test.
            queue.asyncAfter(deadline: .now() + 5) { once(.failure(Failure.listener)) }
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            accepted += 1
            connections.append(connection)
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard metadata?.opcode == .text, let data else {
                if metadata?.opcode != .close { self.receive(on: connection) }
                return
            }
            switch String(decoding: data, as: UTF8.self) {
            case "close":
                let close = NWProtocolWebSocket.Metadata(opcode: .close)
                close.closeCode = .protocolCode(.normalClosure)
                let frame = NWConnection.ContentContext(identifier: "close", metadata: [close])
                connection.send(content: nil, contentContext: frame, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case "drop":
                connection.forceCancel()
            default:
                let text = NWProtocolWebSocket.Metadata(opcode: .text)
                let frame = NWConnection.ContentContext(identifier: "text", metadata: [text])
                connection.send(content: data, contentContext: frame, isComplete: true, completion: .idempotent)
                self.receive(on: connection)
            }
        }
    }

    // MARK: - The certificate

    /// One identity for the whole test run: an EC P-256 key and a self-signed certificate for `CN=Critter Test`.
    private nonisolated(unsafe) static let made: Result<(SecIdentity, String), any Error> = Result { try makeIdentity() }

    private static func identity() throws -> (SecIdentity, String) {
        try made.get()
    }

    private static func makeIdentity() throws -> (SecIdentity, String) {
        guard #available(macOS 15.0, *) else { throw Failure.identity }
        let dir = FileManager.default.temporaryDirectory.appending(path: "critter-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "key.pem"], in: dir)
        try openssl(["req", "-new", "-x509", "-key", "key.pem", "-out", "cert.pem", "-days", "2", "-subj", "/CN=Critter Test"], in: dir)
        let export = ["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:test"]
        try openssl(export, in: dir)
        if let imported = importIdentity(dir) { return imported }
        // An openssl that encrypts PKCS#12 with AES/PBKDF2 makes a file Security cannot read: the legacy algorithms.
        try openssl(export + ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], in: dir)
        if let imported = importIdentity(dir) { return imported }
        throw Failure.identity
    }

    @available(macOS 15.0, *)
    private static func importIdentity(_ dir: URL) -> (SecIdentity, String)? {
        guard let data = try? Data(contentsOf: dir.appending(path: "identity.p12")) else { return nil }
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { return nil }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return (identity, PinnedCertificate.fingerprint(der: SecCertificateCopyData(certificate) as Data))
    }

    private static func openssl(_ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.openssl(process.terminationStatus) }
    }
}
