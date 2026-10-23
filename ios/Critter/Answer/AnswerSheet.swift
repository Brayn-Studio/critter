import CritterClient
import CritterKit
import SwiftUI

/// The card for one pending request (Android `AnswerActivity` and `AnswerSheet`), a sheet over the home list. It is
/// opened with a request id only: the request is looked up in the latest snapshot every time, never taken from "the
/// session's current request" (`CardState`).
///
/// - A request that is no longer in the snapshot: "已在电脑上处理" (or, for one the card never saw in a live snapshot,
///   "这个请求已经不在了"), and the card closes after two seconds.
/// - What was sent: the primary button turns into the success label ("已允许") and the card closes after 0.9 s; a no
///   (a deny, a revise) closes it at once. Too late or answered on the Mac first: the words, then two seconds. Not
///   through: the text over the buttons, the card stays and the buttons work again (on a fresh draft).
struct AnswerSheet: View {
    let requestId: String
    let store: BridgeStore
    /// The drafts the home screen keeps: the rows' buttons and this card answer a request on the same one.
    let drafts: AnswerDrafts

    @Environment(\.dismiss) private var dismiss
    /// The request as it was the last time a live snapshot had it: whether the card ever saw it, and what to show
    /// while an answer is on its way and after it was taken, when the request has left the snapshot. A cached
    /// snapshot does not count: the request may have been gone for long, not just answered on the Mac.
    @State private var seen: Seen?
    @State private var busy = false
    @State private var failure: String?
    /// An answer the Mac took.
    @State private var sent: Seen.Sent?
    /// The Mac's word that nothing is left to answer, which the card shows before it closes.
    @State private var closing: String?
    /// Missing from a cached snapshot proves nothing: the live one gets a while to arrive.
    @State private var waitedOut = false
    @State private var detent: PresentationDetent

    /// A request the card has had in front of it.
    private struct Seen {
        let request: BridgePending
        let session: BridgeSession?

        struct Sent {
            let seen: Seen
            let label: String?
        }
    }

    init(requestId: String, store: BridgeStore, drafts: AnswerDrafts) {
        self.requestId = requestId
        self.store = store
        self.drafts = drafts
        // A permission request is short, and so is what a request that is gone says; a question or a plan wants
        // the room.
        let kind = store.snapshot?.pending.first { $0.requestId == requestId }?.kind
        _detent = State(initialValue: kind == nil || kind == .permission ? .medium : .large)
    }

    private var cardState: CardState {
        CardState(requestId: requestId, snapshot: store.snapshot, everSeen: seen != nil)
    }

    private var waitingForLive: Bool {
        seen == nil && !store.isLive && !waitedOut
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .onChange(of: store.snapshot, initial: true) { noteSeen() }
            // The first live snapshot can be the cached one over again: going live counts too.
            .onChange(of: store.isLive) { noteSeen() }
            .task(id: requestId) {
                try? await Task.sleep(for: .seconds(8))
                waitedOut = true
            }
            .task(id: autoClose) {
                guard let delay = autoClose else { return }
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { dismiss() }
            }
            #if DEBUG
            .task(id: requestId) {
                guard let mode = DebugLaunch.current.autoSubmit, mode != .firstOption else { return }
                // One second after the card is up: the same as tapping the primary button.
                try? await Task.sleep(for: .seconds(1))
                guard case .open(let request) = cardState else { return }
                let draft = drafts.draft(for: request)
                switch (mode, request.kind) {
                case (.allow, .permission): draft.allow()
                case (.approve, .plan): draft.approve()
                default: return
                }
                submit(draft, request: request, session: session(of: request))
            }
            #endif
    }

    /// When the card closes by itself, counted from when what it shows is settled.
    private var autoClose: Duration? {
        if closing != nil { return .seconds(2) }
        if let sent { return sent.label == nil ? .zero : .milliseconds(900) }
        if busy { return nil }
        switch cardState {
        case .open: return nil
        case .handledElsewhere: return .seconds(2)
        case .unknown: return waitingForLive ? nil : .seconds(2)
        }
    }

    // MARK: - What the card shows

    /// What the card is showing a form for: the request as it was, while an answer is on its way and after the Mac
    /// took it (the request may have left the snapshot by then), otherwise the request in the snapshot. The form is
    /// built in one place, so what is chosen or typed in it survives the switch between these.
    private var shownRequest: Seen? {
        if let sent { return sent.seen }
        if busy, let seen { return seen }
        if case .open(let request) = cardState { return Seen(request: request, session: session(of: request)) }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if let closing {
            ClosingCard(text: closing, done: closing == Self.handledText)
        } else if let shown = shownRequest {
            form(shown, doneLabel: sent?.label)
        } else if case .handledElsewhere = cardState {
            ClosingCard(text: Self.handledText, done: true)
        } else if waitingForLive {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在连接电脑…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ClosingCard(text: "这个请求已经不在了", done: false)
        }
    }

    private static let handledText = "已在电脑上处理"

    /// Remembers the request as the snapshot has it, if the snapshot is live.
    private func noteSeen() {
        guard store.isLive, let body = store.snapshot,
              let request = body.pending.first(where: { $0.requestId == requestId })
        else { return }
        seen = Seen(request: request, session: body.sessions.first { $0.id == request.sessionId })
    }

    private func session(of request: BridgePending) -> BridgeSession? {
        store.snapshot?.sessions.first { $0.id == request.sessionId } ?? seen?.session
    }

    private func form(_ shown: Seen, doneLabel: String?) -> some View {
        let request = shown.request
        let draft = drafts.draft(for: request)
        let answering = sent == nil
        let enabled = store.canAct && !busy && answering
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: RequestText.title(request, session: shown.session))
                    .font(.title3.bold())
                    .lineLimit(3)
                if let session = shown.session {
                    Text(verbatim: SessionText.place(session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !store.canAct && answering {
                Text("未连接，连上后才能作答")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color(.systemRed))
            }
            switch request.kind {
            case .permission:
                PermissionForm(
                    request: request, enabled: enabled, failure: failure, doneLabel: doneLabel,
                    onDeny: { reason in
                        draft.deny(message: reason)
                        submit(draft, request: request, session: shown.session)
                    },
                    onAllow: {
                        draft.allow()
                        submit(draft, request: request, session: shown.session)
                    }
                )
            case .question:
                QuestionForm(
                    questions: RequestText.questions(request.input), draft: draft,
                    choices: drafts.choices(for: request.requestId), enabled: enabled,
                    failure: failure, doneLabel: doneLabel,
                    onSubmit: { submit(draft, request: request, session: shown.session) }
                )
            case .plan:
                PlanForm(
                    request: request, enabled: enabled, failure: failure, doneLabel: doneLabel,
                    onRevise: { note in
                        draft.revise(message: note)
                        submit(draft, request: request, session: shown.session)
                    },
                    onApprove: {
                        draft.approve()
                        submit(draft, request: request, session: shown.session)
                    }
                )
            }
            Label("电脑上也能答，谁先答算谁的", systemImage: "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Sending

    /// Sends `draft` (complete: the buttons that call this have just filled it in) and acts on the Mac's receipt.
    private func submit(_ draft: AnswerDraft, request: BridgePending, session: BridgeSession?) {
        guard !busy, sent == nil else { return }
        let label = draft.payload().flatMap(successLabel)
        busy = true
        failure = nil
        Task {
            let outcome = await AnswerSubmit.submit(draft: draft, store: store)
            busy = false
            guard let outcome else { return }
            switch outcome {
            case .sent:
                sent = Seen.Sent(seen: Seen(request: request, session: session), label: label)
            case .handledElsewhere:
                closing = Self.handledText
            case .expired(let message):
                closing = message
            case .failed(let message):
                failure = message
                // This draft counts as submitted: a fresh one lets the user try again.
                drafts.renew(request.requestId)
            }
        }
    }
}

/// "已在电脑上处理" and the like: what is left to say once there is nothing to answer.
private struct ClosingCard: View {
    let text: String
    /// Whether it is good news (answered on the Mac), rather than a loss.
    let done: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: done ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(done ? Color(.systemGreen) : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
