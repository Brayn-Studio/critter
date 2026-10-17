import Foundation

/// The set of alert sounds the pet plays ("声音" in settings). The first three are
/// bundled WAVs made by `scripts/dev/make-sounds.py` into `Sounds/<theme>/<state>.wav`;
/// `system` is macOS's own Ping / Glass / Basso.
public enum SoundTheme: String, CaseIterable, Sendable {
    case voice
    case pixel
    case marimba
    case system

    public static let `default`: SoundTheme = .voice

    /// The theme a stored raw value names; nothing stored, or a name this version doesn't
    /// know, means the default.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .default
    }

    public var label: String {
        switch self {
        case .voice: return "Critter 的声音"
        case .pixel: return "软像素"
        case .marimba: return "小木琴"
        case .system: return "系统音效"
        }
    }

    /// The bundled file for `state`, relative to the `Sounds` folder -- nil for the system
    /// theme and for states that never make a sound.
    public func resourcePath(for state: PetState) -> String? {
        guard self != .system, Self.systemSoundName(for: state) != nil else { return nil }
        return "\(rawValue)/\(state.rawValue).wav"
    }

    /// The macOS sound for `state`: what the system theme plays, and what any other theme
    /// falls back to when its file can't be found.
    public static func systemSoundName(for state: PetState) -> String? {
        switch state {
        case .waiting: return "Ping"
        case .done: return "Glass"
        case .error: return "Basso"
        case .idle, .running: return nil
        }
    }
}
