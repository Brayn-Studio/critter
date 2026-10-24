import CritterKit

/// What the home screen's meadow and the board should currently render (Android `FlockPresentation`; the Mac's
/// `FlockPresentation` is made of `PetSession`s).
public enum PhoneFlockPresentation: Equatable, Sendable {
    case empty
    case expanded([BridgeSession], showCollapse: Bool)
    case merged(lead: BridgeSession, counts: [StateCount], total: Int)
}

/// Decides whether to show every session's own Critter, or merge them into one representative Critter with a
/// summary badge -- automatically above `threshold`, or per the user's `override` while it still applies. A
/// session's sort key is its `startedAt` (the Mac's `PetSession.sortKey`). The same rule as the Mac's `FlockModel`,
/// on the sessions the phone receives.
public enum PhoneFlock {
    private static let countOrder: [PetState] = [.waiting, .error, .done, .running, .idle]

    public static func present(_ sessions: [BridgeSession], threshold: Int, override: FlockOverride?) -> PhoneFlockPresentation {
        if sessions.isEmpty { return .empty }
        if sessions.count == 1 { return .expanded(sessions, showCollapse: false) }

        let shouldMerge: Bool
        if let override, override.sessionCount == sessions.count {
            shouldMerge = override.merged
        } else {
            shouldMerge = sessions.count > threshold
        }

        guard shouldMerge else { return .expanded(sessions, showCollapse: sessions.count >= 2) }
        return merged(sessions)
    }

    /// The merged pile for `sessions` (non-empty): the most urgent session in front (the earliest started among
    /// equals) and a count per state.
    public static func merged(_ sessions: [BridgeSession]) -> PhoneFlockPresentation {
        let leadState = mostUrgent(sessions.map(\.state)) ?? .idle
        let lead = sessions.filter { $0.state == leadState }.min { $0.startedAt < $1.startedAt } ?? sessions[0]

        let counts = countOrder.compactMap { state -> StateCount? in
            let count = sessions.filter { $0.state == state }.count
            return count > 0 ? StateCount(state: state, count: count) : nil
        }

        return .merged(lead: lead, counts: counts, total: sessions.count)
    }

    /// The most urgent state among `states`, or nil if `states` is empty.
    public static func mostUrgent(_ states: [PetState]) -> PetState? {
        PetState.mostUrgent(states)
    }
}
