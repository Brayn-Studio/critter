import CritterClient
import CritterKit
import SwiftUI

/// The first page (visual design §8.2, mockup "欢迎页", Android `WelcomePage`): the five Critters come up out of a
/// morning meadow one after another (`interactions.join`, 260 ms apart), the logo above them, what the app is for, and
/// the way in. At night in the dark appearance.
struct WelcomePage: View {
    let onStart: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The mockup's meadow is 470 of its 800 pt, less on a shorter screen.
    private static let meadowShare: CGFloat = 470 / 800
    private static let meadowMax: CGFloat = 470

    var body: some View {
        let time: SkyTime = colorScheme == .dark ? .night : .dawn
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let full = proxy.size.height + safeTop + proxy.safeAreaInsets.bottom
            let meadowHeight = min(Self.meadowMax, full * Self.meadowShare)
            VStack(spacing: 0) {
                WelcomeMeadow(time: time, width: proxy.size.width, height: meadowHeight, safeTop: safeTop)
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("电脑上的会话，在手机上也看得到")
                                .font(.nunito(size: 21, weight: .black))
                                .tracking(0.21)
                                .lineSpacing(21 * (1.3 - 1.36))
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                            StepBody(
                                text: "每个 Agent 会话都是一只宠物。它们在做什么、卡在哪、要不要你确认，拿起手机就知道，还能直接回答。"
                            )
                        }
                        .padding(.top, 26)
                        .padding(.bottom, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    PixelButton(title: "开始配对", size: .large, wide: true, action: onStart)
                    SkipNote(text: "要先在 Mac 的 Critter 里打开「允许手机连接」")
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 26)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Theme.bg)
    }
}

/// The welcome page's meadow: the sky under the status bar, the wordmark and "a pet for every agent" on it, and five
/// bundled Critters 3 pt a cell standing 52 pt above its bottom, each in the middle of its fifth of the width inside a
/// 22 pt margin (the mockup's `spread(22)`). They are under the ground at first and come up `join`ing, 260 ms apart,
/// once (reduce motion: there at once).
private struct WelcomeMeadow: View {
    let time: SkyTime
    let width: CGFloat
    let height: CGFloat
    let safeTop: CGFloat

    @Environment(SkinStore.self) private var skins
    @State private var stage = CritterStageControl()
    @State private var risen = false

    /// Five of the skins: the mockup spreads the row in fifths, and seven would crowd a phone-width meadow.
    static let skinNames = ["sprig", "mochi", "peep", "frill", "spout"]
    private static let cell: CGFloat = 3
    private static let groundInset: CGFloat = 52
    private static let margin: CGFloat = 22
    private static let stagger: Duration = .milliseconds(260)
    /// The mockup's welcome sky: the moon low on the right, clear of the wordmark.
    private static let clouds = [CGPoint(x: 0.06, y: 0.06), CGPoint(x: 0.7, y: 0.5)]
    private static let moon = CGPoint(x: 0.82, y: 0.62)

    var body: some View {
        let sky = SkyColors.of(time)
        let onSky = Color(rgb: sky.onSky)
        let ground = (height - Self.groundInset).rounded()
        let slots = slots(ground: ground)
        ZStack(alignment: .top) {
            MeadowBackdrop(
                time: time, size: CGSize(width: width, height: height), ground: ground, clouds: Self.clouds,
                moon: Self.moon
            )
            CritterStage(slots: slots, control: stage)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                WordmarkView(
                    cell: 6, ink: onSky,
                    shade: time == .night ? Theme.shade.opacity(0.35) : Theme.ink.opacity(0.22)
                )
                Text(verbatim: "a pet for every agent")
                    .font(.nunito(size: 14, weight: .heavy))
                    .foregroundStyle(onSky.opacity(0.8))
            }
            .padding(.top, safeTop + 52)
        }
        .frame(width: width, height: height)
        .clipped()
        .onChange(of: slots.isEmpty, initial: true) { _, empty in
            // Before the first frame with Critters, so they never stand there before coming up.
            guard !empty, !risen else { return }
            risen = true
            stage.riseAll(stagger: Self.stagger, join: true)
        }
    }

    private func slots(ground: CGFloat) -> [CritterSlot] {
        let names = Self.skinNames
        let room = width - 2 * Self.margin
        return names.enumerated().map { i, name in
            let center = Self.margin + room / CGFloat(names.count) * (CGFloat(i) + 0.5)
            return CritterSlot(
                sessionId: "welcome/\(name)", manifest: skins.previewLibrary.manifest(name), state: .idle, activity: nil,
                dimStrength: 0, origin: CGPoint(x: (center - 18 * Self.cell / 2).rounded(), y: ground),
                scale: Self.cell
            )
        }
    }
}
