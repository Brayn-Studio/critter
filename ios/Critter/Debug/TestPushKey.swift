#if DEBUG
import CritterKit
import Foundation
import os

/// `-critterTestPushKey <key>`: the push key becomes this one (base64url of 32 bytes), written into the shared keychain
/// where the app registers it and the notification service extension opens pushes with it -- so that the files of
/// `scripts/dev/push-payloads/make.sh`, sealed with its test key, open. Only ever a test key: the next registration
/// sends it to the Mac. Not a key: nothing is written.
enum TestPushKey {
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notifications")

    static func install(_ key: String) {
        guard PushCrypto.keyData(key) != nil else {
            log.error("-critterTestPushKey: not a push key (base64url of 32 bytes); nothing written")
            return
        }
        let status = SharedKeychain.push.write(Data(key.utf8), account: SharedKeychain.pushKeyAccount)
        log.notice("-critterTestPushKey: the test key is the push key now (keychain \(status))")
    }
}
#endif
