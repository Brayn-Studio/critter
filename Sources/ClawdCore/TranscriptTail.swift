import Foundation

/// Detects a user-initiated Esc interrupt from the tail of a session's transcript JSONL
/// file. There is no hook for this (Claude Code never fires `Stop` when the user interrupts
/// mid-response), so this is the only way Clawd finds out the session actually went idle.
public enum TranscriptTail {
    public static func isInterrupted(tail: Data) -> Bool {
        // Lenient decoding: a tail cut at a raw byte offset can start mid-character (CJK,
        // emoji). That only garbles the partial first line, which is never the one parsed.
        let text = String(decoding: tail, as: UTF8.self)

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

    /// Whether an interrupt line found at the end of the transcript should flip `record`
    /// to idle. Only a busy (`running`/`waiting`) session can be interrupted. And because
    /// `UserPromptSubmit` fires *before* Claude appends the new prompt to the transcript,
    /// a fresh prompt's record can briefly sit on top of the previous turn's interrupt line:
    /// that line is stale unless the transcript was modified after the prompt was submitted
    /// (`transcriptModifiedAt` and `eventTime` are both ms since epoch). Other events (e.g.
    /// `PostToolUseFailure` for the tool the user just interrupted) can legitimately land
    /// after the interrupt line, so they don't block it.
    public static func interruptApplies(to record: SessionRecord, transcriptModifiedAt: Int64?) -> Bool {
        guard record.state == .running || record.state == .waiting else { return false }
        if record.lastEvent == "UserPromptSubmit" {
            guard let modified = transcriptModifiedAt else { return false }
            return modified > record.eventTime
        }
        return true
    }
}
