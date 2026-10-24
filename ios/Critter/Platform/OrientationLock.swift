import SwiftUI
import UIKit

/// Which way the app may turn. Info.plist allows portrait and both landscapes; this narrows it at run time: portrait
/// everywhere, landscape while the board is open (Task 15 locks it when the board opens and unlocks it when it
/// closes). The app delegate hands `mask` to the system.
@MainActor @Observable
final class OrientationLock {
    static let shared = OrientationLock()

    private(set) var mask: UIInterfaceOrientationMask = .portrait

    /// Allows only `mask` from now on, and turns the screen to it if it is not already.
    func lock(_ mask: UIInterfaceOrientationMask) {
        guard mask != self.mask else { return }
        self.mask = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}

/// The app delegate SwiftUI keeps for the app (`@UIApplicationDelegateAdaptor`): only for the orientations.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask
    }
}
