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
