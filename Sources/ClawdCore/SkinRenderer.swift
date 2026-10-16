import CoreGraphics
import Foundation

/// Renders one skin frame (a grid of palette characters) into a tiny RGBA bitmap, one
/// pixel per character, for `ClawdLayer` to scale up with nearest-neighbor filtering.
public enum SkinRenderer {
    public static func image(frame: [String], palette: [String: String], dim: Bool) -> CGImage? {
        let height = frame.count
        guard height > 0, let width = frame.first?.count, width > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for (row, line) in frame.enumerated() {
            for (col, ch) in line.enumerated() {
                guard col < width else { continue }
                guard ch != "." else { continue } // transparent: already zeroed above
                guard let hex = palette[String(ch)], let rgb = rgb(fromHex: hex) else { continue }

                var (r, g, b) = rgb
                var a: UInt8 = 255
                if dim {
                    let mid: Double = 127.5
                    r = UInt8((Double(r) * 0.5 + mid * 0.5).rounded())
                    g = UInt8((Double(g) * 0.5 + mid * 0.5).rounded())
                    b = UInt8((Double(b) * 0.5 + mid * 0.5).rounded())
                    a = UInt8((Double(a) * 0.85).rounded())
                }

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
