import CritterKit
import Foundation

/// How the quota windows read (Android `LimitsText`).
public enum LimitsText {
    private static let minute: Int64 = 60_000
    private static let hour: Int64 = 60 * minute

    /// Index 0 is Sunday, as `Calendar`'s weekday 1.
    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public static func percent(_ w: RateWindow?) -> String {
        w.map { "\(roundedPercent($0.usedPercentage))%" } ?? "—"
    }

    /// "还剩 49 分钟" within the hour, then the time it resets: "21:40 重置" today, "周四 09:00 重置" later.
    /// The time of day and the weekday are `calendar`'s.
    public static func resets(_ w: RateWindow?, now: Date, calendar: Calendar) -> String {
        guard let w else { return "—" }
        let left = difference(w.resetsAt, milliseconds(now))
        if left <= 0 { return "已重置" }
        if left < hour { return "还剩 \(max(left / minute, 1)) 分钟" }
        let at = Date(timeIntervalSince1970: Double(w.resetsAt) / 1000)
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: at)
        let time = "\(twoDigits(parts.hour ?? 0)):\(twoDigits(parts.minute ?? 0))"
        if calendar.isDate(at, inSameDayAs: now) { return "\(time) 重置" }
        let weekday = ((parts.weekday ?? 1) - 1 + 7) % 7
        return "\(weekdays[weekday]) \(time) 重置"
    }

    /// How old the numbers are, once that is worth mentioning (over 30 minutes); nil while they are fresh.
    public static func staleness(updatedAt: Int64, now: Date) -> String? {
        let age = difference(milliseconds(now), updatedAt)
        if age > 2 * hour { return "\(age / hour) 小时前" }
        if age > 30 * minute { return "\(age / minute) 分钟前" }
        return nil
    }

    /// `percent` rounded to a whole number, half up; a number out of any sane range is cut to `Int32`'s,
    /// as Kotlin's `roundToInt` does (and 0 for NaN, where Kotlin throws).
    static func roundedPercent(_ percent: Double) -> Int {
        guard !percent.isNaN else { return 0 }
        return Int(min(max(percent.rounded(), Double(Int32.min)), Double(Int32.max)))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `a - b`, held at the ends of `Int64` instead of overflowing.
    private static func difference(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? (a < b ? .min : .max) : result
    }

    private static func twoDigits(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
