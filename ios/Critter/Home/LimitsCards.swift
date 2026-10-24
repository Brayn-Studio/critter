import CritterClient
import CritterKit
import SwiftUI

/// Claude Code's two quota windows side by side (Android `Limits`, the mockups' `.limits`), and how old they are
/// once the Mac has not refreshed them for a while. The times read the clock once a minute, on their own.
struct LimitsCards: View {
    let limits: BridgeLimits?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude Code 额度")
                .font(.nunito(size: 12, weight: .heavy))
                .foregroundStyle(Theme.ink2)
                .padding(.leading, 4)
                .padding(.bottom, 6)
            HStack(alignment: .top, spacing: 10) {
                LimitCard(title: "5 小时额度", window: limits?.fiveHour)
                LimitCard(title: "7 天额度", window: limits?.sevenDay)
            }
            if let limits {
                TimelineView(.everyMinute) { context in
                    if let age = LimitsText.staleness(updatedAt: limits.updatedAt, now: context.date) {
                        Text(verbatim: "额度更新于 \(age)")
                            .font(.nunito(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .padding(.leading, 4)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }
}

/// One window: its name, the share used in pixel digits, a meter of ten cells and when it resets.
private struct LimitCard: View {
    let title: String
    let window: RateWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(.nunito(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text.percent(LimitsText.percent(window), digits: .silkscreen(size: 22), signSize: 17)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            SegmentMeter(fraction: window.map { $0.usedPercentage / 100 }, segments: 10)
                .padding(.top, 8)
            TimelineView(.everyMinute) { context in
                Text(verbatim: LimitsText.resets(window, now: context.date, calendar: .autoupdatingCurrent))
                    .font(.nunito(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 4, lipHeight: 4)
        .accessibilityElement(children: .combine)
    }
}
