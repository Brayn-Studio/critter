import CritterCore
import Darwin
import Foundation

/// The phone bridge's brain (spec §6.5): switches the `BridgeServer` on and off, builds the
/// snapshots it pushes (sessions from `SessionMonitor` plus branch, context, status-line data,
/// skins and pending requests), carries out what phones ask for (`BridgeServices`), and runs
/// pairing.
///
/// All of it runs on its own serial queue, `local.critter.pet.bridge`, so nothing it does --
/// or fails to do -- touches the pet's UI or the hooks. The main thread only hands it
/// sessions and settings, and reads the few values below that sit behind `lock`. Switched off,
/// nothing listens and nothing runs (no timers, no watchers); switched on with no phone
/// connected, it only notes that something changed.
final class BridgeController: BridgeServices, @unchecked Sendable {
    /// Changes are pushed together, at most this long after the first one.
    static let pushDelay: TimeInterval = 0.25
    /// How much of a transcript's end is read to estimate its context usage.
    private static let transcriptTailBytes = 64 * 1024
    /// A device's `lastSeen` on disk is refreshed at most this often.
    private static let touchIntervalMs: Int64 = 60_000
    /// After a failed start, the bridge tries again after this long, doubling up to the cap.
    private static let firstRetryDelay: TimeInterval = 5
    private static let maxRetryDelay: TimeInterval = 300

    /// Asks the user "允许「设备名」连接？"; the answer must come back through the callback (on
    /// any thread). Without it, pairing requests are declined.
    @MainActor var onPairRequest: (@MainActor (String, @escaping (Bool) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "local.critter.pet.bridge", qos: .utility)
    private let paths: CritterPaths
    private let skinSearchDirs: [URL]
    private weak var monitor: SessionMonitor?
    private let registry: DeviceRegistry
    private let pendingStore: PendingStore
    private let statusStore: StatusLineStore
    private let inboxStore: InboxStore
    private let home = NSHomeDirectory()

    // Shared with the main thread, only behind `lock`.
    private let lock = NSLock()
    private var listening: Listening?
    /// The listener is ready: phones can actually connect.
    private var serving = false
    private var pairing: Pairing?
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
    private var approveNextPairing = false
    private var branchCache: [String: CachedBranch] = [:]
    private var estimateCache: [String: CachedEstimate] = [:]
    private var lastTouched: [String: Int64] = [:]
    private var retryDelay: TimeInterval = 0
    /// Bumped when the bridge is switched off, so a retry scheduled before doesn't fire.
    private var retryGeneration = 0
    private lazy var computerName = Host.current().localizedName ?? "Mac"

    private struct Listening {
        var port: UInt16
        var fingerprint: String
        var macName: String
    }

    private struct Pairing {
        var code: PairingCode
        var autoApprove: Bool
    }

    /// Keyed by cwd; valid while `HEAD`'s modification time is the same.
    private struct CachedBranch {
        var headModified: Date?
        var branch: String?
    }

    /// Keyed by transcript path; valid while its size and modification time are the same.
    private struct CachedEstimate {
        var size: UInt64
        var modified: Date
        var estimate: ContextEstimate?
    }

    let version: String

    init(paths: CritterPaths, skinSearchDirs: [URL], monitor: SessionMonitor) {
        self.paths = paths
        self.skinSearchDirs = skinSearchDirs
        self.monitor = monitor
        registry = DeviceRegistry(file: paths.bridgeDir.appendingPathComponent("devices.json"))
        pendingStore = PendingStore(paths: paths)
        statusStore = StatusLineStore(paths: paths)
        inboxStore = InboxStore(paths: paths)
        version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        // The settings list the paired phones even while the bridge is off.
        queue.async { [self] in refreshDevices() }
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
        guard let host = Self.lanAddress() else { return nil }
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

    func revoke(deviceId: String) {
        queue.async { [self] in
            registry.revoke(deviceId: deviceId)
            server?.disconnect(deviceId: deviceId)
            refreshDevices()
            DiagnosticLog.shared.log("bridge revoked \(deviceId)")
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
        branchCache = [:]
        estimateCache = [:]
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
        try? FileManager.default.createDirectory(
            at: paths.pendingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
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

    private func buildSnapshot() -> SnapshotBody {
        let now = Self.nowMs()
        pendingStore.sweep(now: now, isAlive: ProcessTools.isAlive)
        let statuses = statusStore.readAll()
        let reported = Set(statuses.filter { $0.contextUsedPercentage != nil }.map(\.sessionId))

        var branches: [String: String] = [:]
        let cwds = Set(sessions.map(\.cwd).filter { !$0.isEmpty })
        for cwd in cwds {
            if let branch = branch(cwd: cwd) { branches[cwd] = branch }
        }
        branchCache = branchCache.filter { cwds.contains($0.key) }

        var estimates: [String: ContextEstimate] = [:]
        var transcripts: Set<String> = []
        for session in sessions where !reported.contains(session.id) {
            guard let path = session.transcriptPath, !path.isEmpty else { continue }
            transcripts.insert(path)
            if let estimate = estimate(transcript: path) { estimates[session.id] = estimate }
        }
        estimateCache = estimateCache.filter { transcripts.contains($0.key) }

        return SnapshotBuilder.build(SnapshotInputs(
            sessions: sessions, skins: skins, statuses: statuses, pending: pendingStore.readAll(),
            branches: branches, estimates: estimates, prefs: prefs, home: home
        ))
    }

    private func branch(cwd: String) -> String? {
        let modified = GitBranch.headFile(cwd: cwd, stopAt: home).flatMap(Self.modificationDate)
        if let cached = branchCache[cwd], cached.headModified == modified { return cached.branch }
        let branch = GitBranch.read(cwd: cwd, stopAt: home)
        branchCache[cwd] = CachedBranch(headModified: modified, branch: branch)
        return branch
    }

    private func estimate(transcript path: String) -> ContextEstimate? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached = estimateCache[path], cached.size == size, cached.modified == modified { return cached.estimate }
        let estimate = Self.tail(of: path, size: size).flatMap(ContextUsage.lastUsage(inTranscriptTail:))
        estimateCache[path] = CachedEstimate(size: size, modified: modified, estimate: estimate)
        return estimate
    }

    /// The last `transcriptTailBytes` of a file. `ContextUsage.lastUsage` drops the first line
    /// as possibly cut off, so when the whole file fits, a newline goes in front of it.
    private static func tail(of path: String, size: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let offset = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, var data = try? handle.readToEnd() else { return nil }
        if offset == 0 { data.insert(UInt8(ascii: "\n"), at: 0) }
        return data
    }

    // MARK: - Pairing

    private func pairRequested(client: Int, deviceName: String) {
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

    // MARK: - BridgeServices (called by `BridgeConnection`, on the bridge queue)

    var macName: String { computerName }

    func verify(deviceId: String, token: String) -> DeviceRecord? {
        registry.verify(deviceId: deviceId, token: token)
    }

    func consumePairingCode(_ code: String) -> Bool {
        let now = Self.nowMs()
        let consumed: Pairing? = lock.withLock {
            guard let current = pairing, now <= current.code.expiresAt else {
                pairing = nil
                return nil
            }
            guard current.code.code == code.uppercased() else { return nil }
            pairing = nil
            return current
        }
        guard let consumed else { return false }
        approveNextPairing = consumed.autoApprove
        return true
    }

    func pendingRequest(_ requestId: String) -> PendingRequest? {
        pendingStore.read(requestId: requestId)
    }

    /// The request's input as published; question texts are never truncated in it.
    func originalToolInput(_ requestId: String) -> [String: Any]? {
        guard let input = pendingStore.read(requestId: requestId)?.input,
              let data = try? JSONEncoder().encode(input) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> Bool {
        (try? pendingStore.writeAnswer(payload, requestId: requestId)) != nil
    }

    func markSeen(sessionId: String) {
        DispatchQueue.main.async { [weak monitor] in
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated { monitor?.markSeen(sessionId) }
        }
    }

    func say(text: String, sessionId: String) -> SayOutcome {
        guard let record = inboxStore.read(sessionId: sessionId) else { return .unavailable }
        do {
            try InboxSender.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: record)
            return .sent
        } catch {
            return .failed
        }
    }

    /// Only plain skin folder names: the name comes off the network, so nothing that could
    /// walk out of the skin directories.
    func skinManifest(name: String) -> JSONValue? {
        guard (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        for dir in skinSearchDirs where SkinLoader.find(name: name, searchDirs: [dir]) != nil {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name).appendingPathComponent("manifest.json")),
               let manifest = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return manifest
            }
        }
        guard name.caseInsensitiveCompare(SkinLoader.builtin().name) == .orderedSame else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(SkinLoader.builtinJSON.utf8))
    }

    /// `seq` is a placeholder: `BridgeServer` numbers snapshots per connection.
    func snapshotMessage() -> ServerMessage {
        .snapshot(seq: 0, sentAt: Self.nowMs(), body: buildSnapshot())
    }

    // MARK: - Helpers

    /// The Mac's address for the pairing QR code: the first private IPv4 address of an active
    /// interface, Wi-Fi/Ethernet (`en*`) first and link-local last.
    private static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (rank: Int, address: String)?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard PrivateNetwork.isAllowed(host: address) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let rank = address.hasPrefix("169.254.") ? 3 : name == "en0" ? 0 : name.hasPrefix("en") ? 1 : 2
            if best == nil || rank < best!.rank { best = (rank, address) }
        }
        return best?.address
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
