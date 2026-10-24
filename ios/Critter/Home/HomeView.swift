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

    @Environment(PhoneSettings.self) private var settings
    @Environment(SkinStore.self) private var skins
    @Environment(\.reduceMotion) private var reduceMotion

    /// The answers being composed, shared by the cards' buttons and the answer card.
    @State private var drafts = AnswerDrafts()
    /// The request whose answer card is open.
    @State private var presentedRequestId: String?
    /// The session whose details are open.
    @State private var presentedSessionId: String?
    @State private var showSettings = false
    @State private var showBoard = false
    /// What became of each card's 「拒绝」「允许」, by request id.
    @State private var inline: [String: InlineAnswerState] = [:]
    /// Offline once an attempt has failed, until connected again: a retry's brief "connecting" stays offline.
    @State private var lost = false
    /// For the ages on screen.
    @State private var now = Date()

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

    private struct Target: Identifiable {
        let id: String
    }

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
                SettingsView(store: store, onPairAgain: onPairAgain)
            }
        }
        .sheet(item: detailTarget) { target in
            DetailSheet(sessionId: target.id, store: store)
        }
        .sheetShell(item: answerTarget) { target in
            AnswerSheet(requestId: target.id, store: store, drafts: drafts, inline: inline[target.id] ?? .idle)
        }
        .fullScreenCover(isPresented: $showBoard) {
            BoardPlaceholder { showBoard = false }
        }
        .onChange(of: store.conn, initial: true) { _, conn in
            switch conn {
            case .connected: lost = false
            case .offline, .needsRepair: lost = true
            default: break
            }
        }
        .onChange(of: store.snapshot) { _, body in
            let pending = Set(body?.pending.map(\.requestId) ?? [])
            // The open card keeps its request's: it says "已提交" rather than that the Mac handled it.
            inline = inline.filter { pending.contains($0.key) || $0.key == presentedRequestId }
            drafts.prune(keeping: pending.union(presentedRequestId.map { [$0] } ?? []))
            now = Date()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                now = Date()
            }
        }
        #if DEBUG
        .task {
            // The sheets look their subject up in the snapshot: let the fixture's arrive first.
            for _ in 0..<20 where store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
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

    private var detailTarget: Binding<Target?> {
        Binding(get: { presentedSessionId.map(Target.init) }, set: { presentedSessionId = $0?.id })
    }

    private var answerTarget: Binding<Target?> {
        Binding(get: { presentedRequestId.map(Target.init) }, set: { presentedRequestId = $0?.id })
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
                ConnectionTag(text: connectionText(offline: offline), connected: store.conn.isConnected, sky: sky)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                PixelIconButton(icon: .board, label: "打开看板") { showBoard = true }
                PixelIconButton(icon: .sliders, label: "设置") { showSettings = true }
            }
        }
        .padding(.leading, Self.headerStart)
        .padding(.trailing, 14)
    }

    /// "已连接", or offline "离线 · 5 分钟前" (how old the numbers below are).
    private func connectionText(offline: Bool) -> String {
        guard offline else { return SessionText.conn(store.conn) }
        return "离线" + (store.snapshotAt.map { " · \(SessionText.ago($0, now: now))" } ?? "")
    }

    // MARK: - The opening

    /// The opening plays once a day, the first time there are Critters to pop up (`HomeRules.shouldPlayOpening`).
    private var openingDue: Bool {
        guard let today = Self.dayNumber(PhoneSettings.day(Date())) else { return false }
        return HomeRules.shouldPlayOpening(lastShownDay: Self.dayNumber(settings.openingShownOn), today: today)
    }

    private func markOpeningShown() {
        settings.openingShownOn = PhoneSettings.day(Date())
    }

    /// Days since 1970-01-01 for a "yyyy-MM-dd" day as `PhoneSettings` keeps it; nil if it is not one.
    static func dayNumber(_ day: String?) -> Int? {
        guard let parts = day?.split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    // MARK: - The list

    private func list(sessions: [BridgeSession], requests: [String: RowRequest], offline: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let card = statusCard(offline: offline) {
                    card.padding(.bottom, 12)
                }
                LimitsCards(limits: store.snapshot?.limits, now: now)
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

    /// The cards glide to their new places (one that starts needing you, to the top); under reduce motion the list
    /// fades from the old order to the new instead.
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
                .id(order)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: order)
        } else {
            stack.animation(.spring(response: 0.4, dampingFraction: 0.85), value: order)
        }
    }

    /// "连不上 …", on top of the list, with the one thing to do about it.
    private func statusCard(offline: Bool) -> StatusCard? {
        if case .needsRepair(let reason) = store.conn {
            // Retrying cannot help (wrong certificate, revoked on the Mac): the way out is right here.
            return StatusCard(title: "连不上 \(macName)", text: reason, action: "重新配对", prominent: true) {
                store.unpair()
            }
        }
        guard offline else { return nil }
        let text: String
        if let at = store.snapshotAt {
            let ago = SessionText.ago(at, now: now)
            text = "正在重试。下面是\(ago.first?.isNumber == true ? " " : "")\(ago)的样子。"
        } else {
            text = "正在重试。"
        }
        return StatusCard(title: "连不上 \(macName)", text: text, action: "重试", prominent: false) {
            store.retry()
        }
    }

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
    let text: String
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
            Text(verbatim: text)
                .font(.nunito(size: 13, weight: .heavy))
                .foregroundStyle(Color(rgb: sky.tagInk))
                .lineLimit(1)
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
    let text: String
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
                Text(verbatim: text)
                    .font(.nunito(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Until the board arrives (Task 15): a black screen that says what will be here, and a way back.
private struct BoardPlaceholder: View {
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.Board.bg.ignoresSafeArea()
            Text("看板")
                .font(.nunito(size: 17, weight: .heavy))
                .foregroundStyle(Theme.Board.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PixelIconButton(icon: .close, label: "关闭", action: onClose)
                .padding(16)
        }
    }
}
