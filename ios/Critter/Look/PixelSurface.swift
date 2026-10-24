import SwiftUI

// The pixel material (visual design §4, Android `pixelSurface`): a face clipped to a `PixelShape`, its darker row
// (the lip) along the bottom like the bottom row of a pet's body, and on coloured faces the three highlight cells at
// the top left. Recessed things (fields, switch tracks, the plan's paper, slider tracks) have the dark row on top.

extension View {
    /// This view on a pixel face of `fill` with stepped corners of `step`, a `lipHeight` row of `lip` along the
    /// bottom (along the top when `inset`), and the three `highlight` cells at the top left (coloured faces only).
    /// With an `outline`, the surface is drawn in two layers, the outline colour outside and the face inset by
    /// `outlineWidth` with the same steps (the outline moved inwards), so the line never breaks at a step. The view
    /// is clipped to the shape.
    ///
    /// Android makes the face's steps a dp smaller; with a 2 dp line on 3 dp steps that leaves the line touching
    /// only at a point at each step, so here the face keeps the steps.
    func pixelSurface(
        fill: Color,
        lip: Color,
        step: CGFloat = 4,
        lipHeight: CGFloat = 4,
        highlight: Color? = nil,
        inset: Bool = false,
        topOnly: Bool = false,
        outline: Color? = nil,
        outlineWidth: CGFloat = 3
    ) -> some View {
        background {
            PixelSurfaceBackground(
                fill: fill, lip: lip, step: step, lipHeight: lipHeight, highlight: highlight, inset: inset,
                topOnly: topOnly, outline: outline, outlineWidth: outlineWidth
            )
        }
        .clipShape(PixelShape(step: step, topOnly: topOnly))
    }

    /// A `width` ring of `color` along this view's stepped edge (`step`), drawn over it and not taking any room: the
    /// outer stepped outline filled, the same outline moved `width` inwards cut out. For a frame around something
    /// that is not a single surface (a chosen tile); a surface's own edge is `pixelSurface(outline:)`.
    func pixelOutline(color: Color, width: CGFloat = 3, step: CGFloat = 4) -> some View {
        overlay {
            PixelRing(step: step, width: width)
                .fill(color, style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
        }
    }
}

private struct PixelSurfaceBackground: View {
    var fill: Color
    var lip: Color
    var step: CGFloat
    var lipHeight: CGFloat
    var highlight: Color?
    var inset: Bool
    var topOnly: Bool
    var outline: Color?
    var outlineWidth: CGFloat

    var body: some View {
        ZStack {
            if let outline {
                PixelShape(step: step, topOnly: topOnly).fill(outline)
            }
            ZStack(alignment: inset ? .top : .bottom) {
                Rectangle().fill(fill)
                if lipHeight > 0 {
                    Rectangle().fill(lip).frame(height: lipHeight)
                }
            }
            .overlay {
                if let highlight {
                    HighlightCells(cell: step).fill(highlight)
                }
            }
            .clipShape(PixelShape(step: step, topOnly: topOnly))
            .padding(outline == nil ? 0 : outlineWidth)
        }
    }
}

/// The pet body's highlight: two cells on the second row, one on the third, `cell` square (the step), at the top
/// left: (2c, c), (3c, c), (c, 2c).
struct HighlightCells: Shape {
    var cell: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = min(cell, (min(rect.width, rect.height) / 4).rounded(.down))
        guard c > 0 else { return Path() }
        var path = Path()
        for (x, y) in [(2.0, 1.0), (3, 1), (1, 2)] {
            path.addRect(CGRect(x: rect.minX + x * c, y: rect.minY + y * c, width: c, height: c))
        }
        return path
    }
}

/// The stepped outline of a rect and the same outline moved `width` inwards (fill it even-odd): a ring of even width
/// that keeps its steps.
struct PixelRing: Shape {
    var step: CGFloat
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = PixelShape(step: step).path(in: rect)
        let inner = rect.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 {
            path.addPath(PixelShape(step: step).path(in: inner))
        }
        return path
    }
}
