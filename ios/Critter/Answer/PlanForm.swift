import CritterClient
import CritterKit
import SwiftUI

/// A plan: its text as Markdown on a sheet of paper that scrolls, 「让它改…」 (which asks what to change) and
/// 「批准计划」.
struct PlanForm: View {
    let request: BridgePending
    let enabled: Bool
    let failure: String?
    let doneLabel: String?
    let onRevise: (String) -> Void
    let onApprove: () -> Void

    @State private var revising = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The paper is what scrolls: it is as tall as the plan, and the sheet scrolls it when that is too much.
            ScrollView {
                MarkdownBlocks(markdown: RequestText.planText(request.input))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(minHeight: 120)
            if revising {
                TextField("想让它怎么改", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($noteFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!enabled)
            }
            FailureLine(text: failure)
            HStack(spacing: 10) {
                Button {
                    if revising {
                        onRevise(note)
                    } else {
                        revising = true
                        noteFocused = true
                    }
                } label: {
                    Text(revising ? "发回去" : "让它改…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!enabled || (revising && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                PrimaryAnswerButton(title: "批准计划", doneLabel: doneLabel, enabled: enabled, action: onApprove)
            }
        }
    }
}
