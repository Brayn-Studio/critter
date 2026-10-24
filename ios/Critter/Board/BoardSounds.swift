import AVFoundation
import CritterClient
import CritterKit

/// The board's sounds (spec §8.7, Android `BoardSounds`): `Sounds/<theme>/{waiting,done,error}.wav` from the app's
/// bundle, while the board is up and the setting 「看板提示音」 is on. The theme is the Mac's `prefs.soundTheme`;
/// `system`, an unknown one or one the app does not have means `voice`. Which snapshot deserves which sound is
/// `BoardSoundCue`'s to say: only a state a session has just entered, never on the first snapshot of a connection (or
/// of the board), and of several only the most urgent.
///
/// The audio session is `.ambient`: the ring/silent switch silences it, and it plays along with whatever else is
/// playing instead of stopping it. One sound at a time.
@MainActor
final class BoardSounds {
    private static let states: [PetState] = [.waiting, .done, .error]

    /// Each sound loaded so far, by "theme/state".
    private var players: [String: AVAudioPlayer] = [:]
    /// Which snapshot plays which sound.
    private var cue = BoardSoundCue()
    private var sessionSet = false

    /// Called with every snapshot while the board is up, and once when it comes up. `live` false (the connection
    /// dropped, or the snapshot is a cached one) forgets the last one, so the first snapshot of the next connection
    /// is not taken for news.
    func update(_ body: SnapshotBody?, live: Bool, enabled: Bool) {
        let entered = cue.next(body.map { BoardSoundCue.states($0.sessions) }, live: live, enabled: enabled)
        guard live, enabled, let body else { return }
        let theme = Self.resolve(body.prefs.soundTheme)
        prepare(theme)
        if let entered { play(entered, theme: theme) }
    }

    /// The board is gone: nothing more is played, and the sounds are let go.
    func stop() {
        for player in players.values { player.stop() }
        players.removeAll()
        cue.reset()
    }

    /// The folder for the Mac's `theme`: the theme itself when the app has it, `voice` otherwise.
    static func resolve(_ theme: String) -> String {
        BoardSoundCue.theme(theme) { name in
            PhoneSkinLibrary.isPlain(name)
                && Bundle.main.url(forResource: "waiting", withExtension: "wav", subdirectory: "Sounds/\(name)") != nil
        }
    }

    /// Loads the theme's three sounds ahead of time, so the first one is not lost to loading.
    private func prepare(_ theme: String) {
        if !sessionSet {
            sessionSet = true
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        }
        for state in Self.states { _ = player(theme, state) }
    }

    private func play(_ state: PetState, theme: String) {
        guard let player = player(theme, state) else { return }
        for other in players.values where other !== player { other.stop() }
        player.currentTime = 0
        player.play()
        boardLog("sound \(state.rawValue) (\(theme))")
    }

    private func player(_ theme: String, _ state: PetState) -> AVAudioPlayer? {
        let key = "\(theme)/\(state.rawValue)"
        if let player = players[key] { return player }
        guard Self.states.contains(state),
              let url = Bundle.main.url(
                  forResource: state.rawValue, withExtension: "wav", subdirectory: "Sounds/\(theme)"
              ),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        player.prepareToPlay()
        players[key] = player
        return player
    }
}
