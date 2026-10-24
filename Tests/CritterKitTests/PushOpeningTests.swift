import CryptoKit
import Foundation
import Testing
@testable import CritterKit

// What the notification service extension makes of a push (spec §8.7, §11): the sealed text opened with the push key,
// the category, thread and level set; the plain "Critter / 有会话需要你" kept when it does not open.

/// The registration's key and the push of the protocol doc's test vector (`docs/critter-bridge-protocol.md`, "Push
/// payload" and "Sealed text"): what the Mac sealed, byte for byte.
private let docKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
private let docPush = #"""
{"aps":{"alert":{"body":"有会话需要你","title":"Critter"},"category":"permission","interruption-level":"time-sensitive","mutable-content":1,"sound":"default","thread-id":"s1"},"c":"EBESExQVFhcYGRobBtz6eS2wGInoBn90aQ1JJ7IjOiw34CTEhY2LEzIxduFyl3hAuuIrvC530RSl+396ZNhnsVSrNJPVcBrzRLdD0I0flIxrkilABPRZm/r7yt1P0ObZA+9y3ANDyKB+bEKZXnqaKzMBXOzpqvxT1aUGlhwh","k":"permission","r":"r1","s":"s1"}
"""#

/// A JSON object as APNs hands it to the phone.
private func userInfo(_ json: String) throws -> [AnyHashable: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
}

/// A push the way the Mac makes one (`PushContent`): the text sealed for this category, request and session.
private func push(
    _ text: PushText, key: String, category: PushCategory, requestId: String?, sessionId: String
) throws -> [AnyHashable: Any] {
    let sealed = try PushCrypto.seal(text, key: key, category: category, requestId: requestId, sessionId: sessionId)
    let payload = PushPayload.alert(
        category: category, requestId: requestId, sessionId: sessionId, sealed: sealed,
        timeSensitive: category.waitsForTheUser
    )
    // Through JSON, as APNs delivers it.
    return try #require(
        JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? [AnyHashable: Any]
    )
}

private let text = PushText(title: "critter 想 swift test", subtitle: "clawd · main · 终端", body: "swift test --filter x")

/// What a push shows that did not open: the plain words, with its category, thread and level all the same.
private func generic(_ category: PushCategory, thread: String) -> NotificationLook {
    NotificationLook(
        title: "Critter", subtitle: "", body: "有会话需要你", category: category, threadId: thread,
        timeSensitive: category.waitsForTheUser, opened: false
    )
}

@Test func opensWhatTheMacSealed() throws {
    // The protocol doc's push, with the doc's key: the Mac's own bytes.
    let look = try #require(PushOpening.look(userInfo(docPush), key: docKey))
    #expect(look == NotificationLook(
        title: "critter 想运行", subtitle: "~/CODESPACE/clawd · main · 终端", body: "swift test",
        category: .permission, threadId: "s1", timeSensitive: true, opened: true
    ))

    // Every category: its text, its category (the buttons), the session as the thread; only a session that waits
    // for the user is time-sensitive.
    let key = PushCrypto.makeKey()
    for category in PushCategory.allCases {
        let requestId: String? = [.permission, .permissionNoReason, .question, .plan].contains(category) ? "r9" : nil
        let look = try #require(PushOpening.look(
            push(text, key: key, category: category, requestId: requestId, sessionId: "s3"), key: key
        ))
        #expect(look.title == text.title && look.subtitle == text.subtitle && look.body == text.body)
        #expect(look.opened && look.category == category && look.threadId == "s3")
        #expect(look.timeSensitive == [.permission, .permissionNoReason, .question, .plan, .waitingElsewhere].contains(category))
    }
}

@Test func undecryptableShowsTheGenericText() throws {
    let key = PushCrypto.makeKey()
    let good = try push(text, key: key, category: .permission, requestId: "r1", sessionId: "s1")

    // Another key (the phone made a new one, or the Mac has an old one).
    #expect(PushOpening.look(good, key: PushCrypto.makeKey()) == generic(.permission, thread: "s1"))
    // No key: never made, or the keychain cannot be read (before the first unlock). No crash, the same plain words,
    // and the buttons still come (the category is set).
    #expect(PushOpening.look(good, key: nil) == generic(.permission, thread: "s1"))
    // A key that is not one.
    #expect(PushOpening.look(good, key: "not a key") == generic(.permission, thread: "s1"))

    // A sealed field that is not base64, too short, or tampered with.
    for sealed in ["not base64!", "AAAA", ""] {
        var bad = good
        bad["c"] = sealed
        #expect(PushOpening.look(bad, key: key) == generic(.permission, thread: "s1"))
    }
    var tampered = good
    let goodSealed = try #require(good["c"] as? String)
    var bytes = try #require(Data(base64Encoded: goodSealed))
    bytes[bytes.count / 2] ^= 0x01
    tampered["c"] = bytes.base64EncodedString()
    #expect(PushOpening.look(tampered, key: key) == generic(.permission, thread: "s1"))

    // It opens, but what is inside is not the three strings of a notification's text.
    let symmetric = SymmetricKey(data: try #require(PushCrypto.keyData(key)))
    let box = try AES.GCM.seal(Data(#"{"title":1}"#.utf8), using: symmetric, authenticating: Data("done||s2".utf8))
    var wrongShape = try push(text, key: key, category: .done, requestId: nil, sessionId: "s2")
    wrongShape["c"] = try #require(box.combined).base64EncodedString()
    #expect(PushOpening.look(wrongShape, key: key) == generic(.done, thread: "s2"))
}

@Test func aMovedCiphertextDoesNotOpen() throws {
    let key = PushCrypto.makeKey()
    let original = try push(text, key: key, category: .permission, requestId: "r1", sessionId: "s1")
    let sealed = try #require(original["c"] as? String)

    // The same sealed text in a push about another request, another session, or of another category.
    let elsewhere: [(PushCategory, String?, String)] = [
        (.permission, "r2", "s1"), (.permission, "r1", "s2"), (.question, "r1", "s1"), (.permissionNoReason, "r1", "s1"),
        (.done, nil, "s1"),
    ]
    for (category, requestId, sessionId) in elsewhere {
        var moved = try push(text, key: key, category: category, requestId: requestId, sessionId: sessionId)
        moved["c"] = sealed
        #expect(PushOpening.look(moved, key: key) == generic(category, thread: sessionId))
    }
    // Its own push still opens.
    #expect(PushOpening.look(original, key: key)?.opened == true)
}

@Test func aPushThatIsNotANotificationIsLeftAsItCame() throws {
    let key = PushCrypto.makeKey()
    let good = try push(text, key: key, category: .permission, requestId: "r1", sessionId: "s1")

    // A category this build does not know (a newer Mac), no session, no sealed text: not Critter's notification as
    // this build knows it. The extension hands it on as it came (the system shows the plain words and whatever
    // category the push names).
    var unknown = good
    unknown["k"] = "somethingNew"
    #expect(PushOpening.look(unknown, key: key) == nil)
    var noSession = good
    noSession["s"] = nil
    #expect(PushOpening.look(noSession, key: key) == nil)
    var noText = good
    noText["c"] = nil
    #expect(PushOpening.look(noText, key: key) == nil)
    // A withdrawal is a background push: never shown.
    #expect(PushOpening.look(try userInfo(#"{"aps":{"content-available":1},"w":["r1"]}"#), key: key) == nil)
    #expect(PushOpening.look([:], key: key) == nil)
}

@Test func theCategoriesThatWaitForTheUser() {
    // What the Mac marks `time-sensitive` (`PushContent`): a request, and a session waiting for the computer.
    #expect(PushCategory.allCases.filter(\.waitsForTheUser)
        == [.permission, .permissionNoReason, .question, .plan, .waitingElsewhere])
}
