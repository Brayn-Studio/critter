import AppKit

/// Makes the transparent parts of the pet panel click-through: the panel only takes the
/// mouse while the pointer is over something clickable (a Clawd, bubble, tag, handle or
/// chips -- `FlockLayout.Result.hitRects`), and lets clicks fall through to whatever is
/// underneath everywhere else.
///
/// A window that ignores mouse events never sees the pointer arrive, so the pointer is
/// followed with a global monitor (events headed to other apps) plus a local one (events
/// headed to this app). While a drag is in progress the panel keeps the mouse throughout.
@MainActor
final class ClickThroughController {
    private weak var panel: NSPanel?
    /// In window coordinates (the panel's content view fills the window).
    private var hitRects: [CGRect] = []
    private var monitors: [Any] = []

    var isDragging = false {
        didSet { update() }
    }

    init(panel: NSPanel) {
        self.panel = panel
        panel.acceptsMouseMovedEvents = true

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Monitors are always called on the main thread.
            MainActor.assumeIsolated { self?.update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.update() }
            return event
        }) {
            monitors.append(local)
        }
        update()
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
