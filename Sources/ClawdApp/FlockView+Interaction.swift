import AppKit
import ClawdCore

/// What the pointer is doing to the flock: the press or drag in progress, and the Clawd it
/// hovers over (design §4.10, §4.11). Owned by `FlockView`.
struct FlockPointer {
    /// Where the button went down (screen coordinates) and the window's origin then; nil
    /// while no button is down.
    var pressLocation: NSPoint?
    var windowOriginAtPress: NSPoint?
    var isDragging = false
    /// The Clawd squeezed by the press (nil: the press hit no Clawd free to react).
    var pressedId: String?
    /// The Clawd lifted by the drag, and the ones walking after it.
    var grabbedId: String?
    var followers: [String] = []
    /// The pointer's previous position in this drag, and when it last moved.
    var lastDragPoint: NSPoint?
    var lastDragMove: TimeInterval = 0
    /// The Clawd under the pointer, the rubbing over it, and the Clawd being petted.
    var hoverId: String?
    var rub = RubDetector()
    var pettingId: String?
    /// The gaze zone each visible Clawd was last given.
    var gaze: [String: GazeZone] = [:]
    /// The press comes from a debug replay, not the mouse button (see `pointerMoved`).
    var simulated = false

    /// The button is up: forget the press and the drag (hover, rubbing and gaze stay).
    mutating func endPress() {
        pressLocation = nil
        windowOriginAtPress = nil
        isDragging = false
        pressedId = nil
        grabbedId = nil
        followers = []
        lastDragPoint = nil
        simulated = false
    }

    /// `id`'s Clawd is gone (or renamed): forget it.
    mutating func forget(_ id: String) {
        gaze[id] = nil
        followers.removeAll { $0 == id }
        if hoverId == id {
            hoverId = nil
            rub.reset()
        }
        if pettingId == id { pettingId = nil }
        if pressedId == id { pressedId = nil }
        if grabbedId == id { grabbedId = nil }
    }
}

/// Pointer interactions: eyes follow the pointer, a Clawd notices it (or wakes up), rubbing
/// back and forth pets it, a press squeezes it and a click boops it, dragging lifts the
/// pressed Clawd while the others walk after the window, and letting go drops it.
///
/// Every actor change goes through `batch`, which first catches the clock up; pointer moves
/// that change nothing (the usual case: the pointer is anywhere on screen) touch no actor
/// and wake no clock.
extension FlockView {
    private static let dragThreshold: CGFloat = 3
    /// While dragged, the held Clawd's swing settles once the pointer has rested this long.
    private static let lagSettleDelay: TimeInterval = 0.12
    /// Lifted this many cells while held.
    private static let heldLift = 3

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        pointerDown(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        pointerDragged(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        pointerUp(at: NSEvent.mouseLocation)
    }

    /// `screen` in view coordinates (the view fills the window).
    private func viewPoint(screen: NSPoint) -> CGPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    /// The Clawd a press at `point` belongs to: its column's Clawd, bubble or tag -- in the
    /// merged pile (count chips included), the lead.
    private func pressTarget(at point: CGPoint) -> String? {
        switch layoutResult.target(at: point) {
        case .slot(let index): layoutResult.slots[index].id
        case .chips: isMerged ? layoutResult.slots.first?.id : nil
        case .handle, nil: nil
        }
    }

    /// Whether `id`'s Clawd can react to the pointer now: on stage, visible, and not hopping
    /// or otherwise in a choreography's hands (a one-shot, mode or follow would cut that short).
    private func isFree(_ id: String) -> Bool {
        guard let actor = actors[id] else { return false }
        return !actor.hidden && !actor.traveling && !isChoreographed(id)
    }

    /// Button down: remember where, and squeeze the Clawd under it.
    func pointerDown(at screen: NSPoint) {
        // A press whose release never arrived lets go first.
        cancelPress()
        pointer.pressLocation = screen
        pointer.windowOriginAtPress = window?.frame.origin
        guard isRunning, let point = viewPoint(screen: screen), let id = pressTarget(at: point) else { return }
        batch {
            endPet()
            guard isFree(id), let actor = actors[id] else { return }
            // A Clawd that dozed off under a resting pointer is woken by the press (its wake-up
            // startle gives way to the squeeze), so it doesn't go back to sleep once let go.
            actor.wake()
            actor.cancelOnce()
            actor.setMode(skin.interactions.press)
            pointer.pressedId = id
        }
        requestRender()
    }

    /// The pointer moved with the button down: past the threshold the whole panel follows it,
    /// the pressed Clawd hangs from the pointer and the others walk after the window.
    func pointerDragged(to screen: NSPoint) {
        guard let start = pointer.pressLocation, let origin = pointer.windowOriginAtPress, let window else { return }
        let dx = screen.x - start.x
        let dy = screen.y - start.y
        if !pointer.isDragging {
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            pointer.isDragging = true
            beginDrag()
            onDragStateChange?(true)
        }
        let before = window.frame.origin
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
        let moved = CGVector(dx: window.frame.minX - before.x, dy: window.frame.minY - before.y)
        let pointerDx = screen.x - (pointer.lastDragPoint ?? start).x
        pointer.lastDragPoint = screen
        pointer.lastDragMove = now
        batch {
            if let id = pointer.grabbedId { actors[id]?.lag = MotionDrag.lag(pointerDx: pointerDx) }
            guard moved.dx != 0 || moved.dy != 0 else { return }
            for id in pointer.followers {
                actors[id]?.followShift(dx: Double(moved.dx / unit), dy: Double(moved.dy / unit))
            }
        }
        requestRender()
    }

    /// The panel was moved by placement mid-drag (the flock changed size): later drag moves
    /// start from there.
    func windowShiftedDuringDrag(by shift: CGVector) {
        guard pointer.isDragging, let origin = pointer.windowOriginAtPress else { return }
        pointer.windowOriginAtPress = NSPoint(x: origin.x + shift.dx, y: origin.y + shift.dy)
    }

    /// Lifts the pressed Clawd (merged: the lead) and sends every other free Clawd after it.
    private func beginDrag() {
        batch {
            endPet()
            pointer.hoverId = nil
            pointer.rub.reset()
            // Nobody watches the pointer while it carries the flock; the next move after the
            // drop sets every gaze afresh.
            for id in pointer.gaze.keys { actors[id]?.setGaze(nil) }
            pointer.gaze = [:]
            guard let id = pointer.pressedId, isFree(id), let grabbed = actors[id] else {
                // The pressed Clawd stopped being free since the press (a hop after a state or
                // width change, a pile seat, a hide): it lets go of the squeeze, and the window
                // moves on its own.
                if let id = pointer.pressedId { releaseMode(id) }
                pointer.pressedId = nil
                pointer.grabbedId = nil
                return
            }
            grabbed.cancelOnce()
            grabbed.setMode(skin.interactions.held)
            grabbed.lift = Self.heldLift
            pointer.grabbedId = id
            let grabbedX = groundOrigin(id)?.x ?? 0
            pointer.followers = []
            for (other, actor) in actors where other != id && isFree(other) {
                let x = groundOrigin(other)?.x ?? 0
                actor.startFollow(lookLeft: grabbedX < x)
                if actor.following { pointer.followers.append(other) }
            }
        }
        DiagnosticLog.shared.log("pointer lift \(pointer.grabbedId ?? "-") followers=\(pointer.followers.sorted().joined(separator: ","))")
    }

    /// Button up: after a drag the held Clawd drops and the others stop once caught up;
    /// otherwise the pressed Clawd boops and the click does what it always did.
    func pointerUp(at screen: NSPoint) {
        let press = pointer
        pointer.endPress()
        guard press.pressLocation != nil else { return }

        if press.isDragging {
            batch {
                if let id = press.grabbedId, let actor = actors[id] {
                    actor.lift = 0
                    actor.lag = 0
                    actor.setMode(nil)
                    if isFree(id) { actor.play(skin.interactions.drop) }
                }
                for id in press.followers { actors[id]?.releaseFollow() }
            }
            // The Clawd under the pointer now counts as hovered already, so the first move
            // after the drop doesn't play its notice on top of the landing.
            if let point = viewPoint(screen: screen) {
                pointer.hoverId = hoverTarget(at: point)
                pointer.rub.reset()
            }
            requestRender()
            DiagnosticLog.shared.log("pointer drop \(press.grabbedId ?? "-")")
            onDragStateChange?(false)
            return
        }

        if let id = press.pressedId {
            batch {
                guard let actor = actors[id] else { return }
                actor.setMode(nil)
                if isFree(id) { actor.play(skin.interactions.boopEnd) }
            }
            requestRender()
        }
        guard let point = viewPoint(screen: screen) else { return }
        click(at: point)
    }

    /// The button went up without the view hearing it (the pet was hidden or rebuilt mid-press,
    /// or the release went elsewhere): let go as if released, without the click, so no Clawd
    /// stays squeezed or lifted and gaze and hover come back.
    func cancelPress() {
        guard pointer.pressLocation != nil else { return }
        let old = pointer
        pointer.endPress()
        batch {
            for id in [old.pressedId, old.grabbedId].compactMap({ $0 }) {
                guard let actor = actors[id] else { continue }
                actor.lift = 0
                actor.lag = 0
                releaseMode(id)
            }
            for id in old.followers { actors[id]?.releaseFollow() }
        }
        requestRender()
        DiagnosticLog.shared.log("pointer press cancelled")
        if old.isDragging { onDragStateChange?(false) }
    }

    /// Ends `id`'s press or held mode (no other mode is the pointer's to end).
    private func releaseMode(_ id: String) {
        guard let actor = actors[id], let mode = actor.modeName,
              mode == skin.interactions.press || mode == skin.interactions.held else { return }
        actor.setMode(nil)
    }

    /// The click's own action: jump back to the session, expand the pile, or merge.
    private func click(at point: CGPoint) {
        switch layoutResult.target(at: point) {
        case .slot(let index):
            if isMerged {
                if canExpand { onExpand?() }
            } else if let session = entries[index].session {
                onClickSession?(session)
            }
        case .chips:
            if canExpand { onExpand?() }
        case .handle:
            onCollapse?()
        case nil:
            break
        }
    }

    // MARK: - Hover, gaze, rubbing

    /// The pointer moved (screen coordinates; from the click-through monitors, so anywhere on
    /// screen). Eyes follow it, the Clawd it arrives on notices it (or wakes up), and rubbing
    /// back and forth over one pets it. Ignored while a button is down or the pet is hidden.
    func pointerMoved(screenPoint screen: NSPoint) {
        // A real press with the button already up: its mouse-up went missing.
        if pointer.pressLocation != nil, !pointer.simulated, NSEvent.pressedMouseButtons & 1 == 0 {
            cancelPress()
        }
        guard isRunning, pointer.pressLocation == nil, window?.isVisible == true,
              let point = viewPoint(screen: screen) else { return }
        let t = now
        let names = skin.interactions
        var changes: [() -> Void] = []

        let hit = hoverTarget(at: point)
        if hit != pointer.hoverId {
            pointer.hoverId = hit
            pointer.rub.reset()
            changes.append { [unowned self] in
                endPet()
                guard let hit, isFree(hit), let actor = actors[hit] else { return }
                if actor.asleep {
                    actor.wake()
                    DiagnosticLog.shared.log("pointer wake \(hit)")
                } else if !actor.isPlayingOnce && actor.modeName == nil {
                    actor.play(names.notice)
                    DiagnosticLog.shared.log("pointer notice \(hit)")
                }
            }
        }
        if let hit, pointer.rub.move(x: point.x, at: t), pointer.pettingId != hit, isFree(hit) {
            changes.append { [unowned self] in
                guard isFree(hit), let actor = actors[hit] else { return }
                actor.setMode(names.pet)
                pointer.pettingId = hit
                DiagnosticLog.shared.log("pointer pet \(hit)")
            }
        }

        // Seated Clawds keep looking ahead (see `setSeatRow`).
        var zones: [String: GazeZone] = [:]
        for (id, actor) in actors where !actor.hidden && !isSeated(id) {
            guard let origin = groundOrigin(id) else { continue }
            let center = CGPoint(x: origin.x + 9 * unit, y: origin.y + 7 * unit)
            zones[id] = MotionGaze.zone(pointer: point, center: center, unit: unit)
        }
        if zones != pointer.gaze {
            let old = pointer.gaze
            pointer.gaze = zones
            changes.append { [unowned self] in
                for id in Set(old.keys).union(zones.keys) where old[id] != zones[id] {
                    actors[id]?.setGaze(zones[id])
                }
            }
        }

        guard !changes.isEmpty else { return }
        batch {
            for change in changes { change() }
        }
        requestRender()
    }

    /// The visible Clawd under `point`, its follow offset included -- merged, the lead, over
    /// the whole pile.
    private func hoverTarget(at point: CGPoint) -> String? {
        if isMerged {
            guard let lead = layoutResult.slots.first?.id, let actor = actors[lead], !actor.hidden,
                  let origin = groundOrigin(lead) else { return nil }
            return MotionHover.contains(pointer: point, anchor: origin, unit: unit, pile: true) ? lead : nil
        }
        for (id, actor) in actors where !actor.hidden {
            guard let origin = groundOrigin(id) else { continue }
            if MotionHover.contains(pointer: point, anchor: origin, unit: unit, offset: actor.followOffset) {
                return id
            }
        }
        return nil
    }

    /// Ends petting (if any): back from the pet mode, with its little ending.
    private func endPet() {
        guard let id = pointer.pettingId else { return }
        pointer.pettingId = nil
        guard let actor = actors[id], actor.modeName == skin.interactions.pet else { return }
        actor.setMode(nil)
        if isFree(id) { actor.play(skin.interactions.petEnd) }
        DiagnosticLog.shared.log("pointer petEnd \(id)")
    }

    // MARK: - Per tick

    /// After every tick's step: petting ends 0.7 s after the last rub, and the held Clawd's
    /// swing settles a cell per tick once the pointer rests.
    func interactionDidStep() {
        let t = now
        if pointer.pettingId != nil, pointer.rub.shouldEnd(at: t) {
            endPet()
            pointer.rub.reset()
        }
        if pointer.isDragging, let id = pointer.grabbedId, let actor = actors[id], actor.lag != 0,
           t - pointer.lastDragMove > Self.lagSettleDelay {
            actor.lag = MotionDrag.settle(actor.lag)
        }
    }

    /// Ticks until the interactions need the clock again: every tick while a Clawd is petted
    /// (to notice the rubbing stop) or the held one still swings.
    func interactionTicksUntilCue() -> Int {
        if pointer.pettingId != nil { return 1 }
        if pointer.isDragging, let id = pointer.grabbedId, let actor = actors[id], actor.drawnLag != 0 { return 1 }
        return TickGrid.maxSleepTicks
    }

    // MARK: - Debug

    /// Debug-only: what the pointer state is (hover, petting, gaze per Clawd) and where each
    /// Clawd's ground origin is on screen, for the `debug-pointer` log line.
    func pointerDebugDescription() -> String {
        let gaze = pointer.gaze.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let origins = actors.keys.sorted().compactMap { id -> String? in
            guard let origin = groundOrigin(id), let window else { return nil }
            let screen = window.convertPoint(toScreen: convert(origin, to: nil))
            guard let actor = actors[id] else { return nil }
            let s = actor.snapshot()
            let look = "\(s.hidden ? "hidden" : "shown") a=\(s.alpha) z=\(s.z) \(s.pose) \(actor.state.rawValue)\(actor.asleep ? "/asleep" : "")"
            return "\(id.prefix(8))@\(Int(screen.x)),\(Int(screen.y))(\(look))"
        }.joined(separator: " ")
        return "hover=\(pointer.hoverId ?? "-") pet=\(pointer.pettingId ?? "-") gaze=[\(gaze)] origins=[\(origins)] unit=\(unit)"
    }

    /// The middle of `target` (a slot's session id, `handle` or `chips`) in screen coordinates.
    private func screenCenter(of target: String) -> NSPoint? {
        let rect: CGRect?
        switch target {
        case "handle": rect = layoutResult.handle
        case "chips": rect = layoutResult.chips
        default: rect = layoutResult.slots.first { $0.id == target }?.clawd
        }
        guard let rect, let window else { return nil }
        return window.convertPoint(toScreen: convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
    }

    /// Debug-only: replays a left click on `target` (a slot's session id, `handle` or
    /// `chips`) -- or, with `menuItem`, a right-click there and that menu choice -- through
    /// the same handlers a real mouse uses. Returns false if there's no such target/item.
    func simulateClick(target: String, menuItem: String?) -> Bool {
        guard let center = screenCenter(of: target), let window else { return false }
        if let menuItem {
            guard let rightDown = NSEvent.mouseEvent(
                with: .rightMouseDown, location: window.convertPoint(fromScreen: center), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            ), let menu = menu(for: rightDown) else { return false }
            DiagnosticLog.shared.log("menu target=\(target) items=" + menu.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|"))
            guard let index = menu.items.firstIndex(where: { $0.title == menuItem }), menu.items[index].isEnabled else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        pointerDown(at: center)
        pointer.simulated = true
        pointerUp(at: center)
        return true
    }

    /// Debug-only: presses on `target`, waits `waitMs`, drags the pointer (dx, dy) points in
    /// `steps` even steps `intervalMs` apart, holds still `holdMs`, and lets go -- through the
    /// same press, drag and release handlers a real mouse uses. Returns false if there's no
    /// such target.
    func simulateDrag(target: String, dx: CGFloat, dy: CGFloat, steps: Int, intervalMs: Int, waitMs: Int,
                      holdMs: Int) -> Bool {
        guard let start = screenCenter(of: target) else { return false }
        let steps = max(1, steps)
        let interval = max(1, intervalMs)
        let wait = max(0, waitMs)
        pointerDown(at: start)
        pointer.simulated = true
        for step in 1...steps {
            let point = NSPoint(x: start.x + dx * CGFloat(step) / CGFloat(steps), y: start.y + dy * CGFloat(step) / CGFloat(steps))
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(wait + step * interval)) { [weak self] in
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self?.pointerDragged(to: point) }
            }
        }
        let end = NSPoint(x: start.x + dx, y: start.y + dy)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(wait + steps * interval + max(0, holdMs))) { [weak self] in
            MainActor.assumeIsolated { self?.pointerUp(at: end) }
        }
        return true
    }
}
