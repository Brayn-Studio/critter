import SwiftUI

/// Children side by side, sharing the width by `weights` after the `spacing` between them (CSS grid's
/// `1fr 1.4fr`): 「拒绝」 and the wider 「允许」. As tall as the tallest child; a missing weight counts as 1.
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(total: proposal.width, count: subviews.count)
        let height = subviews.indices.map { i in
            subviews[i].sizeThatFits(ProposedViewSize(width: widths?[i], height: proposal.height)).height
        }.max() ?? 0
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let widths = widths(total: bounds.width, count: subviews.count) else { return }
        var x = bounds.minX
        for (i, view) in subviews.enumerated() {
            view.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: widths[i], height: bounds.height)
            )
            x += widths[i] + spacing
        }
    }

    private func weight(_ i: Int) -> CGFloat {
        i < weights.count ? weights[i] : 1
    }

    /// Each child's width in whole points (the last takes what rounding leaves), nil without a width to share.
    private func widths(total: CGFloat?, count: Int) -> [CGFloat]? {
        guard let total, count > 0 else { return nil }
        let room = max(total - spacing * CGFloat(count - 1), 0)
        let sum = (0..<count).map(weight).reduce(0, +)
        var widths = (0..<count).map { (room * weight($0) / max(sum, 0.001)).rounded() }
        widths[count - 1] = room - widths.dropLast().reduce(0, +)
        return widths
    }
}
