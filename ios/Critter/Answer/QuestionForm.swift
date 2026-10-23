import CritterClient
import SwiftUI

/// The questions of an `AskUserQuestion` request (Android `QuestionBody`): per question a small topic tag and the
/// question, option cards (a dot to choose one, a square to choose several) and 「自己写一句…」. A lone single-select
/// question is answered by tapping an option; anything else has the button 「提交 n 个回答」.
///
/// What is chosen lives in the draft (it knows what the Mac accepts) and, as it is shown, in `choices`, which belongs
/// to the draft and not to this view: when the card is closed and opened again it shows what the draft holds, and
/// when the draft is replaced after a failed attempt the choices are put into the new one.
struct QuestionForm: View {
    let questions: [Question]
    let draft: AnswerDraft
    let choices: QuestionChoices
    let enabled: Bool
    let failure: String?
    let doneLabel: String?
    let onSubmit: () -> Void

    @FocusState private var focused: String?

    private var instant: Bool {
        RequestText.submitsOnPick(questions)
    }

    var body: some View {
        let ready = choices.revision >= 0 && draft.payload() != nil
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(questions.indices, id: \.self) { index in
                        questionView(questions[index])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            FailureLine(text: failure)
            if let doneLabel {
                DoneButton(label: doneLabel)
            } else if !instant || choices.isTypingAny {
                Button(action: onSubmit) {
                    Text(verbatim: "提交 \(questions.count) 个回答").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(enabled && ready))
            }
        }
        #if DEBUG
        .task {
            guard DebugLaunch.current.autoSubmit == .firstOption else { return }
            // One second after the card is up: the first option of every question, then the same as the button.
            try? await Task.sleep(for: .seconds(1))
            for question in questions {
                if let option = question.options.first { choices.select(question, option, in: draft) }
            }
            onSubmit()
        }
        .task {
            guard DebugLaunch.current.autoPick == .firstOption, !DebugLaunch.autoPickDone else { return }
            try? await Task.sleep(for: .seconds(1))
            // Once per run: a card that is opened again must show what the app kept, not a new pick.
            guard !DebugLaunch.autoPickDone, let question = questions.first, let option = question.options.first else { return }
            DebugLaunch.autoPickDone = true
            choices.select(question, option, in: draft)
        }
        #endif
    }

    // MARK: - A question

    private func questionView(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let header = question.header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(verbatim: header)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }
                Text(verbatim: question.text)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if question.multiSelect {
                    Text("可多选")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            ForEach(question.options.indices, id: \.self) { index in
                optionCard(question, question.options[index])
            }
            ownAnswer(question)
        }
    }

    private func optionCard(_ question: Question, _ option: QuestionOption) -> some View {
        let selected = choices.isPicked(question, option)
        let multi = question.multiSelect
        let description = option.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return Button {
            guard enabled else { return }
            choices.select(question, option, in: draft)
            if instant { onSubmit() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: marker(selected: selected, multi: multi))
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description {
                        Text(verbatim: description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func marker(selected: Bool, multi: Bool) -> String {
        switch (multi, selected) {
        case (false, false): "circle"
        case (false, true): "circle.inset.filled"
        case (true, false): "square"
        case (true, true): "checkmark.square.fill"
        }
    }

    /// 「自己写一句…」, which turns into a field.
    @ViewBuilder
    private func ownAnswer(_ question: Question) -> some View {
        if choices.isTyping(question) {
            TextField("自己写一句", text: typedBinding(question), axis: .vertical)
                .lineLimit(1...3)
                .focused($focused, equals: question.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!enabled)
        } else {
            Button {
                guard enabled else { return }
                choices.startTyping(question)
                focused = question.text
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                    Text("自己写一句…")
                    Spacer(minLength: 0)
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.5)
        }
    }

    // MARK: - Choosing

    private func typedBinding(_ question: Question) -> Binding<String> {
        Binding(
            get: { choices.typedText(question) },
            set: { choices.type($0, for: question, in: draft) }
        )
    }
}
