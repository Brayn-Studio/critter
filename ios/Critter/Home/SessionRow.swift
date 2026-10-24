import CritterClient
import CritterKit
import SwiftUI

/// What a row with a lone permission request shows once its buttons were used.
enum InlineAnswerState: Equatable {
    case idle
    case sending
    /// The Mac took it; the text is the success label ("已允许"), nil for a no.
    case sent(String?)
    /// The request is closed: answered on the Mac, or too late; the text says which.
    case closed(String)
    /// It did not get through; the buttons work again.
    case failed(String)
}

/// One session on the home list: its state, what it is doing, where it runs and how full its context is. With a
/// request it has an orange edge, and under it the command with 「拒绝」「允许」 (a lone permission request) or
/// 「打开回答」.
struct SessionRow: View {
    let session: BridgeSession
    let request: RowRequest?
    /// Whether the Mac can be told something now (`BridgeStore.canAct`).
    let canAct: Bool
    let answer: InlineAnswerState
    let onOpen: () -> Void
    let onOpenRequest: () -> Void
    let onAnswer: (_ allow: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: session.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StateChip(state: session.state)
            }
            Text(verbatim: request?.what ?? SessionText.doing(session))
                .font(.subheadline.weight(request == nil ? .regular : .semibold))
                .lineLimit(1)
            Text(verbatim: SessionText.place(session))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let request {
                ask(request)
                    .padding(.top, 4)
            }
            if let hint = SessionText.waitingHint(session, hasActionableRequest: request != nil) {
                Text(verbatim: hint)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if let context = session.context {
                HStack(spacing: 8) {
                    Text("上下文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    UsageBar(percent: context.usedPercent)
                    Text(verbatim: SessionText.contextPercent(context))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if request != nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 2.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private func ask(_ request: RowRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = request.command {
                CommandSlip(command: command)
            }
            if request.isInline {
                inlineButtons
            } else {
                Button(action: onOpenRequest) {
                    Text("打开回答").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var inlineButtons: some View {
        let enabled = canAct && (answer == .idle || isFailed)
        VStack(spacing: 6) {
            if let line = statusLine {
                Text(verbatim: line.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(line.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button { onAnswer(false) } label: {
                    Text("拒绝").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { onAnswer(true) } label: {
                    Text("允许").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(!enabled)
            if !canAct {
                Text("连上后才能作答")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = answer { true } else { false }
    }

    private var statusLine: (text: String, color: Color)? {
        switch answer {
        case .idle, .sending: nil
        case .sent(let label): label.map { ($0, Color(.systemGreen)) }
        case .closed(let text): (text, Color.secondary)
        case .failed(let text): (text, Color(.systemRed))
        }
    }
}

/// A state's name on a pill, with a dot in the state's color.
struct StateChip: View {
    let state: PetState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.tint)
                .frame(width: 7, height: 7)
            Text(verbatim: state.label)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.16), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

extension PetState {
    /// The state's symbol colour (`Theme.state`).
    var tint: Color {
        Theme.state(self).glyph
    }
}
