import Foundation

/// The app's rules for removing session state files behind the hooks' back (spec §5.3 close
/// detection), as pure decisions the monitor carries out:
///
/// - **exited**: the record's Claude process is gone, or its pid now belongs to a process
///   that started later (reuse) -- checked when a rebuild meets a pid nobody watches yet, at
///   launch, and when a watched process exits;
/// - **switched**: the record's Claude is alive but has moved on to another session without
///   a `SessionEnd` (e.g. an in-session `/resume`): its live registry entry names a
///   different session.
///
/// Every decision is made from an unlocked read, so it is re-checked under the session lock
/// (`confirm`): a record rewritten in the meantime -- by a resumed session's hook, say -- is
/// never deleted on stale evidence.
public enum SessionReaper {
    public enum Reason: String, Sendable {
        case exited, switched
    }

    /// A state file to remove, and what it must still look like under the lock for the
    /// removal to go ahead.
    public struct Removal: Equatable, Sendable {
        public var sessionId: String
        /// The `claudePid` the record must still have (nil: it must still have none).
        public var pid: Int32?
        /// If set, the record must not have had a newer event than this.
        public var eventTime: Int64?
        public var reason: Reason

        public init(sessionId: String, pid: Int32?, eventTime: Int64?, reason: Reason) {
            self.sessionId = sessionId
            self.pid = pid
            self.eventTime = eventTime
            self.reason = reason
        }
    }

    /// The removals a rebuild should attempt.
    ///
    /// - exited: a record whose pid isn't in `watchedPids` (the exit watcher covers those)
    ///   and is dead or reused per `StartupCleanup.isDead`.
    /// - switched: a record whose pid has a live entry in `liveRegistry` and none of that
    ///   pid's entries names the record's session -- provided the entry was written (its
    ///   `updatedAt`, else `startedAt`) no earlier than the record's last event. An entry
    ///   older than the record may simply not show a switch *to* this session yet (right
    ///   after `/clear`, say), so it proves nothing.
    public static func staleRecords(
        records: [SessionRecord],
        liveRegistry: [RegistryEntry],
        watchedPids: Set<Int32>,
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?
    ) -> [Removal] {
        records.compactMap { record in
            guard let pid = record.claudePid else { return nil }
            if !watchedPids.contains(pid),
               StartupCleanup.isDead(pid: pid, recordedStartTime: record.claudeStartTime, isAlive: isAlive, startTime: startTime) {
                return Removal(sessionId: record.sessionId, pid: pid, eventTime: nil, reason: .exited)
            }
            let entries = liveRegistry.filter { $0.pid == pid }
            guard !entries.isEmpty, !entries.contains(where: { $0.sessionId == record.sessionId }) else { return nil }
            if let writtenAt = entries.compactMap({ $0.updatedAt ?? $0.startedAt }).max(), writtenAt < record.eventTime {
                return nil
            }
            return Removal(sessionId: record.sessionId, pid: pid, eventTime: record.eventTime, reason: .switched)
        }
    }

    /// The records owned by `pid`, which just exited: those naming it as their Claude, and
    /// pid-less ones whose session `pid`'s registry entries name -- unless some other live
    /// process (`liveRegistry`, which must exclude `pid`) has that session open too.
    public static func recordsOwned(
        byExited pid: Int32,
        records: [SessionRecord],
        registry: [RegistryEntry],
        liveRegistry: [RegistryEntry]
    ) -> [Removal] {
        let ownedIds = Set(registry.filter { $0.pid == pid }.map(\.sessionId))
        let openElsewhere = Set(liveRegistry.filter { $0.pid != pid }.map(\.sessionId))
        return records.compactMap { record in
            if record.claudePid == pid {
                return Removal(sessionId: record.sessionId, pid: pid, eventTime: nil, reason: .exited)
            }
            if record.claudePid == nil, ownedIds.contains(record.sessionId), !openElsewhere.contains(record.sessionId) {
                return Removal(sessionId: record.sessionId, pid: nil, eventTime: nil, reason: .exited)
            }
            return nil
        }
    }

    /// The launch-time sweep (spec §5.3 layer 3), per `StartupCleanup.isDead(record:)`. A
    /// pid-less record is judged by its age, so it must also still have the same event.
    public static func launchSweep(
        records: [SessionRecord],
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?,
        now: Int64
    ) -> [Removal] {
        records
            .filter { StartupCleanup.isDead(record: $0, isAlive: isAlive, startTime: startTime, now: now) }
            .map { record in
                Removal(
                    sessionId: record.sessionId,
                    pid: record.claudePid,
                    eventTime: record.claudePid == nil ? record.eventTime : nil,
                    reason: .exited
                )
            }
    }

    /// The conditional delete, applied inside `StateStore.update` to the freshly re-read
    /// record: `.delete` only if it still has the judged pid (and, if given, no newer event).
    public static func confirm(_ removal: Removal, current: SessionRecord?) -> ReducerAction {
        guard let current, current.claudePid == removal.pid else { return .ignore }
        if let eventTime = removal.eventTime, current.eventTime > eventTime { return .ignore }
        return .delete
    }
}
