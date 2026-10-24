import CoreGraphics
import Foundation

/// The meadow's four skies; the light theme follows the clock, the dark theme is always night (visual design §5,
/// Android `SkyTime`).
public enum SkyTime: Equatable, Sendable, CaseIterable {
    case dawn, day, dusk, night

    /// 6–10 dawn, 10–17 day, 17–20 dusk, the rest night; `dark` (the dark theme) is always night.
    public static func at(hour: Int, dark: Bool = false) -> SkyTime {
        if dark { return .night }
        switch hour {
        case 6...9: return .dawn
        case 10...16: return .day
        case 17...19: return .dusk
        default: return .night
        }
    }
}

/// A sky's colours as 0xRRGGBB: three bands, clouds, grass, and the text and name tags drawn over it. The name
/// tag is the one colour that is not opaque: `tagOpacity`.
public struct SkyColors: Equatable, Sendable {
    public var top: UInt32
    public var middle: UInt32
    public var bottom: UInt32
    public var cloud: UInt32
    public var grass: UInt32
    public var grassHi: UInt32
    public var grassLo: UInt32
    public var onSky: UInt32
    public var tag: UInt32
    public var tagOpacity: Double
    public var tagInk: UInt32

    private static let ink: UInt32 = 0x2A2140
    private static let nightInk: UInt32 = 0xF3F0FC

    public static func of(_ time: SkyTime) -> SkyColors {
        switch time {
        case .dawn:
            SkyColors(
                top: 0xBFE3FF, middle: 0xDDF0FF, bottom: 0xFFE7CC, cloud: 0xFFFFFF, grass: 0x8ED07A,
                grassHi: 0xB5E39C, grassLo: 0x6DB65A, onSky: ink, tag: 0xFFFFFF, tagOpacity: 0.88, tagInk: ink)
        case .day:
            SkyColors(
                top: 0x9FD6FF, middle: 0xC4E8FF, bottom: 0xE8F6FF, cloud: 0xFFFFFF, grass: 0x8ED07A,
                grassHi: 0xB5E39C, grassLo: 0x6DB65A, onSky: ink, tag: 0xFFFFFF, tagOpacity: 0.88, tagInk: ink)
        case .dusk:
            // White words on the dusk sky; the white tags keep ink.
            SkyColors(
                top: 0x7A69DA, middle: 0xE09BC4, bottom: 0xFFCF9E, cloud: 0xF6C9E0, grass: 0x8ED07A,
                grassHi: 0xB5E39C, grassLo: 0x6DB65A, onSky: 0xFFFFFF, tag: 0xFFFFFF, tagOpacity: 0.88, tagInk: ink)
        case .night:
            SkyColors(
                top: 0x1E1B3A, middle: 0x2B2752, bottom: 0x3B3466, cloud: 0x4A4380, grass: 0x2F5A33,
                grassHi: 0x3E7342, grassLo: 0x22452A, onSky: nightInk, tag: 0x17142A, tagOpacity: 0.82, tagInk: nightInk)
        }
    }
}

/// One filled rectangle of the meadow picture, in pixels, 0xRRGGBB at `opacity`.
public struct MeadowCell: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    public var color: UInt32
    public var opacity: Double

    public init(x: Int, y: Int, w: Int, h: Int, color: UInt32, opacity: Double = 1) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.color = color
        self.opacity = opacity
    }
}

/// Where the clouds float, as fractions of the width and of the sky's height.
public let defaultMeadowClouds: [CGPoint] = [
    CGPoint(x: 0.08, y: 0.2), CGPoint(x: 0.62, y: 0.1), CGPoint(x: 0.86, y: 0.36),
]

private let cloudRows = ["....####......", "..#########...", ".############.", "##############"]
private let moonRows = ["..####.", ".###...", "###....", "###....", "###....", ".###...", "..####."]
private let starColor: UInt32 = 0xFFF3C4

/// The meadow behind the pets, as rectangles to paint in order (the mockups' `paintMeadow`, Android
/// `meadowCells`): three sky bands split at 42 % and 74 % of `ground` with one dithered row each way at each
/// edge; clouds by day, stars and the moon at night; then grass from `ground` down with a light top row, tufts
/// and dark specks. Everything is on the `cell` grid; `seed` fixes the stars and specks. `moon` is where the
/// moon goes, as fractions of the width and of `ground` (`HomeMoon` decides).
public func meadowCells(
    width: Int, height: Int, ground: Int, cell: Int, time: SkyTime, seed: Int = 7,
    clouds: [CGPoint] = defaultMeadowClouds, moon: CGPoint = HomeMoon.standard
) -> [MeadowCell] {
    let c = SkyColors.of(time)
    let p = max(1, cell)
    var out: [MeadowCell] = []
    func snap(_ v: Double) -> Int { Int((v / Double(p) + 0.5).rounded(.down)) * p }
    func rows(_ rows: [String], x: Int, y: Int, color: UInt32, opacity: Double) {
        for r in PixelIcons.runs(rows) {
            out.append(MeadowCell(x: x + r.x * p, y: y + r.y * p, w: r.length * p, h: p, color: color, opacity: opacity))
        }
    }
    func dither(_ y: Int, upper: UInt32, lower: UInt32) {
        var x = 0
        var i = 0
        while x < width {
            if i % 2 == 0 { out.append(MeadowCell(x: x, y: y, w: p, h: p, color: upper)) }
            if i % 4 == 1 { out.append(MeadowCell(x: x, y: y - p, w: p, h: p, color: lower)) }
            x += p
            i += 1
        }
    }

    let b1 = snap(Double(ground) * 0.42)
    let b2 = snap(Double(ground) * 0.74)
    out.append(MeadowCell(x: 0, y: 0, w: width, h: b1, color: c.top))
    out.append(MeadowCell(x: 0, y: b1, w: width, h: b2 - b1, color: c.middle))
    out.append(MeadowCell(x: 0, y: b2, w: width, h: ground - b2, color: c.bottom))
    if ground > 40 {
        dither(b1, upper: c.top, lower: c.middle)
        dither(b2, upper: c.middle, lower: c.bottom)
    }
    var random = Lcg(seed: seed)
    if time == .night {
        let stars = Int((Double(width) * Double(ground) / 2600.0 + 0.5).rounded(.down))
        for _ in 0..<max(stars, 0) {
            let x = snap(random.next() * Double(width))
            let y = snap(random.next() * Double(ground) * 0.7)
            if random.next() > 0.75 {
                out.append(MeadowCell(x: x, y: y, w: p, h: p, color: starColor))
            } else {
                out.append(MeadowCell(x: x, y: y, w: p, h: p, color: 0xFFFFFF, opacity: 0.75))
            }
        }
        if ground > 60 {
            rows(moonRows, x: snap(Double(width) * Double(moon.x)), y: snap(Double(ground) * Double(moon.y)), color: starColor, opacity: 0.95)
        }
    } else if ground > 60 {
        for cloud in clouds {
            rows(cloudRows, x: snap(Double(width) * Double(cloud.x)), y: snap(Double(ground) * Double(cloud.y)), color: c.cloud, opacity: 0.82)
        }
    }

    out.append(MeadowCell(x: 0, y: ground, w: width, h: height - ground, color: c.grass))
    out.append(MeadowCell(x: 0, y: ground, w: width, h: p, color: c.grassHi))
    var x = 0
    var i = 0
    while x < width {
        if i % 7 == 2 { out.append(MeadowCell(x: x, y: ground - p, w: p, h: p, color: c.grassHi)) }
        if i % 13 == 8 {
            out.append(MeadowCell(x: x, y: ground - 2 * p, w: p, h: p, color: c.grassHi))
            out.append(MeadowCell(x: x + p, y: ground - p, w: p, h: p, color: c.grassHi))
        }
        x += p
        i += 1
    }
    let specks = Double(width) * Double(height - ground) / 900
    var n = 0
    while Double(n) < specks {
        let sx = snap(random.next() * Double(width))
        let sy = snap(Double(ground) + 2.0 * Double(p) + random.next() * Double(max(0, height - ground - 3 * p)))
        out.append(MeadowCell(x: sx, y: sy, w: p, h: p, color: c.grassLo))
        n += 1
    }
    return out
}

/// The mockups' `seeded`: a 32-bit linear congruential sequence in 0..<1.
private struct Lcg {
    private var s: UInt32

    init(seed: Int) {
        s = UInt32(truncatingIfNeeded: seed)
    }

    mutating func next() -> Double {
        s = s &* 1_664_525 &+ 1_013_904_223
        return Double(s) / 4_294_967_296.0
    }
}
