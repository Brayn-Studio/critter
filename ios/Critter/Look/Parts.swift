import CritterClient
import CritterKit
import SwiftUI
import UIKit

// The pixel widgets (the mockups' "部件" section, Android `Components.kt`). Small widgets move on the pet engine's
// 60 ms beat in whole jumps (visual design §7): a switch's knob crosses in three (180 ms), a state tag hops one beat
// when its state changes, a button goes down and up in one step after 70 ms. Every motion has an end; with reduce
// motion on they go straight to where they end.

// MARK: - Motion

/// CSS `steps(n)` over `duration` (jump-end, like the mockups): the value stays, then jumps `steps` times, the last
/// jump at the end.
struct SteppedAnimation: CustomAnimation {
    var duration: TimeInterval
    var steps: Int

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: Stepped.fraction(time / duration, steps: steps))
    }
}

extension Animation {
    /// `steps` jumps over `duration` seconds (`SteppedAnimation`).
    static func stepped(_ duration: TimeInterval, steps: Int) -> Animation {
        Animation(SteppedAnimation(duration: duration, steps: steps))
    }
}

extension EnvironmentValues {
    /// Reduce motion: the system's setting or the app's own switch, whichever is on. Set once at the root; the
    /// widgets and the transitions read only this.
    @Entry var reduceMotion = false
}

/// Sets `reduceMotion` for everything under it: the system's "减少动态效果", or `appSetting` (the app's own switch).
struct ReduceMotionRoot: ViewModifier {
    var appSetting = false
    @Environment(\.accessibilityReduceMotion) private var system

    func body(content: Content) -> some View {
        content.environment(\.reduceMotion, system || appSetting)
    }
}

/// The pet engine's beat.
private let beat: Duration = .milliseconds(60)

/// The smallest touch target (global constraint).
let minTouch: CGFloat = 44

// MARK: - Buttons

/// A pixel button (Android `PixelButton`, the mockups' `.btn`): pressed, it sinks 3 pt and its lip shrinks to 1 pt,
/// in one step after 70 ms. A `.destructive` role on a secondary button writes its title in the error red
/// (「取消配对」). Disabled (`.disabled`), it is grey.
struct PixelButton: View {
    enum Style {
        case primary
        case secondary
        /// The waiting orange, ink on it.
        case warning
        /// A text button: no face, the brand colour.
        case text
    }

    enum Size {
        case small, regular, large
    }

    let title: String
    var role: ButtonRole?
    var style: Style
    var size: Size
    var icon: PixelIcon?
    /// As wide as the room it is given (a button in a row of buttons).
    var wide: Bool
    let action: () -> Void

    init(
        title: String, role: ButtonRole? = nil, style: Style = .primary, size: Size = .regular, icon: PixelIcon? = nil,
        wide: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.style = style
        self.size = size
        self.icon = icon
        self.wide = wide
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                if let icon { PixelIconView(icon) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(PixelButtonStyle(style: style, size: size, destructive: role == .destructive, wide: wide))
    }
}

/// `PixelButton`'s look, for a button with its own label. `pinnedDown` draws it pressed (the gallery).
struct PixelButtonStyle: ButtonStyle {
    var style: PixelButton.Style = .primary
    var size: PixelButton.Size = .regular
    var destructive = false
    var wide = false
    var pinnedDown = false

    func makeBody(configuration: Configuration) -> some View {
        PixelButtonBody(
            label: configuration.label, pressed: configuration.isPressed || pinnedDown, style: style, size: size,
            destructive: destructive, wide: wide
        )
    }
}

private struct PixelButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let style: PixelButton.Style
    let size: PixelButton.Size
    let destructive: Bool
    let wide: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.reduceMotion) private var reduceMotion

    /// White at 45 % on a button, in both themes (the mockups' `.btn.pri.hl`).
    private static var shine: Color { Color.white.opacity(0.45) }

    var body: some View {
        let down = pressed && isEnabled
        let text = style == .text
        let height: CGFloat = text ? 36 : size == .small ? 34 : size == .large ? 52 : 44
        let lip: CGFloat = text ? 0 : size == .small ? 3 : 4
        let fontSize: CGFloat = text ? 14 : size == .small ? 13.5 : size == .large ? 16 : 15
        let padding: CGFloat = text ? 4 : size == .small ? 12 : 16
        let look = colors
        label
            .font(.nunito(size: fontSize, weight: .black))
            .tracking(fontSize * 0.02)
            .foregroundStyle(look.fg)
            .padding(.horizontal, padding)
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(minHeight: height - lip)
            .padding(.bottom, lip)
            .modifier(ButtonFace(face: look.face, lip: look.lip, lipHeight: down ? min(lip, 1) : lip, shine: look.shine))
            .offset(y: down ? 3 : 0)
            .animation(reduceMotion ? nil : .stepped(0.07, steps: 1), value: down)
            .frame(minWidth: minTouch, minHeight: minTouch)
            .contentShape(Rectangle())
    }

    private var colors: (fg: Color, face: Color?, lip: Color, shine: Color?) {
        if !isEnabled { return (Theme.ink3, style == .text ? nil : Theme.surface2, Theme.line, nil) }
        switch style {
        case .primary: return (Theme.onBrand, Theme.brand, Theme.brandDeep, Self.shine)
        case .warning: return (Theme.inkOnWait, Theme.wait, Theme.waitDeep, Self.shine)
        case .text: return (Theme.brand, nil, .clear, nil)
        case .secondary: return (destructive ? Theme.err : Theme.ink, Theme.surface2, Theme.shade, nil)
        }
    }
}

/// A button's face, or nothing for a text button.
private struct ButtonFace: ViewModifier {
    let face: Color?
    let lip: Color
    let lipHeight: CGFloat
    let shine: Color?

    func body(content: Content) -> some View {
        if let face {
            content.pixelSurface(fill: face, lip: lip, step: 3, lipHeight: lipHeight, highlight: shine)
        } else {
            content
        }
    }
}

/// A 44 pt square button with one icon (back, close; Android `PixelIconButton`).
struct PixelIconButton: View {
    let icon: PixelIcon
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PixelIconView(icon)
                .frame(width: 44, height: 40)
        }
        .buttonStyle(PixelIconButtonStyle())
        .accessibilityLabel(Text(verbatim: label))
    }
}

private struct PixelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PixelIconButtonBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct PixelIconButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.reduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(Theme.ink)
            .padding(.bottom, 4)
            .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 3, lipHeight: pressed ? 1 : 4)
            .offset(y: pressed ? 3 : 0)
            .animation(reduceMotion ? nil : .stepped(0.07, steps: 1), value: pressed)
            .contentShape(Rectangle())
    }
}

// MARK: - State tag

/// A state's label with its symbol (Android `StateChip`, the mockups' `.chip`); when the state changes it hops up
/// 3 pt for one beat (60 ms).
struct StateTag: View {
    let state: PetState
    /// Other words than the state's name.
    var text: String?

    @Environment(\.reduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        let colors = Theme.state(state)
        HStack(spacing: 4) {
            PixelIconView(.forState(state))
            Text(verbatim: text ?? state.label)
                .font(.nunito(size: 11.5, weight: .black))
                .lineLimit(1)
        }
        .foregroundStyle(colors.fg)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .padding(.bottom, 2)
        .pixelSurface(fill: colors.bg, lip: colors.lip, step: 2, lipHeight: 2)
        .fixedSize()
        .offset(y: lifted ? -3 : 0)
        .onChange(of: state) {
            if !reduceMotion { lifted = true }
        }
        .task(id: lifted) {
            guard lifted else { return }
            try? await Task.sleep(for: beat)
            lifted = false
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Switch

/// A pixel switch (Android `PixelSwitch`, the mockups' `.sw`): a 46 × 28 recessed track, a 20 pt knob that crosses
/// 18 pt in three jumps (180 ms). `label` is what VoiceOver calls it.
struct PixelToggle: View {
    @Binding var isOn: Bool
    var label = ""

    var body: some View {
        Toggle(isOn: $isOn) { Text(verbatim: label) }
            .toggleStyle(PixelToggleStyle())
    }
}

/// `PixelToggle`'s look, for a `Toggle`: only the switch is drawn, its label is for VoiceOver.
struct PixelToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PixelToggleBody(configuration: configuration)
    }
}

private struct PixelToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.reduceMotion) private var reduceMotion

    /// The knob's lip while on: ink at 22 % in both themes.
    private static var knobLipOn: Color { Color(rgb: 0x2A2140, opacity: 0.22) }

    var body: some View {
        let on = configuration.isOn
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.clear
                .frame(width: 20, height: 20)
                .pixelSurface(fill: Theme.knob, lip: on ? Self.knobLipOn : Theme.shade, step: 2, lipHeight: 3)
                .animation(reduceMotion ? nil : .stepped(0.18, steps: 3)) {
                    $0.offset(x: 4 + (on ? 18 : 0), y: 4)
                }
        }
        .frame(width: 46, height: 28)
        .pixelSurface(
            fill: on ? Theme.brand : Theme.surface2, lip: on ? Theme.brandDeep : Theme.shade, step: 3, lipHeight: 3,
            inset: true
        )
        .frame(minHeight: minTouch)
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Segmented

/// A recessed row of choices; the chosen one stands up out of it (Android `PixelSegmented`, the mockups' `.seg`).
/// The well is 38 pt tall in a 44 pt row, and every choice takes touches over the row's full height.
struct PixelSegmented: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { i in
                let on = i == selection
                Button { selection = i } label: {
                    Text(verbatim: options[i])
                        .font(.nunito(size: 13.5, weight: .heavy))
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if on {
                                Color.clear.pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 2, lipHeight: 3)
                            }
                        }
                        .frame(height: minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 3)
        .background {
            Color.clear
                .pixelSurface(fill: Theme.surface2, lip: Theme.shade, step: 3, lipHeight: 2, inset: true)
                .padding(.vertical, 3)
        }
    }
}

// MARK: - Slider and meter

/// A slider in `segments` cells, `value` in 0...1 snapping to them (Android `PixelSlider`, the mockups' `.slider`):
/// drag or tap; the thumb wears the sun. Drawn 28 pt tall in a 44 pt touch area.
struct PixelSlider: View {
    @Binding var value: Double
    var segments = 10
    /// What VoiceOver calls it.
    var label = ""

    var body: some View {
        let lit = Self.lit(value, segments)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                SegmentCells(count: segments, gap: 2) { i in
                    i < lit
                        ? SegmentCells.Cell(fill: Theme.brand, lip: Theme.brandDeep, lipHeight: 2, lipOnTop: false)
                        : SegmentCells.Cell(fill: Theme.surface2, lip: Theme.shade, lipHeight: 2, lipOnTop: true)
                }
                .frame(height: 10)
                PixelIconView(.sun)
                    .foregroundStyle(Theme.runGlyph)
                    .frame(width: 24, height: 21)
                    .padding(.bottom, 3)
                    .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 3, lipHeight: 3)
                    .offset(x: min(max(width * CGFloat(lit) / CGFloat(segments) - 12, 0), max(width - 24, 0)))
            }
            .frame(width: width, height: minTouch)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    guard width > 0 else { return }
                    pick(Int((drag.location.x / width * CGFloat(segments)).rounded()))
                }
            )
        }
        .frame(height: minTouch)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: "\(lit * 100 / max(segments, 1))%"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: pick(lit + 1)
            case .decrement: pick(lit - 1)
            @unknown default: break
            }
        }
    }

    private static func lit(_ value: Double, _ segments: Int) -> Int {
        min(max(Int((value * Double(segments)).rounded()), 0), segments)
    }

    private func pick(_ k: Int) {
        let snapped = min(max(k, 0), segments)
        guard snapped != Self.lit(value, segments) else { return }
        value = Double(snapped) / Double(segments)
    }
}

/// A meter in `segments` cells (Android `SegmentMeter`, the mockups' `.meter`): green below 60 %, gold from 60 %, red
/// from 85 % (`Meters.level`), or `color` when given. On the board (`board`) the cells are flat and dimmed.
struct SegmentMeter: View {
    /// 0...1; nil lights nothing.
    let fraction: Double?
    let segments: Int
    var height: CGFloat = 8
    var color: Color?
    var board = false

    var body: some View {
        let lit = Meters.litSegments(fraction: fraction, count: segments)
        let on = color ?? onColor
        SegmentCells(count: segments, gap: 2) { i in
            if board {
                return SegmentCells.Cell(fill: i < lit ? on : Theme.Board.meterOff, lip: .clear, lipHeight: 0, lipOnTop: false)
            }
            return i < lit
                ? SegmentCells.Cell(fill: on, lip: Color.black.opacity(0.14), lipHeight: 2, lipOnTop: false)
                : SegmentCells.Cell(fill: Theme.surface2, lip: Theme.line, lipHeight: 1, lipOnTop: false)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int(((fraction ?? 0) * 100).rounded()))%"))
    }

    private var onColor: Color {
        switch Meters.level(percent: fraction.map { $0 * 100 }) {
        case .calm: board ? Theme.Board.meterCalm : Theme.doneGlyph
        case .busy: board ? Theme.Board.meterBusy : Theme.runGlyph
        case .hot: board ? Theme.Board.meterHot : Theme.errGlyph
        }
    }
}

/// A row of `count` cells across the width, `gap` apart, each with its lip; cell edges on whole points.
struct SegmentCells: View {
    struct Cell {
        var fill: Color
        var lip: Color
        var lipHeight: CGFloat
        var lipOnTop: Bool
    }

    let count: Int
    let gap: CGFloat
    let cell: (Int) -> Cell

    var body: some View {
        Canvas { context, size in
            guard count > 0 else { return }
            let span = size.width + gap
            for i in 0..<count {
                let left = (CGFloat(i) * span / CGFloat(count)).rounded()
                let right = (CGFloat(i + 1) * span / CGFloat(count)).rounded() - gap
                let look = cell(i)
                context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: size.height)), with: .color(look.fill))
                if look.lipHeight > 0 {
                    let y = look.lipOnTop ? 0 : size.height - look.lipHeight
                    context.fill(
                        Path(CGRect(x: left, y: y, width: right - left, height: look.lipHeight)), with: .color(look.lip)
                    )
                }
            }
        }
    }
}

// MARK: - Text field

/// A recessed text field (Android `PixelField`, the mockups' `.field`): the well's dark row on top; focused, a brand
/// coloured edge. Grows up to `maxLines` lines.
struct PixelTextField: View {
    let placeholder: String
    @Binding var text: String
    var maxLines = 5
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ placeholder: String, text: Binding<String>, maxLines: Int = 5) {
        self.placeholder = placeholder
        _text = text
        self.maxLines = maxLines
    }

    var body: some View {
        TextField(
            text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(Theme.ink3), axis: .vertical
        ) {
            Text(verbatim: placeholder)
        }
        .font(.nunito(size: 14.5, weight: .semibold))
        .foregroundStyle(isEnabled ? Theme.ink : Theme.ink3)
        .tint(Theme.brand)
        .lineLimit(1...max(maxLines, 1))
        .focused($focused)
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(minHeight: minTouch)
        .pixelSurface(
            fill: Theme.surface2, lip: Theme.shade, step: 3, lipHeight: 3, inset: true,
            outline: focused && isEnabled ? Theme.brand : nil, outlineWidth: 2
        )
    }
}

// MARK: - Answers

/// One answer to a question (Android `OptionCard`, the mockups' `.opt`): a round marker for one choice, a square one
/// with a check for several; chosen, a pale purple face with a purple edge.
struct OptionCard: View {
    let title: String
    var detail: String?
    let selected: Bool
    var multi = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.nunito(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(14 * 0.35 - 2)
                if let detail {
                    Text(verbatim: detail)
                        .font(.nunito(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(12 * 0.4 - 2)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 42)
            .padding(.trailing, 12)
            .padding(.top, 9)
            .padding(.bottom, 12)
            .frame(minHeight: minTouch)
            .overlay(alignment: .topLeading) {
                OptionMarker(selected: selected, multi: multi)
                    .offset(x: 13, y: 11)
            }
            .pixelSurface(
                fill: selected ? Theme.brandSoft : Theme.surface, lip: selected ? Theme.brand.opacity(0.3) : Theme.shade,
                step: 3, lipHeight: 3, outline: selected ? Theme.brand : Theme.line, outlineWidth: 2
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The 18 pt marker: stepped round for one choice, notched square for several; a recessed well until chosen.
private struct OptionMarker: View {
    let selected: Bool
    let multi: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if selected {
                Rectangle().fill(Theme.brand)
            } else {
                ZStack(alignment: .top) {
                    Rectangle().fill(Theme.surface2)
                    Rectangle().fill(Theme.shade).frame(height: 3)
                }
            }
            if selected && multi {
                PixelIconView(.check).foregroundStyle(Theme.onBrand).offset(x: 4, y: 4)
            } else if selected {
                Rectangle().fill(Theme.onBrand).frame(width: 6, height: 6).offset(x: 6, y: 6)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(MarkerShape(multi: multi))
    }

    private struct MarkerShape: Shape {
        let multi: Bool

        func path(in rect: CGRect) -> Path {
            multi ? NotchedSquare(notch: 3).path(in: rect) : PixelShape(step: 3).path(in: rect)
        }
    }
}

/// "自己写一句…": a dashed card under the options (Android `WriteOwnCard`, the mockups' `.opt.own`).
struct WriteOwnCard: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .font(.nunito(size: 14, weight: .heavy))
                .foregroundStyle(Theme.brand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 9)
                .padding(.bottom, 12)
                .frame(minHeight: minTouch)
                .background { DashedEdge(color: Theme.ink3) }
                .clipShape(PixelShape(step: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A 2 pt dashed edge, 6 pt on and 4 off, drawn as rectangles so the dashes stay square.
private struct DashedEdge: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let t: CGFloat = 2
            let dash: CGFloat = 6
            let period = dash + 4
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let w = min(dash, size.width - x)
                path.addRect(CGRect(x: x, y: 0, width: w, height: t))
                path.addRect(CGRect(x: x, y: size.height - t, width: w, height: t))
                x += period
            }
            var y: CGFloat = 0
            while y < size.height {
                let h = min(dash, size.height - y)
                path.addRect(CGRect(x: 0, y: y, width: t, height: h))
                path.addRect(CGRect(x: size.width - t, y: y, width: t, height: h))
                y += period
            }
            context.fill(path, with: .color(color))
        }
    }
}

// MARK: - Command slip

/// A command or path as the terminal shows it (Android `CommandSlip`, the mockups' `.slip`): monospaced after a
/// `›`, on a dark slip. It is cut off after `maxLines` lines, or with `scrolls` it is as tall as its text up to
/// `maxLines` lines and scrolls beyond that, so all of it can be read (the answer card).
struct CommandSlip: View {
    let text: String
    var maxLines = 8
    var scrolls = false

    /// 12.5 pt, following the text size like the other fonts.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 12.5
    @State private var textHeight: CGFloat = 0

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    slip.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                }
                .frame(height: min(textHeight, lineHeight * CGFloat(maxLines)))
                .scrollBounceBehavior(.basedOnSize)
            } else {
                slip.lineLimit(maxLines)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.term)
        .clipShape(PixelShape(step: 3))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: text))
    }

    /// The mockups' 1.55 line height.
    private var lineHeight: CGFloat { (fontSize * 1.55).rounded() }

    private var slip: some View {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return Text(slipText)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(Theme.termInk)
            .lineSpacing(max(lineHeight - font.lineHeight, 0))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: scrolls)
    }

    private var slipText: AttributedString {
        var prompt = AttributedString("› ")
        prompt.foregroundColor = Theme.termDim
        return prompt + AttributedString(text)
    }
}
