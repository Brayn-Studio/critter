import CritterClient
import SwiftUI

/// The questions of an `AskUserQuestion` request (Android `QuestionBody`): per question a small topic tag and the
/// question, option cards (a dot to choose one, a square to choose several) and 「自己写一句…」. A lone single-select
/// question is answered by tapping an option; anything else has the button 「提交 n 个回答」.
///
/// What is chosen lives in the draft (it knows what the Mac accepts); the choices shown are kept here too, so that
/// when the draft is replaced after a failed attempt they are put into the new one and nothing has to be redone.
struct QuestionForm: View {
    let questions: [Question]
    let draft: AnswerDraft
    let enabled: Bool
    let failure: String?
    let doneLabel: String?
    let onSubmit: () -> Void

    /// The labels chosen per question, in the order tapped.
    @State private var picked: [String: [String]] = [:]
    /// The questions whose own answer is being written.
    @State private var typing: [String: Bool] = [:]
    @State private var typed: [String: String] = [:]
    /// Counts changes to the draft, which the view cannot see by itself.
    @State private var changes = 0
    @FocusState private var focused: String?

    private var instant: Bool {
        RequestText.submitsOnPick(questions)
    }

    var body: some View {
        let ready = changes >= 0 && draft.payload() != nil
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
            } else if !instant || typing.values.contains(true) {
                Button(action: onSubmit) {
                    Text(verbatim: "提交 \(questions.count) 个回答").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(enabled && ready))
            }
        }
        .onChange(of: ObjectIdentifier(draft)) { replay() }
        #if DEBUG
        .task {
            guard DebugLaunch.current.autoSubmit == .firstOption else { return }
            // One second after the card is up: the first option of every question, then the same as the button.
            try? await Task.sleep(for: .seconds(1))
            for question in questions {
                if let option = question.options.first { select(question, option) }
            }
            onSubmit()
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
        let selected = picked[question.text]?.contains(option.label) == true
        let multi = question.multiSelect
        let description = option.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return Button {
            guard enabled else { return }
            select(question, option)
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
        if typing[question.text] == true {
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
                typing[question.text] = true
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

    /// Chooses `option` (or, for several, adds it or takes it away), without sending anything.
    private func select(_ question: Question, _ option: QuestionOption) {
        typing[question.text] = false
        if question.multiSelect {
            draft.toggle(question: question.text, label: option.label)
            var labels = picked[question.text] ?? []
            if let at = labels.firstIndex(of: option.label) { labels.remove(at: at) } else { labels.append(option.label) }
            picked[question.text] = labels
        } else {
            draft.choose(question: question.text, label: option.label)
            picked[question.text] = [option.label]
        }
        changes += 1
    }

    private func typedBinding(_ question: Question) -> Binding<String> {
        Binding(
            get: { typed[question.text] ?? "" },
            set: { text in
                typed[question.text] = text
                draft.freeText(question: question.text, text: text)
                picked[question.text] = []
                changes += 1
            }
        )
    }

    /// Puts what is shown into the new draft that replaced the old one.
    private func replay() {
        for question in questions {
            if typing[question.text] == true, let text = typed[question.text], !text.isEmpty {
                draft.freeText(question: question.text, text: text)
            } else if question.multiSelect {
                for label in picked[question.text] ?? [] { draft.toggle(question: question.text, label: label) }
            } else if let label = picked[question.text]?.first {
                draft.choose(question: question.text, label: label)
            }
        }
        changes += 1
    }
}
