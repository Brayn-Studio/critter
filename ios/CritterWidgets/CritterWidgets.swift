import ActivityKit
import CritterKit
import SwiftUI
import WidgetKit

/// The widget extension: only the Live Activity (spec §8.5), no home screen widgets.
@main
struct CritterWidgets: WidgetBundle {
    var body: some Widget {
        CritterActivityWidget()
    }
}

/// The Live Activity in every place the system shows it (spec §8.5): the lock screen and its banner, StandBy, and the
/// Dynamic Island's compact, minimal and expanded views. What it shows is the Mac's `LiveActivityContent`; its pieces
/// are in `CritterActivityViews.swift`, its pictures in `ActivityPictures.swift`. A tap opens the app.
struct CritterActivityWidget: Widget {
    /// Where a tap goes: the app's home screen (not a pairing link).
    static let homeURL = URL(string: "critter://home")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CritterActivity.self) { context in
            #if DEBUG
            let _ = SharedCheck.answerIfAsked(context.state)
            #endif
            ActivityLockScreen(state: context.state, stale: context.isStale)
                .widgetURL(Self.homeURL)
        } dynamicIsland: { context in
            let state = context.state
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityIslandPile(state: state, stale: stale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // The counts of five states are wider than the room beside the camera: below it, then (what
                    // overlaps the camera's housing is not drawn).
                    ActivityIslandCounts(state: state, stale: stale)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityIslandBottom(state: state, stale: stale)
                }
            } compactLeading: {
                ActivityLone(badge: state.lead, cell: 1.2, grey: stale)
            } compactTrailing: {
                ActivityUrgent(counts: state.counts, look: .island.stale(stale))
            } minimal: {
                ActivityLone(badge: state.lead, cell: 1.05, grey: stale)
            }
            .widgetURL(Self.homeURL)
            .keylineTint(stale ? ActivityLook.island.ink2 : ActivityLook.island.glyph(state.counts.first?.state ?? .idle))
        }
    }
}

/// The lock screen's block in the look of where it is: the light or dark theme on the lock screen, the board's colours
/// on black in StandBy (the system shows the lock screen's view there, full screen), dimmed at night.
private struct ActivityLockScreen: View {
    let state: LiveActivityContent
    let stale: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isActivityFullscreen) private var fullscreen
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        let look: ActivityLook = fullscreen ? .standBy : colorScheme == .dark ? .dark : .light
        ActivityLockView(state: state, stale: stale, look: look, dimmed: fullscreen && luminanceReduced)
            .activityBackgroundTint(look.background)
            .activitySystemActionForegroundColor(look.ink)
    }
}
