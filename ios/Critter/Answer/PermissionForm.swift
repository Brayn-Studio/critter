import CritterClient
import CritterKit
import SwiftUI

/// A permission request (visual design §8.6, the mockups' "权限"): the command or path on a dark slip, all of it, up
/// to about eight lines and then it scrolls; 「拒绝并写理由…」 (not for Codex approvals, which take only a decision),
/// which opens a field under the slip; 「拒绝」 on the left and the wider 「允许」 on the right.
struct PermissionForm: View {
    let request: BridgePending
    let enabled: Bool
    let failure: String?
    let doneLabel: String?
    /// The reason typed, when there is one and the request takes it.
    let onDeny: (String?) -> Void
    let onAllow: () -> Void

    @State private var writingReason = false
    @State private var reason = ""

    var body: some View {
        let canExplain = RequestText.acceptsDenyMessage(request.input)
        let showingReason = writingReason && canExplain
        VStack(alignment: .leading, spacing: 12) {
            if let command = RequestText.permissionBody(request.input) {
                CommandSlip(text: command, maxLines: 8, scrolls: true)
            }
            if showingReason {
                PixelTextField("拒绝的理由（可不写）", text: $reason, maxLines: 3)
                    .disabled(!enabled)
            } else if canExplain {
                PixelButton(title: "拒绝并写理由…", style: .text) { writingReason = true }
                    .disabled(!enabled)
            }
            FailureLine(text: failure)
            // With a reason the deny button says so, and needs the room: the two share the row evenly then.
            WeightedRow(weights: [1, showingReason ? 1 : 1.4]) {
                PixelButton(
                    title: showingReason ? "拒绝并发送理由" : "拒绝", style: .secondary, size: .large, wide: true
                ) {
                    onDeny(canExplain ? reason : nil)
                }
                .disabled(!enabled || doneLabel != nil)
                PrimaryAnswerButton(title: "允许", doneLabel: doneLabel, enabled: enabled, action: onAllow)
            }
        }
    }
}
