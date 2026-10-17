import Foundation

/// Decides which sessions are dead: their Claude process is gone, or the pid now belongs to
/// a different process (pid reuse). Used once at app launch to sweep stale state files, and
/// by `SessionMonitor` before it starts watching a pid (so a reused pid is never watched as
/// if it were the session's Claude).
public enum StartupCleanup {
    /// A recorded start time may differ from the live process's by up to this much before
    /// the pid is considered reused (start times are whole seconds; allow clock jitter).
    public static let startTimeToleranceSeconds: Int64 = 2
    /// A record with no pid at all is considered abandoned after this long without an event.
    public static let pidlessMaxAgeMs: Int64 = 24 * 60 * 60 * 1000

    public static func deadSessionIds(
        records: [SessionRecord],
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?,
        now: Int64
    ) -> [String] {
        records
            .filter { isDead(record: $0, isAlive: isAlive, startTime: startTime, now: now) }
            .map(\.sessionId)
    }

    /// - With a pid: dead if the process is gone, or the record has a `claudeStartTime` and
    ///   the live process's start time differs from it by more than 2 s. Without a recorded
    ///   start time only liveness is checked.
    /// - Without a pid: dead once its last event is more than 24 h old.
    public static func isDead(
        record: SessionRecord,
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?,
        now: Int64
    ) -> Bool {
        guard let pid = record.claudePid else {
            return now - record.eventTime > pidlessMaxAgeMs
        }
        return isDead(pid: pid, recordedStartTime: record.claudeStartTime, isAlive: isAlive, startTime: startTime)
    }

    public static func isDead(
        pid: Int32,
        recordedStartTime: Int64?,
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?
    ) -> Bool {
        guard isAlive(pid) else { return true }
        guard let recorded = recordedStartTime else { return false }
        guard let current = startTime(pid) else { return false }
        return abs(current - recorded) > startTimeToleranceSeconds
    }

    /// A `~/.claude/sessions` entry is dead if its process is gone, or if the process now
    /// holding that pid started after the session itself did (`startedAt`, ms) -- which
    /// can only mean the pid was reused. Claude never deletes an entry whose process was
    /// killed, so without this the pet would keep showing such sessions forever.
    public static func isDead(
        entry: RegistryEntry,
        isAlive: (Int32) -> Bool,
        startTime: (Int32) -> Int64?
    ) -> Bool {
        guard isAlive(entry.pid) else { return true }
        guard let startedAtMs = entry.startedAt, let processStart = startTime(entry.pid) else { return false }
        return processStart > startedAtMs / 1000 + startTimeToleranceSeconds
    }
}
