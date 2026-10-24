import CoreGraphics
import Foundation

/// What the "发一句" sheet tells the user about the Mac's receipt for a message or a stop request
/// (Android `sayFeedback`, `interruptFeedback`, `afterSent`; spec §6.4).
public enum SayFeedback {
    /// The longest message "发一句" sends.
    public static let maxLength = 4000

    /// The words for `result`. For a message: "已发送", the Mac's own explanation when it gave one, else what an
    /// unavailable route means (`codex`: the Codex control channel is not connected; otherwise the session started
    /// too early to receive), else "发送失败". For a stop request (`isInterrupt`): the Mac's words, else what the
    /// receipt confirms: acceptance of the request, not that the turn has already stopped.
    public static func text(for result: CommandResult, isInterrupt: Bool = false, codex: Bool = false) -> String {
        let message = result.message.flatMap { isBlank($0) ? nil : $0 }
        if isInterrupt {
            if let message { return message }
            if result.ok { return "已请求停止当前回合" }
            return result.reason == .unavailable ? "当前会话无法停止，请在电脑上处理" : "停止请求未发送成功"
        }
        if result.ok { return "已发送" }
        if let message { return message }
        if result.reason == .unavailable {
            return codex ? "尚未连接 Codex 控制通道，请在电脑上继续操作" : "这个会话收不到消息（可能是启动得太早，重启会话后可用）"
        }
        return "发送失败"
    }

    /// The field after `sent` went out: the field stays editable during the send (the keyboard stays up), so what
    /// was typed after the sent words in the meantime is kept. A field whose sent words were edited meanwhile is
    /// the user's new draft and is left as it is.
    public static func afterSent(current: String, sent: String) -> String {
        guard current.hasPrefix(sent) else { return current }
        return String(current.dropFirst(sent.count).drop(while: { $0.isWhitespace }))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The pixel letter's flight from the text field to the pet (Android `letterPath`, visual design §7).
public enum LetterFlight {
    /// Where the letter is at each of its `steps` (1...`steps`) on the way from `from` to `to`: on the straight
    /// line between them, lifted by `sin(t·π)·rise` into an arc, and snapped to whole `cell`s so it moves on the
    /// pixel grid. The last step is `to` (snapped).
    public static func path(
        from: CGPoint, to: CGPoint, steps: Int = 7, rise: CGFloat = 60, cell: CGFloat = 3
    ) -> [CGPoint] {
        (1...max(steps, 1)).map { i in
            let t = CGFloat(i) / CGFloat(max(steps, 1))
            let x = from.x + (to.x - from.x) * t
            let y = from.y + (to.y - from.y) * t - CGFloat(sin(Double(t) * Double.pi)) * rise
            return CGPoint(x: snap(x, cell), y: snap(y, cell))
        }
    }

    private static func snap(_ v: CGFloat, _ cell: CGFloat) -> CGFloat {
        (v / cell + 0.5).rounded(.down) * cell
    }
}
