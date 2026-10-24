import Foundation

/// One pet on the Live Activity: the skin's name and the state it shows.
public struct PetBadge: Codable, Equatable, Sendable {
    public var skin: String
    public var state: PetState

    public init(skin: String, state: PetState) {
        self.skin = skin
        self.state = state
    }
}

/// The Live Activity's `ContentState`. The system renders it straight from the push, so it is
/// numbers, skin names and states -- no session name, path or any other text.
public struct LiveActivityContent: Codable, Equatable, Sendable {
    /// `attributes-type` of a push-to-start: the name of the app's `ActivityAttributes` type.
    public static let attributesName = "CritterActivity"
    /// Most pets shown behind the lead one.
    public static let maxBack = 2

    /// How many sessions are in each state: most urgent first, states with none left out.
    public var counts: [StateCount]
    public var lead: PetBadge?
    public var back: [PetBadge]
    public var total: Int
    /// Used percentage of the 5-hour and 7-day limits, 0...100.
    public var fiveHour: Int?
    public var sevenDay: Int?
    /// Milliseconds since the Unix epoch.
    public var updatedAt: Int64

    public init(
        counts: [StateCount], lead: PetBadge?, back: [PetBadge], total: Int,
        fiveHour: Int?, sevenDay: Int?, updatedAt: Int64
    ) {
        self.counts = counts.filter { $0.count > 0 }.sorted { $0.state.priority > $1.state.priority }
        self.lead = lead
        self.back = Array(back.prefix(Self.maxBack))
        self.total = total
        self.fiveHour = fiveHour.map { min(max($0, 0), 100) }
        self.sevenDay = sevenDay.map { min(max($0, 0), 100) }
        self.updatedAt = updatedAt
    }
}
