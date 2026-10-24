import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// The landscape pro dashboard (mockup "看板 · 专业模式", visual design §8.7, Android `ProBoard`): the clock, the date and
/// the two limit cards (20-cell meters) in a 212 pt column on the left; the session cards in two columns on the right
/// (`ProBoardCards.arrange`: a card with a request is two rows tall and heads the left column), scrolling up and down
/// when there are many. Each card has its session's Critter standing still at the top left, dimmed unless it is
/// waiting. A lone permission request is answered on its card (its command on a slip, 「拒绝」「允许」); with more than
/// one, the oldest shows and the card opens its answer card, as a question or a plan does.
struct ProBoard: View {
    let data: BoardData
    let skins: PhoneSkinLibrary
    /// How much the dimmed portraits are dimmed (the Mac's `idleDim`).
    let dim: Double
    /// Whether the Mac can be told something now (`BridgeStore.canAct`): the answer buttons are grey otherwise.
    let canAct: Bool
    /// What became of each card's 「拒绝」「允许」, by request id.
    let answers: [String: InlineAnswerState]
    /// 「拒绝」 (false) or 「允许」 (true) on a card.
    let onAnswer: (CardRequest, Bool) -> Void
    /// A card with a request, or its 「打开」: the request's id.
    let onOpen: (String) -> Void

    var body: some View {
        let cards = ProBoardCards.arrange(data.snapshot)
        HStack(alignment: .top, spacing: 18) {
            TimelineView(.everyMinute) { context in
                left(now: context.date)
            }
            .frame(width: 212, alignment: .topLeading)
            if cards.isEmpty {
                Text(data.connected ? "电脑上还没有会话" : "还没有数据")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(Theme.Board.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two columns that scroll together; the right 44 pt stay clear for the board's buttons.
                ScrollView {
                    HStack(alignment: .top, spacing: 10) {
                        column(cards.filter { $0.column == .left })
                        column(cards.filter { $0.column == .right })
                    }
                    .padding(.trailing, 44)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 18)
        .padding(.vertical, 18)
    }

    // MARK: - The left column

    private func left(now: Date) -> some View {
        let limits = data.snapshot?.limits
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: BoardScreen.clockText(now, timeZone: .autoupdatingCurrent))
                    .font(.silkscreen(size: 44))
                    .foregroundStyle(Theme.Board.clock)
                    .lineLimit(1)
                    .fixedSize()
                    .pixelDigitLine()
                Text(verbatim: BoardScreen.dateText(now, timeZone: .autoupdatingCurrent))
                    .font(.nunito(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Board.dim)
                    .lineLimit(1)
                    .boardLines()
                    .padding(.leading, 2)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                if !data.connected {
                    Text(verbatim: data.offlineText(now: now))
                        .font(.nunito(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.Board.wait)
                        .lineLimit(1)
                        .boardLines()
                        .padding(.leading, 2)
                        .padding(.bottom, 4)
                }
            }
            .accessibilityElement(children: .combine)
            Text("Claude Code 额度")
                .font(.nunito(size: 12, weight: .heavy))
                .foregroundStyle(Theme.Board.dim)
                .boardLines()
            Gauge(title: "5 小时额度", window: limits?.fiveHour, now: now)
            Gauge(title: "7 天额度", window: limits?.sevenDay, now: now)
            if let limits, let age = LimitsText.staleness(updatedAt: limits.updatedAt, now: now) {
                Text(verbatim: "更新于 \(age)")
                    .font(.nunito(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Board.dim)
                    .boardLines()
            }
        }
    }

    // MARK: - The cards

    private func column(_ cards: [ProBoardCard]) -> some View {
        VStack(spacing: 10) {
            ForEach(cards) { card in
                SessionCard(
                    card: card,
                    manifest: skins.manifest(card.session.skin),
                    dim: dim,
                    canAct: canAct,
                    answer: card.request.flatMap { answers[$0.request.requestId] } ?? .idle,
                    onAnswer: onAnswer,
                    onOpen: onOpen
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Pieces

/// A limit (the mockups' `.gauge`): its name and the share in Silkscreen, a 20-cell meter, and when it resets.
private struct Gauge: View {
    let title: String
    let window: RateWindow?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(.nunito(size: 11.5, weight: .heavy))
                    .foregroundStyle(Theme.Board.dim)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text.percent(LimitsText.percent(window), digits: .silkscreen(size: 22), signSize: 17)
                    .foregroundStyle(Theme.Board.clock)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The digits' line is as tall as they are (`line-height: 1`): they stick out evenly.
            .frame(height: BoardType.scaled(22))
            BoardMeter(percent: window?.usedPercentage, segments: 20, height: 7)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Text(verbatim: LimitsText.resets(window, now: now, calendar: .autoupdatingCurrent))
                .font(.nunito(size: 11, weight: .bold))
                .foregroundStyle(Theme.Board.dim)
                .lineLimit(1)
                .boardLines()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(
            fill: Theme.Board.card, lip: .clear, step: 3, lipHeight: 0, outline: Theme.Board.edge, outlineWidth: 1
        )
        .accessibilityElement(children: .combine)
    }
}

/// One session (the mockups' `.pcard`): its still Critter, the name and state chip, what it is doing (what it wants,
/// with a request), folder, branch and source, and a 16-cell context meter. With a request the card has an orange
/// edge and a tap opens the request; a lone permission request shows its command and 「拒绝」「允许」, any other
/// request 「打开」.
private struct SessionCard: View {
    let card: ProBoardCard
    let manifest: SkinManifest
    let dim: Double
    let canAct: Bool
    let answer: InlineAnswerState
    let onAnswer: (CardRequest, Bool) -> Void
    let onOpen: (String) -> Void

    /// How many lines of a command the card shows; the answer card (a tap on the card) shows all of it.
    private static let slipLines = 4

    var body: some View {
        let session = card.session
        let request = card.request
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                CritterPortrait(
                    manifest: manifest, state: session.state, cell: 2, activity: session.activity,
                    dim: session.state != .waiting, dimStrength: dim
                )
                .frame(width: 44, height: 40, alignment: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: session.name)
                            .font(.nunito(size: 14, weight: .black))
                            .foregroundStyle(Theme.Board.name)
                            .lineLimit(1)
                            .boardLines()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        BoardChip(state: session.state)
                    }
                    Text(verbatim: request?.what ?? SessionText.doing(session))
                        .font(.nunito(size: 12, weight: .semibold))
                        .foregroundStyle(request == nil ? Theme.Board.doing : Theme.Board.waitInk)
                        .lineLimit(1)
                        .boardLines()
                    Meta(session: session)
                }
            }
            if let request {
                ask(request)
            }
            if let hint = SessionText.waitingHint(session, hasActionableRequest: request != nil) {
                Text(verbatim: hint)
                    .font(.nunito(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.Board.waitInk)
                    .boardLines()
                    .padding(.top, 6)
            }
            if let context = session.context {
                HStack(spacing: 8) {
                    BoardMeter(percent: context.usedPercent, segments: 16, height: 4)
                    Text.percent(SessionText.contextPercent(context), digits: .silkscreen(size: 10.5), signSize: 10.5)
                        .foregroundStyle(Theme.Board.dim)
                        .lineLimit(1)
                        .boardLines()
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .padding(.top, 5)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(
            fill: Theme.Board.card, lip: .clear, step: 3, lipHeight: 0,
            outline: request == nil ? Theme.Board.edge : Theme.Board.wait, outlineWidth: request == nil ? 1 : 2
        )
        .tappable(request != nil) { if let request { onOpen(request.request.requestId) } }
        .accessibilityElement(children: .contain)
    }

    /// The command on a dark slip, how many more wait, and the buttons; offline the answer buttons are grey and say
    /// why.
    @ViewBuilder
    private func ask(_ request: CardRequest) -> some View {
        if let command = request.detail {
            Text(slipText(command))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.Board.slipInk)
                .lineSpacing(Self.slipSpacing)
                .lineLimit(Self.slipLines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.Board.card2, in: PixelShape(step: 2))
                .padding(.top, 6)
                .accessibilityLabel(Text(verbatim: command))
        }
        if request.more > 0 {
            Text(verbatim: "还有 \(request.more) 个")
                .font(.nunito(size: 11, weight: .heavy))
                .foregroundStyle(Theme.Board.wait)
                .boardLines()
                .padding(.top, 4)
        }
        let rule = HomeRules.inlineAnswer(request: request, canAct: canAct)
        switch rule {
        case .allowDeny, .allowDenyDisabled:
            if let status = answer.status {
                Text(verbatim: status.text)
                    .font(.nunito(size: 11.5, weight: .heavy))
                    .foregroundStyle(Self.color(status.tone))
                    .lineLimit(2)
                    .boardLines()
                    .padding(.top, 6)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            WeightedRow(weights: [1, 1.3], spacing: 6) {
                BoardButton(title: "拒绝", primary: false) { onAnswer(request, false) }
                BoardButton(title: "允许", primary: true) { onAnswer(request, true) }
            }
            .disabled(!answer.buttonsEnabled(rule))
            .padding(.top, 3)
            if rule == .allowDenyDisabled {
                Text("连上后才能作答")
                    .font(.nunito(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.Board.dim)
                    .boardLines()
                    .frame(maxWidth: .infinity)
            }
        case .open:
            BoardButton(title: "打开", primary: true) { onOpen(request.request.requestId) }
                .padding(.top, 3)
        case .none:
            EmptyView()
        }
    }

    /// The mockups' 1.5 lines of the command's monospaced 11.5 pt.
    private static var slipSpacing: CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: BoardType.scaled(11.5), weight: .regular)
        return max(font.pointSize * 1.5 - font.lineHeight, 0)
    }

    /// "› " and the command, which may break anywhere (the mockups' `word-break: break-all`): a long path fills the
    /// line it starts on instead of leaving "./" alone on it.
    private func slipText(_ command: String) -> AttributedString {
        var prompt = AttributedString("› ")
        prompt.foregroundColor = Theme.Board.dim
        return prompt + AttributedString(command.map(String.init).joined(separator: "\u{200B}"))
    }

    /// The status line's colour on the board.
    private static func color(_ tone: InlineAnswerState.Tone) -> Color {
        switch tone {
        case .quiet: Theme.Board.dim
        case .success: Theme.Board.chipDone
        case .failure: Theme.Board.wait
        }
    }
}

/// Folder and branch, each with its little icon, then where it runs. When they do not all fit, as on the mockup's
/// cards, where it runs is left out first, then the branch is cut short, then the folder.
private struct Meta: View {
    let session: BridgeSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(source: true)
                .fixedSize()
            row(source: false)
        }
        .foregroundStyle(Theme.Board.dim)
        .boardLines()
        .accessibilityElement(children: .combine)
    }

    private func row(source: Bool) -> some View {
        HStack(spacing: 8) {
            MetaPiece(icon: .folder, text: SessionText.folderName(session.cwd))
                .layoutPriority(1)
            if let branch = session.branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MetaPiece(icon: .branch, text: branch)
            }
            if source {
                Text(verbatim: SessionText.source(SessionText.visibleSource(session)))
                    .font(.nunito(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetaPiece: View {
    let icon: PixelIcon
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            PixelIconView(icon, cell: 1.5)
            Text(verbatim: text)
                .font(.nunito(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
    }
}

/// A state's chip on the pro board (the mockups' `.pchip`): its mark and name on the bubbles' dark face, in a dimmed
/// state colour; waiting is ink on the orange.
private struct BoardChip: View {
    let state: PetState

    var body: some View {
        let colors = Self.colors(state)
        HStack(spacing: 3) {
            PixelIconView(.forState(state))
            Text(verbatim: state.label)
                .font(.nunito(size: 10.5, weight: .black))
                .lineLimit(1)
                .boardLines()
        }
        .foregroundStyle(colors.fg)
        .padding(.horizontal, 6)
        .padding(.bottom, 1)
        .background(colors.bg, in: PixelShape(step: 2))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private static func colors(_ state: PetState) -> (fg: Color, bg: Color) {
        switch state {
        case .waiting: (Theme.Board.chipWaitInk, Theme.Board.wait)
        case .running: (Theme.Board.chipRun, Theme.Board.card2)
        case .done: (Theme.Board.chipDone, Theme.Board.card2)
        case .error: (Theme.Board.chipErr, Theme.Board.card2)
        case .idle: (Theme.Board.dim, Theme.Board.card2)
        }
    }
}

/// A button on a pro card (the mockups' `.pbtn`): 34 pt, a darker 3 pt bottom row; pressed, it sinks 3 pt and the row
/// shrinks to 1 pt at once (`PressedLook`). Disabled, it is grey. The touch target is 44 pt tall.
private struct BoardButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
        }
        .buttonStyle(BoardButtonStyle(primary: primary))
    }
}

private struct BoardButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        BoardButtonBody(label: configuration.label, pressed: configuration.isPressed, primary: primary)
    }
}

private struct BoardButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let primary: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let look = colors
        PressedLook(pressed: pressed && isEnabled) { down in
            label
                .font(.nunito(size: 13, weight: .black))
                .foregroundStyle(look.fg)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 31)
                .padding(.bottom, 3)
                .pixelSurface(fill: look.face, lip: look.lip, step: 3, lipHeight: down ? 1 : 3)
                .offset(y: down ? 3 : 0)
        }
        .frame(minHeight: minTouch)
        .contentShape(Rectangle())
    }

    private var colors: (fg: Color, face: Color, lip: Color) {
        if !isEnabled { return (Theme.Board.dim, Theme.Board.card2, Theme.Board.edge) }
        return primary
            ? (Color.white, Theme.Board.primary, Theme.Board.primaryLip)
            : (Theme.Board.buttonInk, Theme.Board.button, Theme.Board.buttonLip)
    }
}
