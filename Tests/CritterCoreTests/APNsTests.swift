import CryptoKit
import Foundation
import Testing
@testable import CritterCore

private let config = APNsConfig(
    keyId: "ABC123DEFG", teamId: "TEAM123456", bundleId: "com.braynlabs.critter",
    keyFile: URL(fileURLWithPath: "/tmp/AuthKey_ABC123DEFG.p8")
)

private let deviceToken = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

// MARK: - Config

@Test func keyIdComesFromTheFileName() {
    #expect(APNsConfig.keyId(fromFileName: "AuthKey_ABC123DEFG.p8") == "ABC123DEFG")
    #expect(APNsConfig.keyId(fromFileName: "AuthKey_Z9.p8") == "Z9")
    // Anything else is for the user to type.
    #expect(APNsConfig.keyId(fromFileName: "AuthKey_.p8") == nil)
    #expect(APNsConfig.keyId(fromFileName: "key.p8") == nil)
    #expect(APNsConfig.keyId(fromFileName: "AuthKey_ABC123DEFG.pem") == nil)
    #expect(APNsConfig.keyId(fromFileName: "AuthKey_ABC123DEFG (1).p8") == nil)
    #expect(APNsConfig.keyId(fromFileName: "authkey_ABC123DEFG.p8") == nil)
    #expect(APNsConfig.keyId(fromFileName: "") == nil)
}

@Test func theDefaultBundleIdIsThePhonesApp() {
    #expect(APNsConfig.defaultBundleId == "com.braynlabs.critter")
}

// MARK: - The JWT

private func base64URLDecode(_ text: Substring) throws -> Data {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    return try #require(Data(base64Encoded: standard))
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func jwtVerifiesWithThePublicKey() throws {
    let key = P256.Signing.PrivateKey()
    let token = try APNsToken(config: config, pem: key.pemRepresentation)
    let jwt = try token.bearer(now: t0)

    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3)
    #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"), "base64url without padding")

    // Header and claims, item by item.
    let header = try object(base64URLDecode(parts[0]))
    #expect(Set(header.keys) == ["alg", "kid"])
    #expect(header["alg"] as? String == "ES256")
    #expect(header["kid"] as? String == "ABC123DEFG")
    let claims = try object(base64URLDecode(parts[1]))
    #expect(Set(claims.keys) == ["iss", "iat"])
    #expect(claims["iss"] as? String == "TEAM123456")
    #expect(claims["iat"] as? Int == 1_760_000_000)

    // The signature is the raw r || s (64 bytes), over "<header>.<claims>", and the public key accepts it.
    let raw = try base64URLDecode(parts[2])
    #expect(raw.count == 64)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
    let signed = Data("\(parts[0]).\(parts[1])".utf8)
    #expect(key.publicKey.isValidSignature(signature, for: signed))
    // And not another message, nor another key.
    #expect(!key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).x".utf8)))
    #expect(!P256.Signing.PrivateKey().publicKey.isValidSignature(signature, for: signed))
}

@Test func jwtIsReusedFor50Minutes() throws {
    let token = try APNsToken(config: config, pem: P256.Signing.PrivateKey().pemRepresentation)
    let first = try token.bearer(now: t0)
    #expect(try token.bearer(now: t0.addingTimeInterval(1)) == first)
    #expect(try token.bearer(now: t0.addingTimeInterval(49 * 60 + 59)) == first)
    // After 50 minutes a new one, issued then.
    let renewed = try token.bearer(now: t0.addingTimeInterval(50 * 60))
    #expect(renewed != first)
    let claims = try object(base64URLDecode(renewed.split(separator: ".")[1]))
    #expect(claims["iat"] as? Int == 1_760_000_000 + 50 * 60)
    // The new one is reused in turn.
    #expect(try token.bearer(now: t0.addingTimeInterval(60 * 60)) == renewed)
}

@Test func aClockThatWentBackwardsGetsAFreshJWT() throws {
    let token = try APNsToken(config: config, pem: P256.Signing.PrivateKey().pemRepresentation)
    let first = try token.bearer(now: t0)
    let earlier = try token.bearer(now: t0.addingTimeInterval(-3600))
    #expect(earlier != first)
    let claims = try object(base64URLDecode(earlier.split(separator: ".")[1]))
    #expect(claims["iat"] as? Int == 1_760_000_000 - 3600)
}

@Test func aBadP8Throws() {
    #expect(throws: APNsToken.Failure.unreadableKey) { try APNsToken(config: config, pem: "") }
    #expect(throws: APNsToken.Failure.unreadableKey) { try APNsToken(config: config, pem: "not a key") }
    #expect(throws: APNsToken.Failure.unreadableKey) {
        try APNsToken(config: config, pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n")
    }
    // A public key is not a signing key.
    #expect(throws: APNsToken.Failure.unreadableKey) {
        try APNsToken(config: config, pem: P256.Signing.PrivateKey().publicKey.pemRepresentation)
    }
}

// MARK: - The request

private func message(
    _ type: APNsPushType, priority: Int = 10, collapseId: String? = nil, expiration: Int64? = nil,
    payload: String = #"{"aps":{}}"#
) -> APNsMessage {
    APNsMessage(pushType: type, priority: priority, collapseId: collapseId, expiration: expiration, payload: Data(payload.utf8))
}

private func make(_ m: APNsMessage, environment: PushEnvironment = .sandbox) -> URLRequest {
    APNsRequest.make(m, deviceToken: deviceToken, environment: environment, config: config, bearer: "JWT.JWT.JWT")
}

@Test func requestHeadersForEachPushType() throws {
    // An alert for a request.
    let alert = make(message(.alert, priority: 10, collapseId: "r-1", expiration: 1_760_000_300, payload: #"{"aps":{"a":1}}"#))
    #expect(alert.httpMethod == "POST")
    #expect(alert.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(deviceToken)")
    #expect(alert.value(forHTTPHeaderField: "authorization") == "bearer JWT.JWT.JWT")
    #expect(alert.value(forHTTPHeaderField: "apns-push-type") == "alert")
    #expect(alert.value(forHTTPHeaderField: "apns-priority") == "10")
    #expect(alert.value(forHTTPHeaderField: "apns-topic") == "com.braynlabs.critter")
    #expect(alert.value(forHTTPHeaderField: "apns-collapse-id") == "r-1")
    #expect(alert.value(forHTTPHeaderField: "apns-expiration") == "1760000300")
    #expect(alert.httpBody == Data(#"{"aps":{"a":1}}"#.utf8))

    // No collapse id and no expiration: no such headers.
    let plain = make(message(.alert))
    #expect(plain.value(forHTTPHeaderField: "apns-collapse-id") == nil)
    #expect(plain.value(forHTTPHeaderField: "apns-expiration") == nil)

    // A withdrawal: background, priority 5, the app's own topic.
    let background = make(message(.background, priority: 5))
    #expect(background.value(forHTTPHeaderField: "apns-push-type") == "background")
    #expect(background.value(forHTTPHeaderField: "apns-priority") == "5")
    #expect(background.value(forHTTPHeaderField: "apns-topic") == "com.braynlabs.critter")

    // A Live Activity.
    let activity = make(message(.liveActivity, priority: 5))
    #expect(activity.value(forHTTPHeaderField: "apns-push-type") == "liveactivity")
    #expect(activity.value(forHTTPHeaderField: "apns-priority") == "5")
}

@Test func aBackgroundPushIsAlwaysPriority5() {
    // APNs refuses a background push of any other priority.
    #expect(make(message(.background, priority: 10)).value(forHTTPHeaderField: "apns-priority") == "5")
    #expect(make(message(.alert, priority: 5)).value(forHTTPHeaderField: "apns-priority") == "5")
}

@Test func liveActivityTopicHasTheSuffix() {
    let activity = make(message(.liveActivity))
    #expect(activity.value(forHTTPHeaderField: "apns-topic") == "com.braynlabs.critter.push-type.liveactivity")
    // Only a Live Activity's.
    #expect(make(message(.alert)).value(forHTTPHeaderField: "apns-topic") == "com.braynlabs.critter")
    // The device's own bundle id, not a fixed one.
    var other = config
    other.bundleId = "com.example.other"
    let request = APNsRequest.make(message(.liveActivity), deviceToken: "ab", environment: .sandbox, config: other, bearer: "x")
    #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.example.other.push-type.liveactivity")
}

@Test func theEnvironmentPicksTheHost() {
    #expect(make(message(.alert), environment: .sandbox).url?.host == "api.sandbox.push.apple.com")
    #expect(make(message(.alert), environment: .production).url?.host == "api.push.apple.com")
    #expect(make(message(.alert), environment: .production).url?.path == "/3/device/\(deviceToken)")
}

@Test func aTokenCannotChangeThePath() {
    // A device token is hex. Whatever else a phone sends cannot reach the path or the query.
    let request = APNsRequest.make(
        message(.alert), deviceToken: "ab/../cd?x=1#y", environment: .production, config: config, bearer: "x"
    )
    #expect(request.url?.absoluteString == "https://api.push.apple.com/3/device/abcd1")
}

@Test func onlyASCIIHexDigitsReachThePath() {
    // Fullwidth digits are hex digits to `Character.isHexDigit`; they must not reach the URL.
    let request = APNsRequest.make(message(.alert), deviceToken: "ab\u{FF11}\u{FF12}cd", environment: .sandbox, config: config, bearer: "x")
    #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/abcd")
}

// MARK: - The reply

private func body(_ reason: String) -> Data { Data(#"{"reason":"\#(reason)"}"#.utf8) }

@Test func goneTokenIsDropped() {
    // Review focus 3: an app that was deleted answers 410, or 400 with a token APNs does not know.
    #expect(APNsResponse.classify(status: 410, body: body("Unregistered")) == .dropToken)
    #expect(APNsResponse.classify(status: 410, body: Data()) == .dropToken)
    #expect(APNsResponse.classify(status: 400, body: body("BadDeviceToken")) == .dropToken)
    #expect(APNsResponse.classify(status: 400, body: body("DeviceTokenNotForTopic")) == .dropToken)
    // Other 400s are not about the token.
    #expect(APNsResponse.classify(status: 400, body: body("PayloadTooLarge")) != .dropToken)
    #expect(APNsResponse.classify(status: 400, body: Data()) != .dropToken)
}

@Test func theOutcomesOfEveryStatus() {
    #expect(APNsResponse.classify(status: 200, body: Data()) == .sent)
    #expect(APNsResponse.classify(status: 403, body: body("InvalidProviderToken")) == .configError("密钥或 Team ID 不对"))
    #expect(APNsResponse.classify(status: 403, body: body("ExpiredProviderToken")) == .configError("ExpiredProviderToken"))
    #expect(APNsResponse.classify(status: 403, body: body("TopicDisallowed")) == .configError("这把密钥不能给这个 bundle id 推送"))
    #expect(APNsResponse.classify(status: 403, body: Data()) == .configError("403"))
    #expect(APNsResponse.classify(status: 403, body: Data("garbage".utf8)) == .configError("403"))
    #expect(APNsResponse.classify(status: 429, body: body("TooManyRequests")) == .retry)
    #expect(APNsResponse.classify(status: 500, body: body("InternalServerError")) == .retry)
    #expect(APNsResponse.classify(status: 503, body: body("ServiceUnavailable")) == .retry)
    #expect(APNsResponse.classify(status: 599, body: Data()) == .retry)
    // A push APNs refuses for itself: not a retry, not the key's fault.
    #expect(APNsResponse.classify(status: 400, body: body("BadCollapseId")) == .rejected("BadCollapseId"))
    #expect(APNsResponse.classify(status: 413, body: body("PayloadTooLarge")) == .rejected("PayloadTooLarge"))
    #expect(APNsResponse.classify(status: 404, body: Data()) == .rejected("404"))
}

// MARK: - Delivery

private struct Reply {
    var status: Int
    var reason: String?
    static func ok() -> Reply { Reply(status: 200) }
    static func status(_ status: Int, _ reason: String? = nil) -> Reply { Reply(status: status, reason: reason) }
}

/// A delivery wired to scripted replies; the scheduler keeps what it is asked to run later.
private final class Harness {
    var replies: [Reply?]  // nil is a network error
    var sent: [URLRequest] = []
    var delays: [TimeInterval] = []
    var later: [() -> Void] = []
    var logs: [String] = []
    private(set) var delivery: PushDelivery!

    init(_ replies: [Reply?]) {
        self.replies = replies
        delivery = PushDelivery(
            transport: { [unowned self] request, completion in
                sent.append(request)
                let reply = self.replies.isEmpty ? nil : self.replies.removeFirst()
                if let reply {
                    completion(.success(APNsReply(
                        status: reply.status, body: reply.reason.map { Data(#"{"reason":"\#($0)"}"#.utf8) } ?? Data()
                    )))
                } else {
                    completion(.failure(URLError(.notConnectedToInternet)))
                }
            },
            schedule: { [unowned self] delay, work in
                delays.append(delay)
                later.append(work)
            },
            log: { [unowned self] line in logs.append(line) }
        )
    }

    var request: URLRequest { make(message(.alert, collapseId: "r-1")) }

    /// Sends `request`; returns the outcome once there is one (running the scheduled retries).
    func deliver() -> APNsOutcome? {
        var outcome: APNsOutcome?
        delivery.send(request) { outcome = $0 }
        while outcome == nil, !later.isEmpty { later.removeFirst()() }
        return outcome
    }
}

@Test func aDeliveredPushIsSent() {
    let h = Harness([.ok()])
    #expect(h.deliver() == .sent)
    #expect(h.sent.count == 1 && h.delays.isEmpty)
}

@Test func goneTokenIsHandedBackAndNotRetried() {
    let h = Harness([.status(410, "Unregistered"), .ok()])
    #expect(h.deliver() == .dropToken)
    #expect(h.sent.count == 1 && h.delays.isEmpty)
    #expect(!h.delivery.isBlocked)
}

@Test func forbiddenStopsUntilTheConfigChanges() {
    // Review focus 4: a wrong key or Team ID is the same for every push; one answer is enough to stop.
    let h = Harness([.status(403, "InvalidProviderToken"), .ok(), .ok()])
    #expect(!h.delivery.isBlocked)
    #expect(h.deliver() == .configError("密钥或 Team ID 不对"))
    #expect(h.delivery.isBlocked)
    #expect(h.delivery.blockedReason == "密钥或 Team ID 不对")
    #expect(h.sent.count == 1)

    // Nothing more goes out, however many pushes there are: no request at all.
    #expect(h.deliver() == .configError("密钥或 Team ID 不对"))
    #expect(h.deliver() == .configError("密钥或 Team ID 不对"))
    #expect(h.sent.count == 1)

    // The settings changed.
    h.delivery.configChanged()
    #expect(!h.delivery.isBlocked && h.delivery.blockedReason == nil)
    #expect(h.deliver() == .sent)
    #expect(h.sent.count == 2)
}

@Test func aConfigErrorStopsPushesWaitingForARetry() {
    let h = Harness([.status(503), .status(403, "InvalidProviderToken")])
    var first: APNsOutcome?
    h.delivery.send(h.request) { first = $0 }
    #expect(h.later.count == 1 && first == nil)
    // Meanwhile another push is answered 403, and that blocks everything.
    var second: APNsOutcome?
    h.delivery.send(h.request) { second = $0 }
    #expect(second == .configError("密钥或 Team ID 不对"))
    #expect(h.delivery.isBlocked)
    // The first one's retry finds the delivery blocked: it does not go out.
    h.later.removeFirst()()
    #expect(first == .configError("密钥或 Team ID 不对"))
    #expect(h.sent.count == 2)
}

@Test func retriesThreeTimesThenGivesUp() {
    let h = Harness([.status(503), .status(503), .status(429), .status(503), .ok()])
    let outcome = h.deliver()
    // The first try and three retries, 1, 2 and 4 seconds apart.
    #expect(h.sent.count == 4)
    #expect(h.delays == [1, 2, 4])
    // No fifth try; the caller is told it did not go out and why.
    #expect(outcome == .rejected("503"))
    #expect(h.logs.count >= 1)
    #expect(h.logs.last?.contains("gave up") == true)
    #expect(!h.delivery.isBlocked)
}

@Test func aRetryThatWorksIsSent() {
    let h = Harness([.status(503), nil, .ok()])
    #expect(h.deliver() == .sent)
    #expect(h.sent.count == 3)
    #expect(h.delays == [1, 2])
}

@Test func aNetworkErrorIsRetried() {
    let h = Harness([nil, nil, nil, nil])
    #expect(h.deliver() == .rejected("network error"))
    #expect(h.sent.count == 4)
    #expect(h.delays == [1, 2, 4])
}

@Test func aRefusedPushIsNotRetried() {
    let h = Harness([.status(400, "PayloadTooLarge"), .ok()])
    #expect(h.deliver() == .rejected("PayloadTooLarge"))
    #expect(h.sent.count == 1 && h.delays.isEmpty)
    #expect(h.logs.count == 1)
}

@Test func theLogNeverHoldsTheDeviceTokenOrThePayload() {
    let h = Harness(
        Array(repeating: .status(503), count: 4) + Array(repeating: nil, count: 4)
            + [.status(410, "Unregistered"), .status(400, "BadPayload"), .status(403, "InvalidProviderToken")]
    )
    for _ in 0..<6 { _ = h.deliver() }
    #expect(h.logs.count >= 5)
    for line in h.logs {
        #expect(!line.contains(deviceToken))
        #expect(!line.contains(String(deviceToken.prefix(16))))
        #expect(!line.contains("aps"))
        #expect(!line.contains("JWT"))
        #expect(!line.contains("apple.com"))
    }
}

@Test func aTopicTheSetupCannotPushToIsASetupError() {
    // The bundle id or the key's rights are wrong: every push would fail the same way until the settings change.
    #expect(APNsResponse.classify(status: 400, body: body("TopicDisallowed")) == .configError("这把密钥不能给这个 bundle id 推送"))
    #expect(APNsResponse.classify(status: 400, body: body("BadTopic")) == .configError("bundle id 不对"))
    #expect(APNsResponse.classify(status: 400, body: body("MissingTopic")) == .configError("没有填 bundle id"))
    // Other 400s stay refusals of that one push.
    #expect(APNsResponse.classify(status: 400, body: body("BadExpirationDate")) == .rejected("BadExpirationDate"))
}
