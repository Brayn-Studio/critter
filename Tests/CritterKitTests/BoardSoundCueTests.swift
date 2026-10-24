import Testing
@testable import CritterKit

/// The first snapshot of a connection (or of the board) is not news; a state a session then enters is.
@Test func theFirstSnapshotIsSilentAndAnEnteredStatePlays() {
    var cue = BoardSoundCue()
    let first = cue.next(["a": .running, "b": .waiting], live: true, enabled: true)
    #expect(first == nil)
    let same = cue.next(["a": .running, "b": .waiting], live: true, enabled: true)
    #expect(same == nil)
    let done = cue.next(["a": .done, "b": .waiting], live: true, enabled: true)
    #expect(done == .done)
}

/// Of several states entered at once, only the most urgent plays.
@Test func ofSeveralTheMostUrgentPlays() {
    var cue = BoardSoundCue()
    _ = cue.next(["a": .running, "b": .running, "c": .running], live: true, enabled: true)
    let entered = cue.next(["a": .done, "b": .waiting, "c": .error], live: true, enabled: true)
    #expect(entered == SoundTrigger.enteredAlertStates(
        old: ["a": .running, "b": .running, "c": .running], new: ["a": .done, "b": .waiting, "c": .error]
    ).first)
    #expect(entered != nil)
}

/// A dropped connection or a cached snapshot forgets the last one: the next connection's first snapshot is silent.
@Test func notLiveForgetsTheLastSnapshot() {
    var cue = BoardSoundCue()
    _ = cue.next(["a": .running], live: true, enabled: true)
    let cached = cue.next(["a": .waiting], live: false, enabled: true)
    #expect(cached == nil)
    #expect(cue.previous == nil)
    let reconnected = cue.next(["a": .waiting], live: true, enabled: true)
    #expect(reconnected == nil)
    let none = cue.next(nil, live: true, enabled: true)
    #expect(none == nil)
    #expect(cue.previous == nil)
}

/// With the sounds off nothing plays, but the snapshot still counts as seen: switching them on plays nothing old.
@Test func soundsOffStillSeeTheSnapshot() {
    var cue = BoardSoundCue()
    _ = cue.next(["a": .running], live: true, enabled: false)
    let off = cue.next(["a": .waiting], live: true, enabled: false)
    #expect(off == nil)
    let on = cue.next(["a": .waiting], live: true, enabled: true)
    #expect(on == nil)
}

/// The board went: the next time it comes up its first snapshot is silent.
@Test func aResetBoardStartsAfresh() {
    var cue = BoardSoundCue()
    _ = cue.next(["a": .running], live: true, enabled: true)
    cue.reset()
    let first = cue.next(["a": .waiting], live: true, enabled: true)
    #expect(first == nil)
}

@Test func theSoundThemeFallsBackToVoice() {
    let has: (String) -> Bool = { ["pixel", "voice"].contains($0) }
    #expect(BoardSoundCue.theme("pixel", has: has) == "pixel")
    #expect(BoardSoundCue.theme("chime", has: has) == "voice")
    #expect(BoardSoundCue.theme("system", has: { _ in true }) == "voice")
    #expect(BoardSoundCue.theme("unknown", has: { _ in true }) == "voice")
}

@Test func statesTakeTheFirstOfAnIdThatComesTwice() {
    func session(_ id: String, _ state: PetState) -> BridgeSession {
        BridgeSession(
            id: id, name: id, source: .terminal, state: state, cwd: "~", skin: "sprig", eventTime: 1, startedAt: 1,
            tracked: true
        )
    }
    let states = BoardSoundCue.states([session("a", .running), session("b", .done), session("a", .error)])
    #expect(states == ["a": .running, "b": .done])
}
