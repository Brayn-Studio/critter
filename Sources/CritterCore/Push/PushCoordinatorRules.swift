import Foundation

/// The decisions the Mac's push coordinator makes without a queue, a clock or the network (spec 6.4).
public enum PushCoordinatorRules {
    /// Whether `BridgeController.changed()` assembles a snapshot at all: for a connected phone, as before, or
    /// for push. With neither, nothing runs: no snapshot, no timer, no request.
    public static func shouldAssemble(hasReadyClients: Bool, pushActive: Bool) -> Bool {
        hasReadyClients || pushActive
    }

    /// Push works only when all three hold: phones may connect (the bridge is on), the APNs setup works (and
    /// APNs has not refused it), and at least one iPhone registered for this app.
    public static func isActive(bridgeOn: Bool, configReady: Bool, blocked: Bool, reachableDevices: Int) -> Bool {
        bridgeOn && configReady && !blocked && reachableDevices > 0
    }

    /// Whether the Mac can push to a device with this registration: it has one, and it is for the app the
    /// settings name (a push to another app's token would be refused, and the registration dropped).
    public static func canPush(_ registration: PushRegistration?, bundleId: String?) -> Bool {
        guard let registration, !registration.isEmpty, let bundleId else { return false }
        return registration.bundleId == bundleId
    }

    /// Whether a device's new registration starts its notifications over (the next snapshot only records):
    /// a device that just registered, or one whose pushes now go elsewhere -- another token, environment, app
    /// or key. New preferences or Live Activity tokens carry on.
    public static func startsOver(from old: PushRegistration?, to new: PushRegistration) -> Bool {
        guard let old else { return true }
        return old.token != new.token || old.environment != new.environment || old.bundleId != new.bundleId
            || old.key != new.key
    }

    public static func prefs(_ registration: PushRegistration) -> PushPrefs {
        PushPrefs(notifyDone: registration.notifyDone, notifyError: registration.notifyError)
    }
}
