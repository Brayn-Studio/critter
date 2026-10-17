import Foundation

/// Rounds like JavaScript's `Math.round`, which the approved motion preview uses: halves go
/// toward +∞ (`-2.5 → -2`). Swift's `.rounded()` sends negative halves away from zero instead.
public func jsRound(_ v: Double) -> Int { Int(floor(v + 0.5)) }

/// A seedable random source (SplitMix64), so motion is reproducible in tests.
public final class MotionRNG {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public static func system() -> MotionRNG { MotionRNG(seed: UInt64.random(in: .min ... .max)) }

    private func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Uniform in `[s.min, s.max)`; a fixed span returns its value without drawing.
    public func value(_ s: Span) -> Double { s.min == s.max ? s.min : s.min + unit() * (s.max - s.min) }

    /// Uniform integer in the closed range `[s.min, s.max]`.
    public func integer(_ s: Span) -> Int {
        let lo = Int(s.min)
        return integer(in: lo...Swift.max(lo, Int(s.max)))
    }

    public func integer(in r: ClosedRange<Int>) -> Int { r.lowerBound + Int(unit() * Double(r.count)) }
}
