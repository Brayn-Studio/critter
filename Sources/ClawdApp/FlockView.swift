import AppKit
import ClawdCore
import QuartzCore

/// The pet window's content: places Clawd sprites, accessories, bubbles, name tags, the
/// collapse handle and the merged pile's count chips exactly where `FlockLayout` says.
///
/// Sprites are reused across snapshots: a session keeps its `ClawdLayer` for as long as it
/// is on screen and only gets `apply(state:)` again when its state actually changes, so a
/// new snapshot never restarts a running animation.
final class FlockView: NSView {
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
