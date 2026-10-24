#if DEBUG
import CritterClient
import CritterKit
import SwiftUI

/// `-critterGallery`: every pixel widget in its states, in the order of the mockups' "部件" section, then the fonts,
/// every pixel icon and the wordmark. For screenshots next to the mockups (`scripts/dev/render-mockups.sh`).
struct Gallery: View {
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
