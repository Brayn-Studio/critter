import Foundation
import Testing
@testable import CritterKit

private func alert(
    _ category: PushCategory = .permission, requestId: String? = "r1", sessionId: String = "s1",
    timeSensitive: Bool = true
) -> [String: Any] {
    PushPayload.alert(category: category, requestId: requestId, sessionId: sessionId, sealed: "c2VhbGVk", timeSensitive: timeSensitive)
}

private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

@Test func alertPayloadHasOnlyTheAllowedPlainKeys() throws {
    let payload = alert()
    #expect(Set(payload.keys) == ["aps", "c", "r", "s", "k"])
    let aps = dictionary(payload["aps"])
    #expect(dictionary(aps["alert"]) as? [String: String] == ["title": "Critter", "body": "有会话需要你"])
    #expect(Set(aps.keys) == ["alert", "mutable-content", "category", "thread-id", "sound", "interruption-level"])
    #expect(aps["mutable-content"] as? Int == 1)
    #expect(aps["category"] as? String == "sealed")
    #expect(aps["thread-id"] as? String == "s1")
    #expect(aps["sound"] as? String == "default")
    #expect(aps["interruption-level"] as? String == "time-sensitive")
    #expect(payload["c"] as? String == "c2VhbGVk")
    #expect(payload["r"] as? String == "r1")
    #expect(payload["s"] as? String == "s1")
    #expect(payload["k"] as? String == "permission")
}

@Test func onlyAWaitingNotificationIsTimeSensitive() {
    let plain = dictionary(alert(.done, requestId: nil, timeSensitive: false)["aps"])
    #expect(plain["interruption-level"] == nil)
}

@Test func aSessionNotificationHasNoRequestId() {
    let payload = alert(.done, requestId: nil, timeSensitive: false)
    #expect(Set(payload.keys) == ["aps", "c", "s", "k"])
}

@Test func withdrawPayloadIsBackground() {
    let payload = PushPayload.withdraw(ids: ["r1", "done:s1"])
    #expect(Set(payload.keys) == ["aps", "w"])
    #expect(dictionary(payload["aps"]) as? [String: Int] == ["content-available": 1])
    #expect(payload["w"] as? [String] == ["r1", "done:s1"])
}

@Test func theNotificationIdIsTheRequestIdOrCategoryAndSession() {
    #expect(PushPayload.notificationId(category: .permission, requestId: "r1", sessionId: "s1") == "r1")
    #expect(PushPayload.notificationId(category: .done, requestId: nil, sessionId: "s1") == "done:s1")
    #expect(PushPayload.notificationId(category: .waitingElsewhere, requestId: nil, sessionId: "s9") == "waitingElsewhere:s9")
}

@Test func parseReadsWhatAlertWrote() throws {
    // Through JSON, as APNs delivers it.
    let data = try JSONSerialization.data(withJSONObject: alert(.question, requestId: "r7", sessionId: "s3"))
    let userInfo = try #require(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
    #expect(PushPayload.parse(userInfo) == .alert(ParsedPush.Alert(
        category: .question, requestId: "r7", sessionId: "s3", sealed: "c2VhbGVk"
    )))
    #expect(PushPayload.parse(alert(.done, requestId: nil, timeSensitive: false)) == .alert(ParsedPush.Alert(
        category: .done, requestId: nil, sessionId: "s1", sealed: "c2VhbGVk"
    )))
}

@Test func parseReadsWhatWithdrawWrote() throws {
    let data = try JSONSerialization.data(withJSONObject: PushPayload.withdraw(ids: ["r1", "error:s2"]))
    let userInfo = try #require(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
    #expect(PushPayload.parse(userInfo) == .withdraw(ids: ["r1", "error:s2"]))
}

@Test func parseRejectsWhatIsNotOurs() {
    #expect(PushPayload.parse([:]) == nil)
    #expect(PushPayload.parse(["aps": ["alert": "hi"]]) == nil)
    #expect(PushPayload.parse(["c": "x", "s": "s1", "k": "bogus"]) == nil)
    #expect(PushPayload.parse(["c": "x", "k": "done"]) == nil)
    #expect(PushPayload.parse(["w": [1, 2]]) == nil)
}

@Test func theNotificationCategoriesAreTheRawValues() {
    #expect(PushCategory.allCases.map(\.rawValue) == [
        "permission", "permissionNoReason", "question", "plan", "waitingElsewhere", "done", "error", "test",
    ])
}
