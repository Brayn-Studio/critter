import CritterKit
import SwiftUI

/// A `CritterStageView` in SwiftUI: the Critters in `slots`, drawn over whatever is behind (the stage is clear and
/// lets through touches that land on no Critter), with the touch callbacks. Reduce motion comes from the environment
/// (`reduceMotion`). For one-off motions (`lookAtYou`, `sinkAll`…) hand it a `CritterStageControl`.
struct CritterStage: UIViewRepresentable {
    var slots: [CritterSlot]
    var claimAllTouches = false
    var carryOnDrag = false
    var restingGaze: GazeZone?
    /// Stops the clock while still on screen (the board's screen went dark).
    var paused = false
    var control: CritterStageControl?
    var onTap: (String) -> Void = { _ in }
    var onLongDragEnd: (String) -> Void = { _ in }
    var onDragStart: (String) -> Void = { _ in }
    var onDragBy: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onCarry: (String, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> CritterStageView {
        let view = CritterStageView(frame: .zero)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: CritterStageView, context: Context) {
        context.coordinator.stage = self
        view.reduceMotion = context.environment.reduceMotion
        view.claimAllTouches = claimAllTouches
        view.carryOnDrag = carryOnDrag
        view.restingGaze = restingGaze
        view.setPaused(paused)
        if view.slots != slots { view.setActors(slots) }
        control?.view = view
    }

    @MainActor
    final class Coordinator: CritterStageDelegate {
        var stage: CritterStage

        init(_ stage: CritterStage) {
            self.stage = stage
        }

        func onTap(_ sessionId: String) { stage.onTap(sessionId) }
        func onLongDragEnd(_ sessionId: String) { stage.onLongDragEnd(sessionId) }
        func onDragStart(_ sessionId: String) { stage.onDragStart(sessionId) }
        func onDragBy(dx: CGFloat, dy: CGFloat) { stage.onDragBy(dx, dy) }
        func onCarry(_ sessionId: String, away: Bool) { stage.onCarry(sessionId, away) }
    }
}

/// A handle on a `CritterStage`'s view for one-off motions, like a `ScrollViewProxy`: keep one in `@State`, hand it
/// to the stage, call it from actions. Does nothing until the stage is on screen.
@MainActor
final class CritterStageControl {
    fileprivate(set) weak var view: CritterStageView?

    init() {}

    func play(_ sessionId: String, clip: String) { view?.play(sessionId, clip: clip) }
    func notice(_ sessionId: String) { view?.notice(sessionId) }
    func playClip(_ sessionId: String, clip: MotionClip, delay: Duration = .zero) {
        view?.playClip(sessionId, clip: clip, delay: delay)
    }
    func lookAtYou(_ sessionId: String) { view?.lookAtYou(sessionId) }
    func hop(_ sessionId: String, delay: Duration = .zero) { view?.hop(sessionId, delay: delay) }

    /// See `CritterStageView.sinkAll`; `onDone` runs at once when there is no stage.
    func sinkAll(stagger: Duration = .milliseconds(60), onDone: @escaping () -> Void) {
        guard let view else { return onDone() }
        view.sinkAll(stagger: stagger, onDone: onDone)
    }

    func riseAll(stagger: Duration = .milliseconds(90), join: Bool = false) {
        view?.riseAll(stagger: stagger, join: join)
    }
}
