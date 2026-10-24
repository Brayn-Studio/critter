import ActivityKit
import SwiftUI
import WidgetKit

/// The widget extension: only the Live Activity (spec §8.5), no home screen widgets. Its look on the lock screen and in
/// the Dynamic Island is plan 4's Task 7; until then it is a bare placeholder.
@main
struct CritterWidgets: WidgetBundle {
    var body: some Widget {
        CritterActivityWidget()
    }
}

struct CritterActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CritterActivity.self) { context in
            Text("\(context.state.total)")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text("\(context.state.total)") }
            } compactLeading: {
                EmptyView()
            } compactTrailing: {
                Text("\(context.state.total)")
            } minimal: {
                EmptyView()
            }
        }
    }
}
