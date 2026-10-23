import CritterClient
import CritterKit
import Foundation
import Testing

/// `LimitsTextTest.kt`.
struct LimitsTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func window(_ day: Int, _ hour: Int, _ minute: Int) -> RateWindow {
        RateWindow(usedPercentage: 10, resetsAt: millis(date(day, hour, minute)))
    }

    // Wednesday 2026-10-21 12:00 in Shanghai.
    private var now: Date { date(21, 12, 0) }

    @Test func limitsTextPercent() {
        #expect(LimitsText.percent(RateWindow(usedPercentage: 16, resetsAt: 0)) == "16%")
        #expect(LimitsText.percent(RateWindow(usedPercentage: 12.5, resetsAt: 0)) == "13%")
        #expect(LimitsText.percent(nil) == "—")
    }

    @Test func limitsTextResetsVariants() {
        #expect(LimitsText.resets(window(21, 11, 59), now: now, calendar: calendar) == "已重置")
        #expect(LimitsText.resets(window(21, 12, 0), now: now, calendar: calendar) == "已重置")
        #expect(LimitsText.resets(window(21, 12, 49), now: now, calendar: calendar) == "还剩 49 分钟")
        #expect(LimitsText.resets(RateWindow(usedPercentage: 1, resetsAt: millis(now) + 20_000), now: now, calendar: calendar) == "还剩 1 分钟")
        #expect(LimitsText.resets(window(21, 21, 40), now: now, calendar: calendar) == "21:40 重置")
        #expect(LimitsText.resets(window(22, 9, 0), now: now, calendar: calendar) == "周四 09:00 重置")
        #expect(LimitsText.resets(window(26, 0, 5), now: now, calendar: calendar) == "周一 00:05 重置")
        #expect(LimitsText.resets(nil, now: now, calendar: calendar) == "—")
    }

    @Test func limitsTextResetsNamesEveryWeekday() {
        // Wed 21st ... Tue 27th, each at 21:00: today has no weekday, the others do.
        let names = (21...27).map { LimitsText.resets(window($0, 21, 0), now: now, calendar: calendar) }
        #expect(names == ["21:00 重置", "周四 21:00 重置", "周五 21:00 重置", "周六 21:00 重置", "周日 21:00 重置", "周一 21:00 重置", "周二 21:00 重置"])
        #expect(LimitsText.resets(window(28, 21, 0), now: now, calendar: calendar) == "周三 21:00 重置")
    }

    /// The time of day is the calendar's: the same instant reads differently in another time zone.
    @Test func limitsTextResetsReadsTheClockOfTheGivenCalendar() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 21:40 in Shanghai is 13:40 UTC, the same day.
        #expect(LimitsText.resets(window(21, 21, 40), now: now, calendar: utc) == "13:40 重置")
        // 07:30 on the 22nd in Shanghai is 23:30 UTC on the 21st: today there, not "周四".
        #expect(LimitsText.resets(window(22, 7, 30), now: now, calendar: utc) == "23:30 重置")
        #expect(LimitsText.resets(window(22, 7, 30), now: now, calendar: calendar) == "周四 07:30 重置")
    }

    @Test func limitsTextStaleness() {
        let min: Int64 = 60_000
        let nowMs = millis(now)
        #expect(LimitsText.staleness(updatedAt: nowMs - 30 * min, now: now) == nil)
        #expect(LimitsText.staleness(updatedAt: nowMs - 31 * min, now: now) == "31 分钟前")
        #expect(LimitsText.staleness(updatedAt: nowMs - 119 * min, now: now) == "119 分钟前")
        #expect(LimitsText.staleness(updatedAt: nowMs, now: now) == nil)
        #expect(LimitsText.staleness(updatedAt: nowMs - 121 * min, now: now) == "2 小时前")
        #expect(LimitsText.staleness(updatedAt: nowMs - 300 * min, now: now) == "5 小时前")
    }

    @Test func limitsTextSurvivesAbsurdTimestamps() {
        let extreme = [Int64.min, Int64.max, 0]
        for value in extreme {
            _ = LimitsText.staleness(updatedAt: value, now: now)
            _ = LimitsText.resets(RateWindow(usedPercentage: 1e30, resetsAt: value), now: now, calendar: calendar)
            _ = LimitsText.percent(RateWindow(usedPercentage: 1e30, resetsAt: value))
        }
    }
}
