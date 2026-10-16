import AppKit
import ClawdCore

/// Plays the alert for a state a session has just entered. The pet depends only on this
/// protocol, so the placeholder sounds can later be replaced by custom ones without
/// touching the caller (spec §8).
protocol SoundPlayer {
    func play(_ state: PetState)
}

/// **System-sound placeholders** (spec §8): waiting → Ping, done → Glass, error → Basso.
/// Sounds are loaded and started on a background queue -- loading one reads its file, and
/// the main thread only does UI -- and play asynchronously from there.
final class SystemSoundPlayer: SoundPlayer, Sendable {
    static let soundNames: [PetState: String] = [.waiting: "Ping", .done: "Glass", .error: "Basso"]

    private let queue = DispatchQueue(label: "local.clawd.pet.sound", qos: .userInitiated)

    func play(_ state: PetState) {
        guard let name = Self.soundNames[state] else { return }
        queue.async {
            // `NSSound(named:)` keeps the sounds it has loaded, so repeats cost nothing.
            guard let sound = NSSound(named: name) else {
                DiagnosticLog.shared.log("sound missing state=\(state.rawValue) name=\(name)")
                return
            }
            if sound.isPlaying { sound.stop() }
            let started = sound.play()
            DiagnosticLog.shared.log("sound played state=\(state.rawValue) name=\(name) started=\(started)")
        }
    }
}
