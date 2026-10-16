import Foundation

/// One row the pet UI can show: the union of a session's on-disk `SessionRecord` state and
/// whatever the Claude CLI's own registry knows about it (name, pid, start time).
public struct PetSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var source: SessionSource
    public var state: PetState
    public var detail: String?
    public var cwd: String
    public var pid: Int32?
    public var transcriptPath: String?
    public var tracked: Bool
    public var eventTime: Int64
    public var sortKey: Int64

    public init(
        id: String,
        name: String,
        source: SessionSource,
        state: PetState,
        detail: String?,
        cwd: String,
        pid: Int32?,
        transcriptPath: String?,
        tracked: Bool,
        eventTime: Int64,
        sortKey: Int64
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.state = state
        self.detail = detail
        self.cwd = cwd
        self.pid = pid
        self.transcriptPath = transcriptPath
        self.tracked = tracked
        self.eventTime = eventTime
        self.sortKey = sortKey
    }
}

/// Builds the pet UI's session list from the two independent sources of truth: Clawd's own
/// state files (what the hooks reported) and the Claude CLI's session registry (what's
/// actually running). Pure and synchronous -- callers own reading the files.
public enum SessionCatalog {
    /// Shown as the detail text for a session Clawd knows is running (via the registry)
    /// but has never received a hook event for -- e.g. a session started before the plugin
    /// was installed, or before hooks were reloaded.
    public static let untrackedHint = "重启该会话后可显示实时状态"

    public static func build(records: [SessionRecord], registry: [RegistryEntry], dismissed: [String: Int64]) -> [PetSession] {
        // Duplicate ids are bad-but-possible input (the same conversation resumed in two
        // terminals; a stray copy of a state file) and must never trap: keep the newest.
        let recordsById = Dictionary(records.map { ($0.sessionId, $0) }) { kept, other in
            other.eventTime > kept.eventTime ? other : kept
        }
        let registryById = Dictionary(registry.map { ($0.sessionId, $0) }) { kept, other in
            (other.startedAt ?? .min) > (kept.startedAt ?? .min) ? other : kept
        }
        let allIds = Set(recordsById.keys).union(registryById.keys)

        struct Draft {
            var id: String
            var baseName: String
            var source: SessionSource
            var state: PetState
            var detail: String?
            var cwd: String
            var pid: Int32?
            var transcriptPath: String?
            var tracked: Bool
            var eventTime: Int64
            var sortKey: Int64
        }

        var drafts: [Draft] = []
        for id in allIds {
            let registryEntry = registryById[id]
            let record = recordsById[id]

            // A session whose registry entry identifies it as SDK-driven is never shown as
            // a pet, no matter what its (if any) state record says. A record with no
            // registry entry at all is unaffected -- it's shown normally.
            if let registryEntry, SessionSource.isExcluded(entrypoint: registryEntry.entrypoint) {
                continue
            }

            let eventTime = record?.eventTime ?? 0
            if let dismissedAt = dismissed[id], eventTime <= dismissedAt {
                continue
            }

            let cwd = record?.cwd ?? registryEntry?.cwd ?? ""
            let tracked: Bool
            let state: PetState
            let detail: String?
            if let record {
                tracked = true
                state = record.state
                detail = record.detail
            } else {
                tracked = false
                state = .idle
                detail = untrackedHint
            }

            drafts.append(Draft(
                id: id,
                baseName: registryEntry?.name ?? URL(fileURLWithPath: cwd).lastPathComponent,
                source: SessionSource(entrypoint: registryEntry?.entrypoint),
                state: state,
                detail: detail,
                cwd: cwd,
                pid: registryEntry?.pid ?? record?.claudePid,
                transcriptPath: record?.transcriptPath,
                tracked: tracked,
                eventTime: eventTime,
                sortKey: registryEntry?.startedAt ?? record?.createdAt ?? 0
            ))
        }

        var nameCounts: [String: Int] = [:]
        for draft in drafts { nameCounts[draft.baseName, default: 0] += 1 }

        let sessions = drafts.map { draft -> PetSession in
            let name = (nameCounts[draft.baseName] ?? 0) > 1
                ? "\(draft.baseName)（\(draft.source.label)）"
                : draft.baseName
            return PetSession(
                id: draft.id, name: name, source: draft.source, state: draft.state, detail: draft.detail,
                cwd: draft.cwd, pid: draft.pid, transcriptPath: draft.transcriptPath, tracked: draft.tracked,
                eventTime: draft.eventTime, sortKey: draft.sortKey
            )
        }

        return sessions.sorted { a, b in
            a.sortKey != b.sortKey ? a.sortKey < b.sortKey : a.id < b.id
        }
    }
}
