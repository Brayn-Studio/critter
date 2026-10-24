import CritterKit

/// What a session card says about its requests (Android `CardRequest`): the oldest one (`request`), what it wants
/// and its command or path, and how many more wait behind it. Only a lone permission request is answered right on
/// the card; with more than one, or for a question or plan, the card opens the answer sheet, so a button never acts
/// on a request the card does not show.
public struct CardRequest: Equatable, Sendable {
    public var request: BridgePending
    public var what: String
    public var detail: String?
    public var more: Int

    public init(request: BridgePending, what: String, detail: String?, more: Int) {
        self.request = request
        self.what = what
        self.detail = detail
        self.more = more
    }

    /// Whether 「拒绝」「允许」 sit on the card (otherwise it has 「打开」).
    public var isInline: Bool { more == 0 && request.kind == .permission }
}

/// One session card of the pro board: where it goes and what it shows.
public struct ProBoardCard: Equatable, Sendable, Identifiable {
    public enum Column: Equatable, Sendable {
        case left, right
    }

    public var session: BridgeSession
    /// The session's oldest request, if it has one the phone can answer.
    public var request: CardRequest?
    public var column: Column
    /// How many rows tall the card is: two with a request, else one.
    public var rows: Int

    public var id: String { session.id }

    /// Whether the card's buttons answer right away (a lone permission request).
    public var answersInline: Bool { request?.isInline ?? false }

    public init(session: BridgeSession, request: CardRequest?, column: Column, rows: Int) {
        self.session = session
        self.request = request
        self.column = column
        self.rows = rows
    }
}

/// The pro board's two columns of cards (Android `ProBoard.kt`): a card with a request is two rows tall and always
/// heads the left column (the mockup's `grid-row: span 2`); every other card, in order, goes to the shorter column,
/// the left one on a tie, so without requests they simply alternate.
public enum ProBoardCards {
    /// Every card, the left column top to bottom, then the right column.
    public static func arrange(_ body: SnapshotBody?) -> [ProBoardCard] {
        guard let body else { return [] }
        let requests = requests(body)
        var left: [ProBoardCard] = []
        var right: [ProBoardCard] = []
        let sessions = SessionOrder.forBoard(body)
        for session in sessions where requests[session.id] != nil {
            left.append(ProBoardCard(session: session, request: requests[session.id], column: .left, rows: 2))
        }
        var leftRows = 2 * left.count
        var rightRows = 0
        for session in sessions where requests[session.id] == nil {
            if leftRows <= rightRows {
                left.append(ProBoardCard(session: session, request: nil, column: .left, rows: 1))
                leftRows += 1
            } else {
                right.append(ProBoardCard(session: session, request: nil, column: .right, rows: 1))
                rightRows += 1
            }
        }
        return left + right
    }

    /// Every session's `CardRequest`, by session id; a session the phone cannot answer for has none.
    static func requests(_ body: SnapshotBody?) -> [String: CardRequest] {
        guard let body else { return [:] }
        let answerable = body.pending.filter { request in
            body.sessions.first { $0.id == request.sessionId }.map(SessionText.supportsAnswers) ?? true
        }
        return Dictionary(grouping: answerable, by: \.sessionId).compactMapValues { requests in
            guard let oldest = requests.min(by: { $0.createdAt < $1.createdAt }) else { return nil }
            let summary = [oldest.summary, oldest.toolName].first { !isBlank($0) }
            let what: String
            switch oldest.kind {
            case .permission: what = summary.map { "想 \($0)" } ?? "想执行一个操作"
            case .question: what = summary.map { "问：\($0)" } ?? "有问题要问你"
            case .plan: what = "计划等你批准"
            }
            let detail = oldest.kind == .permission ? RequestText.permissionBody(oldest.input) : nil
            return CardRequest(request: oldest, what: what, detail: detail, more: requests.count - 1)
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
