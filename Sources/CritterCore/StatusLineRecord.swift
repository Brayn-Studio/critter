import Foundation

/// What Claude Code's status line input said about one session: model, context window and
/// rate limits. Every field except the id and timestamp is optional -- the status line omits
/// whatever it doesn't know yet.
public struct StatusLineRecord: Codable, Sendable, Equatable {
    public var sessionId: String
    public var updatedAt: Int64
    public var modelId: String?
    public var modelDisplayName: String?
    public var contextWindowSize: Int?
    public var contextUsedPercentage: Double?
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?

    public init(
        sessionId: String, updatedAt: Int64,
        modelId: String? = nil, modelDisplayName: String? = nil,
        contextWindowSize: Int? = nil, contextUsedPercentage: Double? = nil,
        fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.contextWindowSize = contextWindowSize
        self.contextUsedPercentage = contextUsedPercentage
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// Parses the status line's stdin JSON; nil if it isn't a JSON object with a `session_id`.
    public static func parse(_ input: Data, now: Int64) -> StatusLineRecord? {
        guard let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let sessionId = root["session_id"] as? String else { return nil }
        let model = root["model"] as? [String: Any]
        let context = root["context_window"] as? [String: Any]
        let limits = root["rate_limits"] as? [String: Any]
        return StatusLineRecord(
            sessionId: sessionId, updatedAt: now,
            modelId: model?["id"] as? String,
            modelDisplayName: model?["display_name"] as? String,
            contextWindowSize: (context?["context_window_size"] as? NSNumber)?.intValue,
            contextUsedPercentage: (context?["used_percentage"] as? NSNumber)?.doubleValue,
            fiveHour: window(limits?["five_hour"]),
            sevenDay: window(limits?["seven_day"])
        )
    }

    private static func window(_ value: Any?) -> RateWindow? {
        guard let obj = value as? [String: Any],
              let used = (obj["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (obj["resets_at"] as? NSNumber)?.int64Value else { return nil }
        return RateWindow(usedPercentage: used, resetsAt: resets * 1000)
    }
}

/// One JSON file per session under `statusDir`, written atomically.
public struct StatusLineStore: Sendable {
    private let paths: CritterPaths

    public init(paths: CritterPaths) {
        self.paths = paths
    }

    public func write(_ record: StatusLineRecord) throws {
        guard let file = paths.sessionScopedFile(in: paths.statusDir, sessionId: record.sessionId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: paths.statusDir, withIntermediateDirectories: true)
        try atomicWrite(JSONEncoder().encode(record), to: file)
    }

    /// Every decodable record; corrupt files and hidden temp files are skipped.
    public func readAll() -> [StatusLineRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: paths.statusDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(StatusLineRecord.self, from: data)
        }
    }

    public func delete(sessionId: String) {
        guard let file = paths.sessionScopedFile(in: paths.statusDir, sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
