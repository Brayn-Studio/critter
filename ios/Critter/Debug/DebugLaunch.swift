#if DEBUG
import CritterClient
import CritterKit
import Foundation

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
/// - `-critterFrameLog`: every 10 seconds, "frames <n>" on standard output: how many ticks changed the picture on any
///   Critter stage (`FrameLog`). Read it with `xcrun simctl launch --console-pty <device> com.braynlabs.critter …`.
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
///   - `paired@<seconds>`: the Mac says yes after that long (a link that came meanwhile is dropped).
/// - `-critterPickSkin <skin>|follow`: with `-critterOpen settings`, a second after the settings are up, that skin's
///   tile is tapped ("follow" is 「跟着电脑」), and 1.5 s later the settings go back to the home screen. The choice is
///   saved like a real tap: `-critterPickSkin follow` undoes it.
/// - `-critterSettingsAt skins|board|motion`: with `-critterOpen settings`, the settings open scrolled to that group.
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
        return BridgeStore(
            storage: FixtureStorage(cached: cached),
            makeLink: { _, onEvent in
                FixtureLink(snapshot: snapshot, result: result, offline: offline, onEvent: onEvent)
            },
            pairer: pairing.map { $0.pairer as any PairingLink } ?? Pairer(transport: URLSessionTransport()),
            background: UIKitBackgroundRunner()
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

    func save(_ pairing: StoredPairing, token: String) {}
    func updateEndpoint(_ endpoint: Endpoint) {}
    func clear() {}
    func loadSnapshot() -> CachedSnapshot? { cached }
    func saveSnapshot(_ snapshot: CachedSnapshot) {}
}

/// Connects at once and sends the fixture; answers every request with the same result after a moment. A request that
/// is answered (`ok`) leaves the snapshot, as it does on the Mac: its session goes on running. `offline`, it never
/// connects: offline since five minutes ago, retrying.
actor FixtureLink: BridgeLink {
    private var snapshot: SnapshotBody
    private let result: CommandResult
    private let offline: Bool
    private let onEvent: @Sendable (BridgeEvent) -> Void
    private var seq = 0

    init(
        snapshot: SnapshotBody, result: CommandResult, offline: Bool, onEvent: @escaping @Sendable (BridgeEvent) -> Void
    ) {
        self.snapshot = snapshot
        self.result = result
        self.offline = offline
        self.onEvent = onEvent
    }

    func start() {
        if offline {
            onEvent(.state(.offline(retryIn: .seconds(30), since: Date(timeIntervalSinceNow: -300))))
            return
        }
        onEvent(.state(.connected(macName: DebugLaunch.fixtureMacName)))
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
