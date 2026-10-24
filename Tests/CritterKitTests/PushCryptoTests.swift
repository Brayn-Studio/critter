import CryptoKit
import Foundation
import Testing
@testable import CritterKit

private let text = PushText(title: "critter 想运行", subtitle: "~/CODESPACE/clawd · main · 终端", body: "swift test --filter \"x\"")

/// Sealed for the push about request r1 of session s1.
private func seal(_ text: PushText, key: String) throws -> String {
    try PushCrypto.seal(text, key: key, category: .permission, requestId: "r1", sessionId: "s1")
}

private func open(_ sealed: String, key: String) throws -> PushText {
    try PushCrypto.open(sealed, key: key, category: .permission, requestId: "r1", sessionId: "s1")
}

@Test func sealThenOpenGivesTheText() throws {
    let key = PushCrypto.makeKey()
    #expect(try open(seal(text, key: key), key: key) == text)
}

@Test func theSealedStringIsPlainBase64OfNonceCiphertextAndTag() throws {
    let key = PushCrypto.makeKey()
    let sealed = try seal(text, key: key)
    let combined = try #require(Data(base64Encoded: sealed))
    // 12-byte nonce + ciphertext + 16-byte tag, and CryptoKit opens it with the same key and "k|r|s".
    let box = try AES.GCM.SealedBox(combined: combined)
    #expect(box.nonce.count == 12 && box.tag.count == 16)
    let keyBytes = try #require(PushCrypto.keyData(key))
    let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: Data("permission|r1|s1".utf8))
    #expect(try JSONDecoder().decode(PushText.self, from: plain) == text)
    // The plaintext is the three fields as JSON.
    let object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: String])
    #expect(Set(object.keys) == ["title", "subtitle", "body"])
}

@Test func aSealedTextOnlyOpensInThePushItWasMadeFor() throws {
    let key = PushCrypto.makeKey()
    let sealed = try seal(text, key: key)
    let elsewhere: [(PushCategory, String?, String)] = [
        (.question, "r1", "s1"), (.permissionNoReason, "r1", "s1"), (.permission, "r2", "s1"),
        (.permission, "r1", "s2"), (.permission, nil, "s1"),
    ]
    for (category, request, session) in elsewhere {
        #expect(throws: (any Error).self) {
            try PushCrypto.open(sealed, key: key, category: category, requestId: request, sessionId: session)
        }
    }
    // A notification about a session has no request id: bound to "<k>||<s>".
    let done = try PushCrypto.seal(text, key: key, category: .done, requestId: nil, sessionId: "s1")
    #expect(try PushCrypto.open(ParsedPush.Alert(category: .done, requestId: nil, sessionId: "s1", sealed: done), key: key) == text)
    #expect(throws: (any Error).self) {
        try PushCrypto.open(ParsedPush.Alert(category: .error, requestId: nil, sessionId: "s1", sealed: done), key: key)
    }
    #expect(PushCrypto.associatedData(category: .permission, requestId: "r1", sessionId: "s1") == Data("permission|r1|s1".utf8))
    #expect(PushCrypto.associatedData(category: .done, requestId: nil, sessionId: "s1") == Data("done||s1".utf8))
}

@Test func sealingTwiceGivesDifferentCiphertexts() throws {
    let key = PushCrypto.makeKey()
    #expect(try seal(text, key: key) != seal(text, key: key))
}

@Test func openWithTheWrongKeyThrows() throws {
    let sealed = try seal(text, key: PushCrypto.makeKey())
    #expect(throws: (any Error).self) { try open(sealed, key: PushCrypto.makeKey()) }
}

@Test func aTamperedCiphertextThrows() throws {
    let key = PushCrypto.makeKey()
    var combined = try #require(Data(base64Encoded: seal(text, key: key)))
    combined[combined.count / 2] ^= 0x01
    #expect(throws: (any Error).self) { try open(combined.base64EncodedString(), key: key) }
}

@Test func garbageAndBadKeysThrow() throws {
    let key = PushCrypto.makeKey()
    #expect(throws: (any Error).self) { try open("not base64!", key: key) }
    #expect(throws: (any Error).self) { try open("AAAA", key: key) }
    #expect(throws: (any Error).self) { try seal(text, key: "short") }
    let sealed = try seal(text, key: key)
    #expect(throws: (any Error).self) { try open(sealed, key: "short") }
}
