import AppKit
import ClawdCore
import QuartzCore

/// The pet window's content: one animated Clawd per session (a `MotionActor` drawn by a
/// `ClawdSpriteLayer`), plus bubbles, name tags, the collapse handle and the merged pile's
/// count chips exactly where `FlockLayout` says.
///
/// Actors live as long as their session: a new snapshot only feeds them their new state or
/// activity, so it never restarts a running animation. `MotionClock` advances them all on
/// the 60 ms tick grid, waking only when the picture can change. Structural changes (expand,
/// collapse, join, leave) are timed by `FlockChoreographer`, which also decides when the
/// window itself moves; this view is its stage.
///
/// Mouse: every click inside the view lands here (never on the labels), and what it hit is
/// decided from the layout geometry. A press that moves less than 3 pt before release is a
/// click; anything further drags the whole panel. Right-click opens a context menu.
final class FlockView: NSView {
    private static let dragThreshold: CGFloat = 3
    /// The merged pile's back rows blink (`blinkPose`) for 2 of every 80 ticks, row k
    /// 23·k ticks out of phase.
    private static let pileBlinkPeriod = 80
    private static let pileBlinkPhase = 23
    private static let pileBlinkTicks = 2
    /// Bubbles, tags, the handle and the chips fade back in this fast after a choreography.
    private static let overlayFadeIn: TimeInterval = 0.18

    /// Left click on a session's Clawd, bubble or tag (expanded flock).
    var onClickSession: ((PetSession) -> Void)?
    /// Click on the merged pile: expand it. / Click on the "收起" handle: merge.
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    /// Context menu "关闭".
    var onDismiss: ((PetSession) -> Void)?
    var onHide: (() -> Void)?
    /// Context menu "设置…" (disabled while nil).
    var onSettings: (() -> Void)?
    /// A drag of the panel started (true) or ended (false).
    var onDragStateChange: ((Bool) -> Void)?
    /// False while the expanded flock wouldn't fit on screen (so it stays merged): the
    /// pile's "展开" is then disabled rather than silently doing nothing.
    var canExpand = true

    private var pressLocation: NSPoint?
    private var windowOriginAtPress: NSPoint?
    private var isDragging = false

    let skin: SkinManifest
    private let metrics: FlockLayout.Metrics
    private(set) var reduceMotion: Bool
    private let atlas: SpriteAtlas
    private let clock: MotionClock
    private lazy var choreographer = FlockChoreographer(view: self)

    /// Layer-hosting container for the sprites, below every subview.
    private let spriteHost = NSView()
    /// One actor and sprite per Clawd on stage, by session id (`""` = the empty state's
    /// placeholder). A leaving session keeps its Clawd until its goodbye has played.
    private(set) var actors: [String: MotionActor] = [:]
    private var sprites: [String: ClawdSpriteLayer] = [:]
    /// The merged pile's back rows (row 1, row 2), drawn as still dimmed poses.
    private let pileLayers: [CALayer] = [CALayer(), CALayer()]
    private var drawnPile: [PileRow] = []
    private var bubbles: [String: BubbleView] = [:]
    private var tags: [String: TagView] = [:]
    private let handleView = HandleView()
    private let chipsView = ChipsView()

    /// What the window is laid out for right now (the choreography may still be heading
    /// for a newer presentation).
    private(set) var presentation: FlockPresentation = .empty
    private(set) var layoutResult: FlockLayout.Result
    /// The latest session data, by id: states and texts apply at once, whatever is shown.
    private var sessionsById: [String: PetSession] = [:]

    /// Bubbles and tags of these Clawds stay hidden (hopping, joining or leaving).
    private var heldIds: Set<String> = []
    /// The handle and the count chips stay hidden while the flock rearranges.
    private var chromeHeld = false
    /// Clawds waiting for their turn to drop in while the pet is being shown.
    var concealed: Set<String> = []

    /// Inside the clock's tick: rendering follows anyway, so no extra redraw is requested.
    private var inTick = false
    /// Work that must wait until the actors are done stepping / taking new states (see `batch`).
    private var deferDepth = 0
    private var deferred: [() -> Void] = []

    init(skin: SkinManifest, metrics: FlockLayout.Metrics, reduceMotion: Bool) {
        self.skin = skin
        self.metrics = metrics
        self.reduceMotion = reduceMotion
        atlas = SpriteAtlas(skin: skin)
        clock = MotionClock(tickMs: skin.tickMs)
        layoutResult = FlockLayout.layout(.empty, metrics: metrics)
        super.init(frame: NSRect(origin: .zero, size: layoutResult.size))
        wantsLayer = true

        spriteHost.layer = CALayer()
        spriteHost.wantsLayer = true
        spriteHost.frame = bounds
        spriteHost.autoresizingMask = [.width, .height]
        addSubview(spriteHost)

        for (index, pileLayer) in pileLayers.enumerated() {
            pileLayer.magnificationFilter = .nearest
            pileLayer.minificationFilter = .nearest
            pileLayer.opacity = index == 0 ? 0.75 : 0.55
            // Behind the lead (z 2), like the seats they stand for (z = 2 − row).
            pileLayer.zPosition = CGFloat(1 - index)
            pileLayer.isHidden = true
            spriteHost.layer?.addSublayer(pileLayer)
        }

        addSubview(handleView)
        addSubview(chipsView)

        clock.onTick = { [weak self] ticks in
            self?.tick(ticks) ?? MotionClock.maxSleepTicks
        }
    }

    required init?(coder: NSCoder) {
        fatalError("FlockView does not support NSCoding")
    }

    /// The session drawn in each slot (nil for the empty state's placeholder Clawd), with
    /// its latest data.
    var entries: [(slot: FlockLayout.Slot, session: PetSession?)] {
        switch presentation {
        case .empty:
            return layoutResult.slots.map { ($0, nil) }
        case .expanded(let shown, _):
            return zip(layoutResult.slots, shown).map { ($0, sessionsById[$1.id] ?? $1) }
        case .merged(let lead, _, _):
            return layoutResult.slots.map { ($0, sessionsById[lead.id] ?? lead) }
        }
    }

    private var isMerged: Bool {
        if case .merged = presentation { return true }
        return false
    }

    var unit: CGFloat { metrics.unit }
    var isRunning: Bool { clock.isRunning }

    // MARK: - Presenting

    /// Shows `presentation`: every Clawd takes its new state and every bubble/tag its new
    /// text right away; the structural change (and the window move, `place`) is handed to
    /// the choreographer, which runs one choreography at a time and keeps only the latest
    /// request while one plays.
    func present(_ presentation: FlockPresentation, layout: FlockLayout.Result, sessions: [PetSession],
                 anchorSide: Anchor.Side, place: @escaping () -> Void) {
        sessionsById = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        batch {
            applyStates()
            refreshTexts()
            choreographer.submit(FlockRequest(
                presentation: presentation, layout: layout, sessions: sessions, anchorSide: anchorSide, place: place
            ))
        }
        requestRender()
    }

    /// Starts or stops the animation clock (stopped while the pet is hidden). Stopping
    /// settles any choreography at once: nobody is watching it.
    func setRunning(_ running: Bool) {
        if running {
            choreographer.surface()
            clock.start()
        } else {
            clock.stop()
            batch { choreographer.settle() }
            requestRender()
        }
    }

    /// "Reduce motion" was toggled: every Clawd holds a still pose (or animates again); hops
    /// in flight land at once.
    func setReduceMotion(_ reduceMotion: Bool) {
        guard reduceMotion != self.reduceMotion else { return }
        self.reduceMotion = reduceMotion
        batch {
            for actor in actors.values { actor.reduceMotion = reduceMotion }
        }
        requestRender()
    }

    /// The pet was just shown: each Clawd drops in from above, one after another.
    func playAppear() {
        batch { choreographer.playAppear() }
        requestRender()
    }

    /// The pet is being hidden: each Clawd sinks into the ground, one after another;
    /// `completion` runs once all are gone (not if a show or another hide supersedes it).
    func playVanish(completion: @escaping () -> Void) {
        batch { choreographer.playVanish(completion: completion) }
        requestRender()
    }

    // MARK: - States and texts

    /// Every Clawd still on stage takes its session's activity and state now, whatever the
    /// choreography is doing (a leaving one has no session left to follow).
    private func applyStates() {
        for (id, actor) in actors where !choreographer.isLeaving(id) {
            let session = sessionsById[id]
            guard session != nil || id.isEmpty else { continue }
            actor.setActivity(session?.activity)
            let state = session?.state ?? .idle
            guard actor.state != state else { continue }
            actor.enterState(state)
            choreographer.stateDidChange(id)
        }
    }

    private func refreshTexts() {
        for (id, bubble) in bubbles {
            if let session = sessionsById[id] { bubble.configure(session: session) }
        }
        guard case .expanded = presentation else { return }
        for (id, tag) in tags {
            if let session = sessionsById[id] { tag.configure(session: session) }
        }
    }

    // MARK: - Stage (driven by FlockChoreographer)

    /// The latest data for `id` (nil for the placeholder or a session that's gone).
    func session(_ id: String) -> PetSession? {
        sessionsById[id]
    }

    /// Creates a quietly entered Clawd for each id without one (hidden or not); returns those.
    @discardableResult
    func ensureActors(_ ids: [String], hidden: Bool) -> [String] {
        var created: [String] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for id in ids where actors[id] == nil {
            let session = sessionsById[id]
            let actor = MotionActor(skin: skin, rng: .system(), reduceMotion: reduceMotion)
            actor.setActivity(session?.activity)
            actor.enterState(session?.state ?? .idle, quiet: true)
            actor.hidden = hidden
            actors[id] = actor
            let sprite = ClawdSpriteLayer(atlas: atlas, unit: unit)
            spriteHost.layer?.addSublayer(sprite)
            sprites[id] = sprite
            created.append(id)
        }
        return created
    }

    func removeActor(_ id: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        actors[id] = nil
        sprites[id]?.removeFromSuperlayer()
        sprites[id] = nil
        heldIds.remove(id)
        concealed.remove(id)
    }

    /// The Clawd (with its bubble and tag) of `from` now stands for `to`.
    func rekey(from: String, to: String) {
        guard from != to, let actor = actors[from] else { return }
        removeActor(to)
        actors[from] = nil
        actors[to] = actor
        sprites[to] = sprites.removeValue(forKey: from)
        if let bubble = bubbles.removeValue(forKey: from) { bubbles[to] = bubble }
        if let tag = tags.removeValue(forKey: from) { tags[to] = tag }
        if heldIds.remove(from) != nil { heldIds.insert(to) }
        if concealed.remove(from) != nil { concealed.insert(to) }
    }

    func groundOrigin(_ id: String) -> CGPoint? {
        sprites[id]?.groundOrigin
    }

    func setGroundOrigin(_ id: String, _ origin: CGPoint) {
        sprites[id]?.groundOrigin = origin
    }

    /// Marks `id` as seated in (or hopping to) pile row `row` (nil: not in the pile).
    func setSeatRow(_ id: String, _ row: Int?) {
        sprites[id]?.seatRow = row
    }

    /// Lays the view out for `presentation`: bubbles, tags, handle and chips (created hidden
    /// when held, so nothing flashes), and the still pile when merged. Clawds aren't moved.
    func adopt(_ presentation: FlockPresentation, layout: FlockLayout.Result) {
        self.presentation = presentation
        layoutResult = layout

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let entries = self.entries
        let liveIds = Set(entries.map(\.slot.id))
        for (slot, session) in entries {
            placeBubble(slot: slot, session: session)
            placeTag(slot: slot, session: session)
        }
        for (id, bubble) in bubbles where !entries.contains(where: { $0.slot.id == id && $0.slot.bubble != nil }) {
            bubble.removeFromSuperview()
            bubbles[id] = nil
        }
        for (id, tag) in tags where !liveIds.contains(id) {
            tag.removeFromSuperview()
            tags[id] = nil
        }

        if let handle = layout.handle { handleView.frame = handle }
        if let chips = layout.chips, case .merged(_, let counts, _) = presentation {
            chipsView.configure(counts: counts)
            chipsView.frame = chips
        }
        refreshOverlays(fade: false)
    }

    /// Whether `id` is hidden when nothing is moving: merged non-leads wait behind the still
    /// pile, and Clawds still waiting to drop in stay out of sight.
    func restHidden(_ id: String) -> Bool {
        if concealed.contains(id) { return true }
        if case .merged(let lead, _, _) = presentation { return id != lead.id }
        return false
    }

    /// The Clawds seen when nothing is moving, left to right.
    func restVisibleIds() -> [String] {
        switch presentation {
        case .merged(let lead, _, _): return actors[lead.id] == nil ? [] : [lead.id]
        case .empty, .expanded: return layoutResult.slots.map(\.id).filter { actors[$0] != nil }
        }
    }

    /// Every Clawd at its resting place and look for the shown presentation: in its column,
    /// or (merged) the lead in front of the pile with the others hidden behind it.
    func placeAtRest() {
        let merged = isMerged
        let front = layoutResult.slots.first?.clawd.origin
        let columns = Dictionary(layoutResult.slots.map { ($0.id, $0.clawd.origin) }) { first, _ in first }
        for (id, actor) in actors {
            actor.hidden = restHidden(id)
            actor.noAccessory = merged
            actor.z = 2
            sprites[id]?.seatRow = nil
            if let origin = merged ? front : columns[id] {
                sprites[id]?.groundOrigin = origin
            }
        }
    }

    // MARK: Overlays

    func hold(_ ids: some Sequence<String>) {
        heldIds.formUnion(ids)
        refreshOverlays(fade: false)
    }

    func release(_ id: String, fade: Bool) {
        guard heldIds.remove(id) != nil else { return }
        refreshOverlays(fade: fade)
    }

    func holdChrome() {
        chromeHeld = true
        refreshOverlays(fade: false)
    }

    func releaseChrome(fade: Bool) {
        chromeHeld = false
        refreshOverlays(fade: fade)
    }

    func releaseAll(fade: Bool) {
        heldIds.removeAll()
        chromeHeld = false
        refreshOverlays(fade: fade)
    }

    private func refreshOverlays(fade: Bool) {
        for (id, bubble) in bubbles { show(bubble, !heldIds.contains(id), fade: fade) }
        for (id, tag) in tags { show(tag, !heldIds.contains(id), fade: fade) }
        show(handleView, layoutResult.handle != nil && !chromeHeld, fade: fade)
        show(chipsView, layoutResult.chips != nil && !chromeHeld, fade: fade)
    }

    /// Hides at once; shows with a short fade-in (no fade under reduced motion).
    private func show(_ view: NSView, _ visible: Bool, fade: Bool) {
        guard visible else {
            view.isHidden = true
            return
        }
        guard view.isHidden else { return }
        guard fade, !reduceMotion else {
            view.alphaValue = 1
            view.isHidden = false
            return
        }
        view.alphaValue = 0
        view.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.overlayFadeIn
            view.animator().alphaValue = 1
        }
    }

    // MARK: Sequencing

    /// Runs `body`, then any work it deferred: completions fired while actors step or take
    /// new states must not rearrange the stage under them.
    func batch(_ body: () -> Void) {
        deferDepth += 1
        body()
        if deferDepth == 1 {
            while !deferred.isEmpty {
                deferred.removeFirst()()
            }
        }
        deferDepth -= 1
    }

    /// Runs `work` now, or -- inside `batch` -- once the batch's own work is done.
    func deferWork(_ work: @escaping () -> Void) {
        if deferDepth > 0 {
            deferred.append(work)
        } else {
            batch(work)
        }
    }

    /// Redraws now and re-aims the clock (a no-op inside a tick, which draws afterwards).
    func requestRender() {
        guard !inTick else { return }
        clock.poke()
    }

    // MARK: - Clock

    /// Advances every actor `ticks` ticks, draws, and returns the ticks until the next change.
    private func tick(_ ticks: Int) -> Int {
        inTick = true
        for _ in 0..<ticks {
            batch {
                for actor in Array(actors.values) { actor.step() }
                choreographer.didStep()
            }
        }
        inTick = false

        render()

        var next = MotionClock.maxSleepTicks
        for actor in actors.values where !actor.hidden || actor.isPlayingOnce {
            next = min(next, actor.ticksUntilChange())
        }
        return min(next, pileTicksUntilChange())
    }

    /// Keeps the sprite layers in `zPosition` order (stable): Core Animation sorts siblings by
    /// it on screen anyway, but `CALayer.render(in:)` (the debug snapshot) only follows the
    /// array order. Runs inside `render`'s transaction.
    private func orderByDepth() {
        guard let host = spriteHost.layer, let layers = host.sublayers else { return }
        let sorted = layers.enumerated()
            .sorted { ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset) }
            .map(\.element)
        guard zip(sorted, layers).contains(where: { $0 !== $1 }) else { return }
        host.sublayers = sorted
    }

    /// The merged pile's lead actor and back-row count, or nil when not merged.
    private var pile: (lead: MotionActor, rows: Int, front: CGPoint)? {
        guard case .merged(let lead, _, let total) = presentation, let actor = actors[lead.id],
              let front = layoutResult.slots.first?.clawd.origin else { return nil }
        return (actor, PileSeating.backRows(total: total), front)
    }

    private func pileBlinks(row: Int, clock: Int) -> Bool {
        (clock + Self.pileBlinkPhase * row) % Self.pileBlinkPeriod < Self.pileBlinkTicks
    }

    /// Draws every changed sprite and the still pile in one actions-disabled transaction --
    /// none at all when nothing changed since the last draw.
    private func render() {
        var changed: [(sprite: ClawdSpriteLayer, snapshot: ActorSnapshot)] = []
        for (id, actor) in actors {
            guard let sprite = sprites[id] else { continue }
            let snapshot = actor.snapshot()
            if sprite.needsRender(snapshot) { changed.append((sprite, snapshot)) }
        }
        let pile = pileRows()
        guard !changed.isEmpty || pile != drawnPile else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (sprite, snapshot) in changed { sprite.render(snapshot) }
        if pile != drawnPile { drawPile(pile) }
        orderByDepth()
        CATransaction.commit()
    }

    /// One back row of the still pile: where it goes and which pose it shows.
    private struct PileRow: Equatable {
        var frame: CGRect
        var pose: String
    }

    /// Row k sits 4k cells right and k cells up from the lead, dimmed, as a still pose --
    /// exactly where (and how) a Clawd seated in that row by a collapse is drawn.
    private func pileRows() -> [PileRow] {
        guard let pile, !pile.lead.hidden, pile.rows > 0 else { return [] }
        let names = skin.interactions
        let u = unit
        return (1...min(pile.rows, pileLayers.count)).compactMap { row in
            let poseName = pileBlinks(row: row, clock: pile.lead.clock) ? names.blinkPose : names.land
            guard let grid = atlas.pose(poseName, dim: true)?.grid else { return nil }
            let frame = CGRect(
                x: pile.front.x + CGFloat(4 * row + grid.minX) * u,
                y: pile.front.y + CGFloat(row + 10 - grid.minY - grid.height) * u,
                width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
            )
            return PileRow(frame: frame, pose: poseName)
        }
    }

    private func drawPile(_ rows: [PileRow]) {
        drawnPile = rows
        for (index, layer) in pileLayers.enumerated() {
            guard index < rows.count else {
                layer.isHidden = true
                continue
            }
            layer.frame = rows[index].frame
            layer.contents = atlas.pose(rows[index].pose, dim: true)?.image
            layer.isHidden = false
        }
    }

    private func pileTicksUntilChange() -> Int {
        guard let pile, pile.rows > 0, !pile.lead.hidden else { return MotionClock.maxSleepTicks }
        let clock = pile.lead.clock
        let changes = (1...Self.pileBlinkPeriod).first { ahead in
            (1...pile.rows).contains { pileBlinks(row: $0, clock: clock + ahead) != pileBlinks(row: $0, clock: clock) }
        }
        return changes ?? MotionClock.maxSleepTicks
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Claims every point inside the view so the bubble/tag labels never swallow clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        windowOriginAtPress = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, let origin = windowOriginAtPress, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !isDragging {
            guard hypot(dx, dy) >= Self.dragThreshold else { return }
            isDragging = true
            onDragStateChange?(true)
        }
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressLocation = nil
            windowOriginAtPress = nil
        }
        if isDragging {
            isDragging = false
            onDragStateChange?(false)
            return
        }
        guard pressLocation != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let target = layoutResult.target(at: point)
        if isMerged, target != nil {
            let expand = ActionMenuItem(title: "展开") { [weak self] in self?.onExpand?() }
            expand.isEnabled = canExpand
            menu.addItem(expand)
            menu.addItem(.separator())
        } else if case .slot(let index) = target, let session = entries[index].session {
            menu.addItem(ActionMenuItem(title: "跳回会话") { [weak self] in self?.onClickSession?(session) })
            menu.addItem(ActionMenuItem(title: "关闭") { [weak self] in self?.onDismiss?(session) })
            menu.addItem(.separator())
        }
        // The expanded flock can always be merged from the menu too, not only via the
        // "⇥ 收起" handle at its far end.
        if case .expanded(_, showCollapse: true) = presentation {
            menu.addItem(ActionMenuItem(title: "收起") { [weak self] in self?.onCollapse?() })
        }
        menu.addItem(ActionMenuItem(title: "隐藏宠物") { [weak self] in self?.onHide?() })
        let settings = ActionMenuItem(title: "设置…") { [weak self] in self?.onSettings?() }
        settings.isEnabled = onSettings != nil
        menu.addItem(settings)
        return menu
    }

    /// Debug-only: replays a left click on `target` (a slot's session id, `handle` or
    /// `chips`) -- or, with `menuItem`, a right-click there and that menu choice -- through
    /// the same handlers a real mouse uses. Returns false if there's no such target/item.
    func simulateClick(target: String, menuItem: String?) -> Bool {
        let rect: CGRect?
        switch target {
        case "handle": rect = layoutResult.handle
        case "chips": rect = layoutResult.chips
        default: rect = layoutResult.slots.first { $0.id == target }?.clawd
        }
        guard let rect, let window else { return false }
        let location = convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        if let menuItem {
            guard let rightDown = event(.rightMouseDown), let menu = menu(for: rightDown) else { return false }
            DiagnosticLog.shared.log("menu target=\(target) items=" + menu.items.map { $0.isSeparatorItem ? "-" : $0.title }.joined(separator: "|"))
            guard let index = menu.items.firstIndex(where: { $0.title == menuItem }), menu.items[index].isEnabled else { return false }
            menu.performActionForItem(at: index)
            return true
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        mouseDown(with: down)
        mouseUp(with: up)
        return true
    }

    // MARK: - Placement

    private func placeBubble(slot: FlockLayout.Slot, session: PetSession?) {
        guard let rect = slot.bubble, let session else { return }
        let bubble = bubbles[slot.id] ?? {
            let bubble = BubbleView(frame: rect)
            // Created hidden while held, so it never shows for a frame and then vanishes.
            bubble.isHidden = heldIds.contains(slot.id)
            addSubview(bubble)
            bubbles[slot.id] = bubble
            return bubble
        }()
        bubble.configure(session: session)
        bubble.frame = rect
    }

    private func placeTag(slot: FlockLayout.Slot, session: PetSession?) {
        let tag = tags[slot.id] ?? {
            let tag = TagView(frame: slot.tag)
            tag.isHidden = heldIds.contains(slot.id)
            addSubview(tag)
            tags[slot.id] = tag
            return tag
        }()
        switch presentation {
        case .empty:
            tag.configure(name: FlockLayout.emptyTagText, source: "暂无会话", color: PetState.idle.tagColor)
        case .merged(_, _, let total):
            tag.configure(name: FlockLayout.mergedTagText(total: total), source: nil, color: NSColor(hex: "#3A3A3C"))
        case .expanded:
            if let session { tag.configure(session: session) }
        }
        tag.frame = slot.tag
    }
}

/// The "⇥ 收起" pill at the end of an expanded flock.
private final class HandleView: NSView {
    private let label = NSTextField(labelWithString: "⇥ 收起")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.7).cgColor
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("HandleView does not support NSCoding")
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

/// The merged pile's per-state counts (`? 1`, `✓ 1`, `••• 2`), each on its state color.
private final class ChipsView: NSView {
    private var chips: [(view: NSView, label: NSTextField)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("ChipsView does not support NSCoding")
    }

    func configure(counts: [StateCount]) {
        while chips.count < counts.count {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 9, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            view.addSubview(label)
            addSubview(view)
            chips.append((view, label))
        }
        for (index, chip) in chips.enumerated() {
            chip.view.isHidden = index >= counts.count
            guard index < counts.count else { continue }
            chip.label.stringValue = FlockLayout.chipLabel(counts[index])
            chip.view.layer?.backgroundColor = counts[index].state.color.cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let visible = chips.filter { !$0.view.isHidden }
        let widths = visible.map { ceil($0.label.intrinsicContentSize.width) + 10 }
        let gap: CGFloat = 4
        var x = (bounds.width - widths.reduce(0, +) - gap * CGFloat(max(visible.count - 1, 0))) / 2
        for (chip, width) in zip(visible, widths) {
            chip.view.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            let height = ceil(chip.label.intrinsicContentSize.height)
            chip.label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
            x += width + gap
        }
    }
}

/// A menu item that runs a closure, so context menus don't need a selector per action.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ActionMenuItem does not support NSCoding")
    }

    @objc private func run() {
        handler()
    }
}
