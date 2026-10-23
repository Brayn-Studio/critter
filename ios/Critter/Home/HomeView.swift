import CritterClient
import CritterKit
import SwiftUI

/// The home screen (Android `HomeScreen`): the Mac and the connection, the two quota cards, and the sessions with the
/// ones that need you first. A lone permission request is answered right on its row; a question or a plan opens the
/// answer card; a finished session is marked seen and opens its details, any other row opens the details.
struct HomeView: View {
    let store: BridgeStore
    /// 「重新配对」 in the settings: back to the pairing screen, keeping the pairing until the new one succeeds.
    let onPairAgain: () -> Void

    /// The answers being composed, shared by the rows' buttons and the card.
    @State private var drafts = AnswerDrafts()
    /// The request whose answer card is open.
    @State private var presentedRequestId: String?
    /// The session whose details are open.
    @State private var presentedSessionId: String?
    @State private var showSettings = false
    /// What became of each row's 「拒绝」「允许」, by request id.
    @State private var inline: [String: InlineAnswerState] = [:]
    /// Offline once an attempt has failed, until connected again: a retry's brief "connecting" stays offline.
    @State private var lost = false
    /// For the ages on screen.
    @State private var now = Date()

    private struct Target: Identifiable {
        let id: String
    }

    var body: some View {
        let snapshot = store.snapshot
        let sessions = snapshot.map(SessionOrder.forBoard) ?? []
        let requests = RowRequest.all(in: snapshot)
        let offline = Self.isOffline(store.conn, lost: lost)
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if let card = connectionCard(offline: offline) {
                            card
                        }
                        LimitsCards(limits: snapshot?.limits, now: now)
                            .opacity(offline ? 0.6 : 1)
                        if sessions.isEmpty {
                            EmptyList(hasData: snapshot != nil || store.canAct)
                        } else {
                            ForEach(sessions, id: \.id) { session in
                                let request = requests[session.id]
                                SessionRow(
                                    session: session,
                                    request: request,
                                    canAct: store.canAct,
                                    answer: request.flatMap { inline[$0.request.requestId] } ?? .idle,
                                    onOpen: { open(session, request: request) },
                                    onOpenRequest: { presentedRequestId = request?.request.requestId },
                                    onAnswer: { allow in if let request { answerInline(request, allow: allow) } }
                                )
                                .opacity(offline ? 0.6 : 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(store: store, onPairAgain: onPairAgain)
            }
            .sheet(item: answerTarget) { target in
                AnswerSheet(requestId: target.id, store: store, drafts: drafts)
            }
        }
        .sheet(item: detailTarget) { target in
            DetailSheet(sessionId: target.id, store: store)
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
            inline = inline.filter { pending.contains($0.key) }
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
            case .answer(let requestId)?: presentedRequestId = requestId
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: macName)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(connectionTint)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    Text(verbatim: SessionText.conn(store.conn))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var macName: String {
        guard let name = store.pairing?.macName, !name.isEmpty else { return "Mac" }
        return name
    }

    private var connectionTint: Color {
        switch store.conn {
        case .connected: .green
        case .needsRepair: .red
        default: Color(.systemGray3)
        }
    }

    // MARK: - The connection card

    /// "连不上 …", on top of the list, with the one thing to do about it.
    private func connectionCard(offline: Bool) -> StatusCard? {
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

    /// A tap on a row: a request opens its card (by id); anything else the details, and a finished session is
    /// marked seen on the way.
    private func open(_ session: BridgeSession, request: RowRequest?) {
        if let request {
            presentedRequestId = request.request.requestId
            return
        }
        if session.state == .done {
            let store = store
            Task { _ = await store.send(.seen(sessionId: session.id)) }
        }
        presentedSessionId = session.id
    }

    /// 「允许」 / 「拒绝」 on a row: the same draft and the same submit as the card's.
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
            case .handledElsewhere: inline[requestId] = .closed("已在电脑上处理")
            case .expired(let message): inline[requestId] = .closed(message)
            case .failed(let message):
                drafts.renew(requestId)
                inline[requestId] = .failed(message)
            }
        }
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
            Image(systemName: "wifi.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(verbatim: text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if prominent {
                Button(action: onAction) { Text(verbatim: action) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: onAction) { Text(verbatim: action) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// No sessions: what to do next. Before any data has come, just that there is none yet.
private struct EmptyList: View {
    let hasData: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf")
                .font(.system(size: 36))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(hasData ? "电脑上还没有会话" : "还没有数据")
                .font(.headline)
                .multilineTextAlignment(.center)
            if hasData {
                Text("在电脑上开一个 Claude Code 会话，它的宠物会从这片草地里钻出来。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}
