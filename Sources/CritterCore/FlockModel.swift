import Foundation

/// What the flock window should currently render.
public enum FlockPresentation: Equatable {
    case empty
    case expanded([PetSession], showCollapse: Bool)
    case merged(lead: PetSession, counts: [StateCount], total: Int)
}

/// Decides whether to show every session's own Critter, or merge them into one representative
/// Critter with a summary badge -- automatically above `threshold`, or per the user's
/// `override` while it still applies.
public enum FlockModel {
    private static let countOrder: [PetState] = [.waiting, .error, .done, .running, .idle]

    public static func present(_ sessions: [PetSession], threshold: Int, override: FlockOverride?) -> FlockPresentation {
        if sessions.isEmpty { return .empty }
        if sessions.count == 1 { return .expanded(sessions, showCollapse: false) }

        let shouldMerge: Bool
        if let override, override.sessionCount == sessions.count {
            shouldMerge = override.merged
        } else {
            shouldMerge = sessions.count > threshold
        }

        guard shouldMerge else {
            return .expanded(sessions, showCollapse: sessions.count >= 2)
        }
        return merged(sessions)
    }

    /// The merged pile for `sessions` (non-empty): the most urgent session in front (the
    /// earliest started among equals) and a count per state.
    public static func merged(_ sessions: [PetSession]) -> FlockPresentation {
        let leadState = PetState.mostUrgent(sessions.map(\.state)) ?? .idle
        let lead = sessions
            .filter { $0.state == leadState }
            .min { $0.sortKey < $1.sortKey }
            ?? sessions[0]

        let counts = countOrder.compactMap { state -> StateCount? in
            let count = sessions.filter { $0.state == state }.count
            return count > 0 ? StateCount(state: state, count: count) : nil
        }

        return .merged(lead: lead, counts: counts, total: sessions.count)
    }
}
