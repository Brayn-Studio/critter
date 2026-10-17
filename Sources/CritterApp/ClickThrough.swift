import AppKit

/// Makes the transparent parts of the pet panel click-through: the panel only takes the
/// mouse while the pointer is over something clickable (a Critter, bubble, tag, handle or
/// chips -- `FlockLayout.Result.hitRects`), and lets clicks fall through to whatever is
/// underneath everywhere else.
///
/// A window that ignores mouse events never sees the pointer arrive, so the pointer is
/// followed with a global monitor (events headed to other apps) plus a local one (events
/// headed to this app). While a drag is in progress the panel keeps the mouse throughout.
/// The same monitors report every pointer move (`onPointerMoved`), for the pet's gaze and
/// hover reactions.
@MainActor
final class ClickThroughController {
    private weak var panel: NSPanel?
    /// In window coordinates (the panel's content view fills the window).
    private var hitRects: [CGRect] = []
    private var monitors: [Any] = []

    var isDragging = false {
        didSet { update() }
    }

    /// Every pointer move, anywhere on screen (screen coordinates), after the click-through
    /// state has been updated for it.
    var onPointerMoved: ((NSPoint) -> Void)?

    init(panel: NSPanel) {
        self.panel = panel
        panel.acceptsMouseMovedEvents = true

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Monitors are always called on the main thread.
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
            return event
        }) {
            monitors.append(local)
        }
        update()
    }

    /// A pointer move at `point` (screen coordinates). Also the entry for the debug-only
    /// `critter://debug-pointer`, which feeds made-up positions down the same path.
    func pointerMoved(to point: NSPoint) {
        update()
        onPointerMoved?(point)
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// Call after every re-layout or window move.
    func setHitRects(_ rects: [CGRect]) {
        hitRects = rects
        update()
    }

    func update() {
        guard let panel else { return }
        let wantsMouse: Bool
        if isDragging {
            wantsMouse = true
        } else {
            let mouse = NSEvent.mouseLocation
            let point = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            wantsMouse = panel.isVisible && hitRects.contains { $0.contains(point) }
        }
        if panel.ignoresMouseEvents == wantsMouse {
            panel.ignoresMouseEvents = !wantsMouse
        }
    }
}
