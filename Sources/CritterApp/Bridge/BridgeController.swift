import CritterCore
import Foundation

/// The phone bridge's brain (spec §6.5): switches the `BridgeServer` on and off, pushes the
/// snapshots `SnapshotAssembler` makes (sessions from `SessionMonitor` plus branch, context,
/// status-line data, skins and pending requests), carries out what phones ask for
/// (`BridgeServices`, in `BridgeController+Services.swift`), and runs pairing.
///
/// All of it runs on its own serial queue, `local.critter.pet.bridge`, so nothing it does --
/// or fails to do -- touches the pet's UI or the hooks. The main thread only hands it
/// sessions and settings, and reads the few values below that sit behind `lock`. Switched off,
/// nothing listens and nothing runs (no timers, no watchers); switched on with no phone
/// connected, it only notes that something changed.
final class BridgeController: @unchecked Sendable {
    /// Changes are pushed together, at most this long after the first one.
    static let pushDelay: TimeInterval = 0.25
    /// A device's `lastSeen` on disk is refreshed at most this often.
    private static let touchIntervalMs: Int64 = 60_000
    /// After a failed start, the bridge tries again after this long, doubling up to the cap.
    private static let firstRetryDelay: TimeInterval = 5
    private static let maxRetryDelay: TimeInterval = 300

    /// Asks the user "允许「设备名」连接？"; the answer must come back through the callback (on
    /// any thread). Without it, pairing requests are declined.
    @MainActor var onPairRequest: (@MainActor (String, @escaping (Bool) -> Void) -> Void)?

    // Not private where `BridgeController+Services.swift` uses them too.
    private let queue = DispatchQueue(label: "local.critter.pet.bridge", qos: .utility)
    private let paths: CritterPaths
    let skinSearchDirs: [URL]
    weak var monitor: SessionMonitor?
    let registry: DeviceRegistry
    let pendingStore: PendingStore
    private let statusStore: StatusLineStore
    let inboxStore: InboxStore

    // Shared with the main thread, only behind `lock`.
    let lock = NSLock()
    private var listening: Listening?
    /// The listener is ready: phones can actually connect.
    private var serving = false
    var pairing: Pairing?
    private var lastSeen: Int64?
    private var deviceList: [DeviceRecord] = []

    // Bridge queue only.
    private var enabled = false
    private var server: BridgeServer?
    private var watchers: [DirectoryWatcher] = []
    private var sessions: [PetSession] = []
    private var skins: [String: String] = [:]
    private var prefs = BridgePrefs(
        skin: SkinLoader.builtin().name, randomSkins: false, idleDim: 1, mergeThreshold: 4, soundTheme: SoundTheme.voice.rawValue
    )
    private var pushScheduled = false
    /// The pairing code just consumed was issued with `autoApprove`.
    var approveNextPairing = false
    /// Snapshots, with their branch and context-estimate caches.
    private let snapshots = SnapshotAssembler(home: NSHomeDirectory())
    private var lastTouched: [String: Int64] = [:]
    /// The last client number handed to a `BridgeServer`; never reset, so numbers stay unique
    /// across servers (see `BridgeServer.nextClientNumber`).
    private var lastClientNumber = 0
    private var retryDelay: TimeInterval = 0
    /// Bumped when the bridge is switched off, so a retry scheduled before doesn't fire.
    private var retryGeneration = 0
    lazy var computerName = Host.current().localizedName ?? "Mac"

    private struct Listening {
        var port: UInt16
        var fingerprint: String
        var macName: String
    }

    struct Pairing {
        var code: PairingCode
        var autoApprove: Bool
    }

    let version: String

    init(paths: CritterPaths, skinSearchDirs: [URL], monitor: SessionMonitor) {
        self.paths = paths
        self.skinSearchDirs = skinSearchDirs
        self.monitor = monitor
        registry = DeviceRegistry(file: paths.bridgeDir.appendingPathComponent("devices.json"), log: { DiagnosticLog.shared.log($0) })
        pendingStore = PendingStore(paths: paths)
        statusStore = StatusLineStore(paths: paths)
        inboxStore = InboxStore(paths: paths)
        version = AppVersion.current
        queue.async { [self] in
            // The settings list the paired phones even while the bridge is off.
            refreshDevices()
            // Requests whose hook is gone or that expired while Critter wasn't running, and
            // answers nobody waits for (spec 6.3) -- also when no phone ever connects.
            pendingStore.sweep(now: Self.nowMs(), isAlive: ProcessTools.isAlive)
        }
    }

    // MARK: - Main-thread interface

    /// Whether phones can reach the bridge right now: it is on and its listener is ready (not
    /// failed, not waiting for the Local Network permission or a network).
    var isServing: Bool { lock.withLock { serving } }

    /// Epoch milliseconds of the last time a paired phone talked to the bridge; nil whenever
    /// the bridge isn't serving, so `critter-hook ask` never waits on an unreachable one.
    var lastClientSeen: Int64? { lock.withLock { serving ? lastSeen : nil } }

    func devices() -> [DeviceRecord] {
        lock.withLock { deviceList }
    }

    func setEnabled(_ on: Bool) {
        queue.async { [self] in
            if on { start() } else { stop() }
        }
    }

    /// The latest sessions, each one's skin id, and the settings the phone mirrors.
    func update(sessions: [PetSession], skins: [String: String], prefs: BridgePrefs) {
        queue.async { [self] in
            self.sessions = sessions
            self.skins = skins
            self.prefs = prefs
            changed()
        }
    }

    /// Issues a new pairing code (replacing any earlier one) and returns what the QR code
    /// shows; nil while the bridge isn't listening or the Mac has no private-network address.
    /// With `autoApprove`, the phone that uses this code is paired without asking.
    func beginPairing(autoApprove: Bool) -> PairingURI? {
        guard let host = LANAddress.current() else { return nil }
        let code = PairingCode.generate(now: Self.nowMs())
        return lock.withLock {
            guard let listening else { return nil }
            pairing = Pairing(code: code, autoApprove: autoApprove)
            return PairingURI(host: host, port: listening.port, fingerprint: listening.fingerprint, code: code.code, name: listening.macName)
        }
    }

    /// `beginPairing`, but once the bridge has finished what it was asked to do before (such
    /// as starting up right after `setEnabled(true)`); `completion` runs on the bridge queue.
    func beginPairing(autoApprove: Bool, completion: @escaping @Sendable (PairingURI?) -> Void) {
        queue.async { [self] in completion(beginPairing(autoApprove: autoApprove)) }
    }

    /// Withdraws the code on show unless it was issued with `autoApprove` (the pairing sheet
    /// closed: its code must stop working). Queued, so it also covers a code still being made.
    func cancelPairing() {
        queue.async { [self] in
            lock.withLock {
                if pairing?.autoApprove == false { pairing = nil }
            }
        }
    }

    func revoke(deviceId: String) {
        queue.async { [self] in
            registry.revoke(deviceId: deviceId)
            server?.disconnect(deviceId: deviceId)
            refreshDevices()
            DiagnosticLog.shared.log("bridge revoked \(deviceId)")
        }
    }

    /// `revoke`, but only for a device `critter-bridge-client` paired (the debug URL scheme
    /// must never be able to unpair a real phone).
    func revokeDevClient(deviceId: String) {
        queue.async { [self] in
            guard registry.list().contains(where: { $0.id == deviceId && $0.name == DeviceRegistry.devClientName }) else {
                DiagnosticLog.shared.log("bridge debug revoke refused \(deviceId)")
                return
            }
            revoke(deviceId: deviceId)
        }
    }

    /// "重置配对": forgets every phone and makes a new TLS identity, so none of them can
    /// connect any more.
    func resetPairing() {
        queue.async { [self] in
            registry.removeAll()
            refreshDevices()
            lock.withLock { pairing = nil }
            let wasEnabled = enabled
            stop()
            BridgeIdentity.reset(dir: paths.bridgeDir)
            DiagnosticLog.shared.log("bridge pairing reset")
            if wasEnabled { start() }
        }
    }

    // MARK: - On / off

    private func start() {
        guard !enabled else { return }
        enabled = true
        let macName = computerName
        do {
            let (identity, fingerprint) = try BridgeIdentity.loadOrCreate(dir: paths.bridgeDir)
            let server = BridgeServer(
                queue: queue, serviceName: macName,
                makeConnection: { [unowned self] in BridgeConnection(services: self) },
                nextClientNumber: { [unowned self] in
                    lastClientNumber += 1
                    return lastClientNumber
                },
                callbacks: BridgeServer.Callbacks(
                    pairRequested: { [weak self] client, deviceName in self?.pairRequested(client: client, deviceName: deviceName) },
                    deviceActive: { [weak self] deviceId in self?.deviceActive(deviceId) },
                    listeningChanged: { [weak self] listening in self?.listeningChanged(listening) },
                    failed: { [weak self] in self?.serverFailed() }
                )
            )
            let port = try server.start(identity: identity)
            self.server = server
            let ready = server.isListening
            lock.withLock {
                listening = Listening(port: port, fingerprint: fingerprint, macName: macName)
                serving = ready
            }
            retryDelay = 0
            startWatchers()
            DiagnosticLog.shared.log("bridge listening port=\(port) ready=\(ready) fp=\(fingerprint.prefix(12))")
        } catch {
            DiagnosticLog.shared.log("bridge failed to start: \(error)")
            lock.withLock {
                serving = false
                lastSeen = nil
            }
            scheduleRetry()
        }
    }

    /// Switched off (or about to be reset): also drops any retry that was due.
    private func stop() {
        guard enabled else { return }
        retryGeneration += 1
        retryDelay = 0
        tearDown()
        DiagnosticLog.shared.log("bridge stopped")
    }

    private func tearDown() {
        enabled = false
        server?.stop()
        server = nil
        for watcher in watchers { watcher.stop() }
        watchers = []
        lock.withLock {
            listening = nil
            serving = false
            pairing = nil
            lastSeen = nil
        }
        approveNextPairing = false
        snapshots.reset()
    }

    /// The listener became ready, or went back to waiting (e.g. no network). While it waits,
    /// no phone can be talking to the bridge.
    private func listeningChanged(_ ready: Bool) {
        lock.withLock {
            serving = ready
            if !ready { lastSeen = nil }
        }
        DiagnosticLog.shared.log("bridge \(ready ? "ready" : "waiting")")
    }

    /// The listener broke after it had started, and the server has stopped itself.
    private func serverFailed() {
        server = nil
        lock.withLock {
            serving = false
            lastSeen = nil
        }
        scheduleRetry()
    }

    /// Starts over after `retryDelay` (5 s, doubling up to 5 min), for as long as the bridge
    /// stays switched on and isn't running.
    private func scheduleRetry() {
        retryDelay = min(max(retryDelay * 2, Self.firstRetryDelay), Self.maxRetryDelay)
        let generation = retryGeneration
        DiagnosticLog.shared.log("bridge retry in \(Int(retryDelay)) s")
        queue.asyncAfter(deadline: .now() + retryDelay) { [self] in
            guard enabled, server == nil, generation == retryGeneration else { return }
            tearDown()
            start()
        }
    }

    /// New and answered requests, and fresh status-line data, change the snapshot too.
    private func startWatchers() {
        // Made private before the watcher would create it with the default permissions.
        try? PrivateDirectory.ensure(paths.pendingDir)
        watchers = [paths.pendingDir, paths.statusDir].map { dir in
            DirectoryWatcher(url: dir, queue: queue, debounce: 0) { [weak self] in self?.changed() }
        }
        for watcher in watchers { watcher.start() }
    }

    // MARK: - Snapshots

    /// Something the snapshot is made from changed: push within `pushDelay` -- but only if
    /// a phone is there to see it.
    private func changed() {
        guard enabled, server?.hasReadyClients == true, !pushScheduled else { return }
        pushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.pushDelay) { [weak self] in
            guard let self else { return }
            pushScheduled = false
            guard enabled, let server, server.hasReadyClients else { return }
            // The server skips connections whose last snapshot is the same.
            server.broadcast(snapshotMessage())
        }
    }

    func buildSnapshot() -> SnapshotBody {
        pendingStore.sweep(now: Self.nowMs(), isAlive: ProcessTools.isAlive)
        return snapshots.build(
            sessions: sessions, skins: skins, statuses: statusStore.readAll(), pending: pendingStore.readAll(), prefs: prefs
        )
    }

    // MARK: - Pairing

    private func pairRequested(client: Int, deviceName raw: String) {
        let deviceName = BridgeProtocol.deviceName(raw)
        if approveNextPairing {
            approveNextPairing = false
            finishPairing(client: client, deviceName: deviceName, allowed: true)
            return
        }
        DispatchQueue.main.async { [self] in
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated {
                guard let ask = onPairRequest else {
                    queue.async { [self] in finishPairing(client: client, deviceName: deviceName, allowed: false) }
                    return
                }
                ask(deviceName) { [self] allowed in
                    queue.async { [self] in finishPairing(client: client, deviceName: deviceName, allowed: allowed) }
                }
            }
        }
    }

    /// Only the first answer counts, and only while that phone is still waiting.
    private func finishPairing(client: Int, deviceName: String, allowed: Bool) {
        guard let server, server.isAwaitingApproval(client) else { return }
        guard allowed, let (record, token) = try? registry.add(name: deviceName, now: Self.nowMs()) else {
            server.rejectPairing(client)
            DiagnosticLog.shared.log("bridge pairing declined")
            return
        }
        refreshDevices()
        server.approvePairing(client, deviceId: record.id, token: token)
        DiagnosticLog.shared.log("bridge paired \(record.id)")
    }

    private func deviceActive(_ deviceId: String) {
        let now = Self.nowMs()
        lock.withLock { lastSeen = now }
        guard now - (lastTouched[deviceId] ?? 0) >= Self.touchIntervalMs else { return }
        lastTouched[deviceId] = now
        registry.touch(deviceId: deviceId, now: now)
        refreshDevices()
    }

    private func refreshDevices() {
        let list = registry.list()
        lock.withLock { deviceList = list }
    }

    // MARK: - Helpers

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
