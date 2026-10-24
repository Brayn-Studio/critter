import ActivityKit
import CritterKit

/// The Live Activity (spec §8.5), shared by the app (which starts it) and the widget extension (which draws it). The
/// name is the one the Mac's push-to-start gives (`LiveActivityContent.attributesName`); nothing is fixed when it
/// starts (the Mac sends `attributes: {}`), and its state is what the Mac pushes, numbers and names only.
struct CritterActivity: ActivityAttributes {
    typealias ContentState = LiveActivityContent
}
