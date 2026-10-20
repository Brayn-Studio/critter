import Foundation

/// Detects a user-initiated Esc interrupt from the tail of a session's transcript JSONL
/// file. There is no hook for this (Claude Code never fires `Stop` when the user interrupts
/// mid-response), so this is the only way Critter finds out the session actually went idle.
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

    /// How much of the transcript's end the hook reads for `latestProgress`: enough to
    /// reach past a few large tool results back to the turn's latest commentary.
    public static let progressTailBytes = 256 * 1024

    /// The current turn's latest public commentary: the last text block of the last main-chain
    /// assistant line after the last user prompt (or interrupt) in `tail`, trimmed and capped
    /// like Codex progress. Nil when the turn hasn't said anything yet. Thinking is read only
    /// from lines with `thinkingDisplay: "updates"`, where Claude Code prints those summaries in
    /// the terminal as the turn's progress lines; other thinking stays internal. Tool results
    /// and meta lines (skill bodies) don't end the turn.
    public static func latestProgress(tail: Data) -> String? {
        var lines = String(decoding: tail, as: UTF8.self).components(separatedBy: "\n")
        lines.removeLast() // The trailing partial (or empty) component, as in `isInterrupted`.
        for line in lines.reversed() {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true
            else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]
            switch obj["type"] as? String {
            case "user":
                let blocks = content as? [[String: Any]] ?? []
                if content is String || blocks.contains(where: { $0["type"] as? String != "tool_result" }) {
                    return nil
                }
            case "assistant":
                guard obj["isApiErrorMessage"] as? Bool != true else { continue }
                let showsThinking = obj["thinkingDisplay"] as? String == "updates"
                let texts = (content as? [[String: Any]] ?? []).compactMap { block -> String? in
                    switch block["type"] as? String {
                    case "text": return block["text"] as? String
                    case "thinking" where showsThinking: return block["thinking"] as? String
                    default: return nil
                    }
                }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let text = texts.last(where: { !$0.isEmpty }) { return String(text.prefix(4000)) }
            default:
                continue
            }
        }
        return nil
    }

    /// The record to write when the app sees `progress` land in the transcript, or nil when
    /// there's nothing to change. Claude can append a text line only after the `PreToolUse`
    /// hook that follows it has run, so this keeps a running bubble current between hooks.
    /// Waiting/terminal bubbles keep their own text. Right after `UserPromptSubmit` the new
    /// prompt may not be in the transcript yet, and the tail's last text is the previous
    /// turn's answer, so a fresh prompt waits for its first tool hook.
    public static func progressUpdate(record: SessionRecord, progress: String?) -> SessionRecord? {
        guard let progress, record.state == .running, record.lastEvent != "UserPromptSubmit",
              progress != record.progress || progress != record.detail else { return nil }
        var next = record
        next.progress = progress
        next.detail = progress
        return next
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
