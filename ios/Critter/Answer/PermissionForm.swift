import CritterClient
import CritterKit
import SwiftUI

/// A permission request: the command or path, 「拒绝并写理由…」 (not for Codex approvals, which take only a decision),
/// 「拒绝」 and 「允许」.
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
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let canExplain = RequestText.acceptsDenyMessage(request.input)
        let showingReason = writingReason && canExplain
        VStack(alignment: .leading, spacing: 12) {
            if let command = RequestText.permissionBody(request.input) {
                CommandSlip(text: command, scrolls: true)
            }
            if showingReason {
                TextField("拒绝的理由（可不写）", text: $reason, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($reasonFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!enabled)
            } else if canExplain {
                Button("拒绝并写理由…") {
                    writingReason = true
                    reasonFocused = true
                }
                .disabled(!enabled)
            }
            FailureLine(text: failure)
            HStack(spacing: 10) {
                Button { onDeny(canExplain ? reason : nil) } label: {
                    Text(showingReason ? "拒绝并发送理由" : "拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!enabled)
                PrimaryAnswerButton(title: "允许", doneLabel: doneLabel, enabled: enabled, action: onAllow)
            }
        }
    }
}
