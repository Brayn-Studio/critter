import AppKit
import ClawdCore
import QuartzCore

/// The pet window's content: places Clawd sprites, accessories, bubbles, name tags, the
/// collapse handle and the merged pile's count chips exactly where `FlockLayout` says.
///
/// Sprites are reused across snapshots: a session keeps its `ClawdLayer` for as long as it
/// is on screen and only gets `apply(state:)` again when its state actually changes, so a
/// new snapshot never restarts a running animation.
///
/// Mouse: every click inside the view lands here (never on the labels), and what it hit is
/// decided from the layout geometry. A press that moves less than 3 pt before release is a
/// click; anything further drags the whole panel. Right-click opens a context menu.
final class FlockView: NSView {
    private static let dragThreshold: CGFloat = 3

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

    /// Layer-hosting container for the sprites, below every subview.
    private let spriteHost = NSView()
    private var clawds: [String: ClawdLayer] = [:]
    private var appliedStates: [String: PetState] = [:]
    /// The two dimmed Clawds stacked behind the front one in the merged pile.
    private let pileLayers: [CALayer] = [CALayer(), CALayer()]
    private var bubbles: [String: BubbleView] = [:]
    private var tags: [String: TagView] = [:]
    private let handleView = HandleView()
    private let chipsView = ChipsView()

    private(set) var presentation: FlockPresentation = .empty
    private(set) var layoutResult: FlockLayout.Result

    init(skin: SkinManifest, metrics: FlockLayout.Metrics, reduceMotion: Bool) {
        self.skin = skin
        self.metrics = metrics
        self.reduceMotion = reduceMotion
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
            pileLayer.zPosition = -CGFloat(index + 1)
            pileLayer.isHidden = true
            spriteHost.layer?.addSublayer(pileLayer)
        }

        addSubview(handleView)
        addSubview(chipsView)
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

    func update(_ presentation: FlockPresentation, layout: FlockLayout.Result) {
        self.presentation = presentation
        layoutResult = layout

        // Standalone CALayers animate geometry changes implicitly; the flock should snap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let entries = self.entries
        let liveIds = Set(entries.map(\.slot.id))
        for (id, clawd) in clawds where !liveIds.contains(id) {
            clawd.removeFromSuperlayer()
            clawd.accessoryLayer.removeFromSuperlayer()
            clawds[id] = nil
            appliedStates[id] = nil
        }

        for (slot, session) in entries {
            placeClawd(slot: slot, state: session?.state ?? .idle)
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

        placePile()

        handleView.isHidden = layout.handle == nil
        if let handle = layout.handle { handleView.frame = handle }

        chipsView.isHidden = layout.chips == nil
        if let chips = layout.chips, case .merged(_, let counts, _) = presentation {
            chipsView.configure(counts: counts)
            chipsView.frame = chips
        }
    }

    /// Re-applies every sprite's animation, e.g. after "Reduce motion" was toggled.
    func setReduceMotion(_ reduceMotion: Bool) {
        guard reduceMotion != self.reduceMotion else { return }
        self.reduceMotion = reduceMotion
        appliedStates.removeAll()
        update(presentation, layout: layoutResult)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for clawd in clawds.values { clawd.accessoryLayer.contentsScale = scale }
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

    private func placeClawd(slot: FlockLayout.Slot, state: PetState) {
        let clawd = clawds[slot.id] ?? makeClawd(id: slot.id)
        if appliedStates[slot.id] != state {
            clawd.apply(state: state, reduceMotion: reduceMotion)
            appliedStates[slot.id] = state
        }
        // In the pile, the front Clawd sits at the bottom-left corner of the pile rect.
        let front = isMerged ? CGRect(origin: slot.clawd.origin, size: metrics.clawdSize) : slot.clawd
        clawd.position = CGPoint(x: front.midX, y: front.midY)
        clawd.accessoryLayer.frame = slot.accessory
        clawd.accessoryLayer.isHidden = isMerged
    }

    private func makeClawd(id: String) -> ClawdLayer {
        let clawd = ClawdLayer(skin: skin, scale: metrics.scale)
        clawd.accessoryLayer.contentsScale = window?.backingScaleFactor ?? 2
        spriteHost.layer?.addSublayer(clawd)
        spriteHost.layer?.addSublayer(clawd.accessoryLayer)
        clawds[id] = clawd
        return clawd
    }

    private func placePile() {
        guard isMerged, let slot = layoutResult.slots.first, let front = clawds[slot.id] else {
            for pileLayer in pileLayers { pileLayer.isHidden = true }
            return
        }
        let still = front.stillImage(for: .idle)
        for (index, pileLayer) in pileLayers.enumerated() {
            let step = CGFloat(index + 1)
            pileLayer.contents = still
            pileLayer.frame = CGRect(
                x: slot.clawd.minX + step * metrics.pileStep.width,
                y: slot.clawd.minY + step * metrics.pileStep.height,
                width: metrics.clawdSize.width,
                height: metrics.clawdSize.height
            )
            pileLayer.isHidden = false
        }
    }

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
