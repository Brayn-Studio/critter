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
        path.addLines([
            CGPoint(x: x0 + n, y: y0), CGPoint(x: x1 - n, y: y0), CGPoint(x: x1 - n, y: y0 + n), CGPoint(x: x1, y: y0 + n),
            CGPoint(x: x1, y: y1 - n), CGPoint(x: x1 - n, y: y1 - n), CGPoint(x: x1 - n, y: y1), CGPoint(x: x0 + n, y: y1),
            CGPoint(x: x0 + n, y: y1 - n), CGPoint(x: x0, y: y1 - n), CGPoint(x: x0, y: y0 + n), CGPoint(x: x0 + n, y: y0 + n),
        ])
        path.closeSubpath()
        return path
    }
}
