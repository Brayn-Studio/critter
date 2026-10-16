import Foundation

/// Detects a user-initiated Esc interrupt from the tail of a session's transcript JSONL
/// file. There is no hook for this (Claude Code never fires `Stop` when the user interrupts
/// mid-response), so this is the only way Clawd finds out the session actually went idle.
public enum TranscriptTail {
    public static func isInterrupted(tail: Data) -> Bool {
        guard let text = String(data: tail, encoding: .utf8) else { return false }

        // Split on newlines and drop the final component: if `text` ends with "\n" that's
        // an empty trailing component, and if it doesn't, that final component is a
        // partial line we only have part of -- either way, not a complete line to parse.
        var lines = text.components(separatedBy: "\n")
        lines.removeLast()
        guard let lastLine = lines.reversed().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return false
        }

        guard let data = lastLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "user"
        else {
            return false
        }

        if obj["interruptedMessageId"] != nil { return true }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                if item["type"] as? String == "text",
                   let text = item["text"] as? String,
                   text.hasPrefix("[Request interrupted by user") {
                    return true
                }
            }
        }

        return false
    }
}
