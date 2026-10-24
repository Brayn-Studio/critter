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
