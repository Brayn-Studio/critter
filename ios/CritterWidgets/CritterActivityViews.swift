import CritterClient
import CritterKit
import SwiftUI

// The Live Activity's pieces (spec §8.5): the lock screen's block, and the parts the Dynamic Island shows. Plain SwiftUI
// over `LiveActivityContent`, without WidgetKit, so the app compiles them too (DEBUG's `-critterActivityDemo` shows
// the lock screen's look in the app, which the simulator cannot lock). Every word here is the widget's own: the content
// the Mac pushes has none (numbers, skin names and states only).
//
// Names start with `Activity` so that they do not meet the app's own (`Theme`, `Fonts`, `PixelShape`, ...).

/// The colours of one place the Live Activity is shown (visual design §5), in colour or, stale, in grey: the system
/// draws a Live Activity from an archive of its views, where filters such as `saturation` have no effect, so a stale one
/// gets grey colours (and grey pictures, `grey`) of its own.
struct ActivityLook {
    /// Where it is shown.
    enum Place {
        /// The lock screen (and its banner) in the light or dark theme.
        case light, dark
        /// StandBy: the board's fixed colours on black.
        case standBy
        /// The Dynamic Island: the system's black.
        case island
    }

    let place: Place
    /// Stale: every colour is a grey of the same lightness, and the pictures are drawn grey.
    let grey: Bool

    /// `activityBackgroundTint`.
    var background: Color
    var ink: Color
    var ink2: Color
    /// The patch of meadow the pile stands on: its sky, top band first (empty: the background shows through), and the
    /// grass's lighter top rows and the grass.
    var sky: [Color]
    var grassTop: Color
    var grass: Color
    /// Meter cells: unlit, and lit while calm, busy or nearly full (green below 60 %, gold from 60 %, red from 85 %).
    var meterOff: Color
    var meterCalm: Color
    var meterBusy: Color
    var meterHot: Color
    /// The state symbols' colours, as the counts tag of the mockups' floating ball has them.
    var waiting: Color
    var running: Color
    var done: Color
    var error: Color
    var idle: Color

    func glyph(_ state: PetState) -> Color {
        switch state {
        case .waiting: waiting
        case .running: running
        case .done: done
        case .error: error
        case .idle: idle
        }
    }

    func meter(_ percent: Int?) -> Color {
        switch Meters.level(percent: percent.map(Double.init)) {
        case .calm: meterCalm
        case .busy: meterBusy
        case .hot: meterHot
        }
    }

    /// Whether the lead is drawn dimmed here: the board's rule in StandBy (idle and done Critters are dimmed, a waiting
    /// one keeps its colours).
    func dimsLead(_ state: PetState?) -> Bool {
        guard place == .standBy, let state else { return false }
        return state == .idle || state == .done
    }

    /// This look, in grey when `stale`.
    func stale(_ stale: Bool) -> ActivityLook {
        stale == grey ? self : Self(place, grey: stale)
    }

    /// The lock screen in the light theme: white, a patch of daytime meadow.
    static let light = ActivityLook(.light, grey: false)
    /// The lock screen in the dark theme: the app's night page, a patch of meadow at night.
    static let dark = ActivityLook(.dark, grey: false)
    /// StandBy: the board's fixed colours (visual design §5), pure black.
    static let standBy = ActivityLook(.standBy, grey: false)
    /// The Dynamic Island: the system's black, the dark theme's words and symbols, night grass.
    static let island = ActivityLook(.island, grey: false)

    init(_ place: Place, grey: Bool) {
        self.place = place
        self.grey = grey
        func c(_ value: UInt32) -> Color { Self.color(value, grey: grey) }
        switch place {
        case .light:
            background = c(0xFFFFFF); ink = c(0x2A2140); ink2 = c(0x625A7A)
            sky = [c(0xC4E8FF), c(0xE8F6FF)]; grassTop = c(0xB5E39C); grass = c(0x8ED07A)
            meterOff = c(0xEFECF7); meterCalm = c(0x2FB457); meterBusy = c(0xE8A21E); meterHot = c(0xF0453A)
            waiting = c(0xD97F00); running = c(0xE8A21E); done = c(0x2FB457); error = c(0xF0453A); idle = c(0x8C85A3)
        case .dark:
            background = c(0x17142A); ink = c(0xF3F0FC); ink2 = c(0xADA6C6)
            sky = [c(0x2B2752), c(0x3B3466)]; grassTop = c(0x3E7342); grass = c(0x2F5A33)
            meterOff = c(0x2F2A47); meterCalm = c(0x5DD47E); meterBusy = c(0xF2B33D); meterHot = c(0xFF7A70)
            waiting = c(0xFF9F0A); running = c(0xF2B33D); done = c(0x5DD47E); error = c(0xFF7A70); idle = c(0x7D7698)
        case .standBy:
            background = c(0x000000); ink = c(0xB9B4CC); ink2 = c(0x7D7896)
            sky = []; grassTop = c(0x1A1630); grass = c(0x16301B)
            meterOff = c(0x1C1830); meterCalm = c(0x3C6E43); meterBusy = c(0x8A6A22); meterHot = c(0x8C3A35)
            waiting = c(0xFF9F0A); running = c(0xD9A93A); done = c(0x4FB86C); error = c(0xD9685F); idle = c(0x7D7896)
        case .island:
            background = c(0x000000); ink = c(0xF3F0FC); ink2 = c(0xADA6C6)
            sky = []; grassTop = c(0x3E7342); grass = c(0x2F5A33)
            meterOff = c(0x2F2A47); meterCalm = c(0x5DD47E); meterBusy = c(0xF2B33D); meterHot = c(0xFF7A70)
            waiting = c(0xFF9F0A); running = c(0xF2B33D); done = c(0x5DD47E); error = c(0xFF7A70); idle = c(0x8C85A3)
        }
    }

    /// 0xRRGGBB, or the grey of its lightness (`ActivityPictures.grey`'s weights).
    private static func color(_ value: UInt32, grey: Bool) -> Color {
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        guard grey else { return Color(.sRGB, red: r, green: g, blue: b) }
        let y = ActivityPictures.luma(r, g, b)
        return Color(.sRGB, red: y, green: y, blue: y)
    }
}

/// The bundled typefaces (the widget lists them under UIAppFonts as the app does), at fixed sizes: the Live Activity
/// has a fixed height, so its words do not grow with the reader's text size. Chinese falls back to the system font.
enum ActivityFonts {
    /// Silkscreen (regular, as the app's counts and percentages): counts and percentages.
    static func digits(_ size: CGFloat) -> Font { .custom("Silkscreen-Regular", fixedSize: size) }
    /// Nunito: "%" (Silkscreen's reads as a z when small) and the words.
    static func words(_ size: CGFloat, heavy: Bool = true) -> Font {
        .custom(heavy ? "Nunito-ExtraBold" : "Nunito-SemiBold", fixedSize: size)
    }
}

// MARK: - The lock screen

/// The lock screen's and the banner's block (spec §8.5): a patch of meadow with the pile on it, the counts beside it
/// (each state's symbol and number) over "n 个会话", the 5-hour and 7-day meters under them, and when it was updated
/// in the bottom right corner. Stale (no update for 15 minutes): grey, and "可能不是最新的". `dimmed`: StandBy at
/// night.
struct ActivityLockView: View {
    let state: LiveActivityContent
    let stale: Bool
    let look: ActivityLook
    var dimmed = false

    var body: some View {
        let look = look.stale(stale)
        HStack(alignment: .center, spacing: 14) {
            ActivityPatch(state: state, look: look, cell: 3)
            VStack(alignment: .leading, spacing: 0) {
                ActivityCounts(counts: state.counts, look: look)
                ActivitySessions(total: state.total, look: look)
                    .padding(.top, 3)
                Spacer(minLength: 6)
                ActivityMeterRow(label: "5 小时", percent: state.fiveHour, look: look)
                ActivityMeterRow(label: "7 天", percent: state.sevenDay, look: look)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    if stale { ActivityStaleNote(look: look) }
                    Spacer(minLength: 0)
                    ActivityUpdated(updatedAt: state.updatedAt, look: look)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(dimmed ? 0.6 : 1)
    }
}

/// A small patch of meadow, stepped corners, with the pile standing on its grass: `cell` points a cell.
struct ActivityPatch: View {
    let state: LiveActivityContent
    let look: ActivityLook
    let cell: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let width = CGFloat(ActivityPictures.pileColumns) * cell
        let height = CGFloat(ActivityPictures.pileRows) * cell
        // The feet stand a point into the grass (as the app's grass tiles): the picture's ground is a cell above its
        // bottom edge.
        let grass = (cell * 7 / 3).rounded()
        let lift = max(0, grass - 1 - cell)
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                ForEach(Array(look.sky.enumerated()), id: \.offset) { _, band in band }
            }
            VStack(spacing: 0) {
                look.grassTop.frame(height: (grass * 2 / 7).rounded())
                look.grass.frame(height: grass - (grass * 2 / 7).rounded())
            }
            if let image = ActivityPictures.pile(
                lead: state.lead, back: state.back,
                cellPixels: ActivityPictures.cellPixels(points: cell, scale: displayScale), scale: displayScale,
                dimLead: look.dimsLead(state.lead?.state), grey: look.grey
            ) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: width, height: height)
                    .padding(.bottom, lift)
            }
        }
        .frame(width: width + 2 * cell, height: height + lift + cell)
        .clipShape(ActivityPixelShape(step: max(2, cell)))
        .accessibilityHidden(true)
    }
}

/// One Critter alone (the Dynamic Island's lead), `cell` points a cell, `ActivityPictures.loneCells` square; `grey` when
/// stale.
struct ActivityLone: View {
    let badge: PetBadge?
    let cell: CGFloat
    var dim = false
    var grey = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let side = CGFloat(ActivityPictures.loneCells) * cell
        Group {
            if let image = ActivityPictures.lone(
                badge, cellPixels: ActivityPictures.cellPixels(points: cell, scale: displayScale), scale: displayScale,
                dim: dim, grey: grey
            ) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Each state's symbol and number, most urgent first (the mockups' counts tag: "?1 ☀2 ✓1 z1").
struct ActivityCounts: View {
    let counts: [StateCount]
    let look: ActivityLook
    var cell: CGFloat = 2
    var digits: CGFloat = 15
    var spacing: CGFloat = 11

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(counts, id: \.state) { count in
                ActivityCount(count: count, look: look, cell: cell, digits: digits)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One state's symbol and number.
struct ActivityCount: View {
    let count: StateCount
    let look: ActivityLook
    var cell: CGFloat = 2
    var digits: CGFloat = 15

    var body: some View {
        HStack(spacing: 4) {
            ActivityGlyph(icon: PixelIcon.forState(count.state), cell: cell, color: look.glyph(count.state))
            Text(verbatim: "\(count.count)")
                .font(ActivityFonts.digits(digits))
                .foregroundStyle(look.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel(Text(verbatim: "\(count.state.label) \(count.count)"))
    }
}

/// "n 个会话".
struct ActivitySessions: View {
    let total: Int
    let look: ActivityLook
    var size: CGFloat = 12

    var body: some View {
        Text(verbatim: "\(total) 个会话")
            .font(ActivityFonts.words(size))
            .foregroundStyle(look.ink2)
            .lineLimit(1)
    }
}

/// One quota window: its name, a meter of ten cells, the share used.
struct ActivityMeterRow: View {
    let label: String
    let percent: Int?
    let look: ActivityLook
    var labelWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: label)
                .font(ActivityFonts.words(11))
                .foregroundStyle(look.ink2)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            ActivityMeter(percent: percent, look: look)
            ActivityPercent(percent: percent, look: look)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Ten cells, as many lit as the share used.
struct ActivityMeter: View {
    let percent: Int?
    let look: ActivityLook
    var segments = 10
    var height: CGFloat = 6

    var body: some View {
        let lit = Meters.litSegments(fraction: percent.map { Double($0) / 100 }, count: segments)
        let on = look.meter(percent)
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle().fill(i < lit ? on : look.meterOff)
            }
        }
        .frame(height: height)
    }
}

/// "42%": the digits in Silkscreen, the "%" in Nunito; "—" when unknown.
struct ActivityPercent: View {
    let percent: Int?
    let look: ActivityLook
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let percent {
                Text(verbatim: "\(percent)").font(ActivityFonts.digits(size))
                    + Text(verbatim: "%").font(ActivityFonts.words(size - 2))
            } else {
                Text(verbatim: "—").font(ActivityFonts.words(size))
            }
        }
        .foregroundStyle(look.ink)
        .lineLimit(1)
        .fixedSize()
    }
}

/// When the content was made, as the system's own relative time that keeps going by itself ("3分钟12秒前"). In a
/// widget such a text takes all the width it is offered: it is aligned to the trailing edge of that width.
struct ActivityUpdated: View {
    let updatedAt: Int64
    let look: ActivityLook

    var body: some View {
        if updatedAt > 0 {
            (Text(Date(timeIntervalSince1970: Double(updatedAt) / 1000), style: .relative) + Text(verbatim: "前"))
                .font(ActivityFonts.words(11, heavy: false))
                .foregroundStyle(look.ink2)
                .monospacedDigit()
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}

/// "可能不是最新的": no update came for 15 minutes (the activity's stale date).
struct ActivityStaleNote: View {
    let look: ActivityLook

    var body: some View {
        Text(verbatim: "可能不是最新的")
            .font(ActivityFonts.words(11))
            .foregroundStyle(look.ink)
            .lineLimit(1)
    }
}

/// "点开查看": the Dynamic Island's expanded view.
struct ActivityOpenHint: View {
    let look: ActivityLook

    var body: some View {
        Text(verbatim: "点开查看")
            .font(ActivityFonts.words(12))
            .foregroundStyle(look.ink)
            .lineLimit(1)
    }
}

// MARK: - The Dynamic Island

/// The compact view's trailing side: the most urgent state's symbol and number (no sessions: idle, 0).
struct ActivityUrgent: View {
    let counts: [StateCount]
    let look: ActivityLook

    var body: some View {
        ActivityCount(
            count: counts.first ?? StateCount(state: .idle, count: 0), look: look, cell: 2, digits: 14
        )
    }
}

/// The expanded view's leading side: the pile on a strip of grass.
struct ActivityIslandPile: View {
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        ActivityPatch(state: state, look: .island.stale(stale), cell: 2.4)
    }
}

/// The expanded view's trailing side: the counts over "n 个会话", to the right. Smaller than on the lock screen: the
/// region beside the camera is narrower than the counts of all five states at full size.
struct ActivityIslandCounts: View {
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        let look = ActivityLook.island.stale(stale)
        VStack(alignment: .trailing, spacing: 5) {
            ActivityCounts(counts: state.counts, look: look, cell: 1.6, digits: 13, spacing: 7)
            ActivitySessions(total: state.total, look: look)
        }
    }
}

/// The expanded view's bottom: the two meters side by side, then "点开查看" and when it was updated (or
/// "可能不是最新的").
struct ActivityIslandBottom: View {
    let state: LiveActivityContent
    let stale: Bool

    var body: some View {
        let look = ActivityLook.island.stale(stale)
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                ActivityMeterRow(label: "5 小时", percent: state.fiveHour, look: look)
                ActivityMeterRow(label: "7 天", percent: state.sevenDay, look: look, labelWidth: 26)
            }
            HStack(spacing: 6) {
                ActivityOpenHint(look: look)
                Spacer(minLength: 6)
                if stale { ActivityStaleNote(look: look) } else { ActivityUpdated(updatedAt: state.updatedAt, look: look) }
            }
        }
        // Clear of the island's rounded bottom corners.
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Pixels

/// A pixel icon's cells, `cell` points each, in `color` (visual design §6: the same symbols the pets wear).
struct ActivityGlyph: View {
    let icon: PixelIcon
    var cell: CGFloat = 2
    let color: Color

    var body: some View {
        let rows = PixelIcons.rows(icon)
        ActivityGlyphShape(icon: icon, cell: cell)
            .fill(color)
            .frame(width: CGFloat(rows.first?.count ?? 0) * cell, height: CGFloat(rows.count) * cell)
            .accessibilityHidden(true)
    }
}

struct ActivityGlyphShape: Shape {
    let icon: PixelIcon
    var cell: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in PixelIcons.runs(icon) {
            path.addRect(CGRect(
                x: rect.minX + CGFloat(run.x) * cell, y: rect.minY + CGFloat(run.y) * cell,
                width: CGFloat(run.length) * cell, height: cell
            ))
        }
        return path
    }
}

/// The pet body's stepped corners (visual design §4): two steps of `step` at each corner.
struct ActivityPixelShape: Shape {
    var step: CGFloat

    func path(in rect: CGRect) -> Path {
        let points = PixelOutline.points(width: rect.width, height: rect.height, step: step)
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        path.closeSubpath()
        return path
    }
}
