import Foundation

/// What kind of work a running session is doing, derived from the tool in flight; the pet
/// picks a matching animation variant (laptop, reading, bash, juggling, or just thinking).
public enum WorkActivity: String, Codable, Sendable, CaseIterable {
    case think, laptop, read, bash, juggle

    /// The activity for a `PreToolUse` of `name`. Unknown and MCP tools count as `laptop`.
    public static func forTool(_ name: String) -> WorkActivity {
        switch name {
        case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch": return .read
        case "Bash", "BashOutput", "KillShell": return .bash
        case "Agent", "Task": return .juggle
        default: return .laptop // Edit, MultiEdit, Write, NotebookEdit, mcp__*, anything new
        }
    }
}
