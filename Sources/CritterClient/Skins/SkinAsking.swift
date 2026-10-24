import CritterKit

/// Which skins to ask the Mac for (Android `BridgeRepository.skinManifest`): one the phone does not have is asked for
/// once per connection. A name the Mac could not send (it has no such skin, it did not answer, the manifest was
/// broken) is not asked for again with every snapshot, only on the next connection. Nothing is asked while the phone
/// is not live (no connection, or only a cached snapshot), and what was asked is forgotten then.
public struct SkinAsking: Sendable {
    /// The names asked for on this connection.
    public private(set) var asked: Set<String> = []

    public init() {}

    /// The names of `names` to ask for now, each remembered as asked: while `live`, the ones `missing` says the phone
    /// does not have and that were not asked for on this connection yet. Not live: none, and the connection's asked
    /// names are forgotten.
    public mutating func toAsk(_ names: [String], live: Bool, missing: (String) -> Bool) -> [String] {
        guard live else {
            asked.removeAll()
            return []
        }
        var out: [String] = []
        for name in names where !asked.contains(name) && missing(name) {
            asked.insert(name)
            out.append(name)
        }
        return out
    }

    /// The skins a snapshot wears: every session's, and the Mac's own (it runs the clock even when no session wears
    /// it).
    public static func names(in snapshot: SnapshotBody?) -> [String] {
        guard let snapshot else { return [] }
        return snapshot.sessions.map(\.skin) + [snapshot.prefs.skin]
    }
}
