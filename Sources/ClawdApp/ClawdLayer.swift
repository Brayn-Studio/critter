import ClawdCore
import CoreGraphics
import CoreText
import QuartzCore

/// Draws one Clawd as a static pose (the animation engine arrives in a later task): the
/// state's `still` pose, scaled up with nearest-neighbor filtering so the pixel art stays
/// crisp, plus a text accessory (`accessoryLayer`).
///
/// The accessory is deliberately *not* a sublayer: the sprite's later motion would
/// otherwise drag it along. The host adds `accessoryLayer` next to this layer and places it
/// in the layout's accessory row.
final class ClawdLayer: CALayer {
    /// The skin's base box, per the design spec: 18 by 10 square pixel cells.
    static let pixelColumns = 18
    static let pixelRows = 10
    /// Each pixel cell renders as a `pixelPt` square at `scale == 1`.
    static let pixelPt: CGFloat = 3

    private let skin: SkinManifest
    private let scale: CGFloat
    /// Each state's `still` pose, cropped to the base box (dimmed when the state says so).
    private var stillImages: [PetState: CGImage] = [:]
    private var baseDimImage: CGImage?
    /// The state's text badge (`z z`, `•••`, `?`, `✓`, `!`), for the host to position.
    let accessoryLayer: CATextLayer

    init(skin: SkinManifest, scale: CGFloat) {
        self.skin = skin
        self.scale = scale
        accessoryLayer = CATextLayer()
        super.init()

        let width = CGFloat(Self.pixelColumns) * Self.pixelPt * scale
        let height = CGFloat(Self.pixelRows) * Self.pixelPt * scale
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        magnificationFilter = .nearest
        minificationFilter = .nearest

        for state in PetState.allCases {
            let spec = skin.state(state)
            stillImages[state] = Self.image(pose: spec.still, dim: spec.tint == .dim, in: skin)
        }
        baseDimImage = Self.image(pose: "base", dim: true, in: skin)

        accessoryLayer.alignmentMode = .center
        accessoryLayer.font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 11, nil)
        accessoryLayer.fontSize = 11
    }

    required init?(coder: NSCoder) {
        fatalError("ClawdLayer does not support NSCoding")
    }

    /// Core Animation makes shallow copies of a layer (e.g. its presentation layer); this
    /// initializer is required so that copy can share the already-rendered images instead
    /// of re-decoding the skin. The copy is read-only, so `apply` is never called on it.
    override init(layer: Any) {
        guard let other = layer as? ClawdLayer else {
            fatalError("ClawdLayer(layer:) given a layer of the wrong type")
        }
        skin = other.skin
        scale = other.scale
        stillImages = other.stillImages
        baseDimImage = other.baseDimImage
        accessoryLayer = other.accessoryLayer
        super.init(layer: layer)
    }

    /// Shows `state`'s `still` pose statically (no animation yet) and its text accessory.
    func apply(state: PetState, reduceMotion: Bool) {
        contents = stillImages[state]
        accessoryLayer.string = state.accessory
        accessoryLayer.foregroundColor = Self.cgColor(hex: state.colorHex)
    }

    /// The dimmed `base` pose, as a still -- used for the Clawds stacked behind the front
    /// one in the merged pile.
    func stillImage(for state: PetState) -> CGImage? {
        baseDimImage
    }

    private static func image(pose: String, dim: Bool, in skin: SkinManifest) -> CGImage? {
        guard let grid = SkinRenderer.grid(pose: pose, in: skin) else { return nil }
        let box = grid.cropped(minX: 0, minY: 0, width: pixelColumns, height: pixelRows)
        return SkinRenderer.image(box, palette: skin.palette, dim: dim)
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
