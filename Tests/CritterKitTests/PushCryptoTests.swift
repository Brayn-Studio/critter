import CryptoKit
import Foundation
import Testing
@testable import CritterKit

private let text = PushText(title: "critter 想运行", subtitle: "~/CODESPACE/clawd · main · 终端", body: "swift test --filter \"x\"")

@Test func sealThenOpenGivesTheText() throws {
    let key = PushCrypto.makeKey()
    let sealed = try PushCrypto.seal(text, key: key)
    #expect(try PushCrypto.open(sealed, key: key) == text)
}

@Test func theSealedStringIsPlainBase64OfNonceCiphertextAndTag() throws {
    let key = PushCrypto.makeKey()
    let sealed = try PushCrypto.seal(text, key: key)
    let combined = try #require(Data(base64Encoded: sealed))
    // 12-byte nonce + ciphertext + 16-byte tag, and CryptoKit opens it with the same key.
    let box = try AES.GCM.SealedBox(combined: combined)
    #expect(box.nonce.count == 12 && box.tag.count == 16)
    let keyBytes = try #require(PushCrypto.keyData(key))
    let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyBytes))
    #expect(try JSONDecoder().decode(PushText.self, from: plain) == text)
    // The plaintext is the three fields as JSON.
    let object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: String])
    #expect(Set(object.keys) == ["title", "subtitle", "body"])
}

@Test func sealingTwiceGivesDifferentCiphertexts() throws {
    let key = PushCrypto.makeKey()
    #expect(try PushCrypto.seal(text, key: key) != PushCrypto.seal(text, key: key))
}

@Test func openWithTheWrongKeyThrows() throws {
    let sealed = try PushCrypto.seal(text, key: PushCrypto.makeKey())
    #expect(throws: (any Error).self) { try PushCrypto.open(sealed, key: PushCrypto.makeKey()) }
}

@Test func aTamperedCiphertextThrows() throws {
    let key = PushCrypto.makeKey()
    var combined = try #require(Data(base64Encoded: PushCrypto.seal(text, key: key)))
    combined[combined.count / 2] ^= 0x01
    #expect(throws: (any Error).self) { try PushCrypto.open(combined.base64EncodedString(), key: key) }
}

@Test func garbageAndBadKeysThrow() throws {
    let key = PushCrypto.makeKey()
    #expect(throws: (any Error).self) { try PushCrypto.open("not base64!", key: key) }
    #expect(throws: (any Error).self) { try PushCrypto.open("AAAA", key: key) }
    #expect(throws: (any Error).self) { try PushCrypto.seal(text, key: "short") }
    let sealed = try PushCrypto.seal(text, key: key)
    #expect(throws: (any Error).self) { try PushCrypto.open(sealed, key: "short") }
}
