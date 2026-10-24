import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The home screen (mockup "首页", Android `HomeScreen`): a meadow with every session's Critter under the sky, the
/// Mac's name and connection over it with the board and settings buttons; below it the limits and the session cards,
/// the ones that need you first. A lone permission request is answered right on its card; a question or a plan opens
/// the answer card; a card or a Critter without a request opens the details, and a finished session is marked seen
/// on the way. Offline it is night, the Critters sleep, a card says so and the numbers fade back.
struct HomeView: View {
    let store: BridgeStore
    /// 「重新配对」 in the settings: back to the pairing screen, keeping the pairing until the new one succeeds.
    let onPairAgain: () -> Void
    /// 「重新走一遍引导」 in the settings.
    let onGuide: () -> Void

    @Environment(PhoneSettings.self) private var settings
    @Environment(SkinStore.self) private var skins
    @Environment(BoardAutoOpen.self) private var autoOpen
    @Environment(NotificationRouter.self) private var router
    @Environment(\.reduceMotion) private var reduceMotion

    /// The answers being composed, shared by the cards' buttons and the answer card.
    @State private var drafts = AnswerDrafts()
    /// The request whose answer card is open.
    @State private var presentedRequestId: String?
    /// The request whose answer card is open over the board.
    @State private var boardRequestId: String?
    /// The session whose details are open.
    @State private var presentedSessionId: String?
    @State private var showSettings = false
    @State private var showBoard = false
    /// The screen as the board found it, given back on every way out.
    @State private var boardScreen = BoardScreenKeeper()
    /// What became of each card's 「拒绝」「允许」, by request id.
    @State private var inline: [String: InlineAnswerState] = [:]
    /// Offline once an attempt has failed, until connected again: a retry's brief "connecting" stays offline.
    @State private var lost = false
    /// A session target from a notification has waited `SheetTarget.liveWait` for a live snapshot.
    @State private var targetWaitedOut = false

    /// The mockups' status bar: the meadow is 236 pt tall with its ground at 200 pt under a 30 pt status bar. A
    /// taller status bar (62 pt on iPhone 17 Pro) makes the meadow taller by the difference, so the sky under it
    /// keeps the mockups' room for the header, the bubbles and the heads.
    private static let mockStatusBar: CGFloat = 30
    private static let meadowHeight: CGFloat = 236
    private static let meadowGround: CGFloat = 200
    /// The header's padding over the meadow, at the top and the start, and the Mac's name in it (design §8.3).
    private static let headerTop: CGFloat = 10
    private static let headerStart: CGFloat = 18
    private static let nameSize: CGFloat = 21
    /// Offline, the numbers and cards below the status card fade back.
    private static let staleOpacity = 0.6
    /// The skin the empty meadow's sleeper wears when the phone has none of its own (the library applies the
    /// phone's).
    private static let emptySkin = "sprig"

    var body: some View {
        let snapshot = store.snapshot
        let sessions = snapshot.map(SessionOrder.forBoard) ?? []
        let requests = RowRequest.all(in: snapshot)
        let offline = Self.isOffline(store.conn, lost: lost)
        NavigationStack {
            GeometryReader { proxy in
                let safeTop = proxy.safeAreaInsets.top
                let extra = max(safeTop - Self.mockStatusBar, 0)
                VStack(spacing: 0) {
                    SkyClock { clockSky in
                        meadow(
                            sessions: sessions, time: offline ? .night : clockSky, offline: offline,
                            safeTop: safeTop, width: proxy.size.width,
                            height: Self.meadowHeight + extra, ground: Self.meadowGround + extra
                        )
                    }
                    .frame(height: Self.meadowHeight + extra)
                    list(sessions: sessions, requests: requests, offline: offline)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(store: store, onPairAgain: onPairAgain, onGuide: onGuide)
            }
        }
        .sheetShell(item: $presentedSessionId.sheetTarget, handle: 160) { target in
            DetailSheet(sessionId: target.id, store: store) { requestId in
                presentedSessionId = nil
                presentedRequestId = requestId
            }
        }
        .sheetShell(item: $presentedRequestId.sheetTarget) { target in
            AnswerSheet(requestId: target.id, store: store, drafts: drafts, inline: inline[target.id] ?? .idle)
        }
        // Under the board the home screen stays in the window: its Critters (the meadow's, a sheet's) stop until it
        // is back.
        .environment(\.critterStagesPaused, showBoard)
        #if DEBUG
        .environment(\.critterFrameTag, "home")
        #endif
        .fullScreenCover(isPresented: $showBoard) {
            BoardView(
                store: store, drafts: drafts, inline: inline, screen: boardScreen,
                presentedRequestId: $boardRequestId,
                onAnswer: { request, allow in answerInline(request, allow: allow) },
                onClose: { closeBoard(.closeButton) }
            )
            .environment(\.critterStagesPaused, false)
            #if DEBUG
            .environment(\.critterFrameTag, "board")
            #endif
        }
        .onChange(of: autoOpen.wantsBoard, initial: true) { _, wanted in
            // Charging in landscape opens the board; unplugged or upright long enough closes it (once no answer card
            // over the board holds the close). A board opened by hand is up before this hears of it.
            if wanted, !showBoard {
                dismissForBoard()
                openBoard()
            } else if !wanted, showBoard {
                closeBoard(autoOpen.closeReason)
            }
        }
        .onChange(of: boardRequestId != nil) { _, open in
            autoOpen.holdClose(open)
        }
        .onChange(of: store.conn, initial: true) { _, conn in
            switch conn {
            case .connected: lost = false
            case .offline, .needsRepair: lost = true
            default: break
            }
        }
        .onChange(of: router.target, initial: true) { openNotificationTarget() }
        .onChange(of: store.isLive) { openNotificationTarget() }
        // A session missing from a cached snapshot waits this long for a live one, as the sheets do.
        .task(id: router.target) {
            targetWaitedOut = false
            guard router.target != nil else { return }
            try? await Task.sleep(for: SheetTarget.liveWait)
            guard !Task.isCancelled else { return }
            targetWaitedOut = true
            openNotificationTarget()
        }
        .onChange(of: store.snapshot) { _, body in
            openNotificationTarget()
            let pending = Set(body?.pending.map(\.requestId) ?? [])
            // An open card keeps its request's, on the home screen and on the board alike: it says "已提交" rather
            // than that the Mac handled it.
            let open = Set([presentedRequestId, boardRequestId].compactMap { $0 })
            inline = inline.filter { pending.contains($0.key) || open.contains($0.key) }
            drafts.prune(keeping: pending.union(open))
        }
        #if DEBUG
        .task {
            // The sheets look their subject up in the snapshot: let the fixture's arrive first.
            for _ in 0..<20 where store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let critterMode = DebugLaunch.current.board {
                settings.boardCritterMode = critterMode
                openBoard()
                await runBoardScript()
                return
            }
            switch DebugLaunch.current.open {
            case .answer(let requestId)?:
                presentedRequestId = requestId
                if DebugLaunch.current.reopen {
                    try? await Task.sleep(for: .seconds(3.5))
                    presentedRequestId = nil
                    try? await Task.sleep(for: .seconds(1.5))
                    presentedRequestId = requestId
                }
            case .detail(let sessionId)?: presentedSessionId = sessionId
            case .settings?: showSettings = true
            case nil: break
            }
        }
        #endif
    }

    /// Not connected, and either down or recovering from it (`lost`).
    private static func isOffline(_ conn: ConnState, lost: Bool) -> Bool {
        switch conn {
        case .connected: false
        case .offline, .needsRepair: true
        default: lost
        }
    }

    private var macName: String {
        Theme.macName(store.pairing?.macName)
    }

    // MARK: - The meadow

    private func meadow(
        sessions: [BridgeSession], time: SkyTime, offline: Bool, safeTop: CGFloat, width: CGFloat, height: CGFloat,
        ground: CGFloat
    ) -> some View {
        // The night moon keeps clear of the Mac's name, measured as the header draws it.
        let nameWidth = nunitoWidth(macName, size: Self.nameSize, weight: .black)
            + Self.nameSize * 0.01 * CGFloat(macName.count)
        let nameHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: Self.nameSize * 1.25)
        let moon = HomeMoon.position(
            width: width, ground: ground, nameRight: Self.headerStart + nameWidth,
            nameBottom: safeTop + Self.headerTop + nameHeight
        )
        return ZStack(alignment: .topLeading) {
            if sessions.isEmpty {
                emptyMeadow(time: time, height: height, ground: ground, moon: moon)
            } else {
                Meadow(
                    sessions: sessions,
                    pending: offline ? [] : Set(sessions.filter { $0.state == .waiting }.map(\.id)),
                    skins: skins.library, dim: skins.idleDim, time: time, offline: offline,
                    height: height, ground: ground, moon: moon,
                    opening: openingDue, onOpening: markOpeningShown,
                    onTap: { id in
                        if let session = sessions.first(where: { $0.id == id }) { open(session) }
                    }
                )
            }
            header(sky: SkyColors.of(time), offline: offline)
                .padding(.top, safeTop + Self.headerTop)
        }
        .frame(height: height)
    }

    /// No sessions: one Critter asleep in the grass (the phone's own skin, or the sprout), greyed like an idle one.
    private func emptyMeadow(time: SkyTime, height: CGFloat, ground: CGFloat, moon: CGPoint) -> some View {
        ZStack(alignment: .top) {
            LonePet(
                skin: skins.library.manifest(Self.emptySkin), state: .idle, sleeping: true, cell: 3,
                groundInset: height - ground, bright: false, time: time, moon: moon
            )
            MeadowTag(text: "睡着了", sky: SkyColors.of(time))
                .padding(.top, ground + 5)
                .accessibilityHidden(true)
        }
    }

    /// The Mac's name and the connection on a tag at the top left, the board and settings buttons at the top right.
    private func header(sky: SkyColors, offline: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: macName)
                    .font(.nunito(size: Self.nameSize, weight: .black))
                    .tracking(Self.nameSize * 0.01)
                    .foregroundStyle(Color(rgb: sky.onSky))
                    .lineLimit(1)
                ConnectionTag(
                    text: { now in connectionText(offline: offline, now: now) }, connected: store.conn.isConnected,
                    sky: sky
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                PixelIconButton(icon: .board, label: "打开看板") { openBoard() }
                PixelIconButton(icon: .sliders, label: "设置") { showSettings = true }
            }
        }
        .padding(.leading, Self.headerStart)
        .padding(.trailing, 14)
    }

    /// "已连接", or offline "离线 · 5 分钟前" (how old the numbers below are, as of `now`).
    private func connectionText(offline: Bool, now: Date) -> String {
        guard offline else { return SessionText.conn(store.conn) }
        return "离线" + (store.snapshotAt.map { " · \(SessionText.ago($0, now: now))" } ?? "")
    }

    // MARK: - The opening

    /// The opening plays once a day, the first time there are Critters to pop up (`HomeRules.shouldPlayOpening`).
    private var openingDue: Bool {
        guard let today = HomeRules.dayNumber(PhoneSettings.day(Date())) else { return false }
        return HomeRules.shouldPlayOpening(lastShownDay: HomeRules.dayNumber(settings.openingShownOn), today: today)
    }

    private func markOpeningShown() {
        settings.openingShownOn = PhoneSettings.day(Date())
    }

    // MARK: - The list

    private func list(sessions: [BridgeSession], requests: [String: RowRequest], offline: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let card = statusCard(offline: offline) {
                    card.padding(.bottom, 12)
                }
                LimitsCards(limits: store.snapshot?.limits)
                    .compositingGroup()
                    .opacity(offline ? Self.staleOpacity : 1)
                if sessions.isEmpty {
                    EmptyList(hasData: store.snapshot != nil || store.canAct)
                } else {
                    SectionHead(count: sessions.count)
                    cards(sessions: sessions, requests: requests, offline: offline)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }

    /// The cards glide to their new places (one that starts needing you, to the top); under reduce motion they are
    /// in their new places at once and the list fades in there over 150 ms. The cards keep who they are either way.
    @ViewBuilder
    private func cards(sessions: [BridgeSession], requests: [String: RowRequest], offline: Bool) -> some View {
        let order = sessions.map(\.id)
        let stack = VStack(spacing: 10) {
            ForEach(sessions, id: \.id) { session in
                let request = requests[session.id]
                SessionRow(
                    session: session,
                    request: request,
                    canAct: store.canAct,
                    offline: offline,
                    skins: skins.library,
                    answer: request.flatMap { inline[$0.request.requestId] } ?? .idle,
                    onOpen: { open(session) },
                    onOpenRequest: { presentedRequestId = request?.request.requestId },
                    onAnswer: { allow in if let request { answerInline(request, allow: allow) } }
                )
                // As one picture: the orange edge is a layer under the face and must not show through it.
                .compositingGroup()
                .opacity(offline ? Self.staleOpacity : 1)
                .transition(.opacity)
            }
        }
        if reduceMotion {
            stack
                .keyframeAnimator(initialValue: 1.0, trigger: order) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    MoveKeyframe(0.0)
                    LinearKeyframe(1.0, duration: 0.15)
                }
        } else {
            stack.animation(.spring(response: 0.4, dampingFraction: 0.85), value: order)
        }
    }

    /// "连不上 …", on top of the list, with the one thing to do about it.
    private func statusCard(offline: Bool) -> StatusCard? {
        if case .needsRepair(let reason) = store.conn {
            // Retrying cannot help (wrong certificate, revoked on the Mac): the way out is right here.
            return StatusCard(title: "连不上 \(macName)", text: { _ in reason }, action: "重新配对", prominent: true) {
                store.unpair()
            }
        }
        guard offline else { return nil }
        let at = store.snapshotAt
        let text = { (now: Date) -> String in
            guard let at else { return "正在重试。" }
            let ago = SessionText.ago(at, now: now)
            return "正在重试。下面是\(ago.first?.isNumber == true ? " " : "")\(ago)的样子。"
        }
        return StatusCard(title: "连不上 \(macName)", text: text, action: "重试", prominent: false) {
            store.retry()
        }
    }

    // MARK: - The board

    /// The board opens by itself: the home screen's answer card or details go first, so a request is never on a card
    /// under the board and on one over it at once (the one under it would only say that it was handled). What was
    /// typed stays in the draft.
    private func dismissForBoard() {
        guard presentedRequestId != nil || presentedSessionId != nil else { return }
        boardLog(
            "the board opens by itself: the home screen's "
                + (presentedRequestId != nil ? "answer card \(presentedRequestId ?? "")" : "details") + " closed first"
        )
        presentedRequestId = nil
        presentedSessionId = nil
    }

    /// Puts the board up: at once, then it turns the screen to landscape.
    private func openBoard() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showBoard = true }
    }

    /// Takes the board down, left by `exit`: the screen as it was before it, portrait again. Closed by hand, it does
    /// not open by itself again until the charger is plugged in again.
    private func closeBoard(_ exit: BoardScreen.Exit) {
        boardScreen.leave(exit)
        if exit == .closeButton { autoOpen.manualExit() }
        // A card that was open over the board goes with it: only when closed by hand (an automatic close waits for
        // the card, `BoardAutoOpen.holdClose`).
        boardRequestId = nil
        OrientationLock.shared.lock(.portrait)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showBoard = false }
    }

    #if DEBUG
    /// `-critterBoardScript`: the board closed and opened at those times after launch, as its close button and
    /// 「打开看板」 do.
    private func runBoardScript() async {
        let launch = DebugLaunch.current
        for step in launch.boardScript {
            let wait = step.at - (ProcessInfo.processInfo.systemUptime - launch.launchUptime)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            switch step.action {
            case .open: openBoard()
            case .close: closeBoard(.closeButton)
            }
        }
    }
    #endif

    // MARK: - Actions

    /// A tap on a card or a Critter: a request opens its card (by id); anything else the details, and a finished
    /// session is marked seen on the way.
    private func open(_ session: BridgeSession) {
        if let request = RowRequest.all(in: store.snapshot)[session.id] {
            presentedRequestId = request.request.requestId
            return
        }
        if session.state == .done {
            let store = store
            Task { _ = await store.send(.seen(sessionId: session.id)) }
        }
        presentedSessionId = session.id
    }

    /// A notification asked for a request's card or a session's details (spec §8.4, `NotificationTarget.decision`): the
    /// same card as a tap on the home screen, by request id (one that is gone says so, as the card always does), over
    /// the board if it is up. A session's details wait for a live snapshot when the one on screen lacks it (the cached
    /// one at a cold launch is older than the session), for as long as the sheets wait; a session that is gone then
    /// opens nothing (the home screen is the place to look); with the board up, they close it as its close button
    /// would (they cannot show over it). One from before a new pairing is dropped.
    private func openNotificationTarget() {
        guard let target = router.target else { return }
        let decision = target.decision(
            pairing: store.pairing?.deviceId, snapshot: store.snapshot, isLive: store.isLive, waitedOut: targetWaitedOut
        )
        switch decision {
        case .wait:
            return
        case .drop:
            router.target = nil
        case .openRequest(let requestId):
            router.target = nil
            if showBoard {
                boardRequestId = requestId
                return
            }
            presentedSessionId = nil
            presentedRequestId = requestId
        case .openSession(let session):
            router.target = nil
            if showBoard { closeBoard(.closeButton) }
            presentedRequestId = nil
            open(session)
        }
    }

    /// 「允许」 / 「拒绝」 on a card: the same draft and the same submit as the answer card's.
    private func answerInline(_ row: RowRequest, allow: Bool) {
        let requestId = row.request.requestId
        let draft = drafts.draft(for: row.request)
        if allow { draft.allow() } else { draft.deny(message: nil) }
        let label = draft.payload().flatMap(successLabel)
        inline[requestId] = .sending
        Task {
            guard let outcome = await AnswerSubmit.submit(draft: draft, store: store) else {
                inline[requestId] = .idle
                return
            }
            switch outcome {
            case .sent: inline[requestId] = .sent(label)
            case .handledElsewhere: inline[requestId] = .closed(Theme.handledElsewhere)
            case .expired(let message): inline[requestId] = .closed(message)
            case .failed(let message):
                drafts.renew(requestId)
                inline[requestId] = .failed(message)
            }
        }
    }
}

extension ConnState {
    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}

// MARK: - Pieces

/// A pixel dot (green with a faint ring while connected, grey otherwise) and the connection's words, on a tag over
/// the sky.
private struct ConnectionTag: View {
    /// The words as of a moment: an age in them reads the clock once a minute.
    let text: (Date) -> String
    let connected: Bool
    let sky: SkyColors

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(connected ? Theme.doneGlyph : Theme.ink3)
                .frame(width: 8, height: 8)
                .background {
                    if connected {
                        Rectangle().fill(Theme.doneGlyph.opacity(0.3)).padding(-2)
                    }
                }
            TimelineView(.everyMinute) { context in
                Text(verbatim: text(context.date))
                    .font(.nunito(size: 13, weight: .heavy))
                    .foregroundStyle(Color(rgb: sky.tagInk))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.top, 2)
        .padding(.bottom, 3)
        .background(Color(rgb: sky.tag, opacity: sky.tagOpacity), in: PixelShape(step: 2))
    }
}

/// "连不上 xxx": what is going on, and the one thing to do about it.
private struct StatusCard: View {
    let title: String
    /// What is going on as of a moment: an age in it reads the clock once a minute.
    let text: (Date) -> String
    let action: String
    let prominent: Bool
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PixelIconView(.wifi, cell: 3)
                .foregroundStyle(Theme.ink3)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(.nunito(size: 14.5, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                TimelineView(.everyMinute) { context in
                    Text(verbatim: text(context.date))
                        .font(.nunito(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PixelButton(title: action, style: prominent ? .primary : .secondary, size: .small, action: onAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 4, lipHeight: 4)
    }
}

/// "会话 5".
private struct SectionHead: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("会话")
                .font(.nunito(size: 14, weight: .black))
                .foregroundStyle(Theme.ink)
            Text(verbatim: "\(count)")
                .font(.silkscreen(size: 14))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 4)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// No sessions: the sprout, and what to do next. Before any data has come, just that there is none yet.
private struct EmptyList: View {
    let hasData: Bool

    var body: some View {
        VStack(spacing: 8) {
            PixelIconView(.seedling, cell: 4)
                .foregroundStyle(Theme.doneGlyph)
            Text(hasData ? "电脑上还没有会话" : "还没有数据")
                .font(.nunito(size: 17, weight: .bold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            if hasData {
                Text("在电脑上开一个 Claude Code 或 Codex 会话，它的宠物会从这片草地里钻出来。")
                    .font(.nunito(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(13.5 * 0.6 - 4)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}
