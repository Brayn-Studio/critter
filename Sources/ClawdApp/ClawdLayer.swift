import ClawdCore
import CoreGraphics
import QuartzCore

/// Draws one Clawd: the sprite flipbook for whatever `PetState` it's currently in, scaled
/// up with nearest-neighbor filtering so the pixel art stays crisp, plus whatever `Motion`
/// the state's animation spec calls for, plus its text accessory above it. Every pixel of
/// behavior here is driven by the skin's data manifest -- nothing about a specific state's
/// look is hardcoded.
final class ClawdLayer: CALayer {
    /// The skin's logical pixel grid, per the design spec: 18 columns by 5 rows.
    static let pixelColumns = 18
    static let pixelRows = 5
    /// Each logical pixel renders as a `pixelWidthPt` x `pixelHeightPt` rectangle at
    /// `scale == 1`; their 1:2 ratio matches the skin's `pixelAspect`.
    static let pixelWidthPt: CGFloat = 3
    static let pixelHeightPt: CGFloat = 6

    private let skin: SkinManifest
    private let scale: CGFloat
    private var frameImages: [String: CGImage] = [:]
    private var dimFrameImages: [String: CGImage] = [:]
    private let accessoryLayer = CATextLayer()

    init(skin: SkinManifest, scale: CGFloat) {
        self.skin = skin
        self.scale = scale
        super.init()

        let width = CGFloat(Self.pixelColumns) * Self.pixelWidthPt * scale
        let height = CGFloat(Self.pixelRows) * Self.pixelHeightPt * scale
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        magnificationFilter = .nearest
        minificationFilter = .nearest

        for (name, rows) in skin.frames {
            frameImages[name] = SkinRenderer.image(frame: rows, palette: skin.palette, dim: false)
            dimFrameImages[name] = SkinRenderer.image(frame: rows, palette: skin.palette, dim: true)
        }

        accessoryLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        accessoryLayer.position = CGPoint(x: width / 2, y: height + 1 * scale)
        accessoryLayer.bounds = CGRect(x: 0, y: 0, width: width, height: 14 * scale)
        accessoryLayer.alignmentMode = .center
        accessoryLayer.fontSize = 9 * scale
        accessoryLayer.contentsScale = 2
        addSublayer(accessoryLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("ClawdLayer does not support NSCoding")
    }

    /// Core Animation makes shallow copies of a layer (e.g. its presentation layer); this
    /// initializer is required so that copy can share the already-rendered frame cache
    /// instead of re-decoding the skin. The copy is read-only, so `apply` is never called
    /// on it.
    override init(layer: Any) {
        guard let other = layer as? ClawdLayer else {
            fatalError("ClawdLayer(layer:) given a layer of the wrong type")
        }
        skin = other.skin
        scale = other.scale
        frameImages = other.frameImages
        dimFrameImages = other.dimFrameImages
        super.init(layer: layer)
    }

    /// Switches the sprite to `state`'s animation: its frame flipbook (cached `CGImage`s,
    /// discretely keyframed onto `contents`), its layered `Motion`, and its text accessory.
    /// When `reduceMotion` is true, no animation is added at all -- just the first frame,
    /// statically, per the design spec's accessibility requirement.
    func apply(state: PetState, reduceMotion: Bool) {
        guard let spec = skin.animations[state.rawValue] else { return }
        let images = spec.tint == .dim ? dimFrameImages : frameImages
        let frames = spec.frames.compactMap { images[$0] }
        guard let first = frames.first else { return }

        removeAnimation(forKey: "spriteFrames")
        removeAnimation(forKey: "motion")
        transform = CATransform3DIdentity
        contents = first

        if !reduceMotion, frames.count > 1 {
            let flipbook = CAKeyframeAnimation(keyPath: "contents")
            flipbook.values = frames
            flipbook.calculationMode = .discrete
            flipbook.duration = Double(frames.count) / spec.fps
            flipbook.repeatCount = .infinity
            add(flipbook, forKey: "spriteFrames")
        }

        if !reduceMotion, let motion = motionAnimation(for: spec.motion) {
            add(motion, forKey: "motion")
        }

        if let accessory = spec.accessory {
            accessoryLayer.string = accessory.text
            accessoryLayer.foregroundColor = Self.cgColor(hex: accessory.color)
        } else {
            accessoryLayer.string = nil
        }
    }

    private func motionAnimation(for motion: Motion) -> CAAnimation? {
        switch motion {
        case .none:
            return nil
        case .hop:
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = [0, 3 * scale, 0]
            animation.duration = 0.6
            animation.repeatCount = .infinity
            return animation
        case .wiggle:
            let radians = 4.0 * CGFloat.pi / 180
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            animation.values = [0, radians, 0, -radians, 0]
            animation.duration = 0.5
            animation.repeatCount = .infinity
            return animation
        case .breathe:
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1.0, 1.04, 1.0]
            animation.duration = 1.6
            animation.repeatCount = .infinity
            return animation
        }
    }

    private static func cgColor(hex: String) -> CGColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return CGColor(gray: 0.5, alpha: 1)
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
