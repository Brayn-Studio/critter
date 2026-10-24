import CritterClient
import CritterKit
import SwiftUI

/// What a card with a lone permission request shows once its buttons were used.
enum InlineAnswerState: Equatable {
    case idle
    case sending
    /// The Mac took it; the text is the success label ("已允许"), nil for a no.
    case sent(String?)
    /// The request is closed: answered on the Mac, or too late; the text says which.
    case closed(String)
    /// It did not get through; the buttons work again.
    case failed(String)
}

/// One session on the home list (Android `SessionCard`, the mockups' `.scard`): its still Critter in a little patch
/// of grass, the name and state, what it is doing, and "folder · branch · source"; the context meter at the bottom.
/// With a request it has an orange edge, the command on a slip, and 「拒绝」「允许」 (a lone permission request,
/// grey and "连上后才能作答" while the phone cannot act) or 「打开回答」. A tap anywhere else is `onOpen`.
struct SessionRow: View {
    let session: BridgeSession
    let request: RowRequest?
    /// Whether the Mac can be told something now (`BridgeStore.canAct`).
    let canAct: Bool
    /// Offline: the Critter dozes in its tile.
    let offline: Bool
    let skins: PhoneSkinLibrary
    let answer: InlineAnswerState
    let onOpen: () -> Void
    let onOpenRequest: () -> Void
    let onAnswer: (_ allow: Bool) -> Void

    /// The longest command shown on a card; the answer card has all of it.
    private static let slipLines = 6

    var body: some View {
        let edge: CGFloat = request == nil ? 0 : 3
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                GrassTile(session: session, manifest: skins.manifest(session.skin), offline: offline)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(verbatim: session.name)
                            .font(.nunito(size: 16, weight: .black))
                            .tracking(0.16)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        StateTag(state: session.state)
                    }
                    Text(verbatim: request?.what ?? SessionText.doing(session))
                        .font(.nunito(size: 13.5, weight: request == nil ? .semibold : .heavy))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    PlaceRow(session: session)
                }
            }
            if let request {
                ask(request)
                    .padding(.top, 6)
            }
            if let hint = SessionText.waitingHint(session, hasActionableRequest: request != nil) {
                Text(verbatim: hint)
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 6)
            }
            if let context = session.context {
                HStack(spacing: 8) {
                    Text("上下文")
                        .font(.nunito(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    SegmentMeter(fraction: context.usedPercent / 100, segments: 24, height: 5)
                    Text.percent(SessionText.contextPercent(context), digits: .silkscreen(size: 11.5), signSize: 11.5)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .padding(.top, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12 + edge)
        .padding(.top, 12 + edge)
        .padding(.bottom, 15 + edge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(
            fill: Theme.surface, lip: Theme.shade, step: 4, lipHeight: 4,
            outline: request == nil ? nil : Theme.wait, outlineWidth: edge
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("打开"), onOpen)
    }

    // MARK: - The request

    @ViewBuilder
    private func ask(_ request: RowRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = request.command {
                CommandSlip(text: command, maxLines: Self.slipLines)
            }
            switch HomeRules.inlineAnswer(request: request.card, canAct: canAct) {
            case .allowDeny, .allowDenyDisabled:
                inlineButtons
            case .open:
                PixelButton(title: "打开回答", size: .small, wide: true, action: onOpenRequest)
            case .none:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var inlineButtons: some View {
        let enabled = canAct && (answer == .idle || isFailed)
        if let line = statusLine {
            Text(verbatim: line.text)
                .font(.nunito(size: 12.5, weight: .heavy))
                .foregroundStyle(line.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
        }
        WeightedRow(weights: [1, 1.4]) {
            PixelButton(title: "拒绝", style: .secondary, size: .small, wide: true) { onAnswer(false) }
            PixelButton(title: "允许", size: .small, wide: true) { onAnswer(true) }
        }
        .disabled(!enabled)
        if !canAct {
            Text("连上后才能作答")
                .font(.nunito(size: 11.5, weight: .heavy))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity)
        }
    }

    private var isFailed: Bool {
        if case .failed = answer { true } else { false }
    }

    private var statusLine: (text: String, color: Color)? {
        switch answer {
        case .idle: nil
        case .sending: ("正在提交…", Theme.ink2)
        case .sent(let label): label.map { ($0, Theme.done) }
        case .closed(let text): (text, Theme.ink2)
        case .failed(let text): (text, Theme.err)
        }
    }
}

/// A 56 pt patch in the state's pale colour with 7 pt of grass, the Critter standing in it, still (Android
/// `GrassTile`, the mockups' `.stile`). Running is a patch of sky, as on the mockups. Offline the Critter dozes, like
/// the meadow's.
struct GrassTile: View {
    let session: BridgeSession
    let manifest: SkinManifest
    let offline: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let grass = SkyColors.of(colorScheme == .dark ? .night : .day)
        ZStack(alignment: .bottom) {
            Self.tile(session.state)
            VStack(spacing: 0) {
                Color(rgb: grass.grassHi).frame(height: 2)
                Color(rgb: grass.grass).frame(height: 5)
            }
            CritterPortrait(
                manifest: manifest, state: offline ? .idle : session.state, cell: 2,
                activity: offline ? nil : session.activity, asleep: offline
            )
            .padding(.bottom, 6)
        }
        .frame(width: 56, height: 56)
        .clipShape(PixelShape(step: 3))
    }

    /// The patch's colour for `state`: the state's pale background; running is the sky's middle band mixed into the
    /// card (the mockups' `color-mix(sky2 70%, surface)`).
    static func tile(_ state: PetState) -> Color {
        switch state {
        case .waiting: Theme.waitBg
        case .running: Color(light: 0xD6EFFF, dark: 0x28244A)
        default: Theme.state(state).bg
        }
    }
}
