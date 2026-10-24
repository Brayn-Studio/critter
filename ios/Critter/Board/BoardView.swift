import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The landscape board (spec §8.6, visual design §8.7, Android `BoardActivity`), over the home screen as a
/// `fullScreenCover`: black, the status bar and the home indicator hidden, locked to landscape while it is up. Two
/// modes, remembered (`PhoneSettings.boardCritterMode`): the Critters (`CritterBoard`) or the pro dashboard
/// (`ProBoard`), switched by the button at the top right; under it, the button that closes the board.
///
/// While it is up the connection pings every 30 s (`BridgeStore.boardOpen`); the screen stays on at the board's
/// brightness and dims once nothing has happened for 15 minutes (`BoardScreenKeeper`); the whole picture moves by a few
/// points every 3 minutes so nothing burns in; and with 「看板提示音」 on, a session that just started waiting, finished
/// or failed plays its sound (`BoardSounds`). Going to the background gives the screen back, coming back takes it
/// again; every other way out is the closer's to report (`BoardScreenKeeper.leave`). A request is answered on the
/// answer card, over the board and in landscape.
///
/// The content uses the whole height, and keeps clear of the Dynamic Island on the side it is on in landscape, but not
/// of the whole of the sides' safe area (62 pt on each side of an iPhone 17 Pro): the island reaches 49 pt in from the
/// edge, and the board needs the width (the mockups' board is 800 pt wide).
struct BoardView: View {
    let store: BridgeStore
    let drafts: AnswerDrafts
    /// What became of each card's 「拒绝」「允许」, by request id (the home list's).
    let inline: [String: InlineAnswerState]
    let screen: BoardScreenKeeper
    /// The request whose answer card is open over the board: the home screen keeps it, so what became of its answer
    /// is kept for it as for its own card.
    @Binding var presentedRequestId: String?
    /// 「拒绝」「允许」 on a pro card: the same path as the home list's.
    let onAnswer: (RowRequest, Bool) -> Void
    /// The close button.
    let onClose: () -> Void

    @Environment(PhoneSettings.self) private var settings
    @Environment(SkinStore.self) private var skins
    @Environment(BoardAutoOpen.self) private var autoOpen
    @Environment(\.scenePhase) private var scenePhase
    @State private var sounds = BoardSounds()
    /// The burn-in shift, re-rolled every 3 minutes while the app is in front.
    @State private var shift = CGSize.zero
    /// The window's safe area on its wider side (62 pt on an iPhone 17 Pro in landscape).
    @State private var safeSide: CGFloat = 0

    private struct Target: Identifiable {
        let id: String
    }

    /// How far in from each side the content keeps, at most (the safe area's side, when it is narrower).
    private static let sideInset: CGFloat = 50

    var body: some View {
        let data = BoardData(snapshot: store.snapshot, connected: store.conn.isConnected, updatedAt: store.snapshotAt)
        ZStack(alignment: .topTrailing) {
            content(data)
                .offset(shift)
            buttons
                .padding(.top, 18)
                .padding(.trailing, 20)
        }
        .padding(.horizontal, min(safeSide, Self.sideInset))
        .background(Theme.Board.bg)
        .ignoresSafeArea()
        // The board is always dark (design §5), whatever the phone's appearance; the answer card is not.
        .environment(\.colorScheme, .dark)
        .background {
            TouchWatch { screen.touched() }
            SafeAreaReader { insets in safeSide = max(insets.left, insets.right) }
        }
        .sheetShell(item: answerTarget) { target in
            AnswerSheet(requestId: target.id, store: store, drafts: drafts, inline: inline[target.id] ?? .idle)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: screen.leave(.background)
            case .active: screen.enter(base: settings.boardBrightness)
            default: break
            }
        }
        .onChange(of: settings.boardBrightness) { _, brightness in
            screen.setBase(brightness)
        }
        .onChange(of: Self.signature(store.snapshot)) {
            // A change on the Mac counts as activity: the board stays bright while something is happening.
            screen.changed()
        }
        .onChange(of: store.snapshot) {
            sounds.update(store.snapshot, live: store.isLive, enabled: settings.boardSounds)
        }
        .onChange(of: store.isLive) {
            sounds.update(store.snapshot, live: store.isLive, enabled: settings.boardSounds)
        }
        .task(id: scenePhase == .active) {
            await rollShift()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            screen.leave(.terminated)
        }
        #if DEBUG
        .task {
            // `-critterBoard` with `-critterOpen answer:…` or `-critterBoardAnswer`, once the snapshot is in.
            let launch = DebugLaunch.current
            guard launch.board != nil else { return }
            for _ in 0..<20 where store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            if case .answer(let requestId)? = launch.open { presentedRequestId = requestId }
            guard let allow = launch.boardAnswer,
                  let row = RowRequest.all(in: store.snapshot).values.first(where: \.isInline)
            else { return }
            boardLog("answer \(row.request.requestId) on its card (\(allow ? "允许" : "拒绝")), then open the card")
            onAnswer(row, allow)
            presentedRequestId = row.request.requestId
        }
        #endif
    }

    @ViewBuilder
    private func content(_ data: BoardData) -> some View {
        if settings.boardCritterMode {
            CritterBoard(data: data, skins: skins.library, dim: skins.idleDim, onTap: tap)
        } else {
            ProBoard(
                data: data, skins: skins.library, dim: skins.idleDim, canAct: store.canAct, answers: inline,
                onAnswer: { card, allow in
                    let row = RowRequest(request: card.request, what: card.what, command: card.detail, more: card.more)
                    onAnswer(row, allow)
                },
                onOpen: { presentedRequestId = $0 }
            )
        }
    }

    /// The mode switch (the icon is the mode it switches to) and, under it, the close button.
    private var buttons: some View {
        VStack(spacing: 4) {
            BoardIconButton(
                icon: settings.boardCritterMode ? .grid : .paw,
                label: settings.boardCritterMode ? "切换到专业模式" : "切换到宠物模式"
            ) {
                settings.boardCritterMode.toggle()
            }
            BoardIconButton(icon: .close, label: "关闭看板", action: onClose)
        }
    }

    private var answerTarget: Binding<Target?> {
        Binding(get: { presentedRequestId.map(Target.init) }, set: { presentedRequestId = $0?.id })
    }

    /// A tap on a Critter: one with a request the phone can answer opens its card (the oldest request); any other was
    /// only booped.
    private func tap(_ sessionId: String) {
        guard let request = RowRequest.all(in: store.snapshot)[sessionId] else { return }
        presentedRequestId = request.request.requestId
    }

    private func appeared() {
        OrientationLock.shared.lock(.landscape)
        store.boardOpen = true
        autoOpen.boardShown(true)
        screen.enter(base: settings.boardBrightness)
        // The snapshot already on screen is not news: no sound for it.
        sounds.update(store.snapshot, live: store.isLive, enabled: settings.boardSounds)
    }

    private func disappeared() {
        store.boardOpen = false
        autoOpen.boardShown(false)
        presentedRequestId = nil
        sounds.stop()
        // Whoever closed the board said why; this only catches a way out that did not.
        screen.leave(.closeButton)
        OrientationLock.shared.lock(.portrait)
    }

    /// Every 3 minutes of the clock, the whole board moves to a new spot within 4 pt each way (no animation).
    private func rollShift() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            let next = ((now / BoardScreen.shiftEvery).rounded(.down) + 1) * BoardScreen.shiftEvery
            try? await Task.sleep(for: .seconds(next - now))
            guard !Task.isCancelled else { return }
            shift = BoardScreen.shift(seed: BoardScreen.shiftSeed(at: Date()))
        }
    }

    /// What the board shows that counts as something happening: each session's state and the open requests.
    private static func signature(_ body: SnapshotBody?) -> [String] {
        guard let body else { return [] }
        return body.sessions.map { "\($0.id):\($0.state.rawValue)" } + body.pending.map(\.requestId)
    }
}
