import CritterClient
import CritterKit
import SwiftUI

/// The card for one pending request (visual design §8.6, Android `AnswerActivity` and `AnswerSheet`), the content of
/// a `sheetShell` over the home screen. It is opened with a request id only: the request is looked up in the latest
/// snapshot every time, never taken from "the session's current request" (`CardState`).
///
/// On top the session's Critter raising its hand on a tile of grass (it looks up at you once the sheet has settled),
/// who wants what and where; then what is asked, the buttons, and "电脑上也能答，谁先答算谁的".
///
/// - What was sent (visual design §7): a yes turns the primary button green in three jumps, "✓ 已允许", the Critter
///   switches to done and plays its entrance, and the card closes after 0.9 s; a no (a deny, a revise) makes the
///   Critter notice and closes the card at once. Not through: the reason over the buttons, the card stays and the
///   buttons work again (on a fresh draft). Offline: "未连接，连上后才能作答" under the header, the buttons grey.
/// - A request that is no longer there: answered on the Mac first, the Critter in bloom and "已在电脑上处理"; too
///   late, "已经过期了"; one the card never saw in a live snapshot, "这个请求已经不在了". Each closes after two seconds.
/// - Answered from the home card's 「拒绝」「允许」 (`inline`): while that is on its way the card says "正在提交…" and
///   its buttons wait; once it landed the card says "已提交" (it was this phone, not the Mac).
struct AnswerSheet: View {
    let requestId: String
    let store: BridgeStore
    /// The drafts the home screen keeps: the cards' buttons and this card answer a request on the same one.
    let drafts: AnswerDrafts
    /// What became of the home card's 「拒绝」「允许」 for this request.
    var inline: InlineAnswerState = .idle

    @Environment(\.closeSheet) private var closeSheet
    @Environment(SkinStore.self) private var skins
    /// The request as it was the last time a live snapshot had it: whether the card ever saw it, and what to show
    /// while an answer is on its way and after it was taken, when the request has left the snapshot. A cached
    /// snapshot does not count: the request may have been gone for long, not just answered on the Mac.
    @State private var seen: Seen?
    @State private var busy = false
    @State private var failure: String?
    /// An answer the Mac took.
    @State private var sent: Seen.Sent?
    /// The Mac's word that nothing is left to answer: answered elsewhere, or expired (its words).
    @State private var closing: Closing?
    /// Missing from a cached snapshot proves nothing: the live one gets a while to arrive.
    @State private var waitedOut = false
    @State private var stage = CritterStageControl()

    /// A request the card has had in front of it.
    private struct Seen {
        let request: BridgePending
        let session: BridgeSession?

        struct Sent {
            let seen: Seen
            let label: String?
        }
    }

    private enum Closing: Equatable {
        case handledElsewhere
        case expired(String)
    }

    private var cardState: CardState {
        CardState(requestId: requestId, snapshot: store.snapshot, everSeen: seen != nil)
    }

    private var waitingForLive: Bool {
        seen == nil && !store.isLive && !waitedOut
    }

    private var inlineSending: Bool {
        inline == .sending
    }

    /// Why the home card's answer did not get through: the card's buttons work again.
    private var inlineFailure: String? {
        if case .failed(let text) = inline { text } else { nil }
    }

    var body: some View {
        content
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
                if !Task.isCancelled { closeSheet() }
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
        if settledCard != nil { return .seconds(2) }
        if let sent { return sent.label == nil ? .zero : .milliseconds(900) }
        return nil
    }

    // MARK: - What the card shows

    /// What the card is showing a form for: the request as it was, while an answer is on its way and after the Mac
    /// took it (the request may have left the snapshot by then), otherwise the request in the snapshot. The form is
    /// built in one place, so what is chosen or typed in it survives the switch between these.
    private var shownRequest: Seen? {
        if let sent { return sent.seen }
        if busy || inlineSending, let seen { return seen }
        if case .open(let request) = cardState { return Seen(request: request, session: session(of: request)) }
        return nil
    }

    /// Nothing is left to answer, and what to say about it: the title, the line under it, whether it is good news.
    private var settledCard: (title: String, text: String?, bloom: Bool)? {
        if sent != nil || busy { return nil }
        switch closing {
        case .expired(let message)?: return ("已经过期了", message, false)
        case .handledElsewhere?: return Self.handled(seen?.session)
        case nil: break
        }
        switch inline {
        case .sent: return ("已提交", "这个请求已经在这台手机上答过了。", true)
        case .closed(let text) where text == Theme.handledElsewhere: return Self.handled(seen?.session)
        case .closed(let text): return ("已经过期了", text, false)
        case .sending: return nil
        case .idle, .failed: break
        }
        if shownRequest != nil { return nil }
        switch cardState {
        case .open: return nil
        case .handledElsewhere: return Self.handled(seen?.session)
        case .unknown: return waitingForLive ? nil : ("这个请求已经不在了", nil, false)
        }
    }

    private static func handled(_ session: BridgeSession?) -> (title: String, text: String?, bloom: Bool) {
        let text = session.map { "\($0.name) 的这个请求已经在电脑上处理了。" } ?? "这个请求已经在电脑上处理了。"
        return (Theme.handledElsewhere, text, true)
    }

    @ViewBuilder
    private var content: some View {
        if let card = settledCard {
            SettledCard(
                title: card.title, text: card.text, manifest: skins.library.manifest(seen?.session?.skin ?? ""),
                bloom: card.bloom
            )
        } else if let shown = shownRequest {
            form(shown, doneLabel: sent?.label)
        } else {
            SheetMessage(text: "正在连接电脑…")
        }
    }

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
        let enabled = store.canAct && !busy && !inlineSending && answering
        let failure = failure ?? inlineFailure
        return VStack(alignment: .leading, spacing: 12) {
            SheetHeader(
                manifest: skins.library.manifest(shown.session?.skin ?? ""),
                state: doneLabel != nil ? .done : .waiting, activity: shown.session?.activity,
                title: RequestText.title(request, session: shown.session), session: shown.session, control: stage
            )
            if !store.canAct && answering {
                FailureLine(text: "未连接，连上后才能作答")
            }
            if inlineSending {
                FailureLine(text: "正在提交…", tone: Theme.ink2)
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
            AnswerFooter()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    // MARK: - Sending

    /// Sends `draft` (complete: the buttons that call this have just filled it in) and acts on the Mac's receipt.
    private func submit(_ draft: AnswerDraft, request: BridgePending, session: BridgeSession?) {
        guard !busy, !inlineSending, sent == nil else { return }
        let label = draft.payload().flatMap(successLabel)
        busy = true
        failure = nil
        Task {
            let outcome = await AnswerSubmit.submit(draft: draft, store: store)
            busy = false
            guard let outcome else { return }
            switch outcome {
            case .sent:
                // A no: the Critter notices, and the card goes at once.
                if label == nil { stage.notice(LonePet.petId) }
                sent = Seen.Sent(seen: Seen(request: request, session: session), label: label)
            case .handledElsewhere:
                closing = .handledElsewhere
            case .expired(let message):
                closing = .expired(message)
            case .failed(let message):
                failure = message
                // This draft counts as submitted: a fresh one lets the user try again.
                drafts.renew(request.requestId)
            }
        }
    }
}
