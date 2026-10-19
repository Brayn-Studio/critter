import CritterCore
import Foundation
import Security

/// The bridge's self-signed TLS identity, kept in `~/.critter/bridge/` (directory 0700, files
/// 0600): an EC P-256 key, a 10-year certificate for `CN=Critter`, and both bundled as a
/// PKCS#12 file. Generated with the system's `/usr/bin/openssl` the first time the bridge is
/// switched on, and only ever replaced by `reset` ("重置配对"). The phone pins the
/// certificate by `fingerprint`, so keeping these files is what keeps old pairings working.
///
/// Blocking file and process work: call it from the bridge queue, never the main thread.
enum BridgeIdentity {
    enum Failure: Error { case openssl(String), importFailed(OSStatus) }

    static let keyFile = "key.pem"
    static let certFile = "cert.pem"
    static let p12File = "identity.p12"
    private static let passphrase = "critter"

    /// The identity in `dir`, generating whatever is missing first. `fingerprint` is the
    /// SHA-256 of the certificate DER, as lowercase hex.
    static func loadOrCreate(dir: URL) throws -> (identity: SecIdentity, fingerprint: String) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        if let loaded = importIdentity(dir: dir) { return loaded }

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(keyFile).path)
            || !fm.fileExists(atPath: dir.appendingPathComponent(certFile).path) {
            try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyFile], in: dir)
            try openssl(["req", "-new", "-x509", "-key", keyFile, "-out", certFile, "-days", "3650", "-subj", "/CN=Critter"], in: dir)
        }
        // The same key and certificate either way, so the fingerprint doesn't change. An
        // openssl that encrypts PKCS#12 with AES/PBKDF2 makes a file Security can't read; the
        // legacy algorithms are the fallback.
        let export = ["pkcs12", "-export", "-inkey", keyFile, "-in", certFile, "-out", p12File, "-passout", "pass:\(passphrase)"]
        try openssl(export, in: dir)
        if let loaded = importIdentity(dir: dir) { return loaded }
        try openssl(export + ["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], in: dir)
        if let loaded = importIdentity(dir: dir) { return loaded }
        throw Failure.importFailed(errSecDecode)
    }

    /// Deletes the identity files; the next `loadOrCreate` makes a new identity (and so a new
    /// fingerprint, which no paired phone trusts).
    static func reset(dir: URL) {
        for name in [keyFile, certFile, p12File] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Imports `identity.p12` into process memory only: on macOS, `SecPKCS12Import` would
    /// otherwise add the key to the login keychain on every launch.
    private static func importIdentity(dir: URL) -> (identity: SecIdentity, fingerprint: String)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(p12File)) else { return nil }
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { return nil }
        // The type was checked just above, so this cast cannot fail.
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let der = SecCertificateCopyData(certificate) as Data
        return (identity, Hex.sha256(der))
    }

    /// Runs `/usr/bin/openssl` in `dir` and makes every file it leaves there 0600 (the
    /// directory is already 0700, so nobody else could read them in between).
    private static func openssl(_ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let message = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for name in [keyFile, certFile, p12File] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        guard process.terminationStatus == 0 else {
            throw Failure.openssl("\(arguments.first ?? "") exited \(process.terminationStatus): \(String(decoding: message, as: UTF8.self))")
        }
    }
}
