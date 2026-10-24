import Foundation
import Testing
@testable import CritterKit

private func encode(_ content: LiveActivityContent) throws -> [String: Any] {
    let data = try JSONEncoder().encode(content)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let content = LiveActivityContent(
    counts: [StateCount(state: .waiting, count: 2), StateCount(state: .running, count: 1)],
    lead: PetBadge(skin: "sprig", state: .waiting),
    back: [PetBadge(skin: "mochi", state: .running)],
    total: 3, fiveHour: 12, sevenDay: 30, updatedAt: 1_760_000_000_000
)

/// What the system renders straight from the push: numbers, skin names and states, no prose.
@Test func activityContentHasNoTextFields() throws {
    let object = try encode(content)
    #expect(Set(object.keys) == ["counts", "lead", "back", "total", "fiveHour", "sevenDay", "updatedAt"])
    let counts = try #require(object["counts"] as? [[String: Any]])
    #expect(counts.allSatisfy { Set($0.keys) == ["state", "count"] })
    let lead = try #require(object["lead"] as? [String: Any])
    #expect(Set(lead.keys) == ["skin", "state"])
    let back = try #require(object["back"] as? [[String: Any]])
    #expect(back.allSatisfy { Set($0.keys) == ["skin", "state"] })
}

@Test func activityContentRoundTrips() throws {
    let data = try JSONEncoder().encode(content)
    #expect(try JSONDecoder().decode(LiveActivityContent.self, from: data) == content)
}

@Test func absentPartsAreLeftOut() throws {
    let empty = LiveActivityContent(counts: [], lead: nil, back: [], total: 0, fiveHour: nil, sevenDay: nil, updatedAt: 5)
    let object = try encode(empty)
    #expect(Set(object.keys) == ["counts", "back", "total", "updatedAt"])
}

@Test func countsAreByPriorityAndOnlyThoseAboveZero() {
    let c = LiveActivityContent(
        counts: [
            StateCount(state: .idle, count: 4), StateCount(state: .done, count: 0), StateCount(state: .running, count: 1),
            StateCount(state: .error, count: 1), StateCount(state: .waiting, count: 3),
        ],
        lead: nil, back: [], total: 9, fiveHour: nil, sevenDay: nil, updatedAt: 0
    )
    #expect(c.counts.map(\.state) == [.waiting, .error, .running, .idle])
}

@Test func atMostTwoBadgesGoBehindAndPercentagesStayInRange() {
    let badges = (0..<4).map { PetBadge(skin: "s\($0)", state: .running) }
    let c = LiveActivityContent(counts: [], lead: nil, back: badges, total: 4, fiveHour: 140, sevenDay: -3, updatedAt: 0)
    #expect(c.back.map(\.skin) == ["s0", "s1"])
    #expect(c.fiveHour == 100)
    #expect(c.sevenDay == 0)
}

@Test func theAttributesNameIsTheOneThePhoneRegisters() {
    #expect(LiveActivityContent.attributesName == "CritterActivity")
}

// MARK: - What the phone decodes

/// The `aps` of a Live Activity push as the protocol doc shows it (`docs/critter-bridge-protocol.md`, "How the Mac
/// pushes"): the Mac's own encoding of the content above, sent at 1760000000000.
private let macPushes = [
    "start": #"{"aps":{"alert":{"body":"有会话需要你","title":"Critter"},"attributes":{},"attributes-type":"CritterActivity","content-state":{"back":[{"skin":"mochi","state":"running"}],"counts":[{"count":2,"state":"waiting"},{"count":1,"state":"running"}],"fiveHour":12,"lead":{"skin":"sprig","state":"waiting"},"sevenDay":30,"total":3,"updatedAt":1760000000000},"event":"start","stale-date":1760000900,"timestamp":1760000000}}"#,
    "update": #"{"aps":{"content-state":{"back":[{"skin":"mochi","state":"running"}],"counts":[{"count":2,"state":"waiting"},{"count":1,"state":"running"}],"fiveHour":12,"lead":{"skin":"sprig","state":"waiting"},"sevenDay":30,"total":3,"updatedAt":1760000000000},"event":"update","stale-date":1760000900,"timestamp":1760000000}}"#,
    "end": #"{"aps":{"content-state":{"back":[],"counts":[],"total":0,"updatedAt":1760000000000},"dismissal-date":1760000000,"event":"end","timestamp":1760000000}}"#,
]

private func contentState(_ event: String) throws -> Data {
    let text = try #require(macPushes[event])
    let push = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    let aps = try #require(push["aps"] as? [String: Any])
    return try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
}

/// The app's `CritterActivity.ContentState` is `LiveActivityContent`: what the Mac pushes decodes as it, field for field.
@Test func theMacsStartAndUpdateDecodeAsTheActivityState() throws {
    let expected = LiveActivityContent(
        counts: [StateCount(state: .waiting, count: 2), StateCount(state: .running, count: 1)],
        lead: PetBadge(skin: "sprig", state: .waiting), back: [PetBadge(skin: "mochi", state: .running)],
        total: 3, fiveHour: 12, sevenDay: 30, updatedAt: 1_760_000_000_000
    )
    #expect(try JSONDecoder().decode(LiveActivityContent.self, from: contentState("start")) == expected)
    #expect(try JSONDecoder().decode(LiveActivityContent.self, from: contentState("update")) == expected)
    // And the Mac's encoder writes exactly that object.
    let mine = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSDictionary
    let theirs = try JSONSerialization.jsonObject(with: contentState("start")) as? NSDictionary
    #expect(mine == theirs)
}

/// An `end` carries an empty content (no lead, no counts): it decodes, and says "no sessions".
@Test func theMacsEndDecodesAsAnEmptyState() throws {
    let final = try JSONDecoder().decode(LiveActivityContent.self, from: contentState("end"))
    #expect(final.lead == nil && final.back.isEmpty && final.counts.isEmpty && final.total == 0)
    #expect(final.fiveHour == nil && final.sevenDay == nil)
}

/// A content state with parts left out (an older or newer Mac, or `{}`) still decodes, as "nothing to show", so the
/// system never drops an update the widget could have drawn.
@Test func aContentStateWithPartsLeftOutStillDecodes() throws {
    let empty = try JSONDecoder().decode(LiveActivityContent.self, from: Data("{}".utf8))
    #expect(empty == LiveActivityContent(counts: [], lead: nil, back: [], total: 0, fiveHour: nil, sevenDay: nil, updatedAt: 0))
    let some = try JSONDecoder().decode(
        LiveActivityContent.self, from: Data(#"{"lead":{"skin":"peep","state":"done"},"total":1}"#.utf8)
    )
    #expect(some.lead == PetBadge(skin: "peep", state: .done) && some.total == 1 && some.counts.isEmpty && some.back.isEmpty)
}
