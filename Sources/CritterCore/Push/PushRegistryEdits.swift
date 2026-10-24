import Foundation

/// The part of the device registry push writes to: `DeviceRegistry`, or a stand-in in tests. Each call says
/// whether the file holds the change now; false when it could not be written.
public protocol PushRegistryWriting: AnyObject {
    @discardableResult func setActivity(deviceId: String, activityId: String?, activityToken: String?) -> Bool
    @discardableResult func setUnconfirmedActivityStart(deviceId: String, at time: Int64?) -> Bool
    @discardableResult func dropPushToken(deviceId: String) -> Bool
}

extension DeviceRegistry: PushRegistryWriting {}

/// Keeps what the fan-out asks for (`PushFanout.takeRegistryEdits()`) in `devices.json`.
public enum PushRegistryEdits {
    /// Makes `edits` in `registry`, then calls `changed` (once) for the caller to read the device list again and hand
    /// it to `PushFanout.sync` -- but only when an edit was written.
    ///
    /// An edit that cannot be written is logged and dropped, not asked for again. Reading the list after a failed
    /// write would bring back what the file still says, the fan-out would ask for the same edit, that write would
    /// fail and read the list again: `PushCoordinator` -> `BridgeController.refreshDevices` -> `PushFanout.sync`
    /// without end. The next change of the list (from anywhere else) asks again, once.
    public static func keep(
        _ edits: [RegistryEdit], in registry: any PushRegistryWriting, log: (String) -> Void, changed: () -> Void
    ) {
        var written = false
        for edit in edits {
            let kept: Bool
            switch edit {
            case .clearActivity(let deviceId):
                kept = registry.setActivity(deviceId: deviceId, activityId: nil, activityToken: nil)
            case .unconfirmedActivityStart(let deviceId, let time):
                kept = registry.setUnconfirmedActivityStart(deviceId: deviceId, at: time)
            }
            if kept {
                written = true
            } else {
                log("push: could not keep \(edit.what) for device \(edit.deviceId.prefix(8)) in the devices file; dropped")
            }
        }
        if written { changed() }
    }
}

private extension RegistryEdit {
    /// What the edit keeps, for the log: nothing from a token.
    var what: String {
        switch self {
        case .clearActivity: "the end of its Live Activity"
        case .unconfirmedActivityStart(_, let time): time == nil ? "the release of its Live Activity start" : "its Live Activity start"
        }
    }
}
