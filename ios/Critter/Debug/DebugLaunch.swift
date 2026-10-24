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
    var open: Open?
    var autoSubmit: AutoSubmit?
    var autoPick: AutoPick?
    var reopen = false
    var pairURI: URL?
    var deviceName: String?
    var openURL: URL?

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
    }

    /// With `-critterFixture`: a store on the fake storage and link, already paired; nil without it.
    @MainActor
    func fixtureStore() -> BridgeStore? {
        guard let fixture else { return nil }
        guard let url = Bundle.main.url(forResource: fixture, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let body = try? JSONDecoder().decode(SnapshotBody.self, from: data)
        else { preconditionFailure("-critterFixture \(fixture): no such fixture, or it is not a SnapshotBody") }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let snapshot = Self.moved(body, by: now - Self.fixtureNow)
        let result = fixtureResult
        return BridgeStore(
            storage: FixtureStorage(),
            makeLink: { _, onEvent in FixtureLink(snapshot: snapshot, result: result, onEvent: onEvent) },
            pairer: Pairer(transport: URLSessionTransport()),
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

/// Paired with "Fixture Mac" for good: saves nothing, so every launch starts the same.
private struct FixtureStorage: PairingStorage {
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
    func loadSnapshot() -> CachedSnapshot? { nil }
    func saveSnapshot(_ snapshot: CachedSnapshot) {}
}

/// Connects at once and sends the fixture; answers every request with the same result after a moment. A request that
/// is answered (`ok`) leaves the snapshot, as it does on the Mac: its session goes on running.
private actor FixtureLink: BridgeLink {
    private var snapshot: SnapshotBody
    private let result: CommandResult
    private let onEvent: @Sendable (BridgeEvent) -> Void
    private var seq = 0

    init(snapshot: SnapshotBody, result: CommandResult, onEvent: @escaping @Sendable (BridgeEvent) -> Void) {
        self.snapshot = snapshot
        self.result = result
        self.onEvent = onEvent
    }

    func start() {
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
