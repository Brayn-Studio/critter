import CritterClient
import SwiftUI

/// The pixel "Critter" (visual design §6, Android `WordmarkImage`): drawn, not typed. `cell` points a cell: first a
/// `shade` copy of the letters one cell lower, then the letters in `ink`, and the dot on the `i` is Sprig's sprout
/// (two leaves over a stem). The defaults are the mockups' ink and shade for the page's appearance.
struct WordmarkView: View {
    var cell: CGFloat
    var ink: Color = Theme.ink
    var shade: Color = Self.defaultShade

    /// Ink at 22 % in the light, black at 35 % in the dark (the mockups' wordmark on the night sky).
    static let defaultShade = Color(light: 0x2A2140, lightOpacity: 0.22, dark: 0x000000, darkOpacity: 0.35)

    private static let leaf = Color(rgb: 0x6BCB5F)
    private static let stem = Color(rgb: 0x3F9442)

    var body: some View {
        Canvas { context, _ in
            let c = cell
            func rect(_ p: WordmarkCell, dy: Int = 0) -> CGRect {
                CGRect(x: CGFloat(p.x) * c, y: CGFloat(p.y + dy) * c, width: c, height: c)
            }
            var shadow = Path()
            var letters = Path()
            var leaves = Path()
            var stems = Path()
            for p in Wordmark.cells {
                switch p.kind {
                case .ink:
                    shadow.addRect(rect(p, dy: 1))
                    letters.addRect(rect(p))
                case .leaf: leaves.addRect(rect(p))
                case .stem: stems.addRect(rect(p))
                }
            }
            context.fill(shadow, with: .color(shade))
            context.fill(letters, with: .color(ink))
            context.fill(leaves, with: .color(Self.leaf))
            context.fill(stems, with: .color(Self.stem))
        }
        .frame(width: CGFloat(Wordmark.width) * cell, height: CGFloat(Wordmark.height + 1) * cell)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Critter"))
        .accessibilityAddTraits(.isImage)
    }
}
