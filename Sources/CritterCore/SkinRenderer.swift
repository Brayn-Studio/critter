import CoreGraphics
import Foundation

/// A rasterized pose: `rows[0]` is row `minY` of the base box, `.` is transparent. Its
/// frame is the bounding box of the pixels actually drawn, so it can extend outside the
/// 18x10 base box (raised arms, dangling legs).
public struct PixelGrid: Sendable, Equatable {
    public var minX: Int
    public var minY: Int
    public var width: Int
    public var height: Int
    public var rows: [String]

    public init(minX: Int, minY: Int, width: Int, height: Int, rows: [String]) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
        self.rows = rows
    }

    /// The palette character at base-box coordinates, or nil if transparent or outside.
    public func character(atX x: Int, y: Int) -> Character? {
        guard x >= minX, x < minX + width, y >= minY, y < minY + height else { return nil }
        let ch = Array(rows[y - minY])[x - minX]
        return ch == "." ? nil : ch
    }

    /// The same pixels re-framed to the given box: pixels outside are dropped, gaps are transparent.
    public func cropped(minX: Int, minY: Int, width: Int, height: Int) -> PixelGrid {
        let rows = (minY..<minY + height).map { y in
            String((minX..<minX + width).map { character(atX: $0, y: y) ?? "." })
        }
        return PixelGrid(minX: minX, minY: minY, width: width, height: height, rows: rows)
    }
}

/// Renders skin poses (grids of palette characters) into tiny RGBA bitmaps, one pixel per
/// cell, for the app to scale up with nearest-neighbor filtering.
public enum SkinRenderer {
    /// Composites `pose`'s parts in order (later parts cover earlier ones) and returns the
    /// bounding box of the drawn pixels, or nil for an unknown or empty pose.
    public static func grid(pose: String, in skin: SkinManifest) -> PixelGrid? {
        guard let partNames = skin.poses[pose] else { return nil }
        var pixels: [Int: [Int: Character]] = [:] // y -> x -> char
        for name in partNames {
            guard let part = skin.parts[name], part.at.count == 2 else { continue }
            for (r, line) in part.rows.enumerated() {
                for (c, ch) in line.enumerated() where ch != "." {
                    pixels[part.at[1] + r, default: [:]][part.at[0] + c] = ch
                }
            }
        }
        guard !pixels.isEmpty else { return nil }
        let ys = pixels.keys
        let xs = pixels.values.flatMap(\.keys)
        let (minX, maxX, minY, maxY) = (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        let rows = (minY...maxY).map { y in
            String((minX...maxX).map { pixels[y]?[$0] ?? "." })
        }
        return PixelGrid(minX: minX, minY: minY, width: maxX - minX + 1, height: maxY - minY + 1, rows: rows)
    }

    public static func image(_ grid: PixelGrid, palette: [String: String], dim: Bool) -> CGImage? {
        bitmap(rows: grid.rows) { ch in
            guard let hex = palette[String(ch)] else { return nil }
            return color(hex: hex, dim: dim)
        }
    }

    /// A glyph in one color: `#` is drawn, everything else is transparent.
    public static func glyphImage(_ rows: [String], color hex: String) -> CGImage? {
        bitmap(rows: rows) { ch in
            ch == "#" ? color(hex: hex, dim: false) : nil
        }
    }

    private static func color(hex: String, dim: Bool) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard let (r, g, b) = rgb(fromHex: hex) else { return nil }
        guard dim else { return (r, g, b, 255) }
        let mid: Double = 127.5
        func mix(_ c: UInt8) -> UInt8 { UInt8((Double(c) * 0.5 + mid * 0.5).rounded()) }
        return (mix(r), mix(g), mix(b), UInt8((255 * 0.85).rounded()))
    }

    private static func bitmap(rows: [String], pixel: (Character) -> (UInt8, UInt8, UInt8, UInt8)?) -> CGImage? {
        let height = rows.count
        guard height > 0, let width = rows.first?.count, width > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (row, line) in rows.enumerated() {
            for (col, ch) in line.enumerated() where col < width && ch != "." {
                guard let (r, g, b, a) = pixel(ch) else { continue }
                let offset = (row * width + col) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = a
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func rgb(fromHex hex: String) -> (UInt8, UInt8, UInt8)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        )
    }
}
