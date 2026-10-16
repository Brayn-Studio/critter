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
