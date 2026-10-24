import Foundation

/// A meter's colour band: green while calm, gold when busy, red when nearly full (Android `MeterLevel`).
public enum MeterLevel: Equatable, Sendable {
    case calm, busy, hot
}

public enum Meters {
    /// How many of `count` cells a meter lights for `fraction` (0...1; none for nil), clamped to the meter.
    public static func litSegments(fraction: Double?, count: Int) -> Int {
        guard let fraction, !fraction.isNaN else { return 0 }
        let lit = (fraction * Double(count) + 0.5).rounded(.down)
        return Int(min(max(lit, 0), Double(count)))
    }

    /// Green below 60 %, gold from 60 %, red from 85 %; no figure is calm.
    public static func level(percent: Double?) -> MeterLevel {
        guard let percent, percent >= 60 else { return .calm }
        return percent < 85 ? .busy : .hot
    }
}

public enum Stepped {
    /// `x` in 0...1 moved in `steps` jumps, like CSS `steps(n)`: the pet's 60 ms beat for small widgets (visual
    /// design §7). The default of three is the switch knob's 180 ms.
    public static func fraction(_ x: Double, steps: Int = 3) -> Double {
        x >= 1 ? 1 : max((x * Double(steps)).rounded(.down) / Double(steps), 0)
    }
}

/// How a touch on the pixel slider is read (Android `PixelSlider`: `detectTapGestures`, `detectHorizontalDragGestures`):
/// nothing happens at touch-down; a touch that lifts before moving `slop` points is a tap and sets the cell under it;
/// one that moves `slop` points mostly sideways drags the thumb from then on; one that moves mostly up or down is the
/// page's scroll, and the slider lets it go.
public enum SliderTouch {
    /// How far a finger moves before the slider decides between a drag and the page's scroll, in points.
    public static let slop: Double = 6

    /// What a touch that has moved by (`dx`, `dy`) since it came down is.
    public enum Reading: Equatable, Sendable {
        /// Not far enough to tell yet: a tap if it lifts now.
        case undecided
        /// Mostly sideways: the thumb follows the finger.
        case drag
        /// Mostly up or down: the page scrolls, the slider lets go.
        case scroll
    }

    public static func read(dx: Double, dy: Double) -> Reading {
        guard (dx * dx + dy * dy).squareRoot() >= slop else { return .undecided }
        return abs(dx) > abs(dy) ? .drag : .scroll
    }

    /// How many of `segments` cells a touch at `x` on a slider `width` wide lights: the cell edge nearest to it, as
    /// the thumb stands on cell edges; nil on a slider with no width.
    public static func lit(x: Double, width: Double, segments: Int) -> Int? {
        guard width > 0, segments > 0 else { return nil }
        let k = Int((x / width * Double(segments)).rounded())
        return min(max(k, 0), segments)
    }
}
