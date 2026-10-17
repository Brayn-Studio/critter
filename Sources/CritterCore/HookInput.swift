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
