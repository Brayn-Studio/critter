import CritterClient
import SwiftUI

/// The questions of an `AskUserQuestion` request (visual design §8.6, Android `QuestionBody`): per question a small
/// topic tag and the question, option cards (a dot to choose one, a square to choose several; chosen, pale purple
/// with a purple edge) and the dashed 「自己写一句…」. A lone single-select question is answered by tapping an option;
/// anything else has the button 「提交 n 个回答」.
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
            // The sheet's own scroll view takes them when they do not fit: the own answer's field stays one field.
            questionList
            FailureLine(text: failure)
            if let doneLabel {
                DoneButton(label: doneLabel)
            } else if !instant || choices.isTypingAny {
                PixelButton(title: "提交 \(questions.count) 个回答", size: .large, wide: true, action: onSubmit)
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

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions.indices, id: \.self) { index in
                questionView(questions[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - A question

    private func questionView(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let header = question.header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TopicChip(text: header)
                }
                Text(verbatim: question.text)
                    .font(.nunito(size: 15, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiSelect {
                    Text("可多选")
                        .font(.nunito(size: 11.5, weight: .bold))
                        .foregroundStyle(Theme.ink2)
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
        let description = option.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return OptionCard(
            title: option.label, detail: description, selected: choices.isPicked(question, option),
            multi: question.multiSelect
        ) {
            guard enabled else { return }
            choices.select(question, option, in: draft)
            if instant { onSubmit() }
        }
        .disabled(!enabled)
    }

    /// 「自己写一句…」, which turns into a field.
    @ViewBuilder
    private func ownAnswer(_ question: Question) -> some View {
        if choices.isTyping(question) {
            PixelTextField("自己写一句", text: typedBinding(question), maxLines: 3)
                .focused($focused, equals: question.text)
                .disabled(!enabled)
        } else {
            WriteOwnCard(text: "自己写一句…") {
                guard enabled else { return }
                choices.startTyping(question)
                focused = question.text
            }
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
