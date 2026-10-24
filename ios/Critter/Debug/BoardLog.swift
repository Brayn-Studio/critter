#if DEBUG
import Foundation

/// `-critterBoardLog`: "board [12.3 s] <what>" on standard output, the time counted from launch, for each thing the
/// board does to the screen (`BoardScreenKeeper`: entering, every brightness set, every way out), each sound it plays
/// and each step of the automatic opening (`BoardAutoOpen`: the charger, the scene, the gravity sensor going on and
/// off, the trigger's decisions). Read it with `xcrun simctl launch --console-pty <device> com.braynlabs.critter …`.
enum BoardLog {
    static func write(_ message: String) {
        let launch = DebugLaunch.current
        guard launch.boardLog else { return }
        let seconds = String(format: "%.1f", ProcessInfo.processInfo.systemUptime - launch.launchUptime)
        FileHandle.standardOutput.write(Data("board [\(seconds) s] \(message)\n".utf8))
    }
}
#endif
