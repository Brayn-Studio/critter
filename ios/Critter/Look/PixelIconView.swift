import CritterClient
import SwiftUI

/// One of the interface icons (visual design §6, Android `PixelIcon`): `cell` points a cell, in the foreground
/// style (the text colour, like Android's `LocalContentColor`). Decorative: the words next to it say what it is.
struct PixelIconView: View {
    let icon: PixelIcon
    var cell: CGFloat = 2

    init(_ icon: PixelIcon, cell: CGFloat = 2) {
        self.icon = icon
        self.cell = cell
    }

    var body: some View {
        let rows = PixelIcons.rows(icon)
        PixelIconShape(icon: icon, cell: cell)
            .frame(width: CGFloat(rows.first?.count ?? 0) * cell, height: CGFloat(rows.count) * cell)
            .accessibilityHidden(true)
    }
}

/// An icon's cells as a shape, `cell` points each, from the top left of the rect: one rectangle per run of a row.
struct PixelIconShape: Shape {
    let icon: PixelIcon
    var cell: CGFloat = 2

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for run in PixelIcons.runs(icon) {
            path.addRect(CGRect(
                x: rect.minX + CGFloat(run.x) * cell, y: rect.minY + CGFloat(run.y) * cell,
                width: CGFloat(run.length) * cell, height: cell
            ))
        }
        return path
    }
}
