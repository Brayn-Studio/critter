#if DEBUG
import CritterClient
import CritterKit
import Foundation
import os
import UserNotifications

/// The launch arguments of DEBUG builds, for screenshots and scripts (`xcrun simctl launch booted
/// com.braynlabs.critter -critterFixture home-mixed`). None of this is in a release build.
///
/// - `-critterFixture <name>`: `Debug/Fixtures/<name>.json` (a `SnapshotBody`). The app then runs on a fake
///   storage and a fake link: paired with "Fixture Mac", and the link sends `connected` and this snapshot as soon as
///   it starts. The fixtures are written as of `fixtureNow` and moved to the launch time, so ages, quota resets and
///   expiries read as written.
/// - `-critterFixtureOffline`: with `-critterFixture`, the phone is offline: the fixture is the snapshot cached five
///   minutes ago, and the fake link never connects (it says it is offline and sends nothing), as when the Mac is
///   out of reach (`offline-idle`, the home screen's offline look).
/// - `-critterFixtureResult ok|resolved|expired|failed`: the fake link's reply to every request (default `ok`).
/// - `-critterOpen answer:<requestId>|detail:<sessionId>|settings`: opens that sheet once launched.
/// - `-critterAutoSubmit allow|approve|first-option`: one second after an answer card is up, does what its primary
///   button does: allows a permission request, approves a plan, or chooses the first option of every question.
///   Together with `-critterFixtureResult` this shows how the card takes each kind of receipt.
/// - `-critterAutoPick first-option`: one second after a question card is up, chooses the first option of its first
///   question, without sending (once per run).
/// - `-critterReopen`: with `-critterOpen answer:…`, closes that card 3.5 s after it was opened and opens it again 1.5 s
///   later, to see what a reopened card shows (it must be what the draft holds).
/// - `-critterPairURI <uri>`: pairs with this URI once launched, without asking (for scripts).
/// - `-critterDeviceName <name>`: the device name pairing sends.
/// - `-critterOpenURL <url>`: once launched, the app opens this URL itself, so it comes back in through the
///   system like a link opened from outside (`xcrun simctl openurl` stops at the system's "在“Critter”中打开?").
/// - `-critterGallery`: instead of the app, a page of every pixel widget in its states, the fonts, every pixel icon
///   and the wordmark (`Gallery.swift`), to put next to the mockups.
/// - `-critterGalleryAt critters|skies|meadow|parts|more|fonts|icons|logo`: with `-critterGallery`, opens the page scrolled
///   to that part. The gallery starts with the seven bundled skins on a strip of meadow (touch them: press, lift
///   and carry, rub) and still portraits of each state, then the meadow's four skies (`skies`), each on a patch of
///   meadow with a Critter, as the mockups' "天空跟着时间走" draws them, and the home meadow with seven sessions on
///   the clock's sky (`meadow`).
/// - `-critterAllAsleep`: the gallery's Critters are all idle and asleep (`sleepNow`), for the frame count.
/// - `-critterPressCheck`: with `-critterGallery`, a second after it opens a `PressedLook` is pressed for 20 ms and
///   then for 200 ms, and standard output says when it showed down and up (`PressCheck.swift`).
/// - `-critterGalleryHold`: a second after the gallery opens, its sprig is held up as if lifted by a finger (its
///   shadow shows on the ground under it).
/// - `-critterFrameLog`: every 10 seconds, "frames <n> (board <b>, home <h>)" on standard output: how many ticks
///   changed the picture on any Critter stage, and the same for each screen (`critterFrameTag`: the home screen with its
///   sheets, the board; "other" for the rest), so `-critterBoard` shows the home screen drawing nothing under the board
///   (`FrameLog`). Read it with `xcrun simctl launch --console-pty <device> com.braynlabs.critter …`.
/// - Reduce motion has no flag: it is the app's own switch, `critter.settings.reduceMotion` in the app container's
///   preferences. From the command line: terminate the app, then `xcrun simctl spawn <device> defaults write
///   "$(xcrun simctl get_app_container <device> com.braynlabs.critter data)/Library/Preferences/com.braynlabs.critter"
///   critter.settings.reduceMotion -bool YES` (with just the bundle id it writes another file, which the app never
///   reads). The system's own setting cannot be changed with `simctl`.
/// - `-critterSayDraft <text>`: the details sheet's 「发一句」 field starts with this text, through the same limit as
///   typing (past 4000 it is cut and the sheet says so). With `-critterAutoSay`, it is sent a second later, as if
///   the send button was tapped (the letter flies; `-critterFixtureResult` decides the receipt).
/// - `-critterSheetMaxHeight <pt>`: every sheet is at most this tall, as if the keyboard had taken the rest of the
///   screen: what does not fit scrolls in the sheet (the command line cannot raise the keyboard).
/// - `-critterPlanRevise`: a plan's card opens with the field for what to change, as after 「让它改…」.
/// - `-critterSkyHour <0-23>`: every meadow's sky is drawn as at this hour of the day (`SkyClock`), whatever the
///   clock says (the dark appearance is still night).
/// - `-critterPairing <demo>`: the pairing screen in one of its states, on fakes (`PairingDemo.swift`): the pairer
///   never touches the network, the Macs found and their certificates are made up ("MacBook Pro" and "Mac mini" on
///   192.168.1.x). Without `-critterFixture` the app starts unpaired; with it, paired with "Fixture Mac", so the
///   pairing screen comes over the home screen (「返回」 on the scanner, the replacement warning in the confirmation).
///   - `scan`: the scanner (the simulator has no camera: the frame says so).
///   - `manual`: 「手动输入」 tapped a second after launch; two Macs found, the first chosen, the code typed.
///     `manual-searching`: none found yet. `manual-trust`: then 「连接」 tapped, the trust dialog asks.
///     `manual-probe-failed`: 「连接」 tapped and the Mac could not be reached (the note on the page).
///   - `confirm`: a link from outside, waiting in its confirmation.
///   - `connecting`, `awaiting`: an attempt from a link, reaching the Mac or waiting there for 「允许」, until 「取消」.
///   - `failed:<reason>[@<seconds>]`: the attempt fails (`badCode`, `rejected`, `protocol`, `cert`, `noAnswer`,
///     `unreachable`), at once or after waiting that long at the Mac. With `-critterOpenURL <a critter-pair:// link>`
///     the link comes in during the wait (queued, then confirmed on the failure page) or, at once, on the failure
///     page (a link to a host off the local network shows its note there).
///   - `paired@<seconds>`: the Mac says yes after that long (a link that came meanwhile is dropped), as a new device
///     (`demo-paired`): with `-critterFixture` and `-critterNotificationAction <id>:open@<seconds>` before it, a target
///     tapped while pairing again is dropped once the new pairing is made, and the log shows the fixture Mac taking the
///     empty token first.
///   - `scan-race`: 1.5 s after the scanner is up the camera "reads" a pairing code, and 100 ms into the green flash
///     「返回」 is tapped (「手动输入」 when unpaired); a second later the log says whether anything is pairing.
///     `scan-read`: the same read with nothing tapped, so the flash ends in an attempt (the control).
///   With any demo, standard output gets "pairing [t s] …" lines (`TraceLog`): pair() starting an attempt, the scan
///   flash cancelled, and `scan-race`'s steps.
/// - `-critterPickSkin <skin>|follow`: with `-critterOpen settings`, a second after the settings are up, that skin's
///   tile is tapped ("follow" is 「跟着电脑」), and 1.5 s later the settings go back to the home screen. The choice is
///   saved like a real tap: `-critterPickSkin follow` undoes it.
/// - `-critterSettingsAt skins|board|motion`: with `-critterOpen settings`, the settings open scrolled to that group.
/// - `-critterNavLog`: standard output gets "nav [t s] …" lines (`TraceLog`) when the settings page takes over the
///   left-edge swipe back and when it gives it back (`EdgeSwipeBack`), with what UIKit's own delegate would have said.
/// - `-critterBoard critter|pro`: once launched, the board opens in that mode, as if 「打开看板」 had been tapped
///   (the mode is saved like the board's own switch). With `-critterOpen answer:<requestId>` the answer card opens on
///   the board (landscape) rather than on the home screen. Fixtures: `board` (six sessions, one waiting) and `many`.
/// - `-critterBoardScript <action>@<seconds>,…`: with `-critterBoard`, closes and opens the board at those times
///   after launch (`close@4,open@6,close@30`), through the same calls as its close button and 「打开看板」.
/// - `-critterBoardAnswer allow|deny`: with `-critterBoard`, half a second after the snapshot is in, the first lone
///   permission request is answered through its pro card's 「允许」 or 「拒绝」 path and its answer card is opened at
///   once over the board (the card must say "已提交" once the Mac has taken the answer).
/// - `-critterBoardLog`: standard output gets "board [t s] …" lines (`BoardLog`): the screen saved on the way in,
///   every brightness set, every way out with what it restored, the sounds, and the automatic opening's steps.
/// - `-critterBoardDimAfter <seconds>`: the board dims after this long without a touch or a change, not 15 minutes.
/// - `-critterFixtureStep <sessionId>:<state>@<seconds>`: with `-critterFixture`, that long after connecting the
///   fixture Mac puts that session in that state and sends the snapshot (a sound on the board, a state change).
/// - `-critterFakeDock`: the automatic opening reads a made-up charger and gravity sensor instead of the phone's
///   (the simulator has neither): 2 s after launch it is plugged in and lying still in landscape; at 20 s it stands
///   upright; at 26 s the setting 「充电横放时自动打开」 is switched off and at 29 s on again; at 32 s it is
///   unplugged. The fake sensor gives a reading every 100 ms while it is on, in g like CoreMotion, through the same
///   path as the real one. With `-critterBoardLog`. `-critterFakeDock unplug` plays a shorter one instead: plugged
///   in and lying still in landscape at 2 s, unplugged at 10 s (the board closes 10 s later). `-critterFakeDock
///   hold-off`: plugged in and landscape at 2 s, the setting switched off at 4 s during the hold (no tick may follow),
///   unplugged at 9 s and the setting on again at 9.5 s. `-critterFakeDock card` (with the `board` fixture): an
///   automatic close waits for an answer card open over the board: the card opens at 7 s, unplugged at 9 s (held),
///   plugged in again in landscape at 22 s, the card closes at 24 s (the board stays), opens again at 26 s, unplugged at
///   28 s (held), and the card closes at 41 s, the board with it (`FakeDock.swift`). With `-critterOpen answer:<id>`
///   too, that card is open on the home screen when the board opens by itself, and goes first.
/// - `-critterSharedCheck`: whether the App Group and the shared keychain group work as the entitlements have them, with
///   nothing registered. Once launched, the app writes markers to both, reads back what the extensions wrote there, and
///   starts a Live Activity for 5 s whose drawing makes the widget extension read the app's markers and write its own;
///   a push with `"critterSharedCheck": 1` and `mutable-content` makes the notification service extension do the same
///   (`SharedCheck.swift` in each target; `xcrun simctl push` does not wake that extension in the simulator). The log
///   says what each side found: `xcrun simctl spawn <device> log show --last 2m --predicate 'subsystem ==
///   "com.braynlabs.critter" AND category == "sharedcheck"'`.
/// - `-critterTestPushKey <key>` (simulator builds only): the push key (base64url of 32 bytes) becomes this test key,
///   in the shared keychain where the notification service extension reads it (`TestPushKey.swift`), so that the
///   pushes of `scripts/dev/push-payloads/make.sh` (sealed with its test key, which it prints) open. Then `xcrun simctl
///   push <device> com.braynlabs.critter ios/build/push-payloads/<file>.apns`. In this simulator `simctl push` posts
///   the push as a local notification and the extension never runs, so what shows is the plain "Critter / 有会话需要你"
///   with the push's own category: a permission request's is the open-only one (only 「打开」), which the extension
///   would switch to its real buttons once the text opened (tested in `PushOpeningTests`); use
///   `-critterNotificationAction` for those buttons. For this run only: a launch without it finds the public test
///   key and replaces it (`PushSetup`, log "the stored push key is the public test key").
/// - `-critterNotificationAction <id>:<allow|deny|open|reason:<text>>[@<seconds>]`: that long after launch (default
///   1.5 s), the notification with this id (a request id, or `done:<session id>` and the like) is answered or tapped
///   through the same handler as a tap on it (`NotificationActionDebug`): `allow`, `deny` and `reason:…` are its buttons
///   (answered in the background over a connection of their own, the result put in its place), `open` is a tap on the
///   notification itself (the app opens the request's card or the session's details). The delivered one is used (from
///   `simctl push`); without it, one is made up from the snapshot. The log (category `notifications`) lists the
///   delivered notifications before and after. With `-critterFixture` the background answer reaches the fixture Mac
///   (`FixtureTransport`): it answers as `-critterFixtureResult` says, and a taken answer leaves the snapshot.
/// - `-critterFixtureMacAway`: with `-critterFixture`, a background answer cannot reach the fixture Mac (no connection
///   can be made): the notification says "没送到…" and keeps its buttons.
/// - `-critterFixtureMacSilent`: with `-critterFixture`, the fixture Mac takes a background answer's connection and never
///   says `welcome` (asleep, or another network in between): the answer waits up to its 20 s.
/// - `-critterAnswerExpiry <seconds>`: that long after an answer from a notification's button starts, its background
///   time runs out as if the system said so (`BackgroundTask.expire`, the path of the system's expiration handler):
///   "没送到…" is posted at once with the buttons, and the cut-short answer adds nothing. With
///   `-critterFixtureMacSilent` the answer is still waiting then.
/// - `-critterWithdrawPush <id>[,<id>…][@<seconds>]`: that long after launch (default 3 s), the Mac's withdrawal of
///   these notifications goes through the app's handler for background pushes (`WithdrawPushDebug`): `xcrun simctl
///   push` turns a background push into a background fetch without its payload. The log lists the delivered
///   notifications before and after.
/// - `-critterActivityDemo many|waiting|idle|stale`: the Live Activity with made-up content (`ActivityDemo.swift`), no Mac
///   needed: once launched the app ends any running one and starts one showing six sessions (one waiting, `many`), two
///   waiting with the 5-hour limit nearly used (`waiting`), three idle (`idle`), or `many` with a stale date three
///   seconds after the start (`stale`: the system greys it, with "可能不是最新的", about two minutes later at the
///   earliest, and `stale` sends no alert update). Instead of the home screen the app shows the lock screen's block
///   as the widget draws it (light or dark as the system is, StandBy's look, stale): the simulator's lock screen cannot be
///   reached from the command line. Put another app in front (`xcrun simctl launch <device> com.apple.Preferences`) for
///   the Dynamic Island's compact view; three seconds later the app updates the activity once with an alert, which opens
///   the island to its expanded view for a few seconds. `xcrun simctl io screenshot` catches the island only while the
///   screen is changing: `xcrun simctl io <device> recordVideo` gets it every time. The app's own Live Activity rules (`LiveActivityManager`) stay
///   out of the way. The log (category `activity`) also has a decode check: the protocol doc's push-to-start
///   `attributes` (`{}`) as `CritterActivity`, and its start and end `content-state` as its `ContentState`.
/// - `-critterLiveActivitySwitch <on|off>@<seconds>[,…]`: at those times after launch the settings' Live Activity switch
///   is set as a tap on 「显示实时活动」 would set it (`off@8,on@14`; it is saved like a tap: end with `on` to leave it
///   on). With `-critterFixture` this shows the app's own activity (`LiveActivityManager`): started
///   in front once connected, updated with each new snapshot, ended at once when switched off. The log (category
///   `activity`) says what it did and which tokens the system gave; the registration's line (category `notifications`)
///   which of them go to the Mac.
/// - `-critterActivityScript <dup|endNamed|hold|follow>@<seconds>[,…]`: at those times after launch another activity
///   comes up next to the app's own, as the Mac's push-to-start would bring one (`dup`), the registered activity ends as
///   if dismissed (`endNamed`), or the app's own rules stand aside as in the background (`hold`) and come back
///   (`follow`); the app keeps running in the background meanwhile (`ActivityScript.swift`). With `-critterFixture`: in
///   front the extra one is ended at once (the registered one, else the app's own, is kept); held, it is left, and when
///   the registered one ends it is registered in its place; a token for an activity no longer running is ignored, and
///   what followed an ended activity is stopped ("stopped watching", category `activity`).
/// - `-critterFixturePush stored|unready|silent|refused`: with `-critterFixture`, how the fixture Mac answers the push
///   registration (default `stored`: "已登记"): `unready` "已登记；这台 Mac 还没配置推送", `silent` never (a Mac too old
///   for the frame: "这台 Mac 上的 Critter 版本太旧，收不到推送"), `refused` "保存失败". With `-critterFixtureOffline`
///   nothing is registered ("还没登记（要连上 Mac）"). The settings' 推送 group shows the line (`-critterOpen settings
///   -critterSettingsAt push`).
/// - `-critterNotificationPermission denied|ask|granted|provisional`: the app reads this as the system's notification
///   permission, whatever the system says (the registration follows it too): `denied` puts "通知被关掉了，去系统设置打开"
///   with 「去打开」 in the settings, `ask` (never asked) 「允许通知」.
/// - `-critterLeftMac <name>`: the line about a Mac this phone left that may still push here (saved like the real one,
///   until 「知道了」), as after pairing again away from an unreachable Mac (`BridgeStore`'s `onUntoldMac`) with the push
///   key changed: in the settings' 推送 group, and on every page of the pairing screen (`-critterPairing scan`,
///   `manual`, `awaiting`, `failed:<reason>`; also the guide's pairing step: `-critterOnboarding pair -critterPairing
///   scan`). `-critterLeftMacKeyKept`: as when the new key could not be
///   written (the line does not say the notifications show only "有会话需要你").
/// - `-critterLocalNetworkDenied`: the app takes the local network as denied (the simulator never asks for the 本地网络
///   permission): the home screen's offline card, the manual entry and an unreachable pairing's failure page say so
///   with 「去设置」 (`LocalNetworkDenial.line`), for the whole run: the simulator's Bonjour browser is always let browse
///   and would take a real denial back at once (`LocalNetworkStatus`).
/// - `-critterScannerForce`: the scanner page starts the camera even where scanning is not supported (the simulator):
///   `startScanning()` throws, and the frame says why (`ScannerTrouble`) instead of a camera that reads nothing.
/// - `-critterFixtureDrop offline|denied@<seconds>`: with `-critterFixture`, that long after its first connection the
///   fixture Mac drops it: `offline`, out of reach (the link says offline and stays so); `denied`, it turns this phone's
///   token away (`denied badToken`, "这台手机已不在电脑的配对列表里，请重新配对"), as after it revoked this phone. Its
///   registration was stored first (`-critterFixturePush`). Unpairing (`-critterUnpair`) or pairing again
///   (`-critterPairing paired@<seconds>`) afterwards: after `offline` the fixture Mac is left untold (the push key
///   changes, the Live Activities end, the line shows: log category `notifications` "a Mac that may still push here was
///   left"); after `denied` it holds nothing, and nothing is said. The fixture store reports a Mac left untold to the
///   app as the real one does.
/// - `-critterSystemBlocksActivities`: the app reads the system's Live Activity setting for it as off: the settings'
///   实时活动 group says so with 「去打开」.
/// - `-critterSettingsAt` also takes `push`, `activity` and `alerts`.
/// - `-critterUnpair <seconds>[:dialog]`: with `-critterOpen settings`, that long after the settings are up 「取消配对」
///   is tapped (its dialog shows), and a second later the dialog's 「取消配对」: the store unpairs as from a real tap,
///   taking the push registration back from the Mac over the connection first. For the live check against a real Mac
///   (`-critterPairURI`); the device stays listed on the Mac until it is revoked there. `:dialog`: the dialog stays up
///   (with `-critterFixtureDrop offline@…` before it, it says up front that the Mac cannot be told).
/// - `-critterOnboarding <step>[:<state>]`: the app starts in the first-run guide at that step (`welcome`, `pair`,
///   `notifications`, `liveActivity`, `board`), paired or not, whatever `critter.settings.onboardingDone` says. Finishing
///   it saves `onboardingDone` like a real run. The pairing step is the real pairing screen: unpaired with
///   `-critterPairing <demo>` (its fakes, e.g. `scan`, `awaiting`, `failed:badCode`) it shows that page with the seeds;
///   paired (`-critterFixture`) it says "已配对". A state shows a step as it would be otherwise:
///   `notifications:ask|denied|granted` (the permission the step shows, whatever the system says), `liveActivity:off`
///   (as with the switch off, without changing it), `board:back` (back from Shortcuts: 「完成引导」).
struct DebugLaunch {
    enum AutoSubmit: Equatable {
        case allow
        case approve
        case firstOption
    }

    enum AutoPick: Equatable {
        case firstOption
    }

    enum Open: Equatable {
        case answer(requestId: String)
        case detail(sessionId: String)
        case settings
    }

    /// One step of `-critterBoardScript`.
    struct BoardStep: Equatable {
        enum Action: Equatable {
            case open, close
        }

        var action: Action
        var at: Double
    }

    /// `-critterFixtureDrop`.
    struct FixtureDrop: Equatable {
        enum Kind: String {
            case offline, denied
        }

        var kind: Kind
        var at: Double
    }

    /// `-critterFixtureStep`.
    struct FixtureStep: Equatable {
        var sessionId: String
        var state: PetState
        var at: Double
    }

    var fixture: String?
    var fixtureResult = CommandResult(ok: true, reason: nil, message: nil)
    var fixtureOffline = false
    var open: Open?
    var autoSubmit: AutoSubmit?
    var autoPick: AutoPick?
    var reopen = false
    var pairURI: URL?
    var deviceName: String?
    var openURL: URL?
    var gallery = false
    var galleryAt: String?
    var allAsleep = false
    var galleryHold = false
    var pressCheck = false
    var frameLog = false
    var skyHour: Int?
    var sayDraft: String?
    var autoSay = false
    var sheetMaxHeight: CGFloat?
    var planRevise = false
    var pairing: PairingDemo?
    /// `-critterPickSkin`: a bundled skin's name, or nil for 「跟着电脑」 ("follow"); unset when not asked for.
    var pickSkin: String??
    var settingsAt: String?
    var navLog = false
    /// `-critterBoard`: true for the Critter mode, false for the pro board; nil when not asked for.
    var board: Bool?
    var boardScript: [BoardStep] = []
    var boardLog = false
    /// `-critterBoardAnswer`: true for 「允许」, false for 「拒绝」; nil when not asked for.
    var boardAnswer: Bool?
    var boardDimAfter: TimeInterval?
    var fixtureStep: FixtureStep?
    /// `-critterFakeDock`: which day on the desk the fake charger and sensor play; nil without it.
    var fakeDock: FakeDock.Script?
    var sharedCheck = false
    /// `-critterTestPushKey`.
    var testPushKey: String?
    /// `-critterNotificationAction`.
    var notificationAction: NotificationActionDebug.Step?
    var fixtureMacAway = false
    var fixtureMacSilent = false
    /// `-critterAnswerExpiry`.
    var answerExpiry: Double?
    /// `-critterWithdrawPush`.
    var withdrawPush: WithdrawPushDebug.Step?
    /// `-critterActivityDemo`.
    var activityDemo: ActivityDemo.Kind?
    /// `-critterLiveActivitySwitch`: the switch's value and when, in seconds after launch.
    var liveActivitySwitch: [(on: Bool, at: Double)] = []
    /// `-critterActivityScript`.
    var activityScript: [ActivityScript.Step] = []
    /// `-critterOnboarding`.
    var onboarding: OnboardingDemo?
    /// `-critterFixturePush`: the fixture Mac's answer to a registration with a token.
    var fixturePush: PushRegistrationReply = .stored(PushRegistrar.registeredLine)
    /// `-critterNotificationPermission`.
    var notificationPermission: UNAuthorizationStatus?
    /// `-critterLeftMac`.
    var leftMac: String?
    var leftMacKeyKept = false
    /// `-critterLocalNetworkDenied`.
    var localNetworkDenied = false
    /// `-critterScannerForce`.
    var scannerForce = false
    /// `-critterFixtureDrop`.
    var fixtureDrop: FixtureDrop?
    /// `-critterUnpair`: seconds after the settings are up.
    var unpairAfter: Double?
    /// `-critterUnpair <seconds>:dialog`: the dialog is left up.
    var unpairDialogOnly = false
    var systemBlocksActivities = false
    /// When the process started, on the system's uptime clock (the board log counts from here).
    let launchUptime = ProcessInfo.processInfo.systemUptime

    static let current = DebugLaunch(arguments: ProcessInfo.processInfo.arguments)

    /// Whether `-critterAutoPick` has done its pick in this run: it picks once, so a card that is opened again shows
    /// only what the app kept.
    @MainActor static var autoPickDone = false

    /// The moment the fixtures are written as of: 2025-10-09 08:53:20 UTC, in milliseconds.
    static let fixtureNow: Int64 = 1_760_000_000_000
    static let fixtureMacName = "Fixture Mac"

    init(arguments: [String]) {
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: "-" + name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        fixture = value("critterFixture")
        fixtureOffline = arguments.contains("-critterFixtureOffline")
        switch value("critterFixtureResult") {
        case "resolved": fixtureResult = CommandResult(ok: false, reason: .resolved, message: "已在电脑上处理")
        case "expired": fixtureResult = CommandResult(ok: false, reason: .expired, message: "这个请求已经过期了")
        case "failed": fixtureResult = CommandResult(ok: false, reason: .failed, message: "提交失败")
        default: break
        }
        if let open = value("critterOpen") {
            if open == "settings" {
                self.open = .settings
            } else if open.hasPrefix("answer:") {
                self.open = .answer(requestId: String(open.dropFirst("answer:".count)))
            } else if open.hasPrefix("detail:") {
                self.open = .detail(sessionId: String(open.dropFirst("detail:".count)))
            }
        }
        switch value("critterAutoSubmit") {
        case "allow": autoSubmit = .allow
        case "approve": autoSubmit = .approve
        case "first-option": autoSubmit = .firstOption
        default: break
        }
        if value("critterAutoPick") == "first-option" { autoPick = .firstOption }
        reopen = arguments.contains("-critterReopen")
        pairURI = value("critterPairURI").flatMap(URL.init(string:))
        deviceName = value("critterDeviceName")
        openURL = value("critterOpenURL").flatMap(URL.init(string:))
        gallery = arguments.contains("-critterGallery")
        galleryAt = value("critterGalleryAt")
        allAsleep = arguments.contains("-critterAllAsleep")
        galleryHold = arguments.contains("-critterGalleryHold")
        pressCheck = arguments.contains("-critterPressCheck")
        frameLog = arguments.contains("-critterFrameLog")
        sayDraft = value("critterSayDraft")
        autoSay = arguments.contains("-critterAutoSay")
        sheetMaxHeight = value("critterSheetMaxHeight").flatMap(Double.init).map { CGFloat($0) }
        planRevise = arguments.contains("-critterPlanRevise")
        skyHour = value("critterSkyHour").flatMap(Int.init).flatMap { (0...23).contains($0) ? $0 : nil }
        pairing = value("critterPairing").flatMap(PairingDemo.init(argument:))
        if let pick = value("critterPickSkin") { pickSkin = .some(pick == "follow" ? nil : pick) }
        settingsAt = value("critterSettingsAt")
        navLog = arguments.contains("-critterNavLog")
        switch value("critterBoard") {
        case "critter": board = true
        case "pro": board = false
        default: break
        }
        boardScript = (value("critterBoardScript") ?? "").split(separator: ",").compactMap { step in
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]) else { return nil }
            switch parts[0] {
            case "open": return BoardStep(action: .open, at: at)
            case "close": return BoardStep(action: .close, at: at)
            default: return nil
            }
        }
        boardLog = arguments.contains("-critterBoardLog")
        switch value("critterBoardAnswer") {
        case "allow": boardAnswer = true
        case "deny": boardAnswer = false
        default: break
        }
        boardDimAfter = value("critterBoardDimAfter").flatMap(Double.init)
        if let step = value("critterFixtureStep") {
            let parts = step.split(separator: "@")
            let target = parts.first?.split(separator: ":") ?? []
            if parts.count == 2, target.count == 2, let at = Double(parts[1]),
               let state = PetState(rawValue: String(target[1])) {
                fixtureStep = FixtureStep(sessionId: String(target[0]), state: state, at: at)
            }
        }
        sharedCheck = arguments.contains("-critterSharedCheck")
        testPushKey = value("critterTestPushKey")
        notificationAction = value("critterNotificationAction").flatMap(NotificationActionDebug.Step.init)
        fixtureMacAway = arguments.contains("-critterFixtureMacAway")
        fixtureMacSilent = arguments.contains("-critterFixtureMacSilent")
        answerExpiry = value("critterAnswerExpiry").flatMap(Double.init)
        withdrawPush = value("critterWithdrawPush").flatMap(WithdrawPushDebug.Step.init)
        activityDemo = value("critterActivityDemo").flatMap(ActivityDemo.Kind.init(rawValue:))
        activityScript = ActivityScript.steps(value("critterActivityScript") ?? "")
        liveActivitySwitch = (value("critterLiveActivitySwitch") ?? "").split(separator: ",").compactMap { step in
            let parts = step.split(separator: "@")
            guard parts.count == 2, let at = Double(parts[1]), parts[0] == "on" || parts[0] == "off" else { return nil }
            return (on: parts[0] == "on", at: at)
        }
        onboarding = value("critterOnboarding").flatMap(OnboardingDemo.init(argument:))
        switch value("critterFixturePush") {
        case "unready": fixturePush = .stored("已登记；这台 Mac 还没配置推送")
        case "silent": fixturePush = .noReply
        case "refused": fixturePush = .rejected("保存失败")
        default: break
        }
        switch value("critterNotificationPermission") {
        case "denied": notificationPermission = .denied
        case "ask": notificationPermission = .notDetermined
        case "granted": notificationPermission = .authorized
        case "provisional": notificationPermission = .provisional
        default: break
        }
        leftMac = value("critterLeftMac")
        leftMacKeyKept = arguments.contains("-critterLeftMacKeyKept")
        localNetworkDenied = arguments.contains("-critterLocalNetworkDenied")
        scannerForce = arguments.contains("-critterScannerForce")
        if let drop = value("critterFixtureDrop")?.split(separator: "@"), drop.count == 2,
           let kind = FixtureDrop.Kind(rawValue: String(drop[0])), let at = Double(drop[1]) {
            fixtureDrop = FixtureDrop(kind: kind, at: at)
        }
        if let unpair = value("critterUnpair") {
            let parts = unpair.split(separator: ":")
            unpairAfter = parts.first.flatMap { Double($0) }
            unpairDialogOnly = parts.count > 1 && parts[1] == "dialog"
        }
        systemBlocksActivities = arguments.contains("-critterSystemBlocksActivities")
        if arguments.contains("-critterFakeDock") {
            switch value("critterFakeDock") {
            case "unplug": fakeDock = .unplug
            case "hold-off": fakeDock = .holdOff
            case "card": fakeDock = .card
            default: fakeDock = .standard
            }
        }
    }

    /// `-critterOnboarding <step>[:<state>]`.
    struct OnboardingDemo: Equatable {
        var step: OnboardingStep
        var state: String?

        init?(argument: String) {
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard let first = parts.first, let step = OnboardingStep(rawValue: first) else { return nil }
            self.step = step
            state = parts.count > 1 ? parts[1] : nil
        }

        /// `notifications:ask|denied|granted`: the permission the notification step shows.
        var notificationStatus: UNAuthorizationStatus? {
            guard step == .notifications else { return nil }
            switch state {
            case "ask": return .notDetermined
            case "denied": return .denied
            case "granted": return .authorized
            default: return nil
            }
        }
    }

    /// With `-critterPairing`: the fake Macs and certificates the pairing screen uses.
    var fakePairingNetwork: PairingNetwork? {
        pairing?.network
    }

    /// The link the app starts with: `-critterPairURI`'s, or the one `-critterPairing` hands in.
    var launchLink: IncomingPairLink? {
        pairURI.flatMap { PairingURI(string: $0.absoluteString) }.map { IncomingPairLink(uri: $0, confirmed: true) }
            ?? pairing?.launchLink
    }

    /// With `-critterPairing` and no `-critterFixture`: an unpaired store on the demo's pairer; once a demo pairs, the
    /// link sends the `empty` fixture. Nil otherwise.
    @MainActor
    func pairingStore() -> BridgeStore? {
        guard let pairing, fixture == nil else { return nil }
        let snapshot = Self.loadFixture("empty")
        return BridgeStore(
            storage: UnpairedStorage(),
            makeLink: { _, onEvent in
                FixtureLink(
                    snapshot: snapshot, result: CommandResult(ok: true, reason: nil, message: nil), offline: false,
                    onEvent: onEvent
                )
            },
            pairer: pairing.pairer,
            background: UIKitBackgroundRunner()
        )
    }

    /// `Debug/Fixtures/<name>.json`, its times moved from `fixtureNow` to now.
    private static func loadFixture(_ name: String) -> SnapshotBody {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let body = try? JSONDecoder().decode(SnapshotBody.self, from: data)
        else { preconditionFailure("-critterFixture \(name): no such fixture, or it is not a SnapshotBody") }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        return moved(body, by: now - fixtureNow)
    }

    /// With `-critterFixture`: a store on the fake storage and link, already paired; nil without it.
    @MainActor
    func fixtureStore() -> BridgeStore? {
        guard let fixture else { return nil }
        let snapshot = Self.loadFixture(fixture)
        let result = fixtureResult
        let offline = fixtureOffline
        let cached = offline ? CachedSnapshot(body: snapshot, receivedAt: Date(timeIntervalSinceNow: -300)) : nil
        let linksMade = OSAllocatedUnfairLock(initialState: 0)
        let drop = fixtureDrop
        return BridgeStore(
            storage: FixtureStorage(cached: cached),
            makeLink: { _, onEvent in
                let first = linksMade.withLock { made in
                    made += 1
                    return made == 1
                }
                let link = FixtureLink(
                    snapshot: snapshot, result: result, offline: offline, drop: first ? drop : nil, onEvent: onEvent
                )
                FixtureLink.current = link
                return link
            },
            pairer: pairing.map { $0.pairer as any PairingLink } ?? Pairer(transport: URLSessionTransport()),
            background: UIKitBackgroundRunner(),
            // As the real store: a Mac left that may still push here changes the push key and shows the line.
            onUntoldMac: { PushSetup.shared.macLeftUntold($0) }
        )
    }

    /// `body` with every time in it moved by `shift` milliseconds.
    static func moved(_ body: SnapshotBody, by shift: Int64) -> SnapshotBody {
        func move(_ limits: BridgeLimits?) -> BridgeLimits? {
            guard var limits else { return nil }
            limits.updatedAt += shift
            limits.fiveHour?.resetsAt += shift
            limits.sevenDay?.resetsAt += shift
            return limits
        }
        var body = body
        body.limits = move(body.limits)
        for i in body.sessions.indices {
            body.sessions[i].eventTime += shift
            body.sessions[i].startedAt += shift
            body.sessions[i].limits = move(body.sessions[i].limits)
        }
        for i in body.pending.indices {
            body.pending[i].createdAt += shift
            body.pending[i].expiresAt? += shift
        }
        return body
    }
}

/// With `-critterFixture`: where the answers from a notification's buttons go (`FixtureTransport`); nil without it.
extension DebugLaunch {
    func fixtureAnswerRoute() -> NotificationCenterDelegate.AnswerRoute? {
        guard fixture != nil else { return nil }
        let storage = FixtureStorage(cached: nil)
        return NotificationCenterDelegate.AnswerRoute(
            pairing: { storage.load() }, transport: FixtureTransport(result: fixtureResult, away: fixtureMacAway, silent: fixtureMacSilent),
            app: "critter-ios/fixture"
        )
    }
}

/// Paired with "Fixture Mac" for good: saves nothing, so every launch starts the same, from `cached` if there is one.
private struct FixtureStorage: PairingStorage {
    let cached: CachedSnapshot?

    func load() -> (StoredPairing, Credentials)? {
        let pairing = StoredPairing(
            endpoint: Endpoint(host: "192.168.1.20", port: BridgeProtocol.defaultPort),
            fingerprint: String(repeating: "0", count: 64), macName: DebugLaunch.fixtureMacName, deviceId: "fixture"
        )
        return (pairing, Credentials(deviceId: "fixture", token: "fixture"))
    }

    func save(_ pairing: StoredPairing, token: String) -> Bool { true }
    func updateEndpoint(_ endpoint: Endpoint) {}
    func clear() {}
    func loadSnapshot() -> CachedSnapshot? { cached }
    func saveSnapshot(_ snapshot: CachedSnapshot) {}
}

/// Connects at once and sends the fixture; answers every request with the same result after a moment. A request that
/// is answered (`ok`) leaves the snapshot, as it does on the Mac: its session goes on running. `offline`, it never
/// connects: offline since five minutes ago, retrying.
actor FixtureLink: BridgeLink {
    /// The fixture store's link: a background answer the fixture Mac took (`FixtureTransport`) leaves its snapshot.
    @MainActor static weak var current: FixtureLink?

    private var snapshot: SnapshotBody
    private let result: CommandResult
    private let offline: Bool
    /// `-critterFixtureDrop`: what ends its connection, and when.
    private let drop: DebugLaunch.FixtureDrop?
    private let onEvent: @Sendable (BridgeEvent) -> Void
    private var seq = 0
    private var dropped = false

    init(
        snapshot: SnapshotBody, result: CommandResult, offline: Bool, drop: DebugLaunch.FixtureDrop? = nil,
        onEvent: @escaping @Sendable (BridgeEvent) -> Void
    ) {
        self.snapshot = snapshot
        self.result = result
        self.offline = offline
        self.drop = drop
        self.onEvent = onEvent
    }

    func start() {
        if offline {
            onEvent(.state(.offline(retryIn: .seconds(30), since: Date(timeIntervalSinceNow: -300))))
            return
        }
        guard !dropped else { return }
        onEvent(.state(.connected(macName: DebugLaunch.fixtureMacName)))
        sendSnapshot()
        if let drop {
            Task {
                try? await Task.sleep(for: .seconds(drop.at))
                self.end(drop.kind)
            }
        }
        if let step = DebugLaunch.current.fixtureStep {
            Task {
                try? await Task.sleep(for: .seconds(step.at))
                self.take(step)
            }
        }
    }

    /// `-critterFixtureDrop`: the connection ends, for good.
    private func end(_ kind: DebugLaunch.FixtureDrop.Kind) {
        guard !dropped else { return }
        dropped = true
        let log = Logger(subsystem: "com.braynlabs.critter", category: "notifications")
        switch kind {
        case .offline:
            log.notice("fixture Mac: out of reach")
            onEvent(.state(.offline(retryIn: .seconds(30), since: Date())))
        case .denied:
            log.notice("fixture Mac: denied badToken (as after revoking this phone)")
            onEvent(.denied(.badToken))
            onEvent(.state(.needsRepair(reason: "这台手机已不在电脑的配对列表里，请重新配对")))
        }
    }

    /// `-critterFixtureStep`: the session goes into the step's state, as the Mac would tell.
    private func take(_ step: DebugLaunch.FixtureStep) {
        guard let i = snapshot.sessions.firstIndex(where: { $0.id == step.sessionId }) else { return }
        snapshot.sessions[i].state = step.state
        sendSnapshot()
    }

    private func sendSnapshot() {
        seq += 1
        onEvent(.snapshot(seq: seq, sentAt: Int64((Date().timeIntervalSince1970 * 1000).rounded()), body: snapshot))
    }

    func stop() {
        onEvent(.state(.idle))
    }

    func reconnectNow() {}

    func setPingInterval(_ seconds: TimeInterval) {}

    /// The fixture Mac has no skins to send: the phone shows what it has.
    func requestSkin(_ name: String) -> JSONValue? { nil }

    /// There is no Mac to push from, but the registration is taken as a Mac that can push would take it (the log says
    /// what came, never the key), so the settings show the whole way through; `-critterFixturePush` makes it answer as
    /// another Mac would.
    func registerPush(_ registration: PushRegistration) -> PushRegistrationReply {
        Logger(subsystem: "com.braynlabs.critter", category: "notifications").notice(
            "fixture Mac: push registration token \(registration.token.isEmpty ? "empty (unregister)" : String(registration.token.prefix(8)) + "…", privacy: .public), \(registration.environment.rawValue, privacy: .public), \(registration.bundleId, privacy: .public), done \(registration.notifyDone), error \(registration.notifyError), live activity \(registration.activity?.enabled ?? false), key \(PushCrypto.keyData(registration.key) != nil ? "32 bytes" : "bad", privacy: .public)"
        )
        return registration.token.isEmpty ? .stored(nil) : DebugLaunch.current.fixturePush
    }

    /// An answer the fixture Mac took over another connection (a notification's button): the request leaves.
    func answeredElsewhere(_ requestId: String) {
        answered(requestId)
    }

    func request(_ command: BridgeCommand) async -> CommandResult {
        // The Mac's snapshot without the request comes before its receipt more often than not.
        if result.ok, case .answer(let requestId, _) = command {
            try? await Task.sleep(for: .milliseconds(100))
            answered(requestId)
            try? await Task.sleep(for: .milliseconds(100))
        } else {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return result
    }

    private func answered(_ requestId: String) {
        guard let request = snapshot.pending.first(where: { $0.requestId == requestId }) else { return }
        snapshot.pending.removeAll { $0.requestId == requestId }
        if !snapshot.pending.contains(where: { $0.sessionId == request.sessionId }),
           let i = snapshot.sessions.firstIndex(where: { $0.id == request.sessionId }) {
            snapshot.sessions[i].state = .running
        }
        sendSnapshot()
    }
}
#endif
