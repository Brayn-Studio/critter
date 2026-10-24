import Foundation
import Testing
@testable import CritterCore

// Odd strings no push may carry in the clear. Each has characters base64 and the allowed plain fields never have.
private let secretName = "Secret Name ÄÖ"
private let secretCommand = "rm -rf ~/Secret Command {x}"
private let secretFolder = "Secret Folder"
private let secretBranch = "secret branch/ß"
private let secretQuestion = "Secret Question?"
private let secretPlan = "Secret Plan: step 1"
private let secretDetail = "Secret Detail (MacBook-of-Secret)"

private let key = PushCrypto.makeKey()

private func session(
    id: String = "s-1", name: String = secretName, state: PetState = .waiting, source: SessionSource = .terminal,
    cwd: String = "/Users/me/\(secretFolder)", branch: String? = secretBranch, detail: String? = secretDetail
) -> BridgeSession {
    BridgeSession(
        id: id, name: name, source: source, state: state, detail: detail, activity: secretDetail, cwd: cwd,
        branch: branch, skin: "sprig", eventTime: 1, startedAt: 1, tracked: true
    )
}

private func request(
    _ kind: PendingKind, id: String = "r-1", summary: String = "运行 Secret Command", input: JSONValue = .null,
    expiresAt: Int64? = nil
) -> BridgePending {
    BridgePending(
        requestId: id, sessionId: "s-1", kind: kind, toolName: "Bash", summary: summary, input: input,
        createdAt: 1, expiresAt: expiresAt
    )
}

private func command(_ text: String) -> JSONValue { .object(["command": .string(text)]) }

private func object(_ message: APNsMessage) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: message.payload) as? [String: Any])
}

private func aps(_ message: APNsMessage) throws -> [String: Any] {
    try #require(try object(message)["aps"] as? [String: Any])
}

private func alert(_ message: APNsMessage) throws -> ParsedPush.Alert {
    guard case .alert(let alert)? = PushPayload.parse(try object(message)) else {
        Issue.record("not an alert push")
        throw CancellationError()
    }
    return alert
}

private func opened(_ message: APNsMessage) throws -> PushText {
    try PushCrypto.open(try alert(message), key: key)
}

// MARK: - What the notification says

@Test func sealedTextOpensToTheNotification() throws {
    let message = try PushContent.request(
        request(.permission, summary: "运行 swift test", input: command("swift test --filter X")),
        session: session(name: "critter", cwd: "/Users/me/critter", branch: "main"), key: key
    )
    #expect(try opened(message) == PushText(
        title: "critter 想 运行 swift test", subtitle: "critter · main · 终端", body: "swift test --filter X"
    ))
    let parsed = try alert(message)
    #expect(parsed.category == .permission)
    #expect(parsed.requestId == "r-1" && parsed.sessionId == "s-1")
    #expect(message.pushType == .alert)
    #expect(message.priority == 10)
    #expect(message.collapseId == "r-1")
}

@Test func theExpirationIsTheRequestsInSeconds() throws {
    let expiring = try PushContent.request(
        request(.permission, expiresAt: 1_760_000_123_456), session: session(), key: key
    )
    #expect(expiring.expiration == 1_760_000_123)
    let open = try PushContent.request(request(.permission), session: session(), key: key)
    #expect(open.expiration == nil)
}

@Test func aQuestionAndAPlanShowTheFolderAndHaveTheirOwnCategories() throws {
    let question = try PushContent.request(
        request(.question, summary: secretQuestion), session: session(name: "critter", cwd: "/Users/me/critter"), key: key
    )
    #expect(try alert(question).category == .question)
    #expect(try opened(question).title == "critter 问：\(secretQuestion)")
    #expect(try opened(question).body == "critter")

    let plan = try PushContent.request(request(.plan), session: session(name: "critter"), key: key)
    #expect(try alert(plan).category == .plan)
    #expect(try opened(plan).title == "critter 的计划等你批准")
}

@Test func aRequestWhoseSessionIsGoneStillGetsPushed() throws {
    let message = try PushContent.request(request(.permission, input: command("ls")), session: nil, key: key)
    #expect(try opened(message) == PushText(title: "会话 想 运行 Secret Command", subtitle: "", body: "ls"))
}

@Test func codexPermissionHasNoReasonCategory() throws {
    let codex = JSONValue.object(["command": .string("npm test"), "acceptsDenyMessage": .bool(false)])
    let message = try PushContent.request(request(.permission, input: codex), session: session(), key: key)
    #expect(try alert(message).category == .permissionNoReason)
    #expect(try aps(message)["category"] as? String == "permissionNoReason")
    // Claude's request, and an older one without the field, can be denied with a reason.
    let claude = try PushContent.request(request(.permission, input: command("npm test")), session: session(), key: key)
    #expect(try alert(claude).category == .permission)
}

@Test func waitingIsTimeSensitive() throws {
    let kinds: [PendingKind] = [.permission, .question, .plan]
    for kind in kinds {
        let message = try PushContent.request(request(kind), session: session(), key: key)
        #expect(try aps(message)["interruption-level"] as? String == "time-sensitive", "\(kind)")
    }
    let notice = try PushContent.waitingNotice(session(), key: key)
    #expect(try aps(notice)["interruption-level"] as? String == "time-sensitive")
    // Done, error and the test are ordinary notifications.
    for message in [
        try PushContent.result(session(), state: .done, key: key),
        try PushContent.result(session(), state: .error, key: key),
        try PushContent.test(key: key),
    ] {
        #expect(try aps(message)["interruption-level"] == nil)
    }
    // The phone's notification service extension sets the level by the category (`waitsForTheUser`): the same rule.
    let codex = request(.permission, input: .object(["acceptsDenyMessage": .bool(false)]))
    for message in try kinds.map({ try PushContent.request(request($0), session: session(), key: key) }) + [
        try PushContent.request(codex, session: session(), key: key), notice,
        try PushContent.result(session(), state: .done, key: key), try PushContent.result(session(), state: .error, key: key),
        try PushContent.test(key: key),
    ] {
        #expect(try alert(message).category.waitsForTheUser == (try aps(message)["interruption-level"] != nil))
    }
}

@Test func theWaitingNoticeSendsYouToTheComputer() throws {
    let message = try PushContent.waitingNotice(
        session(name: "critter", cwd: "/Users/me/critter", detail: "运行 npm test"), key: key
    )
    #expect(try opened(message) == PushText(
        title: "critter 等你确认（请在电脑上处理）", subtitle: "critter · \(secretBranch) · 终端", body: "运行 npm test"
    ))
    let parsed = try alert(message)
    #expect(parsed.category == .waitingElsewhere && parsed.requestId == nil && parsed.sessionId == "s-1")
    #expect(message.collapseId == "waitingElsewhere:s-1")
    #expect(message.collapseId == parsed.notificationId)
    #expect(message.priority == 10 && message.expiration == nil)
}

@Test func aResultNotificationHasTheNameAndTheState() throws {
    let done = try PushContent.result(
        session(name: "critter", cwd: "/Users/me/critter", branch: "main", detail: "测试通过"), state: .done, key: key
    )
    #expect(try opened(done) == PushText(title: "critter 做完了", subtitle: "critter · main · 终端", body: "测试通过"))
    #expect(try alert(done).category == .done)
    #expect(done.collapseId == "done:s-1")

    let failed = try PushContent.result(session(name: "critter", detail: nil), state: .error, key: key)
    #expect(try opened(failed).title == "critter 出错")
    #expect(try opened(failed).body == "")
    #expect(try alert(failed).category == .error)
    #expect(failed.collapseId == "error:s-1")
}

@Test func theTestNotification() throws {
    let message = try PushContent.test(key: key)
    #expect(try opened(message) == PushText(title: "Critter 推送测试", subtitle: "", body: "能看到这条，说明推送通了"))
    #expect(try alert(message).category == .test)
    #expect(message.pushType == .alert)
}

// MARK: - Nothing in the clear

/// Review focus 2: whatever the push, the text of the sessions only exists as ciphertext.
@Test func noSessionTextInThePlainPayload() throws {
    let secretRequestInput = JSONValue.object([
        "command": .string(secretCommand), "file_path": .string(secretFolder), "url": .string(secretQuestion),
        "plan": .string(secretPlan),
    ])
    let loud = session()
    let messages: [APNsMessage] = [
        try PushContent.request(request(.permission, summary: secretCommand, input: secretRequestInput), session: loud, key: key),
        try PushContent.request(
            request(.permission, summary: secretCommand, input: .object(["command": .string(secretCommand), "acceptsDenyMessage": .bool(false)])),
            session: loud, key: key
        ),
        try PushContent.request(request(.question, summary: secretQuestion, input: secretRequestInput), session: loud, key: key),
        try PushContent.request(request(.plan, summary: secretPlan, input: secretRequestInput), session: loud, key: key),
        try PushContent.request(request(.permission, summary: secretCommand, input: secretRequestInput), session: nil, key: key),
        try PushContent.waitingNotice(loud, key: key),
        try PushContent.result(loud, state: .done, key: key),
        try PushContent.result(loud, state: .error, key: key),
        try PushContent.test(key: key),
    ] + PushContent.withdraw(ids: ["r-1", "waitingElsewhere:s-1", "done:s-1"])
    let secrets = [
        secretName, secretCommand, secretFolder, secretBranch, secretQuestion, secretPlan, secretDetail,
        "MacBook", "Secret",
    ]
    for message in messages {
        let text = try #require(String(data: message.payload, encoding: .utf8))
        for secret in secrets {
            #expect(!text.contains(secret), "\(secret) is in the plain payload: \(text)")
        }
        // Only these may appear in the clear.
        let root = try object(message)
        let allowed: Set<String> = ["aps", "c", "r", "s", "k", "w"]
        #expect(Set(root.keys).isSubset(of: allowed), "\(root.keys)")
    }
    // And the sealed ones do hold the text.
    #expect(try opened(messages[0]).body == secretCommand)
}

// MARK: - Fitting 4 KB

@Test func aLongCommandIsCutToFit4KB() throws {
    let long = String(repeating: "x", count: 100_000)
    let message = try PushContent.request(
        request(.permission, input: command(long)), session: session(name: "critter", cwd: "/p/critter", branch: "main"),
        key: key
    )
    #expect(message.payload.count <= 4096)
    let text = try opened(message)
    #expect(text.title == "critter 想 运行 Secret Command")
    #expect(text.subtitle == "critter · main · 终端")
    #expect(text.body.hasSuffix("…"))
    #expect(text.body.count > 2000)
    #expect(long.hasPrefix(String(text.body.dropLast())))
    // As much as fits: one more character would not.
    let longer = PushText(title: text.title, subtitle: text.subtitle, body: String(text.body.dropLast()) + "x…")
    let size = try PushPayload.alert(
        category: .permission, requestId: "r-1", sessionId: "s-1",
        sealed: PushCrypto.seal(longer, key: key, category: .permission, requestId: "r-1", sessionId: "s-1"),
        timeSensitive: true
    )
    #expect(try JSONSerialization.data(withJSONObject: size, options: [.sortedKeys, .withoutEscapingSlashes]).count > 4096)
}

@Test func aShortCommandIsNotTouched() throws {
    let message = try PushContent.request(request(.permission, input: command("ls -la")), session: session(), key: key)
    #expect(try opened(message).body == "ls -la")
    #expect(message.payload.count < 4096)
}

@Test func theCutFallsOnACharacterBoundary() throws {
    // Each family is one Character of 25 UTF-8 bytes; cutting bytes or scalars would split one.
    let family = "👨‍👩‍👧‍👦"
    let long = String(repeating: family, count: 5000)
    let message = try PushContent.request(request(.permission, input: command(long)), session: session(), key: key)
    #expect(message.payload.count <= 4096)
    let body = try opened(message).body
    #expect(body.hasSuffix("…"))
    let kept = body.dropLast()
    #expect(!kept.isEmpty)
    #expect(kept.allSatisfy { $0 == Character(family) })
}

@Test func theSubtitleIsCutWhenTheBodyAloneCannotMakeRoom() throws {
    let branch = String(repeating: "b", count: 20_000)
    let message = try PushContent.request(
        request(.permission, input: command("swift test")), session: session(name: "critter", cwd: "/p/critter", branch: branch),
        key: key
    )
    #expect(message.payload.count <= 4096)
    let text = try opened(message)
    // The body goes first, then the subtitle; the title stays.
    #expect(text.body == "…")
    #expect(text.subtitle.hasSuffix("…") && text.subtitle.hasPrefix("critter · bbb"))
    #expect(text.title == "critter 想 运行 Secret Command")
}

@Test func theTitleHasAtMost60Characters() throws {
    let name = String(repeating: "n", count: 200)
    let message = try PushContent.request(request(.plan), session: session(name: name), key: key)
    let title = try opened(message).title
    #expect(title.count == 60)
    #expect(title.hasSuffix("…") && title.hasPrefix("nnn"))
    // A title that fits stays as it is.
    let short = try PushContent.request(request(.plan), session: session(name: "critter"), key: key)
    #expect(try opened(short).title == "critter 的计划等你批准")
}

@Test func noPushIsOver4KBWhateverTheKind() throws {
    let huge = String(repeating: "界", count: 50_000)
    let big = session(name: huge, cwd: "/p/\(huge)", branch: huge, detail: huge)
    let messages = [
        try PushContent.request(request(.permission, summary: huge, input: command(huge)), session: big, key: key),
        try PushContent.request(request(.question, summary: huge), session: big, key: key),
        try PushContent.waitingNotice(big, key: key),
        try PushContent.result(big, state: .done, key: key),
    ]
    for message in messages {
        #expect(message.payload.count <= 4096)
        #expect(try alert(message).sealed.isEmpty == false)
    }
}

// MARK: - Taking notifications back

@Test func aWithdrawalIsABackgroundPushOfPriority5() throws {
    let messages = PushContent.withdraw(ids: ["r-1", "done:s-1"])
    #expect(messages.count == 1)
    let message = try #require(messages.first)
    #expect(message.pushType == .background)
    #expect(message.priority == 5)
    #expect(message.collapseId == nil)
    #expect(try aps(message)["content-available"] as? Int == 1)
    #expect(try object(message)["w"] as? [String] == ["r-1", "done:s-1"])
    #expect(PushPayload.parse(try object(message)) == .withdraw(ids: ["r-1", "done:s-1"]))
    // Nothing to take back, nothing to send.
    #expect(PushContent.withdraw(ids: []).isEmpty)
}

@Test func manyWithdrawalsAreSplitToFit4KB() throws {
    let ids = (0..<300).map { _ in UUID().uuidString.lowercased() }
    let messages = PushContent.withdraw(ids: ids)
    #expect(messages.count > 1)
    var seen: [String] = []
    for message in messages {
        #expect(message.payload.count <= 4096)
        #expect(message.pushType == .background && message.priority == 5)
        seen += try #require(try object(message)["w"] as? [String])
    }
    #expect(seen == ids)
}

// MARK: - Live Activity

private let badge = PetBadge(skin: "sprig", state: .waiting)

private let content = LiveActivityContent(
    counts: [StateCount(state: .waiting, count: 1), StateCount(state: .running, count: 2)],
    lead: badge, back: [PetBadge(skin: "mint", state: .running)], total: 3, fiveHour: 12, sevenDay: 30,
    updatedAt: 1_760_000_000_000
)

private let now: Int64 = 1_760_000_123_456

@Test func startPushCarriesTheContentAndAnAlert() throws {
    let message = try PushContent.liveActivity(.start(content), now: now)
    #expect(message.pushType == .liveActivity)
    #expect(message.priority == 10)
    #expect(message.collapseId == nil)
    let aps = try aps(message)
    #expect(aps["event"] as? String == "start")
    #expect(aps["timestamp"] as? Int == 1_760_000_123)
    #expect(aps["stale-date"] as? Int == 1_760_000_123 + 15 * 60)
    #expect(aps["attributes-type"] as? String == "CritterActivity")
    #expect((aps["attributes"] as? [String: Any])?.isEmpty == true)
    #expect(aps["alert"] as? [String: String] == ["title": "Critter", "body": "有会话需要你"])
    let state = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
    #expect(try JSONDecoder().decode(LiveActivityContent.self, from: state) == content)
    #expect(aps["dismissal-date"] == nil)
}

@Test func updatePushHasTheGivenPriorityAndNoAlert() throws {
    for priority in [10, 5] {
        let message = try PushContent.liveActivity(.update(content, priority: priority), now: now)
        #expect(message.pushType == .liveActivity)
        #expect(message.priority == priority)
        let aps = try aps(message)
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] as? Int == 1_760_000_123)
        #expect(aps["stale-date"] as? Int == 1_760_000_123 + 15 * 60)
        #expect(aps["alert"] == nil && aps["attributes-type"] == nil && aps["attributes"] == nil)
        #expect(aps["content-state"] is [String: Any])
    }
}

@Test func endPushDismissesAtTheGivenTime() throws {
    let message = try PushContent.liveActivity(.end(dismissAt: 1_760_000_200_000), now: now)
    #expect(message.pushType == .liveActivity)
    let aps = try aps(message)
    #expect(aps["event"] as? String == "end")
    #expect(aps["timestamp"] as? Int == 1_760_000_123)
    #expect(aps["dismissal-date"] as? Int == 1_760_000_200)
    #expect(aps["alert"] == nil && aps["stale-date"] == nil)
    // The system decodes a content state for every event: an empty one, which says "no sessions".
    let state = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
    let final = try JSONDecoder().decode(LiveActivityContent.self, from: state)
    #expect(final.total == 0 && final.lead == nil && final.back.isEmpty && final.counts.isEmpty)
}

/// The system renders the Live Activity straight from the push: no words, only counts, skin names and states.
@Test func activityPushesNeverCarryText() throws {
    let loud = LiveActivityPlanner().content(from: SnapshotBody(
        sessions: [session(id: "s-1", name: secretName, state: .waiting), session(id: "s-2", name: secretFolder, state: .running)],
        limits: BridgeLimits(fiveHour: RateWindow(usedPercentage: 41.6, resetsAt: 1), sevenDay: nil, updatedAt: 1),
        pending: [request(.permission, summary: secretCommand, input: command(secretCommand))],
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1, mergeThreshold: 4, soundTheme: "pixel")
    ))
    for action in [LiveActivityAction.start(loud), .update(loud, priority: 5), .end(dismissAt: now)] {
        let message = try PushContent.liveActivity(action, now: now)
        let text = try #require(String(data: message.payload, encoding: .utf8))
        for secret in [secretName, secretCommand, secretFolder, secretBranch, secretDetail, "Secret"] {
            #expect(!text.contains(secret), "\(secret) in \(text)")
        }
    }
}

@Test func aSealedTextMovedToAnotherPushDoesNotOpen() throws {
    let first = try alert(PushContent.request(request(.permission, input: command("ls")), session: session(), key: key))
    var second = try alert(PushContent.waitingNotice(session(), key: key))
    #expect(try PushCrypto.open(first, key: key).body == "ls")
    // The first request's text in the second push (another category, no request id): it does not open.
    second.sealed = first.sealed
    #expect(throws: (any Error).self) { try PushCrypto.open(second, key: key) }
    var otherRequest = first
    otherRequest.requestId = (first.requestId ?? "") + "x"
    #expect(throws: (any Error).self) { try PushCrypto.open(otherRequest, key: key) }
}
