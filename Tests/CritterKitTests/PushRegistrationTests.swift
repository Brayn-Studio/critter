import Foundation
import Testing
@testable import CritterKit

/// A 32-byte key, base64url without padding (43 characters).
private let goodKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

private func registration(
    token: String = "ab12cd34", key: String = goodKey,
    activity: ActivityRegistration? = nil
) -> PushRegistration {
    PushRegistration(
        token: token, environment: .sandbox, bundleId: "com.braynlabs.critter", key: key,
        notifyDone: true, notifyError: false, activity: activity
    )
}

/// Encoded the way every frame is: sorted keys, no whitespace.
@Test func registrationRoundTrips() throws {
    let full = registration(activity: ActivityRegistration(
        enabled: true, startToken: "5a5a", activityId: "A1", activityToken: "9f9f"
    ))
    let message = ClientMessage.push(id: "p1", registration: full)
    let text = try #require(String(data: message.encode(), encoding: .utf8))
    #expect(text == """
    {"id":"p1","registration":{"activity":{"activityId":"A1","activityToken":"9f9f","enabled":true,"startToken":"5a5a"},\
    "bundleId":"com.braynlabs.critter","environment":"sandbox","key":"\(goodKey)","notifyDone":true,"notifyError":false,\
    "token":"ab12cd34"},"type":"push"}
    """)
    #expect(ClientMessage.decode(message.encode()) == message)
}

@Test func optionalPartsAreLeftOutOfTheFrame() throws {
    let message = ClientMessage.push(id: nil, registration: registration())
    let text = try #require(String(data: message.encode(), encoding: .utf8))
    #expect(!text.contains("activity"))
    #expect(!text.contains("\"id\""))
    #expect(ClientMessage.decode(message.encode()) == message)
}

@Test func aPushFrameWithoutARegistrationDoesNotDecode() {
    #expect(ClientMessage.decode(Data(#"{"id":"p1","type":"push"}"#.utf8)) == nil)
    #expect(ClientMessage.decode(Data(#"{"id":"p1","registration":{"token":"ab"},"type":"push"}"#.utf8)) == nil)
}

@Test func anEmptyTokenIsAnUnregistration() {
    #expect(registration(token: "").isEmpty)
    #expect(!registration().isEmpty)
}

@Test func aKeyThatIsNot32BytesIsInvalid() {
    #expect(registration().hasValidKey)
    #expect(!registration(key: "").hasValidKey)
    #expect(!registration(key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh").hasValidKey)   // 31 bytes
    #expect(!registration(key: goodKey + "AA").hasValidKey)                                    // 33 bytes
    #expect(!registration(key: "not base64url!").hasValidKey)
    // Standard base64 and padding are not base64url without padding.
    #expect(!registration(key: "+/ECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8").hasValidKey)
    #expect(!registration(key: goodKey + "=").hasValidKey)
    #expect(registration(key: goodKey).hasValidKey)
    #expect(registration(key: "-_8" + String(goodKey.dropFirst(3))).hasValidKey)
    #expect(registration(key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh").isEmpty)
}

@Test func aMadeKeyIsValid() {
    let key = PushCrypto.makeKey()
    #expect(key.count == 43)
    #expect(registration(key: key).hasValidKey)
    #expect(PushCrypto.makeKey() != key)
}

@Test func theEnvironmentIsItsRawValueOnTheWire() throws {
    var r = registration()
    r.environment = .production
    let text = try #require(String(data: ClientMessage.push(id: nil, registration: r).encode(), encoding: .utf8))
    #expect(text.contains("\"environment\":\"production\""))
}
