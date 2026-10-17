import AppKit
import UniformTypeIdentifiers

/// Debug-only (`critter://debug-snapshot`): renders the pet window's layer tree to PNG files,
/// for checking the animation where screen capture isn't available. The window's
/// transparent margin is drawn over an opaque dark gray, so it reads like a dark desktop.
@MainActor
enum DebugSnapshot {
    /// #2B2E36.
    private static let background = CGColor(srgbRed: 0x2B / 255.0, green: 0x2E / 255.0, blue: 0x36 / 255.0, alpha: 1)

    /// Writes one PNG to `path` -- or, with `count` > 1, `<path without extension>-<i>.png`
    /// for i = 1…count, one every `intervalMs` milliseconds starting now.
    static func capture(_ window: NSWindow, path: String, count: Int, intervalMs: Int) {
        let count = max(1, count)
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().path
        for index in 1...count {
            let target = count == 1 ? path : "\(base)-\(index).png"
            let delay = DispatchTimeInterval.milliseconds((index - 1) * max(0, intervalMs))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    let ok = write(window, to: target)
                    let f = window.frame
                    DiagnosticLog.shared.log(ok
                        ? "debug-snapshot wrote \(target) frame=\(f.minX),\(f.minY),\(f.width)x\(f.height)"
                        : "debug-snapshot failed \(target)")
                }
            }
        }
    }

    /// Renders `window`'s content view layer at the window's backing scale into `path`.
    static func write(_ window: NSWindow, to path: String) -> Bool {
        guard let view = window.contentView, let layer = view.layer else { return false }
        let scale = window.backingScaleFactor
        let width = Int((view.bounds.width * scale).rounded(.up))
        let height = Int((view.bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
