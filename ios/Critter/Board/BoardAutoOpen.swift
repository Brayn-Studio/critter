import CoreMotion
import CritterClient
import CritterKit
import Foundation
import Observation
import UIKit

/// Opens the board by itself while the phone charges lying still in landscape, and closes it again (spec §8.6). The
/// decisions are `BoardTrigger`'s; this only feeds it the charger, the scene and gravity, and says what it decided
/// through `wantsBoard` (Android `BoardTriggerService`, without the foreground service iOS does not have).
///
/// All of it runs only while the scene is active, which stands for Android's "screen on": in the background, behind
/// Control Center or the app switcher, the trigger is told the screen is off. Gravity is read at 10 Hz and only while
/// the trigger wants it (charging, active, and the board up or allowed to open); it stops at once when the charger
/// goes, the app leaves the front or 「充电横放时自动打开」 is switched off. The trigger's deadlines are met with one
/// sleep each, not by polling.
@MainActor @Observable
final class BoardAutoOpen {
    /// Whether the board should be on screen: set when the trigger opens it and whenever a board comes up (opened by
    /// hand too), cleared when the trigger closes it, gives up on it, or the user closes it. `HomeView` follows it.
    private(set) var wantsBoard = false

    /// Why the trigger last closed the board, for the screen's restore.
    @ObservationIgnored private(set) var closeReason: BoardScreen.Exit = .upright

    @ObservationIgnored private let trigger = BoardTrigger()
    @ObservationIgnored private let power: any BoardPowerSource
    @ObservationIgnored private let gravity: any BoardGravitySource
    /// Whether the scene is active; nil until it is first told.
    @ObservationIgnored private var active: Bool?
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var scheduledAt: Int64?
    @ObservationIgnored private var lastPose: BoardTrigger.Pose?

    /// Standard gravity: CoreMotion reads in g, the trigger's thresholds are Android's m/s².
    private static let standardGravity = 9.80665

    init(power: any BoardPowerSource = DevicePower(), gravity: any BoardGravitySource = DeviceGravity()) {
        self.power = power
        self.gravity = gravity
    }

    /// The scene became active (`true`) or stopped being so.
    func sceneActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        let now = Self.now()
        if active {
            power.start { [weak self] charging in self?.powerChanged(charging) }
            boardLog("auto-open: scene active, \(power.charging ? "charging" : "not charging")")
            perform(trigger.onScreen(on: true, nowMs: now))
            perform(trigger.onPower(charging: power.charging, nowMs: now))
        } else {
            power.stop()
            boardLog("auto-open: scene not active")
            perform(trigger.onScreen(on: false, nowMs: now))
        }
        update()
    }

    /// A board came up (`true`, by hand or as asked) or went away.
    func boardShown(_ shown: Bool) {
        trigger.onBoardShown(shown)
        wantsBoard = shown
        boardLog("auto-open: board \(shown ? "shown" : "gone")")
        update()
    }

    /// The user closed the board: it stays closed until the charger is plugged in again.
    func manualExit() {
        trigger.onManualExit(nowMs: Self.now())
        wantsBoard = false
        boardLog("auto-open: closed by hand")
        update()
    }

    /// 「充电横放时自动打开」 changed.
    func setAutoOpen(_ on: Bool) {
        guard on != trigger.autoOpen else { return }
        trigger.autoOpen = on
        boardLog("auto-open: setting \(on ? "on" : "off")")
        update()
    }

    // MARK: - Feeding the trigger

    private func powerChanged(_ charging: Bool) {
        boardLog("auto-open: \(charging ? "charging" : "not charging")")
        perform(trigger.onPower(charging: charging, nowMs: Self.now()))
        update()
    }

    /// A reading in g.
    private func reading(x: Double, y: Double, z: Double) {
        let g = Self.standardGravity
        let pose = BoardTrigger.poseOf(gx: x * g, gy: y * g, gz: z * g)
        if pose != lastPose {
            lastPose = pose
            boardLog("auto-open: lying \(pose)")
        }
        perform(trigger.onGravity(x: x * g, y: y * g, z: z * g, nowMs: Self.now()))
        update()
    }

    private func perform(_ action: BoardTrigger.Action) {
        switch action {
        case .open:
            boardLog("auto-open: open the board")
            wantsBoard = true
        case .close:
            closeReason = power.charging ? .upright : .unplugged
            boardLog("auto-open: close the board (\(closeReason))")
            wantsBoard = false
        case .blocked:
            // The board did not come up within 2 s (no home screen to show it on): no more asking on this charge.
            boardLog("auto-open: the board did not come up; not again on this charge")
            wantsBoard = false
        case .none:
            break
        }
    }

    /// Gravity on or off, and the wake-up re-aimed, after anything the trigger was told.
    private func update() {
        let wanted = active == true && trigger.sensorWanted
        if wanted, !listening {
            listening = true
            lastPose = nil
            trigger.onSensorStarted()
            let started = gravity.start { [weak self] x, y, z in self?.reading(x: x, y: y, z: z) }
            boardLog("auto-open: gravity on\(started ? "" : " (this device has no sensor)")")
        } else if !wanted, listening {
            listening = false
            gravity.stop()
            boardLog("auto-open: gravity off")
        }
        reschedule()
    }

    /// One sleep until the trigger's next deadline, if it has one.
    private func reschedule() {
        let deadline = trigger.nextDeadline()
        guard deadline != scheduledAt else { return }
        tick?.cancel()
        tick = nil
        scheduledAt = deadline
        guard let deadline else { return }
        let wait = max(deadline - Self.now(), 0)
        tick = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self else { return }
            scheduledAt = nil
            perform(trigger.onTick(nowMs: Self.now()))
            update()
        }
    }

    /// The trigger's monotonic clock, in milliseconds.
    private static func now() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }
}

// MARK: - Where the readings come from

/// The charger: whether it is plugged in, and changes while started.
@MainActor
protocol BoardPowerSource: AnyObject {
    var charging: Bool { get }
    func start(onChange: @escaping (Bool) -> Void)
    func stop()
}

/// Gravity, in g like CoreMotion's, about 10 times a second while started. `start` says whether there is a sensor.
@MainActor
protocol BoardGravitySource: AnyObject {
    func start(onReading: @escaping (_ x: Double, _ y: Double, _ z: Double) -> Void) -> Bool
    func stop()
}

/// The phone's battery: charging or full counts as plugged in.
@MainActor
final class DevicePower: BoardPowerSource {
    private var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?

    var charging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        default: false
        }
    }

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(self.charging)
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onChange = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }
}

/// CoreMotion's gravity (device motion), 10 times a second.
@MainActor
final class DeviceGravity: BoardGravitySource {
    private let manager = CMMotionManager()

    func start(onReading: @escaping (_ x: Double, _ y: Double, _ z: Double) -> Void) -> Bool {
        guard manager.isDeviceMotionAvailable else { return false }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated { onReading(gravity.x, gravity.y, gravity.z) }
        }
        return true
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
