import Foundation

/// A user's explicit override of the automatic merge/expand decision (e.g. they manually
/// expanded a merged flock). Held by the app only as long as the session count it was made
/// against still matches -- once sessions are added or removed, the automatic rule resumes.
public struct FlockOverride: Sendable, Equatable {
    public var merged: Bool
    public var sessionCount: Int

    public init(merged: Bool, sessionCount: Int) {
        self.merged = merged
        self.sessionCount = sessionCount
    }
}

/// How many sessions share a given state, for the merged flock's summary badge.
public struct StateCount: Codable, Equatable, Sendable {
    public var state: PetState
    public var count: Int

    public init(state: PetState, count: Int) {
        self.state = state
        self.count = count
    }
}
