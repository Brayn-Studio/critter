#if DEBUG
import Foundation

/// `-critterFakeDock`: a made-up charger and gravity sensor for the automatic opening (the simulator has neither, and
/// `simctl` cannot change them), handed to `BoardAutoOpen` in place of the phone's. `run` plays a fixed day on the
/// desk, in seconds after launch:
///
/// - 2: plugged in, lying still in landscape (the board opens about 3 s later);
/// - 20: standing upright (the board closes about 3 s later);
/// - 26: 「充电横放时自动打开」 switched off (gravity stops); 29: on again (it starts again);
/// - 32: unplugged (gravity stops).
///
/// `unplug`: plugged in and lying still in landscape at 2 s, unplugged at 10 s (the board closes 10 s later).
///
/// `hold-off`: plugged in and lying still in landscape at 2 s; 「充电横放时自动打开」 switched off at 4 s, during the
/// 3 s hold (nothing may be due any more: no tick at 5 s, nor after); unplugged at 9 s and the setting on again at
/// 9.5 s.
///
/// The fake sensor reads every 100 ms while it is started, in g like CoreMotion, so the readings take the same path
/// (and the same conversion to m/s²) as the real ones.
@MainActor
final class FakeDock {
    enum Script: Equatable, Sendable {
        case standard, unplug, holdOff
    }

    let power = FakePower()
    let gravity = FakeGravity()
    private let script: Script

    init(script: Script) {
        self.script = script
    }

    /// Gravity in g: lying on its long edge, and standing on its short one.
    private static let landscape = (x: -1.0, y: 0.0, z: 0.0)
    private static let upright = (x: 0.0, y: -1.0, z: 0.0)

    func run(settings: PhoneSettings) async {
        gravity.reading = Self.upright
        await at(2)
        gravity.reading = Self.landscape
        power.set(true)
        switch script {
        case .unplug:
            await at(10)
            power.set(false)
            return
        case .holdOff:
            await at(4)
            settings.boardAutoOpen = false
            await at(9)
            power.set(false)
            await at(9.5)
            settings.boardAutoOpen = true
            return
        case .standard:
            break
        }
        await at(20)
        gravity.reading = Self.upright
        await at(26)
        settings.boardAutoOpen = false
        await at(29)
        settings.boardAutoOpen = true
        await at(32)
        power.set(false)
    }

    /// Sleeps until `seconds` after launch.
    private func at(_ seconds: Double) async {
        let wait = seconds - (ProcessInfo.processInfo.systemUptime - DebugLaunch.current.launchUptime)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
}

@MainActor
final class FakePower: BoardPowerSource {
    private(set) var charging = false
    private var onChange: ((Bool) -> Void)?

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func set(_ charging: Bool) {
        guard charging != self.charging else { return }
        self.charging = charging
        onChange?(charging)
    }
}

@MainActor
final class FakeGravity: BoardGravitySource {
    var reading = (x: 0.0, y: -1.0, z: 0.0)
    private var task: Task<Void, Never>?

    func start(onReading: @escaping (_ x: Double, _ y: Double, _ z: Double) -> Void) -> Bool {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled, let self {
                onReading(reading.x, reading.y, reading.z)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return true
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
