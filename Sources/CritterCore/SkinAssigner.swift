import Foundation

/// Deals skins out to sessions for "随机宠物", so a row of sessions isn't all the same pet.
public enum SkinAssigner {
    /// A skin (a name from `skins`) for every id in `sessionIDs`. A session keeps the one it
    /// has in `previous` while that skin is still in `skins`; any other session, in
    /// `sessionIDs` order, gets a uniformly random pick among the skins the sessions use least
    /// so far, so no skin repeats until every one is in use. `onStage` are ids whose Critters
    /// are still on stage though missing from `sessionIDs` (leaving, or a snapshot that briefly
    /// lost them): they keep their skins, counted as in use, but are never dealt a new one.
    /// Everyone else is dropped. With no skins, nobody gets one.
    public static func assign(sessionIDs: [String], onStage: [String] = [], skins: [String], previous: [String: String],
                              rng: MotionRNG) -> [String: String] {
        var offered: [String] = []
        for skin in skins where !offered.contains(skin) { offered.append(skin) }
        guard !offered.isEmpty else { return [:] }

        var uses = Dictionary(uniqueKeysWithValues: offered.map { ($0, 0) })
        var out: [String: String] = [:]
        for id in sessionIDs + onStage where out[id] == nil {
            guard let skin = previous[id], uses[skin] != nil else { continue }
            out[id] = skin
            uses[skin, default: 0] += 1
        }
        for id in sessionIDs where out[id] == nil {
            let least = uses.values.min() ?? 0
            let candidates = offered.filter { uses[$0] == least }
            let skin = candidates[rng.integer(in: 0...candidates.count - 1)]
            out[id] = skin
            uses[skin, default: 0] += 1
        }
        return out
    }
}
