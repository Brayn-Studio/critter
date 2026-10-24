import Foundation

/// Decides which states deserve a sound this update: only `waiting`/`done`/`error` states a
/// session has just *entered*, never ones it was already in (so a sound doesn't replay on
/// every unrelated snapshot) and never on first load (there's no "entering" anything yet).
public enum SoundTrigger {
    private static let alertStates: [PetState] = [.waiting, .error, .done]

    public static func enteredAlertStates(old: [String: PetState]?, new: [String: PetState]) -> [PetState] {
        guard let old else { return [] }

        var entered: Set<PetState> = []
        for (id, newState) in new {
            guard alertStates.contains(newState), old[id] != newState else { continue }
            entered.insert(newState)
        }

        return entered.sorted { $0.priority > $1.priority }
    }
}

/// What the phone's board plays (spec §8.7, Android `BoardSounds`): for each snapshot while the board is up, the sound
/// of the most urgent alert state a session has just entered (`SoundTrigger`), and from which theme folder. The app
/// only loads and plays the file.
public struct BoardSoundCue: Sendable {
    /// The theme played for `system`, an unknown theme, or one the app does not have.
    public static let fallbackTheme = "voice"

    /// The sessions' states in the last live snapshot; nil before the first one of a connection (or of the board).
    public private(set) var previous: [String: PetState]?

    public init() {}

    /// A snapshot came while the board is up, or the board came up with one (`states`: each session's state). Returns
    /// the state whose sound plays, if the sounds are `enabled`: only one a session has just entered, never on the
    /// first snapshot of a connection or of the board, and of several the most urgent. Not `live` (the connection
    /// dropped, or the snapshot is a cached one) or no snapshot: nothing, and the last one is forgotten, so the first
    /// snapshot of the next connection is not taken for news. With the sounds off the snapshot still counts as seen.
    public mutating func next(_ states: [String: PetState]?, live: Bool, enabled: Bool) -> PetState? {
        guard live, let states else {
            previous = nil
            return nil
        }
        defer { previous = states }
        guard enabled else { return nil }
        return SoundTrigger.enteredAlertStates(old: previous, new: states).first
    }

    /// The board is gone: the next time it comes up starts afresh.
    public mutating func reset() {
        previous = nil
    }

    /// Each session's state; for an id that comes twice, the first.
    public static func states(_ sessions: [BridgeSession]) -> [String: PetState] {
        Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    /// The theme folder for the Mac's `theme` (`prefs.soundTheme`): the theme itself when `has` says the app has it,
    /// `voice` otherwise, and for `system` and `unknown`.
    public static func theme(_ theme: String, has: (String) -> Bool) -> String {
        guard theme != "system", theme != "unknown", has(theme) else { return fallbackTheme }
        return theme
    }
}
