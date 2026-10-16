import AppKit
import ClawdCore

/// Owns the pet panel: whether it's shown, what it shows -- the latest session snapshot
/// from `SessionMonitor`, presented as an expanded flock or a merged pile (`FlockModel`),
/// laid out by `FlockLayout` and drawn by `FlockView` -- and where it sits (pinned at a
/// saved `Anchor`, kept on screen by `PositionModel`). It also routes the pet's clicks and
/// menu choices to the right place.
@MainActor
final class PetController {
    private static let scale: CGFloat = 1
    /// Above this many sessions the flock merges into a pile. UserDefaults `mergeThreshold`
    /// (2…10, default 4) until the settings window takes it over.
    private static var mergeThreshold: Int {
        let stored = UserDefaults.standard.object(forKey: "mergeThreshold") as? Int ?? 4
        return min(max(stored, 2), 10)
    }
    private static let fallbackScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private(set) var visible = true
    /// Called whenever `visible` changes -- including before the panel exists -- so the
    /// status-item menu title can follow immediately.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Left click on a session (or its menu's "跳回会话"). Wired to the jump-back service
    /// once it exists; until then the click is only logged.
    var onJump: ((PetSession) -> Void)?
    /// "设置…" in the pet's context menu (disabled while nil).
    var onOpenSettings: (() -> Void)? {
        didSet { flockView?.onSettings = onOpenSettings }
    }

    private let monitor: SessionMonitor
    private var panel: PetPanel?
    private var flockView: FlockView?
    private var clickThrough: ClickThroughController?
    private var sessions: [PetSession] = []
    /// The user's explicit expand/collapse, honored until the session count changes.
    private var flockOverride: FlockOverride?
    /// Where the user last dropped the pet (UserDefaults `anchor`); nil → default corner.
    private var anchor: Anchor? = AnchorStore.load()
    private var isDragging = false
    /// False until the monitor's first snapshot arrives, so the log doesn't record the
    /// placeholder "empty" state the panel shows while the first scan is still running.
    private var hasSnapshot = false
    private var lastLogLine: String?
    private var observers: [NSObjectProtocol] = []

    init(monitor: SessionMonitor) {
        self.monitor = monitor
    }

    /// Shows or hides the pet. Safe before the panel exists: the request is remembered and
    /// applied by `install(skin:)`.
    func setVisible(_ visible: Bool) {
        self.visible = visible
        if let panel {
            if visible {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
            clickThrough?.update()
        }
        onVisibilityChange?(visible)
    }

    /// Builds the panel once the skin has been loaded (off the main thread).
    func install(skin: SkinManifest) {
        let view = FlockView(
            skin: skin,
            metrics: FlockLayout.Metrics(scale: Self.scale),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        let newPanel = PetPanel(contentRect: NSRect(origin: .zero, size: view.frame.size))
        newPanel.contentView = view
        panel = newPanel
        flockView = view
        clickThrough = ClickThroughController(panel: newPanel)
        wire(view)

        // "Reduce motion" (System Settings › Accessibility › Display) stops every animation.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flockView?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        })
        // Displays added/removed/rearranged or resolution changed: pull the pet back on screen.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        })

        render()
        setVisible(visible)
    }

    func show(sessions: [PetSession]) {
        self.sessions = sessions
        if let flockOverride, flockOverride.sessionCount != sessions.count {
            self.flockOverride = nil
        }
        hasSnapshot = true
        render()
    }

    // MARK: - Interaction

    private func wire(_ view: FlockView) {
        view.onClickSession = { [weak self] session in
            guard let self else { return }
            DiagnosticLog.shared.log("event jump \(session.id)")
            onJump?(session)
            if session.state == .done {
                monitor.markSeen(session.id)
            }
        }
        view.onExpand = { [weak self] in self?.setMerged(false) }
        view.onCollapse = { [weak self] in self?.setMerged(true) }
        view.onDismiss = { [weak self] session in self?.monitor.dismiss(session.id) }
        view.onHide = { [weak self] in self?.setVisible(false) }
        view.onSettings = onOpenSettings
        view.onDragStateChange = { [weak self] dragging in self?.dragStateChanged(dragging) }
    }

    private func setMerged(_ merged: Bool) {
        flockOverride = FlockOverride(merged: merged, sessionCount: sessions.count)
        DiagnosticLog.shared.log(merged ? "event collapse" : "event expand")
        render()
    }

    private func dragStateChanged(_ dragging: Bool) {
        isDragging = dragging
        clickThrough?.isDragging = dragging
        guard !dragging, let panel else { return }
        // Dropped: remember which corner it was dropped by, then snap fully on screen.
        let screen = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        let dropped = PositionModel.anchor(for: panel.frame, in: screen?.frame ?? Self.fallbackScreen)
        anchor = dropped
        AnchorStore.save(dropped)
        DiagnosticLog.shared.log("event moved anchor=\(dropped.side.rawValue),\(Int(dropped.x)),\(Int(dropped.y))")
        render()
    }

    /// Debug-only (`clawd://debug-click`): see `FlockView.simulateClick`.
    func debugClick(target: String, menuItem: String?) {
        let handled = flockView?.simulateClick(target: target, menuItem: menuItem) ?? false
        DiagnosticLog.shared.log("debug-click target=\(target) item=\(menuItem ?? "-") handled=\(handled)")
    }

    // MARK: - Rendering

    private func render() {
        let presentation = FlockModel.present(sessions, threshold: Self.mergeThreshold, override: flockOverride)
        let layout = FlockLayout.layout(presentation, metrics: FlockLayout.Metrics(scale: Self.scale))
        guard let panel, let flockView else {
            logIfChanged(presentation, placement: nil)
            return
        }
        flockView.update(presentation, layout: layout)

        var placement = targetPlacement(size: layout.size)
        if isDragging {
            // Mid-drag the window follows the mouse; only its size may change.
            placement.frame = NSRect(origin: panel.frame.origin, size: layout.size)
        }
        panel.setFrame(placement.frame, display: true)
        clickThrough?.setHitRects(layout.hitRects)
        logIfChanged(presentation, placement: placement)
    }

    /// The window frame for `size` at the saved anchor, on the anchor's screen -- or on the
    /// main screen if that display is gone -- clamped fully into that screen's visible area.
    private func targetPlacement(size: CGSize) -> (frame: NSRect, visible: NSRect) {
        let screens = NSScreen.screens
        let visibleOfMain = screens.first?.visibleFrame ?? Self.fallbackScreen
        guard let anchor else {
            let frame = PositionModel.frame(size: size, anchor: PositionModel.defaultAnchor(visible: visibleOfMain), visible: visibleOfMain)
            return (frame, visibleOfMain)
        }
        let index = PositionModel.screenIndex(for: anchor, screens: screens.map(\.frame))
        let visibleFrame = index.map { screens[$0].visibleFrame } ?? visibleOfMain
        return (PositionModel.frame(size: size, anchor: anchor, visible: visibleFrame), visibleFrame)
    }

    private static func describe(_ rect: NSRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))"
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens.first
    }

    /// One `~/.clawd/app.log` line per change in what's presented (debug mode only).
    private func logIfChanged(_ presentation: FlockPresentation, placement: (frame: NSRect, visible: NSRect)?) {
        guard hasSnapshot else { return }
        var line: String
        switch presentation {
        case .empty:
            line = "snapshot empty"
        case .expanded(let shown, let showCollapse):
            line = "snapshot expanded" + (showCollapse ? " handle" : "") + " "
                + shown.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: " ")
        case .merged(let lead, let counts, let total):
            let countText = counts.map { "\($0.state.rawValue)=\($0.count)" }.joined(separator: ",")
            line = "snapshot merged total=\(total) lead=\(lead.id) counts=\(countText) "
                + sessions.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: " ")
        }
        if let placement {
            line += " frame=\(Self.describe(placement.frame)) visible=\(Self.describe(placement.visible))"
        }
        guard line != lastLogLine else { return }
        lastLogLine = line
        DiagnosticLog.shared.log(line)
    }
}

/// UserDefaults `anchor`: the pet's pinned position, as a JSON string (readable with
/// `defaults read local.clawd.pet anchor`).
private enum AnchorStore {
    static let key = "anchor"

    static func load() -> Anchor? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: Data(text.utf8))
    }

    static func save(_ anchor: Anchor) {
        guard let data = try? JSONEncoder().encode(anchor) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}
