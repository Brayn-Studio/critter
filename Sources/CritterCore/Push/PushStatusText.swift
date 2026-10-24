import Foundation

/// The words of the settings' "iPhone 推送" (spec 6.4).
public enum PushStatusText {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// Shown in red.
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    /// "未配置", "已配置 · 上次发送 <x 分钟前>" or "出错：<原因>".
    /// - Parameters:
    ///   - setup: what `APNsConfigStore.load()` said; nil before it has been read.
    ///   - blockedReason: APNs refused the setup (`PushSender.blockedReason`).
    ///   - lastFailure: why the last push that failed failed (`PushSender.lastFailure`).
    ///   - lastSentAt: epoch milliseconds.
    public static func line(setup: APNsSetup?, blockedReason: String?, lastFailure: String?, lastSentAt: Int64?, now: Int64) -> Line {
        switch setup {
        case nil, .notConfigured?:
            return Line(text: "未配置", isError: false)
        case .problem(let reason)?:
            return Line(text: "出错：\(reason)", isError: true)
        case .ready?:
            if let blockedReason { return Line(text: "出错：\(blockedReason)", isError: true) }
            if let lastFailure { return Line(text: "出错：\(failure(lastFailure))", isError: true) }
            guard let lastSentAt else { return Line(text: "已配置 · 还没有发送过", isError: false) }
            return Line(text: "已配置 · 上次发送 \(ago(lastSentAt, now: now))", isError: false)
        }
    }

    /// Why "发送测试通知" cannot be used, if that is the reason: no iPhone registered, or none for this app.
    public static func testHint(registered: Int, reachable: Int, setUp: Bool) -> String? {
        if registered == 0 { return "还没有 iPhone 登记推送" }
        if setUp, reachable == 0 { return "登记了的 iPhone 不是这个 bundle id 的 App" }
        return nil
    }

    /// `PushSender`'s failure reasons in words.
    static func failure(_ reason: String) -> String {
        switch reason {
        case "network error": return "连不上 APNs"
        case "signing": return "签不了推送的令牌，检查 .p8 文件"
        default:
            if let status = Int(reason), status == 429 || (500...599).contains(status) {
                return "APNs 暂时不可用（\(reason)）"
            }
            return "APNs 不收这条推送（\(reason)）"
        }
    }

    /// "刚刚", "3 分钟前", "2 小时前", "3 天前".
    static func ago(_ time: Int64, now: Int64) -> String {
        let seconds = max(0, (now - time) / 1000)
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(seconds / 60) 分钟前"
        case ..<86_400: return "\(seconds / 3600) 小时前"
        default: return "\(seconds / 86_400) 天前"
        }
    }
}
