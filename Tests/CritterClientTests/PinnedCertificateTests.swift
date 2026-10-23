import CritterClient
import Foundation
import Testing

struct PinnedCertificateTests {
    private let der = Data("abc".utf8)
    private let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test func fingerprintIsLowercaseSHA256OfTheDER() {
        #expect(PinnedCertificate.fingerprint(der: der) == sha256)
        #expect(PinnedCertificate.matches(der: der, fingerprint: sha256))
    }

    @Test func uppercaseOrShortPinsNeverMatch() {
        #expect(!PinnedCertificate.matches(der: der, fingerprint: sha256.uppercased()))
        #expect(!PinnedCertificate.matches(der: der, fingerprint: String(sha256.prefix(16))))
        #expect(!PinnedCertificate.matches(der: der, fingerprint: ""))
        #expect(!PinnedCertificate.matches(der: Data("abd".utf8), fingerprint: sha256))
    }
}
