import CoreGraphics

/// Where the night moon goes on the home meadow (Android `homeMoon`).
public enum HomeMoon {
    /// How far the night moon keeps from the Mac's name, in pt.
    public static let clearance: CGFloat = 4

    /// The mockup's spot for the moon, as fractions of the meadow's width and ground height.
    public static let standard = CGPoint(x: 0.58, y: 0.3)

    /// Where the moon goes, as fractions of `width` and `ground` (as the backdrop takes them): the mockup's
    /// spot, unless the Mac's name reaches it there (the name's box ends at `nameRight` and `nameBottom`, from
    /// the meadow's top left); then it drops to just under the name, in the same column, beside the short
    /// connection tag. A long real name ("文博的MacBook Pro") ran over it once the status bar pushed the header
    /// down, and it stays whole this way.
    public static func position(width: CGFloat, ground: CGFloat, nameRight: CGFloat, nameBottom: CGFloat) -> CGPoint {
        let clear = nameRight + clearance <= width * standard.x || nameBottom + clearance <= ground * standard.y
        return clear ? standard : CGPoint(x: standard.x, y: min((nameBottom + clearance) / ground, 1))
    }
}
