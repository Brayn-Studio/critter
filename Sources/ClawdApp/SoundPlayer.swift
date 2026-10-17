import AppKit
import ClawdCore

/// Plays the alert for a state a session has just entered, from the chosen set of sounds.
/// The pet depends only on this protocol (spec §8).
protocol SoundPlayer {
    func play(_ state: PetState, theme: SoundTheme)
}

/// Plays a theme's bundled WAVs from `Contents/Resources/Sounds` (`build-app.sh` copies
/// `Sounds/` there), or macOS's own sounds for the system theme -- and in place of any file
/// that can't be found, as when running a bare development binary, so an alert never goes
/// silent. Sounds are loaded and started on a background queue -- loading one reads its
/// file, and the main thread only does UI -- and play asynchronously from there.
/// `loaded` is only touched on that queue, which is what makes the `@unchecked Sendable`
/// sound.
final class ThemedSoundPlayer: SoundPlayer, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.clawd.pet.sound", qos: .userInitiated)
    private let soundsDir: URL?
    private var loaded: [String: NSSound] = [:]

    init(soundsDir: URL? = Bundle.main.resourceURL?.appending(path: "Sounds")) {
        self.soundsDir = soundsDir
    }

    func play(_ state: PetState, theme: SoundTheme) {
        guard let systemName = SoundTheme.systemSoundName(for: state) else { return }
        let path = theme.resourcePath(for: state)
        queue.async { [self] in
            var sound: NSSound?
            var name = systemName
            if let path {
                sound = bundled(path)
                if sound == nil {
                    DiagnosticLog.shared.log("sound missing state=\(state.rawValue) theme=\(theme.rawValue) file=\(path) fallback=\(systemName)")
                } else {
                    name = path
                }
            }
            // `NSSound(named:)` keeps the sounds it has loaded, so repeats cost nothing.
            guard let sound = sound ?? NSSound(named: systemName) else {
                DiagnosticLog.shared.log("sound missing state=\(state.rawValue) name=\(systemName)")
                return
            }
            if sound.isPlaying { sound.stop() }
            let started = sound.play()
            DiagnosticLog.shared.log("sound played state=\(state.rawValue) theme=\(theme.rawValue) name=\(name) started=\(started)")
        }
    }

    /// The bundled sound at `path` (relative to `Sounds`), loaded on first use and kept,
    /// the way `NSSound(named:)` keeps the system ones.
    private func bundled(_ path: String) -> NSSound? {
        if let sound = loaded[path] { return sound }
        guard let soundsDir, let sound = NSSound(contentsOf: soundsDir.appending(path: path), byReference: true) else { return nil }
        loaded[path] = sound
        return sound
    }
}
