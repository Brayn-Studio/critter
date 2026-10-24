import CritterClient
import SwiftUI

/// The pet body's stepped corners as a shape (visual design §4, Android `PixelShape`): two steps of `step` at each
/// corner, or only at the top (`topOnly`, for sheets). Steps: cards 4, buttons and fields 3, small tags 2, big panels
/// 5, a sheet's top 6.
struct PixelShape: Shape {
    var step: CGFloat
    var topOnly = false

    func path(in rect: CGRect) -> Path {
        let points = PixelOutline.points(width: rect.width, height: rect.height, step: step, topOnly: topOnly)
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        path.closeSubpath()
        return path
    }
}

/// A square with one notch of `notch` at each corner: the marker of a question that takes several answers.
struct NotchedSquare: Shape {
    var notch: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let n = notch
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        var path = Path()
        let corners: [(CGFloat, CGFloat)] = [
            (x0 + n, y0), (x1 - n, y0), (x1 - n, y0 + n), (x1, y0 + n),
            (x1, y1 - n), (x1 - n, y1 - n), (x1 - n, y1), (x0 + n, y1),
            (x0 + n, y1 - n), (x0, y1 - n), (x0, y0 + n), (x0 + n, y0 + n),
        ]
        path.addLines(corners.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        return path
    }
}
