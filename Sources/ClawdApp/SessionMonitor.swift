import ClawdCore
import Foundation

/// The app's data layer: watches Clawd's state files and Claude's own session registry,
/// notices sessions ending (process exit) or being interrupted (Esc, which fires no hook),
/// and publishes the resulting `[PetSession]` list on the main thread.
///
/// All file reads, directory scans and process queries run on `MonitorEngine`'s background
/// serial queue (Global Constraint: the main thread only does UI); this main-actor facade
/// only forwards requests to it and receives snapshots back.
@MainActor
final class SessionMonitor {
    /// Called on the main thread with every changed snapshot (sorted by session start).
    var onSnapshot: (([PetSession]) -> Void)?

    private(set) var sessions: [PetSession] = []
    /// Every session id seen in the last scan, including dismissed ones -- used to prune
    /// `dismissed` entries for sessions that no longer exist at all.
    private var knownIds: Set<String> = []
    private let engine: MonitorEngine

    init(paths: ClawdPaths) {
        engine = MonitorEngine(paths: paths)
    }

    func start() {
        engine.start { [weak self] snapshot in
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    self?.receive(snapshot)
                }
            }
        }
    }

    /// The user has seen this session's result (e.g. clicked it): `done` → `idle`.
    func markSeen(_ id: String) {
        engine.markSeen(id)
    }

    /// Hides a session until its next event: records its current `eventTime`, which
    /// `SessionCatalog.build` compares against later events.
    func dismiss(_ id: String) {
        let eventTime = sessions.first { $0.id == id }?.eventTime ?? 0
        var dismissed = DismissedSessions.load()
        dismissed[id] = eventTime
        dismissed = dismissed.filter { knownIds.contains($0.key) || $0.key == id }
        DismissedSessions.save(dismissed)
        DiagnosticLog.shared.log("event dismissed \(id) eventTime=\(eventTime)")
        engine.refresh()
    }

    private func receive(_ snapshot: MonitorSnapshot) {
        sessions = snapshot.sessions
        knownIds = snapshot.knownIds
        onSnapshot?(snapshot.sessions)
    }
}

/// `UserDefaults` key `dismissed`: session id → the `eventTime` it had when dismissed.
/// `UserDefaults` is thread-safe, so the engine reads it from its queue.
enum DismissedSessions {
    static let key = "dismissed"

    static func load() -> [String: Int64] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }

    static func save(_ dismissed: [String: Int64]) {
        UserDefaults.standard.set(dismissed.mapValues { NSNumber(value: $0) }, forKey: key)
    }
}

struct MonitorSnapshot: Sendable, Equatable {
    var sessions: [PetSession]
    var knownIds: Set<String>
}

/// Everything below runs on `queue`, and only there: the watchers deliver their callbacks
/// on it and every public entry point hops onto it first. That confinement is what makes
/// the `@unchecked Sendable` sound.
private final class MonitorEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.clawd.pet.monitor", qos: .utility)
    private let paths: ClawdPaths
    private let store: StateStore
    private let log = DiagnosticLog.shared

    private var publish: (@Sendable (MonitorSnapshot) -> Void)?
    private var directoryWatchers: [DirectoryWatcher] = []
    private var exitWatcher: ProcessExitWatcher?
    private var transcriptWatchers: [String: (path: String, watcher: FileAppendWatcher)] = [:]
    /// Registry sessions whose process we saw exit. Claude leaves the registry file behind
    /// when its process is killed, so they're filtered out until that file disappears.
    private var exitedRegistrySessions: Set<String> = []
    private var lastPublished: MonitorSnapshot?
    private var rebuildScheduled = false

    init(paths: ClawdPaths) {
        self.paths = paths
        store = StateStore(paths: paths)
    }

    func start(publish: @escaping @Sendable (MonitorSnapshot) -> Void) {
        queue.async { [self] in
            self.publish = publish
            sweepDeadSessions()
            exitWatcher = ProcessExitWatcher(queue: queue) { [weak self] pid in self?.handleExit(pid) }
            for dir in [paths.sessionsDir, paths.claudeSessionsDir] {
                let watcher = DirectoryWatcher(url: dir, queue: queue) { [weak self] in self?.rebuild() }
                watcher.start()
                directoryWatchers.append(watcher)
            }
            rebuild()
        }
    }

    func refresh() {
        scheduleRebuild()
    }

    func markSeen(_ id: String) {
        queue.async { [self] in
            var changed = false
            try? store.update(sessionId: id) { previous in
                guard var next = previous, next.state == .done else { return .ignore }
                next.state = .idle
                next.detail = nil
                next.lastEvent = "Seen"
                next.eventTime = max(Self.nowMs(), next.eventTime)
                changed = true
                return .write(next)
            }
            if changed {
                log.log("event seen \(id)")
                rebuild()
            }
        }
    }

    // MARK: - Queue-confined work

    private func scheduleRebuild() {
        queue.async { [self] in
            guard !rebuildScheduled else { return }
            rebuildScheduled = true
            queue.async { [self] in
                rebuildScheduled = false
                rebuild()
            }
        }
    }

    /// Launch-time sweep (spec §5.3 layer 3): drop state files whose Claude is gone, whose
    /// pid has been reused, or which have no pid and haven't changed in 24 h.
    private func sweepDeadSessions() {
        let dead = StartupCleanup.deadSessionIds(
            records: store.readAll(),
            isAlive: ProcessTools.isAlive,
            startTime: { ProcessTools.startTime(of: $0) },
            now: Self.nowMs()
        )
        for id in dead {
            store.delete(sessionId: id)
            log.log("event cleanup \(id)")
        }
    }

    private func rebuild() {
        var records = store.readAll()

        // Before trusting (and watching) a pid we aren't watching yet, make sure it is
        // still that session's Claude -- not dead, not reused. Otherwise it has exited.
        let watched = exitWatcher?.watchedPids ?? []
        var exited: Set<String> = []
        for record in records {
            guard let pid = record.claudePid, !watched.contains(pid) else { continue }
            let dead = StartupCleanup.isDead(
                pid: pid,
                recordedStartTime: record.claudeStartTime,
                isAlive: ProcessTools.isAlive,
                startTime: { ProcessTools.startTime(of: $0) }
            )
            if dead {
                store.delete(sessionId: record.sessionId)
                exited.insert(record.sessionId)
                log.log("event exited \(record.sessionId) pid=\(pid)")
            }
        }
        records.removeAll { exited.contains($0.sessionId) }

        let registryAll = ClaudeRegistry.entries(in: paths.claudeSessionsDir)
        exitedRegistrySessions.formIntersection(registryAll.map(\.sessionId))
        let registry = registryAll.filter { entry in
            !exitedRegistrySessions.contains(entry.sessionId)
                && !StartupCleanup.isDead(entry: entry, isAlive: ProcessTools.isAlive, startTime: { ProcessTools.startTime(of: $0) })
        }

        // Exit detection covers every live session, dismissed ones included, so their
        // state files still get cleaned up when they end.
        let pids = Set(records.compactMap(\.claudePid)).union(registry.map(\.pid))
        for pid in pids.subtracting(watched) { exitWatcher?.watch(pid: pid) }
        for pid in watched.subtracting(pids) { exitWatcher?.unwatch(pid: pid) }

        reconcileTranscriptWatchers(records)

        let snapshot = MonitorSnapshot(
            sessions: SessionCatalog.build(records: records, registry: registry, dismissed: DismissedSessions.load()),
            knownIds: Set(records.map(\.sessionId)).union(registryAll.map(\.sessionId))
        )
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        publish?(snapshot)
    }

    /// Process-exit fallback (spec §5.3 layer 2): the session's Claude is gone, so its state
    /// file goes too, even if `SessionEnd` never fired (crash, `kill -9`, closed terminal).
    private func handleExit(_ pid: Int32) {
        for record in store.readAll() where record.claudePid == pid {
            store.delete(sessionId: record.sessionId)
            log.log("event exited \(record.sessionId) pid=\(pid)")
        }
        for entry in ClaudeRegistry.entries(in: paths.claudeSessionsDir) where entry.pid == pid {
            exitedRegistrySessions.insert(entry.sessionId)
        }
        rebuild()
    }

    /// Busy (`running`/`waiting`) sessions get their transcript tailed, since an Esc
    /// interrupt fires no hook and would otherwise leave the pet stuck "running".
    private func reconcileTranscriptWatchers(_ records: [SessionRecord]) {
        var wanted: [String: String] = [:]
        for record in records where record.state == .running || record.state == .waiting {
            if let path = record.transcriptPath, !path.isEmpty {
                wanted[record.sessionId] = path
            }
        }

        for (id, entry) in transcriptWatchers where wanted[id] != entry.path {
            entry.watcher.stop()
            transcriptWatchers[id] = nil
        }

        for (id, path) in wanted where transcriptWatchers[id] == nil {
            let url = URL(fileURLWithPath: path)
            let watcher = FileAppendWatcher(url: url, queue: queue) { [weak self] tail in
                self?.checkInterrupt(sessionId: id, transcript: url, tail: tail)
            }
            // A transcript that doesn't exist yet is retried on the next rebuild.
            guard watcher.start() else { continue }
            transcriptWatchers[id] = (path, watcher)
            // The interrupt may already be there (Esc pressed while the app wasn't running).
            if let tail = FileAppendWatcher.readTail(of: url) {
                checkInterrupt(sessionId: id, transcript: url, tail: tail)
            }
        }
    }

    private func checkInterrupt(sessionId: String, transcript: URL, tail: Data) {
        guard TranscriptTail.isInterrupted(tail: tail) else { return }
        var flipped = false
        try? store.update(sessionId: sessionId) { previous in
            // Re-read under the session lock: a new prompt may have landed since `tail`
            // was captured, in which case the interrupt line is no longer the last word.
            guard let previous,
                  let fresh = FileAppendWatcher.readTail(of: transcript),
                  TranscriptTail.isInterrupted(tail: fresh),
                  TranscriptTail.interruptApplies(to: previous, transcriptModifiedAt: Self.modifiedMs(transcript))
            else { return .ignore }
            var next = previous
            next.state = .idle
            next.detail = nil
            next.lastEvent = "Interrupted"
            next.eventTime = max(Self.nowMs(), previous.eventTime)
            flipped = true
            return .write(next)
        }
        if flipped {
            log.log("event interrupted \(sessionId)")
            scheduleRebuild()
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func modifiedMs(_ url: URL) -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}
