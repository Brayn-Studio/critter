import Foundation

/// The lifecycle state of a single Claude Code session, as shown by the pet.
public enum PetState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waiting
    case done
    case error

    /// Higher priority states win when multiple sessions must be summarized into one.
    /// waiting > error > done > running > idle
    public var priority: Int {
        switch self {
        case .waiting: return 4
        case .error: return 3
        case .done: return 2
        case .running: return 1
        case .idle: return 0
        }
    }

    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .waiting: return "等你确认"
        case .done: return "做完了"
        case .error: return "出错"
        }
    }

    public var accessory: String {
        switch self {
        case .idle: return "z z"
        case .running: return "•••"
        case .waiting: return "?"
        case .done: return "✓"
        case .error: return "!"
        }
    }

    public var colorHex: String {
        switch self {
        case .waiting: return "#FF9F0A"
        case .done: return "#34C759"
        case .error: return "#FF3B30"
        case .running, .idle: return "#8E8E93"
        }
    }

    /// The most urgent state among `states`, or nil if `states` is empty.
    public static func mostUrgent(_ states: [PetState]) -> PetState? {
        states.max(by: { $0.priority < $1.priority })
    }
}
