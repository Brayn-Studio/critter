import AppKit
import ClawdCore
import QuartzCore

/// The pet window's content: one animated Clawd per session (a `MotionActor` drawn by a
/// `ClawdSpriteLayer`), plus bubbles, name tags, the collapse handle and the merged pile's
/// count chips exactly where `FlockLayout` says.
///
/// Actors live as long as their session: a new snapshot only feeds them their new state or
/// activity, so it never restarts a running animation. `MotionClock` advances them all on
/// the 60 ms tick grid, waking only when the picture can change.
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

    private let skin: SkinManifest
    private let metrics: FlockLayout.Metrics
    private var reduceMotion: Bool
    private let atlas: SpriteAtlas
    private let clock: MotionClock

    /// Layer-hosting container for the sprites, below every subview.
    private let spriteHost = NSView()
    /// One actor and sprite per shown session id (`""` = the empty state's placeholder).
    private var actors: [String: MotionActor] = [:]
    private var sprites: [String: ClawdSpriteLayer] = [:]
    /// The merged pile's back rows (row 1, row 2), drawn as still dimmed poses.
    private let pileLayers: [CALayer] = [CALayer(), CALayer()]
    private var pileImages: [CGImage?] = [nil, nil]
    private var bubbles: [String: BubbleView] = [:]
    private var tags: [String: TagView] = [:]
    private let handleView = HandleView()
    private let chipsView = ChipsView()

    private(set) var presentation: FlockPresentation = .empty
    private(set) var layoutResult: FlockLayout.Result
    /// The latest session list (merged presentations only carry the lead).
    private var sessions: [PetSession] = []

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

    /// The session drawn in each slot (nil for the empty state's placeholder Clawd).
    var entries: [(slot: FlockLayout.Slot, session: PetSession?)] {
        switch presentation {
        case .empty:
            return layoutResult.slots.map { ($0, nil) }
        case .expanded(let sessions, _):
            return zip(layoutResult.slots, sessions).map { ($0, $1) }
        case .merged(let lead, _, _):
            return layoutResult.slots.map { ($0, lead) }
        }
    }

    private var isMerged: Bool {
        if case .merged = presentation { return true }
        return false
    }

    private var unit: CGFloat { metrics.unit }

    func update(_ presentation: FlockPresentation, layout: FlockLayout.Result, sessions: [PetSession]) {
        self.presentation = presentation
        layoutResult = layout
        self.sessions = sessions

        syncActors()
        placeActors()

        // Standalone CALayers animate geometry changes implicitly; the flock should snap.
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

        handleView.isHidden = layout.handle == nil
        if let handle = layout.handle { handleView.frame = handle }

        chipsView.isHidden = layout.chips == nil
        if let chips = layout.chips, case .merged(_, let counts, _) = presentation {
            chipsView.configure(counts: counts)
            chipsView.frame = chips
        }
        clock.poke()
    }

    /// Starts or stops the animation clock (stopped while the pet is hidden).
    func setRunning(_ running: Bool) {
        if running {
            clock.start()
        } else {
            clock.stop()
        }
    }

    /// "Reduce motion" was toggled: every Clawd holds a still pose (or animates again).
    func setReduceMotion(_ reduceMotion: Bool) {
        guard reduceMotion != self.reduceMotion else { return }
        self.reduceMotion = reduceMotion
        for actor in actors.values { actor.reduceMotion = reduceMotion }
        clock.poke()
    }

    // MARK: - Actors

    /// The ids that get a Clawd: every session, or the placeholder when there are none.
    private var actorIds: [String] {
        if case .empty = presentation { return [""] }
        return sessions.map(\.id)
    }

    /// Creates a quiet actor for each new id, feeds the existing ones their new activity and
    /// state, and drops the ones whose session is gone.
    private func syncActors() {
        let byId = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        let ids = actorIds
        for id in ids {
            let session = byId[id]
            if let actor = actors[id] {
                actor.setActivity(session?.activity)
                let state = session?.state ?? .idle
                if actor.state != state { actor.enterState(state) }
            } else {
                let actor = MotionActor(skin: skin, rng: .system(), reduceMotion: reduceMotion)
                actor.setActivity(session?.activity)
                actor.enterState(session?.state ?? .idle, quiet: true)
                actors[id] = actor
                let sprite = ClawdSpriteLayer(atlas: atlas, unit: unit)
                spriteHost.layer?.addSublayer(sprite)
                sprites[id] = sprite
            }
        }
        let live = Set(ids)
        for id in actors.keys where !live.contains(id) {
            actors[id] = nil
            sprites[id]?.removeFromSuperlayer()
            sprites[id] = nil
        }
    }

    /// Expanded: each Clawd stands in its column. Merged: only the lead shows, in front of
    /// the pile (the others wait hidden); its head marker gives way to the count chips.
    private func placeActors() {
        switch presentation {
        case .empty, .expanded:
            for slot in layoutResult.slots {
                guard let actor = actors[slot.id] else { continue }
                actor.hidden = false
                actor.noAccessory = false
                sprites[slot.id]?.groundOrigin = slot.clawd.origin
            }
        case .merged(let lead, _, _):
            let front = layoutResult.slots.first?.clawd.origin ?? .zero
            for (id, actor) in actors {
                actor.hidden = id != lead.id
                actor.noAccessory = true
                sprites[id]?.groundOrigin = front
            }
        }
    }

    // MARK: - Clock

    /// Advances every actor `ticks` ticks, draws, and returns the ticks until the next change.
    private func tick(_ ticks: Int) -> Int {
        for _ in 0..<ticks {
            for actor in actors.values { actor.step() }
        }
        for (id, actor) in actors {
            sprites[id]?.render(actor.snapshot())
        }
        renderPile()

        var next = MotionClock.maxSleepTicks
        for actor in actors.values where !actor.hidden || actor.isPlayingOnce {
            next = min(next, actor.ticksUntilChange())
        }
        return min(next, pileTicksUntilChange())
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

    /// Row k sits 4k cells right and k cells up from the lead, dimmed, as a still pose.
    private func renderPile() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let pile = self.pile
        for (index, layer) in pileLayers.enumerated() {
            let row = index + 1
            guard let pile, row <= pile.rows, !pile.lead.hidden else {
                layer.isHidden = true
                continue
            }
            let names = skin.interactions
            let poseName = pileBlinks(row: row, clock: pile.lead.clock) ? names.blinkPose : names.land
            guard let pose = atlas.pose(poseName, dim: true) else {
                layer.isHidden = true
                continue
            }
            let u = unit
            let grid = pose.grid
            let frame = CGRect(
                x: pile.front.x + CGFloat(4 * row + grid.minX) * u,
                y: pile.front.y + CGFloat(row + 10 - grid.minY - grid.height) * u,
                width: CGFloat(grid.width) * u, height: CGFloat(grid.height) * u
            )
            if layer.frame != frame { layer.frame = frame }
            if pileImages[index] !== pose.image {
                pileImages[index] = pose.image
                layer.contents = pose.image
            }
            if layer.isHidden { layer.isHidden = false }
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
