import Foundation

/// What a reply from APNs means for the Mac.
public enum APNsOutcome: Equatable, Sendable {
    /// APNs took the push.
    case sent
    /// The phone's token is no good any more (the app was deleted, or the token belongs to another environment
    /// or app): forget it.
    case dropToken
    /// Every push will fail the same way until the settings change: the key, the Team ID or the bundle id.
    /// The text is for the settings' status line.
    case configError(String)
    /// Worth trying again: APNs is busy or down, or there was no answer.
    case retry
    /// APNs refused this push for itself (a bad payload, say); trying again would not help, and nothing else is
    /// wrong. The text says why, for the log.
    case rejected(String)
}

/// A reply from APNs: the status and the body (JSON with a `reason` when it is not 200).
public struct APNsReply: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public enum APNsResponse {
    /// - Parameter body: the reply's body; may be empty or not JSON.
    public static func classify(status: Int, body: Data) -> APNsOutcome {
        let reason = reason(in: body)
        switch status {
        case 200:
            return .sent
        case 410:
            return .dropToken
        case 400 where reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic":
            return .dropToken
        case 403:
            return .configError(reason == "InvalidProviderToken" ? "密钥或 Team ID 不对" : (reason ?? "403"))
        case 429, 500...599:
            return .retry
        default:
            return .rejected(reason ?? String(status))
        }
    }

    private static func reason(in body: Data) -> String? {
        guard !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reason = object["reason"] as? String, !reason.isEmpty
        else { return nil }
        return reason
    }
}
