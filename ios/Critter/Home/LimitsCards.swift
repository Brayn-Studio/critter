import CritterClient
import CritterKit
import SwiftUI

/// The two quota windows side by side, and how old the numbers are once they are not fresh.
struct LimitsCards: View {
    let limits: BridgeLimits?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                LimitCard(name: "5 小时", window: limits?.fiveHour, now: now)
                LimitCard(name: "7 天", window: limits?.sevenDay, now: now)
            }
            if let limits, let age = LimitsText.staleness(updatedAt: limits.updatedAt, now: now) {
                Text(verbatim: "额度更新于 \(age)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

private struct LimitCard: View {
    let name: String
    let window: RateWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(verbatim: LimitsText.percent(window))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
            }
            UsageBar(percent: window?.usedPercentage ?? 0, height: 8)
            Text(verbatim: LimitsText.resets(window, now: now, calendar: .current))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A used-share bar: green below 60 %, yellow to 85 %, red above.
struct UsageBar: View {
    /// 0...100; anything else is held to that.
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        let share = percent.isNaN ? 0 : min(max(percent, 0), 100) / 100
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * share)
                }
            }
            .accessibilityHidden(true)
    }

    private var tint: Color {
        percent < 60 ? .green : percent < 85 ? .yellow : .red
    }
}
