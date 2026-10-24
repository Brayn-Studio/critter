import CritterKit
import Testing
@testable import CritterClient

/// `startedAt` is the sort key.
private func s(_ id: String, _ state: PetState, _ sortKey: Int64) -> BridgeSession {
    var session = fixtureSession(id, state: state)
    session.eventTime = sortKey
    session.startedAt = sortKey
    return session
}

@Test func emptyIsEmpty() {
    #expect(PhoneFlock.present([], threshold: 4, override: nil) == .empty)
}

@Test func singleSessionNeverShowsCollapse() {
    let one = [s("0", .running, 0)]
    #expect(PhoneFlock.present(one, threshold: 4, override: nil) == .expanded(one, showCollapse: false))
}

@Test func autoMergeAboveThreshold() {
    let five = (0..<5).map { s("\($0)", $0 == 3 ? .waiting : .running, Int64($0)) }
    guard case .merged(let lead, let counts, let total) = PhoneFlock.present(five, threshold: 4, override: nil) else {
        Issue.record("five sessions over a threshold of 4 should merge")
        return
    }
    #expect(total == 5)
    #expect(lead.id == "3")
    #expect(counts == [StateCount(state: .waiting, count: 1), StateCount(state: .running, count: 4)])
    #expect(
        PhoneFlock.present(Array(five.prefix(4)), threshold: 4, override: nil)
            == .expanded(Array(five.prefix(4)), showCollapse: true))
}

@Test func overrideHoldsUntilCountChanges() {
    let five = (0..<5).map { s("\($0)", .running, Int64($0)) }
    let override = FlockOverride(merged: false, sessionCount: 5)
    #expect(PhoneFlock.present(five, threshold: 4, override: override) == .expanded(five, showCollapse: true))

    let six = five + [s("5", .running, 5)]
    // merged once the session count no longer matches the override
    guard case .merged(_, _, let total) = PhoneFlock.present(six, threshold: 4, override: override) else {
        Issue.record("six sessions no longer match the override")
        return
    }
    #expect(total == 6)
}

@Test func mergedLeadIsEarliestAmongMostUrgentState() {
    // Two waiting sessions, "later" one should still lose to the earlier-sorted one even
    // though both share the most urgent state.
    let sessions = [
        s("x", .running, 0),
        s("y", .waiting, 5),
        s("z", .waiting, 2),
        s("w", .running, 1),
        s("v", .running, 3),
    ]
    guard case .merged(let lead, _, let total) = PhoneFlock.present(sessions, threshold: 4, override: nil) else {
        Issue.record("five sessions over a threshold of 4 should merge")
        return
    }
    #expect(total == 5)
    #expect(lead.id == "z")
}

@Test func countsOmitZeroAndOrderByPriority() {
    let sessions = [
        s("0", .done, 0),
        s("1", .idle, 1),
        s("2", .error, 2),
        s("3", .idle, 3),
        s("4", .done, 4),
    ]
    guard case .merged(_, let counts, let total) = PhoneFlock.present(sessions, threshold: 4, override: nil) else {
        Issue.record("five sessions over a threshold of 4 should merge")
        return
    }
    #expect(total == 5)
    #expect(counts == [StateCount(state: .error, count: 1), StateCount(state: .done, count: 2), StateCount(state: .idle, count: 2)])
}

/// The home screen merges a pile it was handed directly, and asks which state to show on top.
@Test func mergedAndMostUrgentWorkOnTheirOwn() {
    let sessions = [s("a", .idle, 1), s("b", .error, 2), s("c", .done, 3)]
    guard case .merged(let lead, _, _) = PhoneFlock.merged(sessions) else {
        Issue.record("merged(_:) should give a merged pile")
        return
    }
    #expect(lead.id == "b")
    #expect(PhoneFlock.mostUrgent([.idle, .done, .waiting, .error]) == .waiting)
    #expect(PhoneFlock.mostUrgent([]) == nil)
}
