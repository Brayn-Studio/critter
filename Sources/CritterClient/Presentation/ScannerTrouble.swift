/// Why the camera did not start scanning (`DataScannerViewController.startScanning()` threw), and what the scanner's
/// frame says instead of showing a camera that reads nothing.
public enum ScannerTrouble: Equatable, Sendable {
    /// Scanning is not supported on this device.
    case unsupported
    /// The camera may not be used (denied, or restricted by Screen Time or a profile).
    case cameraRestricted
    /// Anything else.
    case other

    public var text: String {
        switch self {
        case .unsupported: "这台设备不能扫码，可以用系统相机扫，或者手动输入"
        case .cameraRestricted: "Critter 不能用相机。在设置里允许它用相机，或者手动输入"
        case .other: "相机没能打开，可以用系统相机扫，或者手动输入"
        }
    }
}
