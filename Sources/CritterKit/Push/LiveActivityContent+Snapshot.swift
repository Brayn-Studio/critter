import Foundation

extension LiveActivityContent {
    /// The content to show for `snapshot` (spec §6.6, §8.5): the one rule the Mac's pushes (`LiveActivityPlanner`) and
    /// the phone's own updates (`LocalActivity`) both use, so the two never disagree. The lead and the two behind it are
    /// the most urgent sessions, the earlier started first among equals: the same order as the flock (`FlockModel`,
    /// `PhoneFlock`). Counts, skin names, states and percentages only: nothing the system would show as text.
    /// - Parameter updatedAt: milliseconds since the epoch.
    public init(snapshot: SnapshotBody, updatedAt: Int64) {
        let ordered = snapshot.sessions.sorted { a, b in
            if a.state.priority != b.state.priority { return a.state.priority > b.state.priority }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
        let badges = ordered.prefix(1 + Self.maxBack).map { PetBadge(skin: $0.skin, state: $0.state) }
        self.init(
            counts: PetState.allCases.map { state in
                StateCount(state: state, count: snapshot.sessions.filter { $0.state == state }.count)
            },
            lead: badges.first, back: Array(badges.dropFirst()), total: snapshot.sessions.count,
            fiveHour: Self.percent(snapshot.limits?.fiveHour), sevenDay: Self.percent(snapshot.limits?.sevenDay),
            updatedAt: updatedAt
        )
    }

    /// A used percentage as a whole number; nil if there is none or it is not a number.
    private static func percent(_ window: RateWindow?) -> Int? {
        guard let value = window?.usedPercentage, value.isFinite else { return nil }
        return Int(min(max(value.rounded(), 0), 100))
    }
}
