import Testing
@testable import CritterCore

private func s(_ id: String, state: PetState = .running) -> PetSession {
    PetSession(
        id: id, name: "name-\(id)", source: .terminal, state: state, detail: nil, cwd: "/x", pid: nil,
        transcriptPath: nil, tracked: true, eventTime: 1, sortKey: Int64(id.unicodeScalars.first?.value ?? 0)
    )
}

private func exp(_ ids: String...) -> FlockStructure {
    FlockStructure(.expanded(ids.map { s($0) }, showCollapse: ids.count >= 2))
}
private func mrg(_ lead: String) -> FlockStructure {
    FlockStructure(.merged(lead: s(lead), counts: [StateCount(state: .running, count: 5)], total: 5))
}
private let empty = FlockStructure(.empty)

@Test func structureOfPresentations() {
    #expect(empty.kind == .empty && empty.ids == [])
    #expect(mrg("a").kind == .merged && mrg("a").ids == ["a"])
    #expect(exp("a", "b").kind == .expanded && exp("a", "b").ids == ["a", "b"])
}

@Test func classification() {
    #expect(FlockTransition.between(exp("a", "b"), exp("a", "b")) == .update)
    #expect(FlockTransition.between(mrg("a"), mrg("b")) == .update)
    #expect(FlockTransition.between(empty, empty) == .update)
    #expect(FlockTransition.between(mrg("a"), exp("a", "b")) == .expand)
    #expect(FlockTransition.between(exp("a", "b"), mrg("a")) == .collapse)
    #expect(FlockTransition.between(exp("a", "b"), exp("a", "b", "c")) == .join(added: ["c"]))
    #expect(FlockTransition.between(exp("a", "b", "c"), exp("a", "c")) == .leave(removed: ["b"]))
    #expect(FlockTransition.between(exp("a", "b"), exp("b", "c")) == .leaveThenJoin(removed: ["a"], added: ["c"]))
    #expect(FlockTransition.between(exp("a", "b"), exp("b", "a")) == .reorder)
    #expect(FlockTransition.between(empty, exp("a")) == .reuse(from: "", to: "a"))
    #expect(FlockTransition.between(exp("a"), empty) == .reuse(from: "a", to: ""))
    #expect(FlockTransition.between(empty, exp("a", "b")) == .snap)
    #expect(FlockTransition.between(exp("a", "b"), empty) == .snap)
    #expect(FlockTransition.between(empty, mrg("a")) == .snap)
    #expect(FlockTransition.between(mrg("a"), empty) == .snap)
}

@Test func joinAndLeaveWithReorderedSurvivorsStillJoinLeave() {
    #expect(FlockTransition.between(exp("a", "b"), exp("c", "b", "a")) == .join(added: ["c"]))
    #expect(FlockTransition.between(exp("a", "b", "c"), exp("c", "a")) == .leave(removed: ["b"]))
}

@Test func stateOnlyChangeIsUpdate() {
    let a = FlockStructure(.expanded([s("a", state: .running), s("b", state: .idle)], showCollapse: true))
    let b = FlockStructure(.expanded([s("a", state: .waiting), s("b", state: .done)], showCollapse: true))
    #expect(FlockTransition.between(a, b) == .update)
}

@Test func idleSubmitRunsImmediately() {
    var q = ChoreographyQueue<Int>()
    #expect(!q.isBusy)
    #expect(q.submit(1) == 1)
    #expect(q.isBusy)
}

@Test func latestPendingWins() {
    var q = ChoreographyQueue<String>()
    _ = q.submit("run")
    #expect(q.submit("A") == nil)
    #expect(q.submit("B") == nil)
    #expect(q.finish() == "B")
    #expect(q.isBusy)
}

@Test func finishRunsPendingThenGoesIdle() {
    var q = ChoreographyQueue<Int>()
    _ = q.submit(1)
    _ = q.submit(2)
    #expect(q.finish() == 2)
    #expect(q.isBusy)
    #expect(q.finish() == nil)
    #expect(!q.isBusy)
    #expect(q.submit(3) == 3)
}

@Test func removeThenReAddSameIdWhileBusy() {
    var q = ChoreographyQueue<FlockStructure>()
    _ = q.submit(exp("x", "y"))
    #expect(q.submit(exp("y")) == nil)
    #expect(q.submit(exp("x", "y")) == nil)
    #expect(q.finish() == exp("x", "y"))
}
