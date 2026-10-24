import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The board's Critter mode (mockup "看板 · 宠物模式", visual design §8.7, Android `CritterBoard`): the Critters at 6 pt
/// a cell standing on a dim 2 pt horizon with sparse dark grass; a dark bubble over the running and waiting ones (the
/// waiting one's edged in orange: what it wants, "点我回答"); under each, its name, "folder · branch" and a thin
/// context meter. The Silkscreen clock and the date at the top left, the 5h and 7d limits at the top right. Too many
/// sessions shrink the row, then merge into a pile (`BoardLayout.place`), with its counts above and "n 个会话" below.
///
/// The Critters are one live `CritterStage`. One can be carried sideways (`carryOnDrag`; the others stay where they
/// are); let go, it lands and walks back home, its name staying put as its home and its bubble hidden until it is
/// back. A tap boops it; on one with a request the phone can answer (its bubble and name too), `onTap` opens the
/// answer card.
struct CritterBoard: View {
    let data: BoardData
    let skins: PhoneSkinLibrary
    /// How much the dimmed states are dimmed (the Mac's `idleDim`).
    let dim: Double
    /// A tap on a Critter (the session's id), or on the bubble or name of one with a request.
    let onTap: (String) -> Void

    /// Carried away from their place, until they have walked back (`onCarry`).
    @State private var carried: Set<String> = []

    /// The room under the horizon for the name, the place and the context meter (the mockup's 360 − 276).
    private static let belowGround: CGFloat = 84
    /// A slot's width in cells (a Critter's 18 and the 4-cell gap), which its texts share with nobody.
    private static let pitchCells: CGFloat = 22
    // The clock and date block at the top left (the mockup's `.bclock` at 20 and 52px/1, `.bdate` at 82).
    private static let clockSize: CGFloat = 52
    private static let dateSize: CGFloat = 13
    private static let headerTop: CGFloat = 20
    private static let headerStart: CGFloat = 30
    private static let dateGap: CGFloat = 10

    var body: some View {
        let body = data.snapshot
        let sessions = body.map(SessionOrder.forBoard) ?? []
        let requests = RowRequest.all(in: body)
        GeometryReader { proxy in
            let size = proxy.size
            let ground = max(size.height * 0.6, size.height - Self.belowGround).rounded()
            let layout = BoardLayout.place(count: sessions.count, width: size.width, height: size.height)
            let shown = layout.pileFrom.map { Array(sessions.prefix($0)) } ?? sessions
            let pile = layout.pileFrom.map { Array(sessions.dropFirst($0)) } ?? []
            // Where the date's line ends: no bubble reaches above it (a large text size makes bubbles taller).
            let floor = Self.headerTop + BoardType.scaled(Self.clockSize) + Self.dateGap
                + BoardType.scaled(Self.dateSize) * BoardType.line
            ZStack(alignment: .topLeading) {
                Horizon(ground: ground)
                CritterStage(
                    slots: slots(layout: layout, shown: shown, pile: pile, ground: ground),
                    carryOnDrag: true,
                    onTap: onTap,
                    onCarry: { id, away in
                        if away { carried.insert(id) } else { carried.remove(id) }
                    }
                )
                ForEach(Array(layout.slots.enumerated()), id: \.offset) { i, point in
                    if i < shown.count {
                        let session = shown[i]
                        SessionTexts(
                            session: session, request: requests[session.id], x: point.x.rounded(), ground: ground,
                            scale: layout.scale, width: size.width, floor: floor,
                            bubble: !carried.contains(session.id), onTap: onTap
                        )
                    } else {
                        PileTexts(pile: pile, x: point.x.rounded(), ground: ground, scale: layout.scale, onTap: onTap)
                    }
                }
                header
                    .padding(.leading, Self.headerStart)
                    .padding(.top, Self.headerTop)
                limits
                    .padding(.top, 24)
                    .padding(.trailing, 76)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if sessions.isEmpty, body != nil {
                    Text(data.connected ? "电脑上还没有会话" : "还没有数据")
                        .font(.nunito(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Board.dim)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .onChange(of: sessions.map(\.id)) { _, ids in
            carried.formIntersection(ids)
        }
    }

    // MARK: - The Critters

    private func slots(
        layout: BoardLayout.Layout, shown: [BridgeSession], pile: [BridgeSession], ground: CGFloat
    ) -> [CritterSlot] {
        var out: [CritterSlot] = []
        for (i, point) in layout.slots.enumerated() {
            let origin = CGPoint(x: point.x.rounded(), y: ground)
            if i < shown.count {
                out.append(PileSlots.slot(shown[i], library: skins, dim: dim, origin: origin, scale: layout.scale))
            } else {
                out += PileSlots.build(pile, library: skins, dim: dim, origin: origin, scale: layout.scale)
            }
        }
        return out
    }

    // MARK: - The corners

    /// "22:12" and "10 月 19 日 星期日", once a minute in the phone's time zone; offline, "未连接 · 5 分钟前" in orange on
    /// the date's line (a two-line bubble reaches up to just under it).
    private var header: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: BoardScreen.clockText(context.date, timeZone: .autoupdatingCurrent))
                    .font(.silkscreen(size: Self.clockSize))
                    .foregroundStyle(Theme.Board.clock)
                    .lineLimit(1)
                    .fixedSize()
                    .pixelDigitLine()
                HStack(spacing: 10) {
                    Text(verbatim: BoardScreen.dateText(context.date, timeZone: .autoupdatingCurrent))
                        .font(.nunito(size: Self.dateSize, weight: .bold))
                        .foregroundStyle(Theme.Board.dim)
                        .lineLimit(1)
                        .fixedSize()
                    if !data.connected {
                        Text(verbatim: data.offlineText(now: context.date))
                            .font(.nunito(size: 12, weight: .heavy))
                            .foregroundStyle(Theme.Board.wait)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .boardLines()
                .padding(.leading, 2)
                .padding(.top, Self.dateGap)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "5h" and "7d", each with a 10-cell meter and the share in Silkscreen.
    private var limits: some View {
        VStack(alignment: .leading, spacing: 6) {
            MiniLimit(label: "5h", window: data.snapshot?.limits?.fiveHour)
            MiniLimit(label: "7d", window: data.snapshot?.limits?.sevenDay)
        }
    }
}

// MARK: - Pieces

/// The horizon: a 2 pt line under the Critters' feet, 40 pt in from each side, with sparse 4 pt tufts of dark grass on
/// it (the mockup's sprinkle: a tuft every 9th and 23rd cell). It only changes with the size.
private struct Horizon: View {
    let ground: CGFloat

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 40
            context.fill(
                Path(CGRect(x: inset, y: ground, width: size.width - 2 * inset, height: 2)),
                with: .color(Theme.Board.horizon)
            )
            let cell: CGFloat = 4
            let start: CGFloat = 46
            var tufts = Path()
            var x = start
            var i = 0
            while x < size.width - start {
                if i % 9 == 3 || i % 23 == 11 {
                    tufts.addRect(CGRect(x: x, y: ground - cell, width: cell, height: cell))
                }
                x += cell
                i += 1
            }
            context.fill(tufts, with: .color(Theme.Board.grass))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "5h", a 10-cell meter and the share in Silkscreen (the mockup's `.blim`).
private struct MiniLimit: View {
    let label: String
    let window: RateWindow?

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .font(.nunito(size: 12, weight: .heavy))
                .foregroundStyle(Theme.Board.dim)
                .lineLimit(1)
                .frame(minWidth: 16, alignment: .leading)
            BoardMeter(percent: window?.usedPercentage, segments: 10, height: 6)
                .frame(width: 120)
            Text.percent(LimitsText.percent(window), digits: .silkscreen(size: 13), signSize: 11)
                .foregroundStyle(Theme.Board.clock)
                .lineLimit(1)
                .boardLines()
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The bubble over a Critter (while it is at home) and, under the horizon, its name, "folder · branch" and the
/// context meter. Everything stays inside the slot's pitch, so long names end in "…" rather than running into the
/// neighbour; the bubble also stays inside the board (`width`) and below the date (`floor`).
private struct SessionTexts: View {
    let session: BridgeSession
    let request: RowRequest?
    /// The base box's left edge and the ground line.
    let x: CGFloat
    let ground: CGFloat
    let scale: CGFloat
    let width: CGFloat
    let floor: CGFloat
    /// The bubble shows (the Critter is at home).
    let bubble: Bool
    let onTap: (String) -> Void

    /// Bubbles stand this many cells above the ground, over the Critter's head.
    private static let bubbleCells: CGFloat = 20
    private static let bubbleMax: CGFloat = 150

    var body: some View {
        let center = x + 9 * scale
        let textW = 22 * scale - 6
        ZStack(alignment: .topLeading) {
            if bubble, session.state == .running || session.state == .waiting {
                let bubbleW = min(Self.bubbleMax, textW)
                BottomPin(
                    x: min(max(center - bubbleW / 2, 4), max(4, width - bubbleW - 4)), width: bubbleW,
                    bottom: max(ground - Self.bubbleCells * scale, 0), minTop: floor
                ) {
                    BoardBubble(session: session, what: request?.what)
                        .tappable(request != nil) { onTap(session.id) }
                }
            }
            VStack(spacing: 0) {
                Text(verbatim: session.name)
                    .font(.nunito(size: 14, weight: .black))
                    .tracking(0.14)
                    .foregroundStyle(Theme.Board.name)
                    .lineLimit(1)
                    .boardLines()
                Text(verbatim: Self.folderBranch(session))
                    .font(.nunito(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Board.dim)
                    .lineLimit(1)
                    .boardLines()
                if let context = session.context {
                    BoardMeter(percent: context.usedPercent, segments: 14, height: 3)
                        .frame(width: 84)
                        .padding(.top, 6)
                }
            }
            .frame(width: textW)
            .tappable(request != nil) { onTap(session.id) }
            .offset(x: center - textW / 2, y: ground + 10)
            .accessibilityElement(children: .combine)
        }
    }

    /// "proj · main" (the branch left out when there is none).
    static func folderBranch(_ s: BridgeSession) -> String {
        var parts = [SessionText.folderName(s.cwd)]
        if let branch = s.branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(branch)
        }
        return parts.joined(separator: " · ")
    }
}

/// A dark stepped bubble, two lines at most: what a running session is doing; for a waiting one, what it wants
/// ("想 …", or "等你确认") and, in orange, "点我回答", inside a 2 pt orange edge.
private struct BoardBubble: View {
    let session: BridgeSession
    let what: String?

    var body: some View {
        let waiting = session.state == .waiting
        VStack(spacing: 0) {
            if waiting {
                Text(verbatim: what ?? "等你确认")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Board.waitInk)
                    .lineLimit(1)
                Text("点我回答")
                    .font(.nunito(size: 11, weight: .black))
                    .foregroundStyle(Theme.Board.wait)
                    .lineLimit(1)
            } else {
                Text(verbatim: SessionText.doing(session))
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Board.name)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .pixelSurface(
            fill: Theme.Board.card2, lip: .clear, step: 3, lipHeight: 0,
            outline: waiting ? Theme.Board.wait : Theme.Board.edge, outlineWidth: waiting ? 2 : 1.5
        )
        .accessibilityElement(children: .combine)
    }
}

/// The pile's counts (each state's mark and how many, most urgent first) above it and "n 个会话" below; a tap on
/// either is the most urgent one's. The count tag is as wide as its content, centred over the pile; it may reach into
/// the gap next to the pile but no further, so on a crowded board the least urgent states are left out
/// (`fitCounts`) instead of running into the neighbour's bubble.
private struct PileTexts: View {
    let pile: [BridgeSession]
    let x: CGFloat
    let ground: CGFloat
    let scale: CGFloat
    let onTap: (String) -> Void

    /// The count tag's order: the desktop markers from the most to the least urgent.
    private static let order: [PetState] = [.waiting, .running, .done, .error, .idle]
    /// Which states a tag that is too narrow leaves out first: idle, then done, running and error; waiting stays.
    private static let dropOrder: [PetState] = [.idle, .done, .running, .error]
    /// How wide the count tag may be, in cells: the pile (25) and the gap beside it (4).
    private static let tagCells: CGFloat = 18 + PileSlots.extraCells + 4
    private static let countSize: CGFloat = 12
    private static let tagPad: CGFloat = 8
    private static let between: CGFloat = 8
    private static let inner: CGFloat = 3
    private static let iconCell: CGFloat = 2

    var body: some View {
        let boxW = (18 + PileSlots.extraCells) * scale
        let lead = Self.lead(pile)
        let counts = Self.fit(Self.counts(pile), maxWidth: Self.tagCells * scale)
        ZStack(alignment: .topLeading) {
            BottomPin(x: x, width: boxW, bottom: max(ground - 20 * scale, 0), minTop: 0) {
                HStack(spacing: Self.between) {
                    ForEach(counts, id: \.state) { count in
                        HStack(spacing: Self.inner) {
                            PixelIconView(.forState(count.state), cell: Self.iconCell)
                                .foregroundStyle(Self.iconColor(count.state))
                            Text(verbatim: "\(count.count)")
                                .font(.silkscreen(size: Self.countSize))
                                .foregroundStyle(Theme.Board.name)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, Self.tagPad)
                .padding(.vertical, 5)
                .pixelSurface(
                    fill: Theme.Board.card2, lip: .clear, step: 2, lipHeight: 0, outline: Theme.Board.edge,
                    outlineWidth: 1.5
                )
                .fixedSize()
                .tappable(lead != nil) { if let lead { onTap(lead.id) } }
            }
            Text(verbatim: "\(pile.count) 个会话")
                .font(.nunito(size: 14, weight: .black))
                .foregroundStyle(Theme.Board.name)
                .lineLimit(1)
                .boardLines()
                .frame(width: boxW)
                .tappable(lead != nil) { if let lead { onTap(lead.id) } }
                .offset(x: x, y: ground + 10)
        }
        .accessibilityElement(children: .combine)
    }

    /// The pile's most urgent session, the one in front.
    private static func lead(_ pile: [BridgeSession]) -> BridgeSession? {
        guard !pile.isEmpty, case .merged(let lead, _, _) = PhoneFlock.merged(pile) else { return nil }
        return lead
    }

    /// How many of `pile` are in each state, in `order`; states nobody is in are left out.
    private static func counts(_ pile: [BridgeSession]) -> [StateCount] {
        order.compactMap { state in
            let n = pile.filter { $0.state == state }.count
            return n > 0 ? StateCount(state: state, count: n) : nil
        }
    }

    /// What of `counts` a tag `maxWidth` wide shows: the least urgent states are left out until it fits, but never
    /// the last one (Android `fitCounts`). The total is on the "n 个会话" line anyway.
    private static func fit(_ counts: [StateCount], maxWidth: CGFloat) -> [StateCount] {
        var entries = counts
        for drop in dropOrder {
            if entries.count <= 1 || width(entries) <= maxWidth { break }
            entries.removeAll { $0.state == drop }
        }
        return entries
    }

    /// How wide a count tag with `entries` is: padding, icons, numbers and the gaps between them.
    private static func width(_ entries: [StateCount]) -> CGFloat {
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .silkscreen(size: countSize))
        var total = 2 * tagPad + between * CGFloat(max(entries.count - 1, 0))
        for entry in entries {
            let columns = CGFloat(PixelIcons.rows(.forState(entry.state)).first?.count ?? 0)
            let number = ("\(entry.count)" as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
            total += columns * iconCell + inner + number
        }
        return total
    }

    /// A count's mark in its colour, as on the mockup: the deep orange question mark, the sun, the check, the bang, a
    /// grey z (the dark theme's, like the rest of the board).
    private static func iconColor(_ state: PetState) -> Color {
        switch state {
        case .waiting: Theme.waitDeep
        case .running: Theme.runGlyph
        case .done: Theme.doneGlyph
        case .error: Theme.errGlyph
        case .idle: Theme.ink3
        }
    }
}

/// Its child `width` wide at most (as wide as it needs, centred in `width`; wider only if it insists), its left edge
/// at `x` and its bottom at `bottom`, but its top never above `minTop`: over a Critter's head, and at a large text size
/// lower rather than on the date. It takes the whole room it is given and draws nothing itself.
private struct BottomPin: Layout {
    var x: CGFloat
    var width: CGFloat
    var bottom: CGFloat
    var minTop: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let top = max(bottom - size.height, minTop)
        child.place(
            at: CGPoint(x: bounds.minX + x + ((width - size.width) / 2).rounded(), y: bounds.minY + top),
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}

extension View {
    /// A tap target when `enabled` (`action` on a tap); otherwise touches go through it to what is behind.
    @ViewBuilder
    func tappable(_ enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
        } else {
            allowsHitTesting(false)
        }
    }
}
