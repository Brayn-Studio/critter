import CritterClient
import SwiftUI
import UIKit

/// The sky and grass behind the Critters (`meadowCells`, Android `MeadowBackdrop`): `size` in points, the ground
/// `ground` from the top, `cell` points a cell; a scene places its own `clouds` and `moon` (fractions, as
/// `meadowCells` takes them) to keep them clear of what it draws on the sky. Painted once into a bitmap per size and
/// sky (`MeadowImages`) and drawn whole: no work per frame, nothing new until the size or the sky changes.
///
/// The cells are laid out in points, as the mockups lay them out in CSS pixels, so the stars and specks are as
/// dense as there (Android lays them out in device pixels and gets several times more).
struct MeadowBackdrop: View {
    let time: SkyTime
    let size: CGSize
    var ground: CGFloat
    var cell: CGFloat = 3
    var clouds: [CGPoint] = defaultMeadowClouds
    var moon: CGPoint = HomeMoon.standard

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = MeadowImages.image(
                time: time, size: size, ground: ground, cell: cell, clouds: clouds, moon: moon, scale: displayScale
            ) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// The meadow pictures drawn so far, a few at most, the most recently used last: a sheet that opens again, or the
/// home screen coming back, finds its picture here.
@MainActor
enum MeadowImages {
    private struct Key: Hashable {
        var time: SkyTime
        var width: Int
        var height: Int
        var ground: Int
        var cell: Int
        var clouds: [CGFloat]
        var moon: [CGFloat]
        var scale: CGFloat
    }

    private static let capacity = 12
    private static var cache: [Key: UIImage] = [:]
    private static var recent: [Key] = []

    /// The meadow `size` points large, at `scale` pixels a point; nil for an empty size.
    static func image(
        time: SkyTime, size: CGSize, ground: CGFloat, cell: CGFloat, clouds: [CGPoint], moon: CGPoint, scale: CGFloat
    ) -> UIImage? {
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let key = Key(
            time: time, width: width, height: height, ground: Int(ground.rounded()), cell: max(1, Int(cell.rounded())),
            clouds: clouds.flatMap { [$0.x, $0.y] }, moon: [moon.x, moon.y], scale: scale
        )
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let cg = context.cgContext
            cg.setShouldAntialias(false)
            for c in meadowCells(
                width: width, height: height, ground: key.ground, cell: key.cell, time: time, clouds: clouds, moon: moon
            ) {
                cg.setFillColor(UIColor(rgb: c.color, alpha: c.opacity).cgColor)
                cg.fill(CGRect(x: c.x, y: c.y, width: c.w, height: c.h))
            }
        }
        cache[key] = image
        touch(key)
        if recent.count > capacity {
            cache[recent.removeFirst()] = nil
        }
        return image
    }

    private static func touch(_ key: Key) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }
}

/// The sky for now (visual design §8.3, Android `currentSkyTime`): from the hour on the phone's clock, which is
/// read once a minute (`TimelineView(.everyMinute)`, not an animation) out of sight of the content, so it changes on
/// the hour, and always night in the dark appearance. The content is only built again when the sky changes, not
/// every minute. `-critterSkyHour <0-23>` (DEBUG) fixes the hour.
struct SkyClock<Content: View>: View {
    @ViewBuilder let content: (SkyTime) -> Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var hour = SkyHour.at(Date())

    var body: some View {
        content(SkyTime.at(hour: hour, dark: colorScheme == .dark))
            .background {
                TimelineView(.everyMinute) { context in
                    Color.clear
                        .onChange(of: SkyHour.at(context.date)) { _, now in hour = now }
                }
                .accessibilityHidden(true)
            }
    }

}

/// The hour the sky follows.
private enum SkyHour {
    static func at(_ date: Date) -> Int {
        #if DEBUG
        if let forced = DebugLaunch.current.skyHour { return forced }
        #endif
        return Calendar.autoupdatingCurrent.component(.hour, from: date)
    }
}
