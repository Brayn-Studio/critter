#if DEBUG
import Foundation

/// "<topic> [12.3 s] <what>" on standard output, the time counted from launch, like `BoardLog`: what the pairing
/// screen does under a `-critterPairing` demo, and the settings page's edge swipe under `-critterNavLog`. Read it with
/// `xcrun simctl launch --console-pty <device> com.braynlabs.critter …`.
enum TraceLog {
    static func pairing(_ message: String) {
        if DebugLaunch.current.pairing != nil { write("pairing", message) }
    }

    static func nav(_ message: String) {
        if DebugLaunch.current.navLog { write("nav", message) }
    }

    private static func write(_ topic: String, _ message: String) {
        let seconds = String(format: "%.1f", ProcessInfo.processInfo.systemUptime - DebugLaunch.current.launchUptime)
        FileHandle.standardOutput.write(Data("\(topic) [\(seconds) s] \(message)\n".utf8))
    }
}
#endif
