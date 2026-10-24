import CritterKit
import QuartzCore
import UIKit

/// One Critter to draw (Android `CritterSlot`). `origin` is in view points, y down: where the base box's column 0
/// meets the ground; `scale` is points per cell. `seatRow` puts it on the back of a pile (dimmed, still, no shadow);
/// `sleeping` shows an idle Critter dozing (the offline pile, an empty meadow).
struct CritterSlot: Equatable {
    var sessionId: String
    var manifest: SkinManifest
    var state: PetState
    var activity: String?
    var dimStrength: Double
    var origin: CGPoint
    var scale: CGFloat
    var seatRow: Int?
    var sleeping = false
}

/// What touching a Critter on a stage tells its owner (Android `CritterTouchListener`).
@MainActor
protocol CritterStageDelegate: AnyObject {
    /// A touch that was neither a drag nor a rub: the Critter was booped.
    func onTap(_ sessionId: String)
    /// The finger let go after lifting the Critter (it has been dropped).
    func onLongDragEnd(_ sessionId: String)
    /// The finger moved past the drag threshold: the Critter is lifted.
    func onDragStart(_ sessionId: String)
    /// The finger's whole movement since it touched down, in screen points, while the Critter is held.
    func onDragBy(dx: CGFloat, dy: CGFloat)
    /// With `carryOnDrag`: the Critter was carried away from its place (`away`), or is back in it.
    func onCarry(_ sessionId: String, away: Bool)
}

extension CritterStageDelegate {
    func onDragStart(_ sessionId: String) {}
    func onDragBy(dx: CGFloat, dy: CGFloat) {}
    func onCarry(_ sessionId: String, away: Bool) {}
}

/// Draws one or more Critters with the desktop's layers (`CritterSpriteLayer`), advances them on a clock that only
/// wakes when the picture can next change (`MotionClock`) and stops while it cannot be seen, and reacts to touch the
/// way the pet reacts to the mouse (spec §8.2, Android `CritterView`): a press is noticed (sleepers wake, the others
/// reach up), a drag past 3 pt lifts, a release drops or boops, rubbing back and forth pets, and the others look at
/// the finger. No hover on a phone: nothing happens without a finger on the screen.
///
/// The sprite layers sit in a container whose geometry is flipped, so their y-up coordinates are the Mac's.
final class CritterStageView: UIView {
    private final class Entry {
        var slot: CritterSlot
        let actor: MotionActor
        var layer: CritterSpriteLayer

        init(slot: CritterSlot, actor: MotionActor, layer: CritterSpriteLayer) {
            self.slot = slot
            self.actor = actor
            self.layer = layer
        }
    }

    private final class Press {
        let id: String
        let downRaw: CGPoint
        var dragging = false
        var grabbedId: String?
        var lastRawX: CGFloat
        var lastMove: TimeInterval = 0
        var squeezed = false
        var carrying = false

        init(id: String, downRaw: CGPoint) {
            self.id = id
            self.downRaw = downRaw
            lastRawX = downRaw.x
        }
    }

    weak var delegate: CritterStageDelegate?

    /// A touch that lands on no Critter counts for the first one (a pile's label and counts belong to it).
    var claimAllTouches = false

    /// A drag carries the lifted Critter sideways inside the view, and once let go it lands and walks back to its
    /// place (the board, spec §8.7). Off, the Critter stays put and `onDragBy` reports the finger instead.
    var carryOnDrag = false

    /// Where the Critters look while no finger is down; nil looks straight ahead. A finger still drives the gaze and
    /// hands it back when it lifts. The engine only lets idle and done Critters look.
    var restingGaze: GazeZone? {
        didSet {
            guard restingGaze != oldValue else { return }
            clock.catchUp()
            applyRestingGaze()
            clock.poke()
        }
    }

    /// Reduce motion: the app's switch or the system's (`PhoneSettings.motionReduced`); Critters keep their
    /// representative poses.
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            clock.catchUp()
            for entry in entries.values { entry.actor.reduceMotion = reduceMotion }
            clock.poke()
        }
    }

    /// The slots last given to `setActors`.
    private(set) var slots: [CritterSlot] = []

    /// How many ticks changed the picture (a sprite layer actually rendered something new).
    private(set) var frameCount = 0

    #if DEBUG
    /// `frameCount` over every stage, for `-critterFrameLog`.
    static var framesDrawn = 0
    /// The same by the screen the stages are on (`critterFrameTag`): every tag a stage has had, from 0.
    static var framesByTag: [String: Int] = [:]
    /// The screen this stage counts its frames for (`critterFrameTag`).
    var frameTag = "other" {
        didSet {
            if Self.framesByTag[frameTag] == nil { Self.framesByTag[frameTag] = 0 }
        }
    }
    #endif

    private static let dragThreshold: CGFloat = 3
    private static let hitSlop: CGFloat = 6
    private static let heldLift = 3
    private static let lagSettleDelay: TimeInterval = 0.12
    private static let baseColumns: CGFloat = 18
    /// How deep a sunk Critter is held: its whole body under the ground.
    private static let undergroundCells = 12

    private let container = CALayer()
    private var entries: [String: Entry] = [:]
    /// Drawing order among Critters of the same depth: later ones on top.
    private var ids: [String] = []
    private var clock: MotionClock
    private var paused = false
    private var inForeground = UIApplication.shared.applicationState != .background

    private var press: Press?
    private var touch: UITouch?
    private var pettingId: String?
    private var rub = RubDetector()
    private var gaze: [String: GazeZone?] = [:]
    /// Scroll views around the stage held still while a Critter is carried.
    private var heldScrollViews: [UIScrollView] = []

    /// Carried Critters, from the lift until they are back in their place (`onCarry`), and those walking back.
    private var away: Set<String> = []
    private var homing: Set<String> = []

    /// Clips waiting for their delay (`playClip`); dropped when the view leaves the window.
    private var delayedClips: [Task<Void, Never>] = []

    // The staggered steps of the latest sink or rise; a newer one cancels them.
    private var staged: [Task<Void, Never>] = []
    private var showHideGeneration = 0
    private var sinking: Set<String>?
    private var sinkDone: (() -> Void)?
    /// Held under ground by `riseAll` and not released yet.
    private var rising: Set<String>?

    override init(frame: CGRect) {
        clock = MotionClock(tickMs: 60)
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        container.isGeometryFlipped = true
        container.masksToBounds = false
        layer.addSublayer(container)
        clock.onTick = { [weak self] ticks in self?.tick(ticks) ?? TickGrid.maxSleepTicks }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self, selector: #selector(enteringForeground), name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CritterStageView is made in code")
    }

    // MARK: - Actors

    func setActors(_ list: [CritterSlot]) {
        slots = list
        // One clock for the whole view, on its skins' tick (the library only lets skins on one tick share a row).
        if let first = list.first { retune(first.manifest.tickMs) }
        clock.catchUp()
        let wanted = Set(list.map(\.sessionId))
        for id in ids where !wanted.contains(id) { remove(id) }
        ids = []
        for slot in list where !ids.contains(slot.sessionId) {
            ids.append(slot.sessionId)
            if let entry = entries[slot.sessionId], entry.slot.manifest == slot.manifest {
                update(entry, slot)
            } else {
                if entries[slot.sessionId] != nil { remove(slot.sessionId) }
                entries[slot.sessionId] = makeEntry(slot)
            }
        }
        applyRestingGaze()
        clock.poke()
    }

    /// Plays clip `clip` (by name) once on one Critter, if it is free (the "notice" hop when a session starts
    /// waiting).
    func play(_ sessionId: String, clip: String) {
        clock.catchUp()
        if isFree(sessionId) { entries[sessionId]?.actor.play(clip) }
        clock.poke()
    }

    /// The hop a Critter makes when it needs you (the skin's `notice`).
    func notice(_ sessionId: String) {
        guard let notice = entries[sessionId]?.slot.manifest.interactions.notice else { return }
        play(sessionId, clip: notice)
    }

    /// Plays `clip` once on one Critter after `delay`, if it is free by then; under reduce motion it keeps its
    /// still pose.
    func playClip(_ sessionId: String, clip: MotionClip, delay: Duration = .zero) {
        if delay > .zero {
            let task = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.playClip(sessionId, clip: clip)
            }
            delayedClips.append(task)
            return
        }
        clock.catchUp()
        if !reduceMotion, isFree(sessionId) { entries[sessionId]?.actor.play(clip: clip, name: nil) }
        clock.poke()
    }

    /// The Critter looks up at you (`MotionCues.lookAtYou`): a sheet just settled over it.
    func lookAtYou(_ sessionId: String) {
        guard let skin = entries[sessionId]?.slot.manifest else { return }
        playClip(sessionId, clip: MotionCues.lookAtYou(skin))
    }

    /// One small hop (`MotionCues.hop`) after `delay`.
    func hop(_ sessionId: String, delay: Duration = .zero) {
        guard let skin = entries[sessionId]?.slot.manifest else { return }
        playClip(sessionId, clip: MotionCues.hop(skin), delay: delay)
    }

    /// Every Critter in view sinks into the ground (`vanish`), `stagger` after the previous one, and stays there;
    /// then `onDone`, unless `riseAll` or another sink came first. At once under reduce motion or out of sight (the
    /// desktop's `FlockChoreographer.playVanish`).
    func sinkAll(stagger: Duration = .milliseconds(60), onDone: @escaping () -> Void) {
        let generation = newShowHide()
        clock.catchUp()
        let sinkIds = ids.filter { entries[$0].map { !$0.actor.hidden && $0.actor.underground == nil } ?? false }
        sinking = Set(sinkIds)
        sinkDone = onDone
        if sinkIds.isEmpty || reduceMotion || !clock.isRunning {
            finishSink()
            return
        }
        for (i, id) in sinkIds.enumerated() {
            later(after: stagger * i) { [weak self] in self?.sinkOut(id, generation: generation) }
        }
    }

    /// Every Critter in view comes up out of the ground, `stagger` after the previous one: `appear`, or with `join`
    /// the skin's `join` (it looks left and right on the way up). Those still above ground go under first; a sink in
    /// progress is called off (the desktop's `FlockChoreographer.playAppear`).
    func riseAll(stagger: Duration = .milliseconds(90), join: Bool = false) {
        newShowHide()
        clock.catchUp()
        let riseIds = ids.filter { entries[$0].map { !$0.actor.hidden } ?? false }
        for id in riseIds {
            if let actor = entries[id]?.actor, actor.underground == nil {
                actor.holdUnderground(depth: Self.undergroundCells)
            }
        }
        rising = Set(riseIds)
        if reduceMotion {
            finishRise()
        } else {
            for (i, id) in riseIds.enumerated() {
                later(after: stagger * i) { [weak self] in self?.riseUp(id, join: join) }
            }
        }
        clock.poke()
    }

    #if DEBUG
    /// Holds one Critter up as if a finger had lifted it (`-critterGalleryHold`): its shadow shows under it.
    func debugHold(_ sessionId: String) {
        guard let actor = entries[sessionId]?.actor, isFree(sessionId) else { return }
        clock.catchUp()
        actor.setMode(actor.skin.interactions.held)
        actor.lift = Self.heldLift
        clock.poke()
    }
    #endif

    /// Stops the clock without leaving the window (the board's screen went dark); false resumes it.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        updateRunning()
    }

    private func makeEntry(_ slot: CritterSlot) -> Entry {
        let actor = MotionActor(skin: slot.manifest, rng: .system(), reduceMotion: reduceMotion)
        actor.setActivity(slot.activity)
        actor.enterState(slot.state, quiet: true)
        if slot.sleeping { actor.sleepNow() }
        let entry = Entry(slot: slot, actor: actor, layer: makeLayer(slot))
        if let row = slot.seatRow { seat(actor, row: row) }
        container.addSublayer(entry.layer)
        place(entry)
        return entry
    }

    /// A sprite layer for `slot`: its unit and its atlas (the dimming) are fixed for the layer's life.
    private func makeLayer(_ slot: CritterSlot) -> CritterSpriteLayer {
        let layer = CritterSpriteLayer(
            atlas: AtlasPool.atlas(slot.manifest, dimStrength: slot.dimStrength), unit: slot.scale
        )
        layer.seatRow = slot.seatRow
        return layer
    }

    private func update(_ entry: Entry, _ slot: CritterSlot) {
        let actor = entry.actor
        let old = entry.slot
        entry.slot = slot
        if slot.scale != old.scale || AtlasPool.quantize(slot.dimStrength) != AtlasPool.quantize(old.dimStrength) {
            let layer = makeLayer(slot)
            container.replaceSublayer(entry.layer, with: layer)
            entry.layer = layer
        }
        entry.layer.seatRow = slot.seatRow
        place(entry)
        actor.setActivity(slot.activity)
        if slot.state != actor.state { actor.enterState(slot.state) }
        if slot.sleeping && !actor.asleep { actor.sleepNow() }
        if !slot.sleeping && old.sleeping { actor.wake() }
        if slot.seatRow != old.seatRow {
            if let row = slot.seatRow {
                seat(actor, row: row)
            } else {
                actor.brainEnabled = true
                actor.unseat()
            }
        }
    }

    /// A pile member behind the lead: hops onto its row, then stays there dimmed and quiet.
    private func seat(_ actor: MotionActor, row: Int) {
        actor.brainEnabled = false
        actor.noAccessory = true
        actor.travel(fromDx: 0, fromDy: 0, delay: 0, seat: PileSeating.seat(row: row))
    }

    /// Where `entry`'s layer goes in the flipped container: the slot's y-down origin, measured from the bottom.
    private func place(_ entry: Entry) {
        entry.layer.groundOrigin = CGPoint(x: entry.slot.origin.x, y: bounds.height - entry.slot.origin.y)
    }

    private func remove(_ id: String) {
        entries[id]?.layer.removeFromSuperlayer()
        entries[id] = nil
        forget(id)
    }

    private func forget(_ id: String) {
        gaze[id] = nil
        homing.remove(id)
        rising?.remove(id)
        sinkFinished(id)
        if pettingId == id { pettingId = nil }
        if let p = press, p.id == id || p.grabbedId == id {
            press = nil
            touch = nil
            holdScrollViews(false)
        }
        // Gone (or rebuilt at home) while carried or walking back: it is not away any more.
        if away.remove(id) != nil { delegate?.onCarry(id, away: false) }
    }

    private func retune(_ tickMs: Int) {
        guard tickMs != clockTickMs else { return }
        clock.catchUp()
        let running = clock.isRunning
        clock.stop()
        clock = MotionClock(tickMs: tickMs)
        clockTickMs = tickMs
        clock.onTick = { [weak self] ticks in self?.tick(ticks) ?? TickGrid.maxSleepTicks }
        if running { clock.start() }
    }

    private var clockTickMs = 60

    // MARK: - Lifetime

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
        for entry in entries.values { place(entry) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRunning()
        if window == nil {
            finishRise()
            for task in delayedClips { task.cancel() }
            delayedClips.removeAll()
        }
    }

    @objc private func enteredBackground() {
        inForeground = false
        updateRunning()
    }

    @objc private func enteringForeground() {
        inForeground = true
        updateRunning()
    }

    private func updateRunning() {
        if window != nil && inForeground && !paused {
            clock.start()
        } else {
            if window == nil || !inForeground { cancelPress() }
            clock.stop()
            // Nobody can watch it sink: done now.
            finishSink()
        }
    }

    // MARK: - Sink and rise

    /// Calls off the previous sink or rise (its steps, and a sink's `onDone`) and starts a new one.
    @discardableResult
    private func newShowHide() -> Int {
        cancelStaged()
        sinking = nil
        sinkDone = nil
        rising = nil
        showHideGeneration += 1
        return showHideGeneration
    }

    /// Runs `step` after `delay` (now for none), unless a newer sink or rise cancels it first.
    private func later(after delay: Duration, _ step: @escaping @MainActor () -> Void) {
        guard delay > .zero else {
            step()
            return
        }
        staged.append(Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            step()
        })
    }

    private func cancelStaged() {
        for task in staged { task.cancel() }
        staged.removeAll()
    }

    private func sinkOut(_ id: String, generation: Int) {
        guard let actor = entries[id]?.actor else { return sinkFinished(id) }
        guard actor.underground == nil else { return sinkFinished(id) }
        clock.catchUp()
        actor.holdUnderground(depth: Self.undergroundCells)
        if reduceMotion {
            sinkFinished(id)
        } else {
            actor.play(actor.skin.interactions.vanish) { [weak self] _ in
                guard let self, generation == showHideGeneration else { return }
                sinkFinished(id)
            }
        }
        clock.poke()
    }

    private func sinkFinished(_ id: String) {
        guard sinking != nil, sinking?.remove(id) != nil, sinking?.isEmpty == true else { return }
        finishSink()
    }

    /// Ends the sink in progress (if any): whoever is still above ground goes under at once, then its `onDone`.
    private func finishSink() {
        guard let done = sinkDone else { return }
        cancelStaged()
        sinking = nil
        sinkDone = nil
        for entry in entries.values where !entry.actor.hidden && entry.actor.underground == nil {
            entry.actor.holdUnderground(depth: Self.undergroundCells)
        }
        clock.poke()
        done()
    }

    /// Ends the rise in progress (if any): whoever is still held comes up at once, without the animation.
    private func finishRise() {
        guard let left = rising else { return }
        cancelStaged()
        rising = nil
        for id in left { entries[id]?.actor.releaseUnderground() }
        clock.poke()
    }

    private func riseUp(_ id: String, join: Bool) {
        rising?.remove(id)
        guard let actor = entries[id]?.actor else { return }
        clock.catchUp()
        actor.releaseUnderground()
        if !reduceMotion { actor.play(join ? actor.skin.interactions.join : actor.skin.interactions.appear) }
        clock.poke()
    }

    // MARK: - Clock

    /// Advances every actor `ticks` ticks, renders what changed, and returns the ticks until the next change.
    private func tick(_ ticks: Int) -> Int {
        for _ in 0..<ticks {
            for id in ids { entries[id]?.actor.step() }
            interactionDidStep()
        }
        if !homing.isEmpty { reportHome() }
        var changed = false
        var next = TickGrid.maxSleepTicks
        for id in ids {
            guard let entry = entries[id] else { continue }
            let snapshot = entry.actor.snapshot()
            if entry.layer.needsRender(snapshot) {
                entry.layer.render(snapshot)
                changed = true
            }
            if !entry.actor.hidden || entry.actor.isPlayingOnce {
                next = min(next, entry.actor.ticksUntilChange())
            }
        }
        if changed {
            frameCount += 1
            #if DEBUG
            Self.framesDrawn += 1
            Self.framesByTag[frameTag, default: 0] += 1
            #endif
        }
        return min(next, interactionTicksUntilCue())
    }

    // MARK: - Touch

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func isFree(_ id: String) -> Bool {
        guard let a = entries[id]?.actor else { return false }
        return !a.hidden && !a.traveling && !a.following && a.underground == nil
    }

    /// The visible Critter a touch at `point` belongs to: its base box plus the room above it, with some slop; the
    /// nearest when several are there.
    private func hit(_ point: CGPoint) -> String? {
        let slop = Self.hitSlop
        var best: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for id in ids {
            guard let entry = entries[id], !entry.actor.hidden else { continue }
            let u = entry.slot.scale
            let left = entry.slot.origin.x
            let ground = entry.slot.origin.y
            guard point.x >= left - slop, point.x <= left + Self.baseColumns * u + slop,
                  point.y >= ground - 12 * u - slop, point.y <= ground + slop
            else { continue }
            let d = hypot(point.x - (left + 9 * u), point.y - (ground - 5 * u))
            if d < bestDistance {
                bestDistance = d
                best = id
            }
        }
        guard best == nil, claimAllTouches else { return best }
        // The pile's front Critter (not a seated one behind it) takes the touches nobody else was under.
        return ids.first { entries[$0]?.slot.seatRow == nil } ?? ids.first
    }

    /// Touches that land on no Critter go through to what is behind the stage.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && hit(point) != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        cancelPress()
        let point = first.location(in: self)
        guard let id = hit(point) else { return }
        touch = first
        press = Press(id: id, downRaw: first.location(in: nil))
        // A swipe that starts on a carried Critter carries it: the scroll view around it must not take it over.
        if carryOnDrag { holdScrollViews(true) }
        clock.catchUp()
        endPet()
        if isFree(id), let actor = entries[id]?.actor {
            // A sleeper is woken by the touch (its startle gives way to the squeeze).
            actor.wake()
            actor.cancelOnce()
            actor.setMode(actor.skin.interactions.press)
            press?.squeezed = true
        }
        updateGaze(point)
        clock.poke()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch), let p = press else { return }
        clock.catchUp()
        let t = now
        let raw = touch.location(in: nil)
        if !p.dragging {
            if hypot(raw.x - p.downRaw.x, raw.y - p.downRaw.y) >= Self.dragThreshold {
                p.dragging = true
                beginDrag(p)
            } else {
                updateGaze(touch.location(in: self))
            }
        }
        if p.dragging {
            if let id = p.grabbedId, let grabbed = entries[id]?.actor, pettingId == nil {
                grabbed.lag = MotionDrag.lag(pointerDx: raw.x - p.lastRawX)
                p.lastMove = t
                if p.carrying {
                    carry(p, to: raw.x)
                } else {
                    delegate?.onDragBy(dx: raw.x - p.downRaw.x, dy: raw.y - p.downRaw.y)
                }
            }
            p.lastRawX = raw.x
        }
        // Rubbing back and forth pets, even after the drag started lifting it (not one carried across the view).
        if !p.carrying, rub.move(x: raw.x, at: t), pettingId != p.id, isFree(p.id) { startPet(p) }
        clock.poke()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        pointerUp()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        cancelPress()
    }

    private func beginDrag(_ p: Press) {
        endPet()
        rub.reset()
        clearGaze()
        guard let grabbed = entries[p.id]?.actor, isFree(p.id) else {
            releaseMode(p.id)
            return
        }
        grabbed.cancelOnce()
        grabbed.setMode(grabbed.skin.interactions.held)
        grabbed.lift = Self.heldLift
        p.grabbedId = p.id
        p.lastMove = now
        delegate?.onDragStart(p.id)
        if carryOnDrag {
            p.carrying = true
            away.insert(p.id)
            delegate?.onCarry(p.id, away: true)
        }
    }

    /// The carried Critter follows the finger sideways, its base box kept inside the view.
    private func carry(_ p: Press, to rawX: CGFloat) {
        guard let entry = entries[p.id] else { return }
        let u = entry.slot.scale
        let low = -entry.slot.origin.x / u
        let high = max(low, (bounds.width - entry.slot.origin.x) / u - Self.baseColumns)
        entry.actor.carry(dxCells: Double(min(max((rawX - p.downRaw.x) / u, low), high)))
    }

    /// Lets go of a carried Critter: it lands where it is (`drop`), then walks home; straight home under reduce
    /// motion.
    private func putDown(_ id: String, _ actor: MotionActor) {
        if reduceMotion || !isFree(id) {
            sendHome(id, actor)
            return
        }
        actor.play(actor.skin.interactions.drop) { [weak self] _ in
            guard let self, entries[id]?.actor === actor else { return }
            sendHome(id, actor)
        }
    }

    private func sendHome(_ id: String, _ actor: MotionActor) {
        actor.walkHome()
        homing.insert(id)
    }

    /// Carried Critters that are back in their place: the place is theirs again.
    private func reportHome() {
        let home = homing.filter { entries[$0]?.actor.following != true }
        homing.subtract(home)
        for id in home where away.remove(id) != nil { delegate?.onCarry(id, away: false) }
    }

    private func startPet(_ p: Press) {
        guard let actor = entries[p.id]?.actor else { return }
        actor.lift = 0
        actor.lag = 0
        actor.setMode(actor.skin.interactions.pet)
        pettingId = p.id
        p.grabbedId = nil
    }

    private func pointerUp() {
        guard let p = press else { return }
        press = nil
        touch = nil
        holdScrollViews(false)
        clock.catchUp()
        clearGaze()
        rub.reset()
        let actor = entries[p.id]?.actor
        if pettingId != nil {
            endPet() // a rub is not a tap
            if p.dragging { delegate?.onLongDragEnd(p.id) }
        } else if p.dragging {
            if let actor, p.grabbedId != nil {
                actor.lift = 0
                actor.lag = 0
                actor.setMode(nil)
                if p.carrying {
                    putDown(p.id, actor)
                } else if isFree(p.id) {
                    actor.play(actor.skin.interactions.drop)
                }
            }
            clock.poke()
            delegate?.onLongDragEnd(p.id)
            return
        } else {
            if let actor, p.squeezed {
                actor.setMode(nil)
                if isFree(p.id) { actor.play(actor.skin.interactions.boopEnd) }
            }
            clock.poke()
            delegate?.onTap(p.id)
            return
        }
        clock.poke()
    }

    /// The touch ended without a release (the view was hidden, a scroll took it over): let go without the click.
    private func cancelPress() {
        guard let p = press else { return }
        press = nil
        touch = nil
        holdScrollViews(false)
        for id in Set([p.id] + (p.grabbedId.map { [$0] } ?? [])) {
            guard let actor = entries[id]?.actor else { continue }
            actor.lift = 0
            actor.lag = 0
            releaseMode(id)
        }
        if p.carrying {
            entries[p.id]?.actor.carry(dxCells: 0)
            if away.remove(p.id) != nil { delegate?.onCarry(p.id, away: false) }
        }
        endPet()
        clearGaze()
        rub.reset()
        clock.poke()
    }

    private func releaseMode(_ id: String) {
        guard let actor = entries[id]?.actor, let mode = actor.modeName else { return }
        if mode == actor.skin.interactions.press || mode == actor.skin.interactions.held { actor.setMode(nil) }
    }

    /// Ends petting (if any): back from the pet mode, with its little ending.
    private func endPet() {
        guard let id = pettingId else { return }
        pettingId = nil
        guard let actor = entries[id]?.actor, actor.modeName == actor.skin.interactions.pet else { return }
        actor.setMode(nil)
        if isFree(id) { actor.play(actor.skin.interactions.petEnd) }
    }

    /// The others look at the finger (the pressed one is busy with its own mode). `MotionGaze` is y up.
    private func updateGaze(_ point: CGPoint) {
        let pointer = CGPoint(x: point.x, y: -point.y)
        for id in ids {
            guard let entry = entries[id], !entry.actor.hidden, entry.slot.seatRow == nil else { continue }
            let u = entry.slot.scale
            let center = CGPoint(x: entry.slot.origin.x + 9 * u, y: -entry.slot.origin.y + 7 * u)
            let zone = MotionGaze.zone(pointer: pointer, center: center, unit: u)
            if gaze[id] != zone {
                gaze[id] = .some(zone)
                entry.actor.setGaze(zone)
            }
        }
    }

    private func clearGaze() {
        for id in gaze.keys { entries[id]?.actor.setGaze(nil) }
        gaze.removeAll()
        applyRestingGaze()
    }

    /// With no finger down, every Critter looks at `restingGaze` (a finger's gaze wins while it is down).
    private func applyRestingGaze() {
        guard press == nil else { return }
        for entry in entries.values { entry.actor.setGaze(restingGaze) }
    }

    /// After every tick's step: petting ends 0.7 s after the last rub, and the held Critter's swing settles.
    private func interactionDidStep() {
        let t = now
        if pettingId != nil, rub.shouldEnd(at: t) {
            endPet()
            rub.reset()
        }
        guard let p = press, let id = p.grabbedId, let actor = entries[id]?.actor else { return }
        if p.dragging, actor.lag != 0, t - p.lastMove > Self.lagSettleDelay { actor.lag = MotionDrag.settle(actor.lag) }
    }

    /// Ticks until the interactions need the clock again: every tick while petting or while the held one swings.
    private func interactionTicksUntilCue() -> Int {
        if pettingId != nil { return 1 }
        if let p = press, p.dragging, let id = p.grabbedId, let actor = entries[id]?.actor, actor.drawnLag != 0 {
            return 1
        }
        return TickGrid.maxSleepTicks
    }

    /// Holds the scroll views around the stage still while a Critter is carried (Android's
    /// `requestDisallowInterceptTouchEvent`), and lets them go again.
    private func holdScrollViews(_ hold: Bool) {
        if hold {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                    scroll.panGestureRecognizer.isEnabled = false
                    heldScrollViews.append(scroll)
                }
                view = current.superview
            }
        } else {
            for scroll in heldScrollViews { scroll.panGestureRecognizer.isEnabled = true }
            heldScrollViews.removeAll()
        }
    }
}
