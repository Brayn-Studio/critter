import CritterClient
import CritterKit
import SwiftUI

/// The settings (mockup "设置", visual design §8.8, Android `SettingsScreen`): the connection card, then grouped
/// cards each under a pixel icon: the skin, the board, motion and power. Every switch writes `PhoneSettings` at once;
/// picking a skin changes every screen's Critters at once.
struct SettingsView: View {
    let store: BridgeStore
    /// 「重新配对」: the pairing screen over the home screen; the pairing stays until the new one has succeeded.
    let onPairAgain: () -> Void

    @Environment(PhoneSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false

    private var macName: String {
        Theme.macName(store.pairing?.macName)
    }

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PixelIconButton(icon: .back, label: "返回") { dismiss() }
                Text("设置")
                    .font(.nunito(size: 20, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 12) {
                        ConnectionCard(
                            macName: macName, conn: store.conn, onPairAgain: onPairAgain,
                            onUnpair: { confirmingUnpair = true }
                        )
                        SettingsGroup(icon: .paw, title: "形象") {
                            SkinPicker(selected: $settings.forcedSkin)
                        }
                        .id(Group.skins)
                        SettingsGroup(icon: .board, title: "看板") {
                            boardRows(settings)
                        }
                        .id(Group.board)
                        SettingsGroup(icon: .spark, title: "动画与省电") {
                            SwitchRow(
                                title: "减少动态效果", detail: "宠物停在代表姿势上；系统的「减少动态效果」打开时也会生效",
                                isOn: $settings.reduceMotion
                            )
                        }
                        .id(Group.motion)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
                .overlay(alignment: .bottom) { BottomFade() }
                #if DEBUG
                .onAppear {
                    if let at = DebugLaunch.current.settingsAt { reader.scrollTo(at, anchor: .top) }
                }
                #endif
            }
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if confirmingUnpair { unpairDialog }
        }
        #if DEBUG
        .task {
            // `-critterPickSkin`: the skin picker taps the tile; then back to the home screen.
            guard DebugLaunch.current.pickSkin != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            dismiss()
        }
        #endif
    }

    /// The groups' ids, for `-critterSettingsAt`.
    private enum Group {
        static let skins = "skins"
        static let board = "board"
        static let motion = "motion"
    }

    // MARK: - The board

    @ViewBuilder
    private func boardRows(_ settings: PhoneSettings) -> some View {
        @Bindable var settings = settings
        BrightnessRow(value: Binding(
            get: { settings.boardBrightness },
            // The first cell is the floor: the board is never fully dark.
            set: { settings.boardBrightness = min(max($0, 0.1), 1) }
        ))
        RowLine()
        SwitchRow(
            title: "充电横放时自动打开", detail: "充电、横放、静止 3 秒后打开；拔电 10 秒后或竖起来 3 秒后退出，平放不退出",
            isOn: $settings.boardAutoOpen
        )
        RowLine()
        VStack(alignment: .leading, spacing: 6) {
            RowTitle(text: "默认模式")
            PixelSegmented(
                options: ["宠物", "专业"],
                selection: Binding(
                    get: { settings.boardCritterMode ? 0 : 1 }, set: { settings.boardCritterMode = $0 == 0 }
                )
            )
        }
        .padding(.horizontal, rowPadding)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        RowLine()
        SwitchRow(title: "看板提示音", detail: "只在看板打开时响；勿扰模式下不响", isOn: $settings.boardSounds)
    }

    // MARK: - Unpairing

    private var unpairDialog: some View {
        PixelDialog(
            title: "取消和 \(macName) 的配对？", confirm: "取消配对", dismiss: "保留", destructive: true,
            onConfirm: {
                confirmingUnpair = false
                store.unpair()
            },
            onDismiss: { confirmingUnpair = false }
        ) {
            Text("手机会断开。之后要用，得在 Mac 上重新「添加手机」再扫码。")
        }
    }
}

// MARK: - The connection

/// The Mac and how the connection is, on a row that never changes height (only its words and the dot's colour
/// change), and the two pairing buttons.
private struct ConnectionCard: View {
    let macName: String
    let conn: ConnState
    let onPairAgain: () -> Void
    let onUnpair: () -> Void

    var body: some View {
        let look = Theme.conn(conn)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                PixelIconView(.laptop, cell: 3)
                    .foregroundStyle(Theme.brand)
                    .frame(width: 44, height: 44)
                    .pixelSurface(fill: Theme.brandSoft, lip: Theme.brandSoft, step: 3, lipHeight: 0)
                // One line each: a long reason is cut short rather than making the card jump.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: macName)
                        .font(.nunito(size: 16, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        PixelIconView(.dot)
                            .foregroundStyle(look.dot)
                        Text(verbatim: SessionText.conn(conn))
                            .font(.nunito(size: 12.5, weight: .heavy))
                            .foregroundStyle(look.tone)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            WeightedRow(weights: [1, 1], spacing: 8) {
                PixelButton(title: "重新配对", style: .secondary, size: .small, wide: true, action: onPairAgain)
                PixelButton(
                    title: "取消配对", role: .destructive, style: .secondary, size: .small, wide: true, action: onUnpair
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 5, lipHeight: 4)
    }
}

// MARK: - Groups and rows

/// A row's side padding inside its group card.
private let rowPadding: CGFloat = 16

/// A card of settings under a heading with its pixel `icon` (the mockups' `.grp` and `.gh`).
private struct SettingsGroup<Content: View>: View {
    let icon: PixelIcon
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PixelIconView(icon)
                    .foregroundStyle(Theme.brand)
                Text(verbatim: title)
                    .font(.nunito(size: 13, weight: .black))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelSurface(fill: Theme.surface, lip: Theme.surface, step: 5, lipHeight: 0)
    }
}

/// The thin line between two rows of a group.
private struct RowLine: View {
    var body: some View {
        Theme.line.frame(height: 1)
    }
}

private struct RowTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.nunito(size: 15, weight: .heavy))
            .foregroundStyle(Theme.ink)
    }
}

/// A title, a line under it, and a switch (the mockups' `.row` with `.sw`).
private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                RowTitle(text: title)
                if let detail {
                    Text(verbatim: detail)
                        .font(.nunito(size: 12, weight: .semibold))
                        .lineSpacing(12 * (1.45 - 1.36))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            PixelToggle(isOn: $isOn, label: detail.map { "\(title)，\($0)" } ?? title)
        }
        .padding(.horizontal, rowPadding)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }
}

/// The board's brightness: the label with the value in percent over a ten-cell slider whose thumb is a little sun.
private struct BrightnessRow: View {
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RowTitle(text: "亮度")
                Spacer(minLength: 8)
                // The number in Silkscreen, the "%" in Nunito (Silkscreen's % reads as a z when small).
                Text.percent("\(Int((value * 100).rounded()))%", digits: .silkscreen(size: 14), signSize: 14)
                    .foregroundStyle(Theme.ink2)
            }
            .accessibilityHidden(true)
            PixelSlider(value: $value, segments: 10, label: "看板亮度")
        }
        .padding(.horizontal, rowPadding)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// The bottom of the page fading into the background (the mockups' `.fade-b`).
private struct BottomFade: View {
    var body: some View {
        LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg], startPoint: .top, endPoint: .bottom)
            .frame(height: 56)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The skin

/// A row of little meadows to scroll through (the mockups' `.skins`): 「跟着电脑」 first, then every bundled skin with
/// a live Critter. The chosen one has a brand frame and a check; picking a skin makes its Critter cheer once (its
/// `done` entrance). `selected` is `PhoneSettings.forcedSkin`: nil follows the Mac.
private struct SkinPicker: View {
    @Binding var selected: String?

    @Environment(SkinStore.self) private var skins
    /// One stage handle per tile, for the cheer.
    @State private var controls: [String: CritterStageControl] = Dictionary(
        uniqueKeysWithValues: SkinStore.bundledNames.map { ($0, CritterStageControl()) }
    )

    /// The id of 「跟着电脑」's tile (the skins' tiles go by the skin's name).
    private static let followId = "follow"

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    SkinTile(label: "跟着电脑", chosen: selected == nil, action: { pick(nil) }) {
                        PixelIconView(.laptop, cell: 4)
                            .foregroundStyle(Theme.ink2)
                    }
                    .id(Self.followId)
                    ForEach(SkinStore.bundledNames, id: \.self) { name in
                        let manifest = skins.previewLibrary.manifest(name)
                        SkinTile(label: Self.shortTitle(manifest), chosen: selected == name, action: { pick(name) }) {
                            TilePet(manifest: manifest, control: controls[name])
                        }
                        .id(name)
                    }
                }
                .padding(.horizontal, rowPadding)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
            // The chosen tile in view when the settings open.
            .onAppear { reader.scrollTo(selected ?? Self.followId, anchor: .center) }
            #if DEBUG
            .task {
                guard let pick = DebugLaunch.current.pickSkin else { return }
                try? await Task.sleep(for: .seconds(1))
                reader.scrollTo(pick ?? Self.followId, anchor: .center)
                // Once the tile is in place.
                try? await Task.sleep(for: .milliseconds(100))
                self.pick(pick)
            }
            #endif
        }
    }

    /// Chooses `name` (nil: follow the Mac); a skin's Critter cheers.
    private func pick(_ name: String?) {
        selected = name
        guard let name, let control = controls[name] else { return }
        let manifest = skins.previewLibrary.manifest(name)
        if let enter = manifest.state(.done).enter, let clip = manifest.clips[enter] {
            control.playClip(LonePet.petId, clip: clip)
        }
    }

    /// "小芽" from "小芽 Sprig"; the capitalised name ("Mochi") for a skin without a title.
    private static func shortTitle(_ manifest: SkinManifest) -> String {
        if let title = manifest.title, let head = title.split(separator: " ").first, !head.isEmpty {
            return String(head)
        }
        return manifest.name.prefix(1).uppercased() + manifest.name.dropFirst()
    }
}

/// A skin tile's patch of meadow, and its strip of grass.
private let skinTileSize = CGSize(width: 76, height: 70)
private let skinTileGrass: CGFloat = 9

/// One tile: a 76 × 70 patch of pale sky with a 9 pt strip of grass, `picture` on it, and the label under it. Chosen:
/// a 3 pt brand frame inside the stepped edge and a check at the top right.
private struct SkinTile<Picture: View>: View {
    let label: String
    let chosen: Bool
    let action: () -> Void
    @ViewBuilder let picture: Picture

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    backdrop
                    picture
                }
                .frame(width: skinTileSize.width, height: skinTileSize.height)
                .clipShape(PixelShape(step: 3))
                .pixelOutline(color: chosen ? Theme.brand : .clear, width: 3, step: 3)
                .overlay(alignment: .topTrailing) {
                    if chosen {
                        PixelIconView(.check)
                            .foregroundStyle(Theme.onBrand)
                            .frame(width: 18, height: 18)
                            .pixelSurface(fill: Theme.brand, lip: Theme.brand, step: 2, lipHeight: 0)
                            .padding(5)
                    }
                }
                Text(verbatim: label)
                    .font(.nunito(size: 12, weight: .heavy))
                    .foregroundStyle(chosen ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
            }
            .frame(width: skinTileSize.width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    /// The sky's middle colour mixed 60 % into the card (the mockups' `color-mix(sky2 60%, surface)`), night in the
    /// dark appearance, over the grass with its lighter top row.
    private var backdrop: some View {
        let dark = colorScheme == .dark
        let sky = SkyColors.of(dark ? .night : .day)
        return VStack(spacing: 0) {
            Color(rgb: Self.mix(sky.middle, dark ? 0x221E36 : 0xFFFFFF, 0.6))
            Color(rgb: sky.grassHi).frame(height: 2)
            Color(rgb: sky.grass).frame(height: skinTileGrass - 2)
        }
    }

    /// `a` mixed `t` into `b`, per channel.
    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift in [16, 8, 0] as [UInt32] {
            let x = Double((a >> shift) & 0xFF)
            let y = Double((b >> shift) & 0xFF)
            out |= UInt32((x * t + y * (1 - t)).rounded()) << shift
        }
        return out
    }
}

/// A tile's Critter: live, idle, 3 pt a cell, standing on the grass in the middle, never dimmed.
private struct TilePet: View {
    let manifest: SkinManifest
    let control: CritterStageControl?

    private static let cell: CGFloat = 3

    var body: some View {
        let size = skinTileSize
        CritterStage(
            slots: [
                CritterSlot(
                    sessionId: LonePet.petId, manifest: manifest, state: .idle, activity: nil, dimStrength: 0,
                    origin: CGPoint(
                        x: ((size.width - 18 * Self.cell) / 2).rounded(), y: size.height - skinTileGrass
                    ),
                    scale: Self.cell
                ),
            ],
            control: control
        )
        .allowsHitTesting(false)
        .frame(width: size.width, height: size.height)
    }
}
