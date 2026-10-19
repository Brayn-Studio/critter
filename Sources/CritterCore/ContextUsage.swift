import Foundation

/// How much context a session has used, estimated from its transcript.
public struct ContextEstimate: Equatable, Sendable {
    public var usedTokens: Int
    public var model: String?

    public init(usedTokens: Int, model: String? = nil) {
        self.usedTokens = usedTokens
        self.model = model
    }
}

/// Fallback context-usage numbers for when the status line hasn't reported them.
public enum ContextUsage {
    /// The latest assistant turn's token usage in the tail of a transcript. The tail starts at an
    /// arbitrary byte, so its first line may be cut off, and the last line may still be being
    /// written; both are dropped. A usage that adds up to 0 (a synthetic message) says nothing
    /// about the context, so the turn before it counts instead.
    public static func lastUsage(inTranscriptTail tail: Data) -> ContextEstimate? {
        let lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for line in lines.dropFirst().dropLast().reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            func tokens(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let used = tokens("input_tokens") + tokens("cache_creation_input_tokens") + tokens("cache_read_input_tokens")
            guard used > 0 else { continue }
            return ContextEstimate(usedTokens: used, model: message["model"] as? String)
        }
        return nil
    }

    private static let millionTokenPrefixes = [
        "claude-fable-", "claude-sonnet-5", "claude-haiku-5-5", "claude-opus-4-7", "claude-opus-5",
    ]

    public static func windowSize(forModel model: String?) -> Int {
        guard let model else { return 200_000 }
        if model.contains("[1m]") || millionTokenPrefixes.contains(where: { model.hasPrefix($0) }) { return 1_000_000 }
        return 200_000
    }

    /// 0...100, one decimal place.
    public static func percent(usedTokens: Int, windowSize: Int) -> Double {
        guard windowSize > 0 else { return 0 }
        let raw = Double(usedTokens) / Double(windowSize) * 100
        return min(100, max(0, (raw * 10).rounded() / 10))
    }
}
