import Foundation

/// One pet on the Live Activity: the skin's name and the state it shows.
public struct PetBadge: Codable, Hashable, Sendable {
    public var skin: String
    public var state: PetState

    public init(skin: String, state: PetState) {
        self.skin = skin
        self.state = state
    }
}

/// The Live Activity's `ContentState`. The system renders it straight from the push, so it is
/// numbers, skin names and states -- no session name, path or any other text.
public struct LiveActivityContent: Codable, Hashable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case counts, lead, back, total, fiveHour, sevenDay, updatedAt
    }

    /// Reads what the Mac pushes (the phone's `CritterActivity.ContentState`). A part left out reads as nothing (no
    /// counts, no pets, 0): the system decodes a content state for every push, an `end`'s empty one included, and one
    /// it cannot decode is dropped rather than drawn.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([StateCount].self, forKey: .counts) ?? []
        lead = try c.decodeIfPresent(PetBadge.self, forKey: .lead)
        back = try c.decodeIfPresent([PetBadge].self, forKey: .back) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        fiveHour = try c.decodeIfPresent(Int.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(Int.self, forKey: .sevenDay)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}
