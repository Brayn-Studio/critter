import Foundation
import CoreFoundation

/// The latest values reported by a Codex rollout. Unknown values stay nil: model names do
/// not imply a context window, and cumulative billing totals are not context occupancy.
public struct CodexTelemetry: Codable, Sendable, Equatable {
    public var model: String?
    public var usedTokens: Int?
    public var contextWindow: Int?
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?
    public var limitsUpdatedAt: Int64?

    public init(
        model: String? = nil, usedTokens: Int? = nil, contextWindow: Int? = nil,
        fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil, limitsUpdatedAt: Int64? = nil
    ) {
        self.model = model
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limitsUpdatedAt = limitsUpdatedAt
    }

    /// Reduces complete rollout envelopes without changing the session's activity state.
    /// Sparse token events retain previously reported model/window values.
    public static func updated(from root: [String: Any], previous: CodexTelemetry?) -> CodexTelemetry? {
        guard let envelope = root["type"] as? String,
              let payload = root["payload"] as? [String: Any] else { return previous }
        var next = previous ?? CodexTelemetry()
        switch envelope {
        case "turn_context", "session_meta":
            next.updateModelAndWindow(payload)
            // session_meta.context_window contains a window_id, not a token capacity.
        case "token_usage_record":
            next.updateUsage(payload["usage"] as? [String: Any])
        case "event_msg":
            switch payload["type"] as? String {
            case "thread_settings_applied":
                if let settings = payload["thread_settings"] as? [String: Any] {
                    next.updateModelAndWindow(settings)
                }
            case "turn_started", "task_started":
                next.updateModelAndWindow(payload)
            case "token_count":
                if let info = payload["info"] as? [String: Any] {
                    next.updateModelAndWindow(info)
                    next.updateUsage(info["last_token_usage"] as? [String: Any])
                }
                if let limits = payload["rate_limits"] as? [String: Any] {
                    // primary/secondary are positions, not guaranteed durations.
                    let windows = [limits["primary"], limits["secondary"]]
                    next.fiveHour = windows.compactMap { window($0, minutes: 300) }.first
                    next.sevenDay = windows.compactMap { window($0, minutes: 10_080) }.first
                    next.limitsUpdatedAt = next.fiveHour != nil || next.sevenDay != nil
                        ? milliseconds(root["timestamp"] as? String) : nil
                }
            case "token_usage_record":
                next.updateUsage(payload["usage"] as? [String: Any])
            default:
                return previous
            }
        default:
            return previous
        }
        return next == CodexTelemetry() ? nil : next
    }

    private mutating func updateModelAndWindow(_ payload: [String: Any]) {
        if let model = payload["model"] as? String, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.model = model
        }
        if let size = Self.integer(payload["model_context_window"]), size > 0 { contextWindow = size }
    }

    private mutating func updateUsage(_ usage: [String: Any]?) {
        guard let usage else { return }
        if let total = Self.integer(usage["total_tokens"]), total >= 0 {
            usedTokens = total
        } else if usage["total_tokens"] == nil,
                  let input = Self.integer(usage["input_tokens"]), input >= 0,
                  let output = Self.integer(usage["output_tokens"]), output >= 0 {
            // Cached input and reasoning output are already included in these totals.
            let (total, overflow) = input.addingReportingOverflow(output)
            if !overflow { usedTokens = total }
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    private static func window(_ value: Any?, minutes: Int) -> RateWindow? {
        guard let window = value as? [String: Any], integer(window["window_minutes"]) == minutes,
              let used = window["used_percent"] as? NSNumber, CFGetTypeID(used) != CFBooleanGetTypeID(),
              used.doubleValue.isFinite, (0...100).contains(used.doubleValue),
              let resets = integer(window["resets_at"]), resets >= 0 else { return nil }
        let (milliseconds, overflow) = Int64(resets).multipliedReportingOverflow(by: 1000)
        guard !overflow else { return nil }
        return RateWindow(usedPercentage: used.doubleValue, resetsAt: milliseconds)
    }

    private static func milliseconds(_ timestamp: String?) -> Int64? {
        guard let timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        return date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
