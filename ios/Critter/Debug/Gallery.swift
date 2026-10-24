#if DEBUG
import CritterClient
import CritterKit
import SwiftUI

/// `-critterGallery`: the seven bundled skins on a strip of meadow and their still portraits, the meadow's four skies
/// and the home meadow, then every pixel widget in its states, in the order of the mockups' "部件" section, then the
/// fonts, every pixel icon and the wordmark. For screenshots next to the mockups (`scripts/dev/render-mockups.sh`).
struct Gallery: View {
    @Environment(SkinStore.self) private var skins
    @Environment(\.colorScheme) private var colorScheme
    @State private var touched = "点一下、按住拎起来左右拖、来回蹭"
    @State private var stage = CritterStageControl()
    @State private var switchOn = true
    @State private var switchOff = false
    @State private var size = 1
    @State private var brightness = 0.3
    @State private var said = ""
    @State private var cycling: PetState = .running
    @State private var single = 1
    @State private var several: Set<Int> = [0]

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("critters", "宠物") { critters }
                    section("skies", "天空跟着时间走") { skies }
                    section("meadow", "首页草地") { meadow }
                    section("parts", "部件") { parts }
                    section("more", "更多部件") { moreParts }
                    section("fonts", "字体") { fonts }
                    section("icons", "像素图标") { icons }
                    section("logo", "Logo") { logo }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear {
                if let at = DebugLaunch.current.galleryAt { reader.scrollTo(at, anchor: .top) }
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
    }

    /// A titled part of the page; `id` is what `-critterGalleryAt` scrolls to.
    private func section(_ id: String, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(.nunito(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)
            content()
        }
        .id(id)
    }

    /// The meadow strip's size and ground line, in points; the Critters are 2 pt a cell.
    private static let stripHeight: CGFloat = 100
    private static let stripGround: CGFloat = 72
    private static let stripCell: CGFloat = 2

    /// The seven bundled skins in a row, each in a state that wears a mark over its head (all asleep with
    /// `-critterAllAsleep`), and under them their still portraits in the same state, and the five states of sprig.
    private var critters: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                let slots = Self.slots(width: proxy.size.width, library: skins.previewLibrary, dim: skins.idleDim)
                ZStack(alignment: .topLeading) {
                    MeadowStrip(time: colorScheme == .dark ? .night : .day, ground: Self.stripGround)
                    CritterStage(
                        slots: slots, carryOnDrag: true, control: stage,
                        onTap: { touched = "点了 \($0)" },
                        onLongDragEnd: { touched = "放下了 \($0)" },
                        onCarry: { id, away in touched = away ? "拎走了 \(id)" : "\(id) 走回来了" }
                    )
                    ForEach(slots, id: \.sessionId) { slot in
                        CritterPortrait(
                            manifest: slot.manifest, state: slot.state, cell: Self.stripCell, asleep: slot.sleeping,
                            dim: slot.manifest.state(slot.state).tint == .dim, dimStrength: slot.dimStrength
                        )
                        .offset(x: slot.origin.x - Self.stripCell, y: Self.stripHeight + 8)
                    }
                }
            }
            .frame(height: Self.stripHeight + 8 + CGFloat(Portraits.cells) * Self.stripCell)
            .task {
                guard DebugLaunch.current.galleryHold else { return }
                try? await Task.sleep(for: .seconds(1))
                stage.view?.debugHold(PhoneSkinLibrary.fallback)
            }
            Text(verbatim: touched)
                .font(.nunito(size: 13, weight: .bold))
                .foregroundStyle(Theme.ink2)
            HStack(spacing: 8) {
                ForEach([PetState.idle, .running, .waiting, .done, .error], id: \.self) { state in
                    VStack(spacing: 6) {
                        CritterPortrait(
                            manifest: skins.previewLibrary.manifest(PhoneSkinLibrary.fallback), state: state, cell: 3
                        )
                        .background(state == .waiting ? Theme.waitBg : Theme.state(state).bg)
                        .clipShape(PixelShape(step: 3))
                        StateTag(state: state)
                    }
                }
            }
        }
    }

    private static let stripStates: [PetState] = [.waiting, .running, .done, .error, .idle, .running, .idle]

    private static func slots(width: CGFloat, library: PhoneSkinLibrary, dim: Double) -> [CritterSlot] {
        let names = SkinStore.bundledNames
        let box = 18 * stripCell
        let gap = max(0, (width - CGFloat(names.count) * box) / CGFloat(names.count))
        let asleep = DebugLaunch.current.allAsleep
        return names.enumerated().map { i, name in
            CritterSlot(
                sessionId: name, manifest: library.manifest(name),
                state: asleep ? .idle : stripStates[i % stripStates.count], activity: nil, dimStrength: dim,
                origin: CGPoint(x: (gap / 2 + CGFloat(i) * (box + gap)).rounded(), y: stripGround),
                scale: stripCell, sleeping: asleep
            )
        }
    }

    /// The mockups' "天空跟着时间走": the four skies, each a 96 pt patch of meadow (3 pt cells, the ground 18 pt above
    /// the bottom) with one Critter at 2 pt a cell, dimmed and idle, asleep at night. Always in the light sky set,
    /// like the mockups' panel.
    private var skies: some View {
        let tiles: [(SkyTime, String, String)] = [
            (.dawn, "清晨 6–10 点", "peep"), (.day, "白天 10–17 点", "sprig"),
            (.dusk, "黄昏 17–20 点", "mochi"), (.night, "夜里 20–6 点", "bristle"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles, id: \.1) { time, title, skin in
                VStack(alignment: .leading, spacing: 4) {
                    LonePet(
                        skin: skins.previewLibrary.manifest(skin), state: .idle, sleeping: time == .night, cell: 2,
                        groundInset: 18, bright: false, time: time,
                        clouds: [CGPoint(x: 0.05, y: 0.15), CGPoint(x: 0.62, y: 0.35)], moon: CGPoint(x: 0.8, y: 0.16)
                    )
                    .frame(height: 96)
                    .clipShape(PixelShape(step: 3))
                    Text(verbatim: title)
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    /// The home meadow on the clock's sky (`-critterSkyHour` fixes it): seven sessions, so four stand on their own
    /// and three merge into a pile; one waits for you.
    private var meadow: some View {
        SkyClock { time in
            Meadow(
                sessions: Self.meadowSessions, pending: ["g1"], skins: skins.previewLibrary, dim: skins.idleDim,
                time: time, height: 236, ground: 200, onTap: { touched = "点了 \($0)" }
            )
        }
        .frame(height: 236)
        .clipShape(PixelShape(step: 4))
    }

    private static let meadowSessions: [BridgeSession] = {
        let rows: [(String, String, PetState)] = [
            ("critter-4c", "sprig", .waiting), ("robocup-b8", "mochi", .running), ("infra-e3", "bristle", .running),
            ("blog-21", "peep", .done), ("notes-07", "bonnet", .idle), ("api-9f", "frill", .error),
            ("docs-12", "spout", .idle),
        ]
        return rows.enumerated().map { i, row in
            BridgeSession(
                id: "g\(i + 1)", name: row.0, source: .terminal, state: row.2, cwd: "~/CODE/\(row.0)", skin: row.1,
                eventTime: 0, startedAt: Int64(i), tracked: true
            )
        }
    }()

    /// The mockups' "部件" panel, row by row.
    private var parts: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowRow {
                PixelButton(title: "允许") {}
                PixelButton(title: "拒绝", style: .secondary) {}
                Button("按下") {}.buttonStyle(PixelButtonStyle(pinnedDown: true))
                PixelButton(title: "不可用") {}.disabled(true)
            }
            FlowRow {
                ForEach([PetState.waiting, .running, .done, .error, .idle], id: \.self) { StateTag(state: $0) }
            }
            HStack(spacing: 14) {
                PixelToggle(isOn: $switchOn, label: "示例开关")
                PixelToggle(isOn: $switchOff, label: "示例开关")
                PixelSegmented(options: ["小", "中", "大"], selection: $size)
                    .frame(width: 190)
            }
            PixelSlider(value: $brightness, label: "亮度")
            HStack(spacing: 8) {
                SegmentMeter(fraction: 0.62, segments: 20)
                Text.percent("62%", digits: .silkscreen(size: 14), signSize: 14)
            }
            PixelTextField("发一句…", text: $said)
        }
        .padding(18)
        .background(Theme.bg)
    }

    private var moreParts: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowRow {
                PixelButton(title: "允许", style: .warning) {}
                PixelButton(title: "取消配对", role: .destructive, style: .secondary) {}
                PixelButton(title: "拒绝并写理由…", style: .text) {}
            }
            FlowRow {
                PixelButton(title: "重新配对", style: .secondary, size: .small) {}
                PixelButton(title: "开始配对", size: .large) {}
                PixelButton(title: "发送", icon: .send) {}
                PixelIconButton(icon: .back, label: "返回") {}
                PixelIconButton(icon: .close, label: "关闭") {}
            }
            HStack(spacing: 8) {
                PixelButton(title: "拒绝", style: .secondary, wide: true) {}
                PixelButton(title: "允许", wide: true) {}
            }
            HStack(spacing: 10) {
                Text(verbatim: "点一下换状态：")
                    .font(.nunito(size: 13, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                StateTag(state: cycling)
                    .onTapGesture { cycling = Self.next(cycling) }
            }
            VStack(spacing: 6) {
                SegmentMeter(fraction: 0.3, segments: 10)
                SegmentMeter(fraction: 0.7, segments: 10)
                SegmentMeter(fraction: 0.9, segments: 10)
                SegmentMeter(fraction: 0.45, segments: 20, height: 3, board: true)
                    .padding(6)
                    .background(Theme.Board.bg)
            }
            VStack(spacing: 8) {
                OptionCard(title: "用 Postgres", detail: "已有的服务都在用它", selected: single == 0) { single = 0 }
                OptionCard(title: "用 SQLite", detail: "单机、零配置", selected: single == 1) { single = 1 }
                OptionCard(title: "加测试", selected: several.contains(0), multi: true) { toggle(0) }
                OptionCard(title: "更新文档", detail: "README 和 CHANGELOG", selected: several.contains(1), multi: true) {
                    toggle(1)
                }
                WriteOwnCard(text: "自己写一句…") {}
            }
            CommandSlip(text: "docker compose up -d --build api worker && docker compose logs -f api")
        }
    }

    private var fonts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(verbatim: "22:12").font(.silkscreen(size: 34, bold: true))
                Text.percent("41%", digits: .silkscreen(size: 34, bold: true), signSize: 30)
                Text(verbatim: "5H").font(.silkscreen(size: 34, bold: true))
            }
            Text(verbatim: "0123456789 2828 8282").font(.silkscreen(size: 14))
            Text(verbatim: "critter-4c 想运行命令").font(.nunito(size: 18, weight: .black))
            Text(verbatim: "critter-4c 想运行命令").font(.system(size: 18, weight: .black))
            Text(verbatim: "Nunito 600 正文 Body text").font(.nunito(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
    }

    private var icons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
            ForEach(PixelIcon.allCases, id: \.self) { icon in
                VStack(spacing: 6) {
                    PixelIconView(icon)
                        .frame(height: 20, alignment: .bottom)
                    Text(verbatim: Self.iconName(icon))
                        .font(.nunito(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                }
                .foregroundStyle(Theme.ink2)
            }
        }
        .padding(18)
        .background(Theme.bg)
    }

    private var logo: some View {
        VStack(alignment: .leading, spacing: 12) {
            WordmarkView(cell: 6)
            WordmarkView(cell: 3)
        }
    }

    private func toggle(_ i: Int) {
        if several.contains(i) { several.remove(i) } else { several.insert(i) }
    }

    private static func next(_ state: PetState) -> PetState {
        let all: [PetState] = [.running, .waiting, .done, .error, .idle]
        return all[((all.firstIndex(of: state) ?? 0) + 1) % all.count]
    }

    /// The mockups' names for the icons; the rest by their key.
    private static func iconName(_ icon: PixelIcon) -> String {
        switch icon {
        case .board: "看板"
        case .sliders: "设置"
        case .back: "返回"
        case .close: "关闭"
        case .folder: "目录"
        case .branch: "分支"
        case .term: "终端"
        case .editor: "VS Code"
        case .laptop: "电脑"
        case .wifi: "网络"
        case .bell: "提醒"
        case .battery: "电池"
        case .send: "发送"
        case .letter: "一句话"
        case .qr: "扫码"
        case .keys: "手动输入"
        case .lock: "锁屏"
        case .ball: "悬浮球"
        case .grid: "专业看板"
        case .paw: "形象"
        case .spark: "动画"
        case .seedling: "空状态"
        case .sun: "运行中"
        case .q: "等你确认"
        case .check: "做完了"
        case .bang: "出错"
        case .z: "空闲"
        case .moon: "夜里"
        case .seed: "种子"
        case .bud: "花苞"
        case .sprout: "发芽"
        default: icon.rawValue
        }
    }
}

/// A strip of meadow (`meadowCells`) the gallery's Critters stand on, 2 pt a cell.
private struct MeadowStrip: View {
    let time: SkyTime
    let ground: CGFloat

    var body: some View {
        Canvas { context, size in
            for c in meadowCells(
                width: Int(size.width), height: Int(size.height), ground: Int(ground), cell: 2, time: time
            ) {
                context.fill(
                    Path(CGRect(x: c.x, y: c.y, width: c.w, height: c.h)),
                    with: .color(Color(rgb: c.color, opacity: c.opacity))
                )
            }
        }
        .frame(height: 100)
        .clipShape(PixelShape(step: 4))
    }
}

/// Children left to right, wrapping onto the next line like the mockups' `.compgrid` (14 pt apart).
private struct FlowRow: Layout {
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
#endif
