import AppKit
import ClawdCore

/// Owns the pet panel: whether it's shown, what it shows -- the latest session snapshot
/// from `SessionMonitor`, presented as an expanded flock or a merged pile (`FlockModel`),
/// laid out by `FlockLayout` and drawn by `FlockView` -- and where it sits (pinned at a
/// saved `Anchor`, kept on screen by `PositionModel`). It also routes the pet's clicks and
/// menu choices to the right place, and plays the alert sound when a session enters
/// waiting/done/error. Size, merge threshold and sounds follow `SettingsStore`.
@MainActor
final class PetController {
    private static let fallbackScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private(set) var visible = true
    /// Called whenever `visible` changes -- including before the panel exists -- so the
    /// status-item menu title can follow immediately.
    var onVisibilityChange: ((Bool) -> Void)?
    /// Left click on a session (or its menu's "跳回会话"): jump back to its window. The
    /// app delegate connects this to `JumpBackService`.
    var onJump: ((PetSession) -> Void)?
    /// "设置…" in the pet's context menu (disabled while nil).
    var onOpenSettings: (() -> Void)? {
        didSet { flockView?.onSettings = onOpenSettings }
    }

    private let monitor: SessionMonitor
    private let settings: SettingsStore
    private let soundPlayer: SoundPlayer
    private var skin: SkinManifest?
    private var panel: PetPanel?
    private var flockView: FlockView?
    private var clickThrough: ClickThroughController?
    private var sessions: [PetSession] = []
    /// Each session's state in the previous snapshot (nil before the first one), to tell
    /// which alert states were just entered.
    private var previousStates: [String: PetState]?
    /// The user's explicit expand/collapse, honored until the session count changes.
    private var flockOverride: FlockOverride?
    /// Where the user last dropped the pet (UserDefaults `anchor`); nil → default corner.
    private var anchor: Anchor? = AnchorStore.load()
    private var isDragging = false
    /// The hide animation is playing; the panel goes away when it ends.
    private var isVanishing = false
    /// The layout currently on screen (its `content` rect maps the panel to the flock).
    private var currentLayout: FlockLayout.Result?
    /// False until the monitor's first snapshot arrives, so the log doesn't record the
    /// placeholder "empty" state the panel shows while the first scan is still running.
    private var hasSnapshot = false
    private var lastLogLine: String?
    private var observers: [NSObjectProtocol] = []

    init(monitor: SessionMonitor, settings: SettingsStore, soundPlayer: SoundPlayer) {
        self.monitor = monitor
        self.settings = settings
        self.soundPlayer = soundPlayer
    }

    private var metrics: FlockLayout.Metrics {
        FlockLayout.Metrics(scale: CGFloat(settings.petScale))
    }

    /// Shows or hides the pet. Safe before the panel exists: the request is remembered and
    /// applied by `install(skin:)`. Animated (unless `animated` is false or "Reduce motion"
    /// is on): showing drops every Clawd in from above, hiding sinks them into the ground
    /// before the panel goes away.
    func setVisible(_ visible: Bool, animated: Bool = true) {
        self.visible = visible
        if let panel, let flockView {
            let animate = animated && !Self.reduceMotion
            if visible {
                let appearing = !panel.isVisible || isVanishing
                isVanishing = false
                // Set up (and commit) the first frame before the panel shows, so it never
                // flashes the flock standing in place first.
                if animate && appearing { flockView.playAppear() }
                flockView.setRunning(true)
                CATransaction.flush()
                panel.orderFrontRegardless()
            } else if animate && panel.isVisible {
                if !isVanishing {
                    isVanishing = true
                    flockView.playVanish { [weak self] in self?.finishHiding() }
                }
            } else {
                isVanishing = false
                panel.orderOut(nil)
                // The clock only runs while the pet can be seen.
                flockView.setRunning(false)
            }
            clickThrough?.update()
        }
        onVisibilityChange?(visible)
    }

    /// The hide animation is over: put the panel away (unless shown again meanwhile).
    private func finishHiding() {
        guard isVanishing, !visible, let panel else { return }
        isVanishing = false
        panel.orderOut(nil)
        DiagnosticLog.shared.log("event hidden")
        flockView?.setRunning(false)
        clickThrough?.update()
    }

    /// Builds the panel once the skin has been loaded (off the main thread).
    func install(skin: SkinManifest) {
        self.skin = skin
        let view = makeFlockView(skin: skin)
        let newPanel = PetPanel(contentRect: NSRect(origin: .zero, size: view.frame.size))
        newPanel.contentView = view
        panel = newPanel
        flockView = view
        let clickThrough = ClickThroughController(panel: newPanel)
        // Eyes, hover and rubbing follow the pointer (whichever flock view is current).
        clickThrough.onPointerMoved = { [weak self] point in
            self?.flockView?.pointerMoved(screenPoint: point)
        }
        self.clickThrough = clickThrough

        // "Reduce motion" (System Settings › Accessibility › Display) stops every animation.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotionDidChange()
            }
        })
        // Displays added/removed/rearranged or resolution changed: pull the pet back on screen.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        })

        render()
        // At launch the pet is simply there; the drop-in is for showing it later.
        setVisible(visible, animated: false)
    }

    func show(sessions: [PetSession]) {
        self.sessions = sessions
        if let flockOverride, flockOverride.sessionCount != sessions.count {
            self.flockOverride = nil
        }
        hasSnapshot = true
        render()
        playAlert(for: sessions)
    }

    // MARK: - Settings

    /// "Reduce motion" (System Settings › Accessibility › Display) -- or, in debug mode only,
    /// the `debugReduceMotion` default, so the reduced path can be checked without changing
    /// the system setting (`clawd://debug-set?debugReduceMotion=1`).
    private static var reduceMotion: Bool {
        let defaults = UserDefaults.standard
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || (defaults.bool(forKey: "debugEnabled") && defaults.bool(forKey: "debugReduceMotion"))
    }

    /// The reduce-motion setting (or its debug override) changed: every Clawd follows.
    func reduceMotionDidChange() {
        let reduce = Self.reduceMotion
        DiagnosticLog.shared.log("event reduce-motion \(reduce ? "on" : "off")")
        flockView?.setReduceMotion(reduce)
    }

    /// Clawd's size changed (the settings slider). Sprites are drawn for one scale, so the
    /// flock view is rebuilt at the new one; the window keeps its anchor.
    func scaleDidChange() {
        guard let skin, let panel else { return }
        // A hide still sinking ends now: the old view's clock stops below, so its animation
        // would never finish and the panel would stay up while the pet counts as hidden.
        if isVanishing { finishHiding() }
        flockView?.setRunning(false)
        let view = makeFlockView(skin: skin)
        panel.contentView = view
        flockView = view
        render()
        view.setRunning(visible)
    }

    /// The merge threshold changed.
    func layoutSettingsDidChange() {
        render()
    }

    /// "重置位置": back to the default spot, the bottom-right corner of the main screen
    /// (`PositionModel.defaultAnchor`), forgetting where the pet was dropped.
    func resetPosition() {
        anchor = nil
        AnchorStore.clear()
        DiagnosticLog.shared.log("event moved anchor=default")
        render()
    }

    // MARK: - Sounds

    /// One sound per snapshot at most: the most urgent alert state some session has just
    /// entered whose switch is on -- and only while the pet is visible (spec §7: no sounds
    /// while hidden).
    private func playAlert(for sessions: [PetSession]) {
        let states = Dictionary(sessions.map { ($0.id, $0.state) }) { first, _ in first }
        let entered = SoundTrigger.enteredAlertStates(old: previousStates, new: states)
        previousStates = states
        guard let mostUrgent = entered.first else { return }
        guard visible else {
            DiagnosticLog.shared.log("sound skipped state=\(mostUrgent.rawValue) reason=hidden")
            return
        }
        guard let state = entered.first(where: settings.soundAllowed(for:)) else {
            let reason = settings.soundEnabled ? "state-off" : "sound-off"
            DiagnosticLog.shared.log("sound skipped state=\(mostUrgent.rawValue) reason=\(reason)")
            return
        }
        soundPlayer.play(state)
    }

    // MARK: - Interaction

    private func makeFlockView(skin: SkinManifest) -> FlockView {
        let view = FlockView(
            skin: skin,
            metrics: metrics,
            reduceMotion: Self.reduceMotion
        )
        wire(view)
        return view
    }

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
        // The anchor follows the flock itself, not the transparent margin around it.
        let flock = currentLayout?.contentFrame(windowFrame: panel.frame) ?? panel.frame
        let screen = Self.screen(containing: CGPoint(x: flock.midX, y: flock.midY))
        let dropped = PositionModel.anchor(for: flock, in: screen?.frame ?? Self.fallbackScreen)
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

    /// Debug-only (`clawd://debug-pointer`): a pointer move to `point` (screen coordinates),
    /// down the same path as the mouse monitors'.
    func debugPointer(_ point: NSPoint) {
        clickThrough?.pointerMoved(to: point)
        DiagnosticLog.shared.log("debug-pointer x=\(point.x) y=\(point.y) " + (flockView?.pointerDebugDescription() ?? "-"))
    }

    /// Debug-only (`clawd://debug-drag`): see `FlockView.simulateDrag`.
    func debugDrag(target: String, dx: CGFloat, dy: CGFloat, steps: Int, intervalMs: Int, waitMs: Int, holdMs: Int) {
        let handled = flockView?.simulateDrag(
            target: target, dx: dx, dy: dy, steps: steps, intervalMs: intervalMs, waitMs: waitMs, holdMs: holdMs
        ) ?? false
        DiagnosticLog.shared.log("debug-drag target=\(target) dx=\(dx) dy=\(dy) steps=\(steps) handled=\(handled)")
    }

    /// Debug-only (`clawd://debug-snapshot`): see `DebugSnapshot`.
    func debugSnapshot(path: String, count: Int, intervalMs: Int) {
        guard let panel else {
            DiagnosticLog.shared.log("debug-snapshot skipped: no panel")
            return
        }
        DebugSnapshot.capture(panel, path: path, count: count, intervalMs: intervalMs)
    }

    // MARK: - Rendering

    private func render() {
        // An expanded flock wider than its screen is shown merged (`FlockLayout.fitted`), so
        // no Clawd and not the "⇥ 收起" handle can end up out of reach.
        let visibleFrame = anchorVisibleFrame()
        let maxWidth = PositionModel.usableWidth(of: visibleFrame)
        let presentation = FlockLayout.fitted(
            FlockModel.present(sessions, threshold: settings.mergeThreshold, override: flockOverride),
            metrics: metrics,
            maxWidth: maxWidth
        )
        let layout = FlockLayout.layout(presentation, metrics: metrics)
        guard let flockView else {
            logIfChanged(presentation, placement: nil)
            return
        }
        // Whether "展开" can do anything: the expanded flock would fit on this screen.
        flockView.canExpand = FlockLayout.layout(.expanded(sessions, showCollapse: true), metrics: metrics).content.width <= maxWidth
        // States show at once; the window follows when the flock view's choreography is
        // ready for the new layout (`place`).
        let side = (anchor ?? PositionModel.defaultAnchor(visible: visibleFrame)).side
        flockView.present(presentation, layout: layout, sessions: sessions, anchorSide: side) { [weak self] in
            self?.place(presentation, layout: layout)
        }
    }

    /// Moves and resizes the panel for `layout` (anchored, kept on screen), updates where it
    /// takes clicks, and logs the change.
    private func place(_ presentation: FlockPresentation, layout: FlockLayout.Result) {
        guard let panel else { return }
        let previousLayout = currentLayout
        currentLayout = layout
        let visibleFrame = anchorVisibleFrame()
        // The flock (not the transparent margin) is what gets anchored and clamped on screen.
        let contentFrame = placementFrame(size: layout.content.size, visible: visibleFrame)
        var placement = (frame: layout.windowFrame(contentFrame: contentFrame), visible: visibleFrame)
        if isDragging {
            // Mid-drag the window follows the mouse; a resized flock keeps its anchored side
            // and bottom edge where they are (where a collapse seated the pile), and the drag
            // carries on from there.
            let old = previousLayout?.contentFrame(windowFrame: panel.frame) ?? layout.contentFrame(windowFrame: panel.frame)
            let side = (anchor ?? PositionModel.defaultAnchor(visible: visibleFrame)).side
            let x = side == .left ? old.minX : old.maxX - layout.content.width
            placement.frame = layout.windowFrame(contentFrame: CGRect(origin: CGPoint(x: x, y: old.minY), size: layout.content.size))
            flockView?.windowShiftedDuringDrag(by: CGVector(
                dx: placement.frame.minX - panel.frame.minX, dy: placement.frame.minY - panel.frame.minY
            ))
        }
        panel.setFrame(placement.frame, display: true)
        clickThrough?.setHitRects(layout.hitRects)
        logIfChanged(presentation, placement: placement)
    }

    /// The visible area of the saved anchor's screen -- or of the main screen if that
    /// display is gone, or there's no saved anchor yet.
    private func anchorVisibleFrame() -> NSRect {
        let screens = NSScreen.screens
        let visibleOfMain = screens.first?.visibleFrame ?? Self.fallbackScreen
        guard let anchor, let index = PositionModel.screenIndex(for: anchor, screens: screens.map(\.frame)) else {
            return visibleOfMain
        }
        return screens[index].visibleFrame
    }

    /// The frame for a flock of `size` at the saved anchor (or the default spot), clamped
    /// fully into `visible`.
    private func placementFrame(size: CGSize, visible: NSRect) -> NSRect {
        PositionModel.frame(size: size, anchor: anchor ?? PositionModel.defaultAnchor(visible: visible), visible: visible)
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

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
