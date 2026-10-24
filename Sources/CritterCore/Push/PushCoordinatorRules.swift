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

    /// What the Mac's `result` to a registration says (spec 8.8): whether it can push to it now -- the setup works
    /// (`bundleId` is nil without one), APNs has not refused it, and the registration is for the app it names.
    public static func pushReady(_ registration: PushRegistration, bundleId: String?, blocked: Bool) -> Bool {
        !blocked && canPush(registration, bundleId: bundleId)
    }

    /// Whether a device's new registration starts its notifications over (the next snapshot only records):
    /// a device that just registered, or one whose pushes now go elsewhere -- another token, environment, app
    /// or key. New preferences or Live Activity tokens carry on.
    public static func startsOver(from old: PushRegistration?, to new: PushRegistration) -> Bool {
        guard let old else { return true }
        return old.token != new.token || old.environment != new.environment || old.bundleId != new.bundleId
            || old.key != new.key
    }

    /// The APNs tokens a registration holds: the device's, and its Live Activity's. Two devices must not share
    /// one (`DeviceRegistry.setPush`), or everything would be pushed twice.
    public static func tokens(of registration: PushRegistration) -> Set<String> {
        let all = [registration.token, registration.activity?.startToken, registration.activity?.activityToken]
        return Set(all.compactMap { $0 }.filter { !$0.isEmpty })
    }

    public static func prefs(_ registration: PushRegistration) -> PushPrefs {
        PushPrefs(notifyDone: registration.notifyDone, notifyError: registration.notifyError)
    }
}
