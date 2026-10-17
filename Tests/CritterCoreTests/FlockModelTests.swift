import Testing
@testable import CritterCore

private func s(_ id: String, state: PetState, sortKey: Int64) -> PetSession {
    PetSession(
        id: id, name: id, source: .terminal, state: state, detail: nil, cwd: "/x", pid: nil,
        transcriptPath: nil, tracked: true, eventTime: sortKey, sortKey: sortKey
    )
}

@Test func emptyIsEmpty() {
    #expect(FlockModel.present([], threshold: 4, override: nil) == .empty)
}

@Test func singleSessionNeverShowsCollapse() {
    let one = [s("0", state: .running, sortKey: 0)]
    #expect(FlockModel.present(one, threshold: 4, override: nil) == .expanded(one, showCollapse: false))
}

@Test func autoMergeAboveThreshold() {
    let five = (0..<5).map { s("\($0)", state: $0 == 3 ? .waiting : .running, sortKey: Int64($0)) }
    guard case .merged(let lead, let counts, 5) = FlockModel.present(five, threshold: 4, override: nil) else {
        Issue.record("expected merged")
        return
    }
    #expect(lead.id == "3")
    #expect(counts == [StateCount(state: .waiting, count: 1), StateCount(state: .running, count: 4)])
    #expect(FlockModel.present(Array(five.prefix(4)), threshold: 4, override: nil) == .expanded(Array(five.prefix(4)), showCollapse: true))
}

@Test func overrideHoldsUntilCountChanges() {
    let five = (0..<5).map { s("\($0)", state: .running, sortKey: Int64($0)) }
    let override = FlockOverride(merged: false, sessionCount: 5)
    #expect(FlockModel.present(five, threshold: 4, override: override) == .expanded(five, showCollapse: true))

    let six = five + [s("5", state: .running, sortKey: 5)]
    guard case .merged(_, _, 6) = FlockModel.present(six, threshold: 4, override: override) else {
        Issue.record("expected merged once the session count no longer matches the override")
        return
    }
}

@Test func mergedLeadIsEarliestAmongMostUrgentState() {
    // Two waiting sessions, "later" one should still lose to the earlier-sorted one even
    // though both share the most urgent state.
    let sessions = [
        s("x", state: .running, sortKey: 0),
        s("y", state: .waiting, sortKey: 5),
        s("z", state: .waiting, sortKey: 2),
        s("w", state: .running, sortKey: 1),
        s("v", state: .running, sortKey: 3),
    ]
    guard case .merged(let lead, _, 5) = FlockModel.present(sessions, threshold: 4, override: nil) else {
        Issue.record("expected merged")
        return
    }
    #expect(lead.id == "z")
}

@Test func countsOmitZeroAndOrderByPriority() {
    let sessions = [
        s("0", state: .done, sortKey: 0),
        s("1", state: .idle, sortKey: 1),
        s("2", state: .error, sortKey: 2),
        s("3", state: .idle, sortKey: 3),
        s("4", state: .done, sortKey: 4),
    ]
    guard case .merged(_, let counts, 5) = FlockModel.present(sessions, threshold: 4, override: nil) else {
        Issue.record("expected merged")
        return
    }
    #expect(counts == [StateCount(state: .error, count: 1), StateCount(state: .done, count: 2), StateCount(state: .idle, count: 2)])
}

@Test func soundTriggers() {
    #expect(SoundTrigger.enteredAlertStates(old: nil, new: ["a": .waiting]) == [])
    #expect(SoundTrigger.enteredAlertStates(old: ["a": .running], new: ["a": .waiting, "b": .done]) == [.waiting, .done])
    #expect(SoundTrigger.enteredAlertStates(old: ["a": .waiting], new: ["a": .waiting]) == [])
}

@Test func soundTriggersIgnoreNonAlertStates() {
    #expect(SoundTrigger.enteredAlertStates(old: ["a": .idle], new: ["a": .running]) == [])
}

@Test func soundTriggersDedupeAndOrderByPriority() {
    #expect(SoundTrigger.enteredAlertStates(
        old: ["a": .running, "b": .running, "c": .running],
        new: ["a": .done, "b": .error, "c": .waiting]
    ) == [.waiting, .error, .done])
}
