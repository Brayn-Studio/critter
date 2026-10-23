import SwiftUI

/// Why the answer did not get through, in red over the buttons; the card stays open.
struct FailureLine: View {
    let text: String?

    var body: some View {
        if let text {
            Text(verbatim: text)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color(.systemRed))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The primary button once the Mac took the answer: green, with the label ("已允许"). It takes no more taps.
struct DoneButton: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
            Text(verbatim: label)
        }
        .font(.headline)
        .foregroundStyle(Color.black.opacity(0.85))
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(Color(.systemGreen), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The card's primary button, or the green `DoneButton` in its place once `doneLabel` is set.
struct PrimaryAnswerButton: View {
    let title: String
    let doneLabel: String?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        if let doneLabel {
            DoneButton(label: doneLabel)
        } else {
            Button(action: action) {
                Text(verbatim: title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!enabled)
        }
    }
}
