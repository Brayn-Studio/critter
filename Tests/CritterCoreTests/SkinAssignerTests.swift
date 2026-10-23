import Foundation
import Testing
@testable import CritterCore

private let four = ["sprig", "mochi", "peep", "bristle"]

private func deal(_ ids: [String], _ skins: [String] = four, onStage: [String] = [], previous: [String: String] = [:],
                  seed: UInt64 = 7) -> [String: String] {
    SkinAssigner.assign(sessionIDs: ids, onStage: onStage, skins: skins, previous: previous, rng: MotionRNG(seed: seed))
}

@Test func assignerKeepsWhatSessionsHave() {
    let previous = ["a": "peep", "b": "peep"]
    let out = deal(["a", "b", "c"], previous: previous)
    #expect(out["a"] == "peep" && out["b"] == "peep")
    #expect(out["c"] != nil && out["c"] != "peep")   // peep is already the most used
}

@Test func assignerNeverRepeatsWhileSkinsLast() {
    for seed in UInt64(0)..<200 {
        let out = deal(["a", "b", "c"], seed: seed)
        #expect(Set(out.values).count == 3, "seed \(seed): \(out)")
        let all = deal(["a", "b", "c", "d"], seed: seed)
        #expect(Set(all.values) == Set(four), "seed \(seed): \(all)")
    }
}

@Test func assignerSpreadsEvenlyWhenSessionsOutnumberSkins() {
    for seed in UInt64(0)..<100 {
        let out = deal((1...7).map { "s\($0)" }, ["bristle", "sprig", "mochi"], seed: seed)
        let uses = Dictionary(grouping: out.values, by: { $0 }).mapValues(\.count)
        #expect(out.count == 7)
        #expect(uses.values.sorted() == [2, 2, 3], "seed \(seed): \(uses)")
    }
}

@Test func assignerFillsTheLeastUsedSkinsFirst() {
    // bristle and sprig are taken; the newcomers get mochi and peep before anything repeats.
    for seed in UInt64(0)..<100 {
        let out = deal(["a", "b", "c", "d"], ["bristle", "sprig", "mochi", "peep"], previous: ["a": "bristle", "b": "sprig"], seed: seed)
        #expect(Set([out["c"], out["d"]]) == Set(["mochi", "peep"]), "seed \(seed): \(out)")
    }
}

@Test func assignerDropsSessionsThatAreGone() {
    let out = deal(["a"], previous: ["a": "sprig", "gone": "mochi"])
    #expect(out == ["a": "sprig"])
}

@Test func assignerRedealsASkinThatIsNoLongerOffered() {
    let out = deal(["a", "b"], ["bristle", "sprig"], previous: ["a": "mochi", "b": "bristle"])
    #expect(out == ["a": "sprig", "b": "bristle"])
}

@Test func assignerIsReproducibleWithASeedAndRandomAcrossSeeds() {
    let ids = ["a", "b", "c"]
    #expect(deal(ids, seed: 42) == deal(ids, seed: 42))
    let firstPicks = Set((UInt64(0)..<50).compactMap { deal(["a"], seed: $0)["a"] })
    #expect(firstPicks == Set(four))
}

@Test func assignerKeepsTheSkinsOfCrittersStillOnStage() {
    // "b" is missing from this snapshot but its Critter is still on stage (leaving, or a
    // snapshot that briefly lost it): it keeps peep, and peep counts as in use.
    for seed in UInt64(0)..<50 {
        let out = deal(["a", "c"], ["bristle", "peep", "sprig"], onStage: ["b", "ghost"], previous: ["a": "bristle", "b": "peep"], seed: seed)
        #expect(out["b"] == "peep")
        #expect(out["c"] == "sprig", "seed \(seed): \(out)")
        #expect(out["ghost"] == nil)    // never dealt one of its own
    }
    // Once its Critter is gone too, it's forgotten.
    #expect(deal(["a"], onStage: [], previous: ["a": "bristle", "b": "peep"])["b"] == nil)
}

@Test func assignerWithoutSkinsDealsNothing() {
    #expect(deal(["a", "b"], []).isEmpty)
    #expect(deal([], four).isEmpty)
}
