import Foundation

/// Decoded form of a Claude Code hook's stdin JSON payload. Fields not present for a
/// given `hookEventName` are simply nil; this struct is the union of every event's shape.
public struct HookInput: Decodable, Sendable {
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var hookEventName: String
    public var source: String?
    public var reason: String?
    public var prompt: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var notificationType: String?
    public var message: String?
    public var lastAssistantMessage: String?
    public var errorType: String?
    public var errorMessage: String?
    public var commandName: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case hookEventName = "hook_event_name"
        case source
        case reason
        case prompt
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case notificationType = "notification_type"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case commandName = "command_name"
    }
}

extension HookInput {
    /// The `HookInput` decoding would give, built from the payload as `JSONSerialization` parsed
    /// it -- so the event hook parses its stdin once and still has `tool_input` exactly as parsed.
    /// Nil wherever decoding fails: a required string missing, null or of another type, or an
    /// optional field present with another type (null counts as absent).
    public init?(json root: [String: Any]) {
        var wrongType = false
        func optional(_ key: CodingKeys) -> String? {
            guard let value = root[key.rawValue], !(value is NSNull) else { return nil }
            guard let string = value as? String else {
                wrongType = true
                return nil
            }
            return string
        }
        guard let sessionId = root[CodingKeys.sessionId.rawValue] as? String,
              let cwd = root[CodingKeys.cwd.rawValue] as? String,
              let hookEventName = root[CodingKeys.hookEventName.rawValue] as? String else { return nil }
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookEventName = hookEventName
        transcriptPath = optional(.transcriptPath)
        source = optional(.source)
        reason = optional(.reason)
        prompt = optional(.prompt)
        toolName = optional(.toolName)
        notificationType = optional(.notificationType)
        message = optional(.message)
        lastAssistantMessage = optional(.lastAssistantMessage)
        errorType = optional(.errorType)
        errorMessage = optional(.errorMessage)
        commandName = optional(.commandName)
        if let value = root[CodingKeys.toolInput.rawValue], !(value is NSNull) {
            toolInput = JSONValue(any: value)
        }
        if wrongType { return nil }
    }
}
