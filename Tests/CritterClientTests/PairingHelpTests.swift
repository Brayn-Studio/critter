import CritterClient
import Testing

// Plan 1 backlog (plan 5 T3): what the pairing screen does while it waits, and says when the camera or the local
// network cannot be used.

/// Up to 120 s waiting for the Mac's 「允许」: the screen would lock first, and the pairing fail. It stays on while the
/// request is with the Mac and is given back as it was.
@Test func theScreenStaysOnWhileTheMacIsAskedAndIsGivenBack() {
    var hold = ScreenAwakeHold()
    #expect(!hold.isHolding)
    #expect(hold.hold(current: false) == true)
    #expect(hold.isHolding)
    // Asked again (the page drawn again): what was there before the first hold is what goes back.
    #expect(hold.hold(current: true) == true)
    #expect(hold.release() == false)
    #expect(!hold.isHolding)
    // Released twice (the page went, then the wait ended): nothing to give back the second time.
    #expect(hold.release() == nil)

    // It was already on (kept on by something else): it stays on afterwards.
    var kept = ScreenAwakeHold()
    _ = kept.hold(current: true)
    #expect(kept.release() == true)
}

/// The camera could not start scanning: said in the frame instead of a camera that reads nothing.
@Test func aScannerThatCannotStartSaysWhy() {
    #expect(ScannerTrouble.unsupported.text == "这台设备不能扫码，可以用系统相机扫，或者手动输入")
    #expect(ScannerTrouble.cameraRestricted.text == "Critter 不能用相机。在设置里允许它用相机，或者手动输入")
    #expect(ScannerTrouble.other.text == "相机没能打开，可以用系统相机扫，或者手动输入")
}

/// The local network is denied: said with 「去设置」, which opens the app's page in Settings.
@Test func aDeniedLocalNetworkIsSaidWithGoToSettings() {
    #expect(LocalNetworkDenial.line == "没有本地网络权限，连不上 Mac。在设置里打开 Critter 的「本地网络」。")
    #expect(LocalNetworkDenial.action == "去设置")
}
