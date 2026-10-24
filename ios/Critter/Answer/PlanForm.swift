import CritterClient
import CritterKit
import SwiftUI

/// A plan (visual design §8.6, the mockups' "计划"): its text on a recessed sheet of paper that scrolls, its bottom
/// fading out while there is more below; 「让它改…」, which shortens the paper and opens a field for what to change
/// (the button then says 「发回去」), and 「批准计划」.
struct PlanForm: View {
    let request: BridgePending
    let enabled: Bool
    let failure: String?
    let doneLabel: String?
    let onRevise: (String) -> Void
    let onApprove: () -> Void

    @State private var revising = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Writing a change, the paper gets shorter to make room for the field (and the keyboard).
            PlanPaper(plan: RequestText.planText(request.input), maxHeight: revising ? 200 : 356)
            if revising {
                PixelTextField("想让它怎么改", text: $note, maxLines: 4)
                    .disabled(!enabled)
            }
            FailureLine(text: failure)
            WeightedRow(weights: [1, 1.4]) {
                PixelButton(title: revising ? "发回去" : "让它改…", style: .secondary, size: .large, wide: true) {
                    if revising { onRevise(note) } else { revising = true }
                }
                .disabled(
                    !enabled || doneLabel != nil
                        || (revising && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                PrimaryAnswerButton(title: "批准计划", doneLabel: doneLabel, enabled: enabled, action: onApprove)
            }
        }
    }
}

/// The plan on recessed paper (its dark row on top), as tall as the text up to `maxHeight`, then it scrolls; while
/// there is more below, the bottom 46 pt fade into the paper.
private struct PlanPaper: View {
    let plan: String
    let maxHeight: CGFloat

    @State private var textHeight: CGFloat = 0
    /// How far the text has scrolled up.
    @State private var scrolled: CGFloat = 0

    private static let fade: CGFloat = 46

    var body: some View {
        let height = min(textHeight, maxHeight)
        ScrollView {
            MarkdownBlocks(markdown: plan)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                    textHeight = frame.height
                    scrolled = -frame.minY
                }
        }
        .coordinateSpace(.named(Self.space))
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(height, 1))
        .overlay(alignment: .bottom) {
            if textHeight - scrolled > height + 1 {
                LinearGradient(colors: [Theme.surface2.opacity(0), Theme.surface2], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
                    .allowsHitTesting(false)
            }
        }
        .pixelSurface(fill: Theme.surface2, lip: Theme.shade, step: 4, lipHeight: 3, inset: true)
    }

    private nonisolated static let space = "plan-paper"
}
