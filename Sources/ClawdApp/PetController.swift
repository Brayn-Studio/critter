import AppKit
import ClawdCore

/// Owns the pet panel: whether it's shown, and what it shows for the latest session
/// snapshot from `SessionMonitor`.
@MainActor
final class PetController {
    private static let scale: CGFloat = 1
    private static let mergeThreshold = 4
    private static let edgeInset: CGFloat = 24
    private static let columnWidth = CGFloat(ClawdLayer.pixelColumns) * ClawdLayer.pixelWidthPt * scale + 12
    private static let rowHeight = CGFloat(ClawdLayer.pixelRows) * ClawdLayer.pixelHeightPt * scale + 16 * scale

    private(set) var visible = true
    /// Called whenever `visible` changes -- including before the panel exists -- so the
    /// status-item menu title can follow immediately.
    var onVisibilityChange: ((Bool) -> Void)?

    private let monitor: SessionMonitor
    private var skin: SkinManifest?
    private var panel: PetPanel?
    private var sessions: [PetSession] = []
    /// False until the monitor's first snapshot arrives, so the log doesn't record the
    /// placeholder "empty" state the panel shows while the first scan is still running.
    private var hasSnapshot = false
    private var layers: [String: ClawdLayer] = [:]
    private var appliedStates: [String: PetState] = [:]
    private var lastLogLine: String?

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
        }
        onVisibilityChange?(visible)
    }

    /// Builds the panel once the skin has been loaded (off the main thread).
    func install(skin: SkinManifest) {
        self.skin = skin
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: Self.columnWidth, height: Self.rowHeight))
        render()
        setVisible(visible)
    }

    func show(sessions: [PetSession]) {
        self.sessions = sessions
        hasSnapshot = true
        render()
    }

    private func render() {
        let presentation = FlockModel.present(sessions, threshold: Self.mergeThreshold, override: nil)
        logIfChanged(presentation)
        guard let skin, let panel, let root = panel.contentView?.layer else { return }

        // Minimal data-path rendering: one Clawd per session in a row (or one idle Clawd
        // when there are none). The real flock layout replaces this.
        let rows: [(id: String, state: PetState)] = sessions.isEmpty
            ? [("", .idle)]
            : sessions.map { ($0.id, $0.state) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let liveIds = Set(rows.map(\.id))
        for (id, layer) in layers where !liveIds.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
            appliedStates[id] = nil
        }

        for (index, row) in rows.enumerated() {
            let layer = layers[row.id] ?? {
                let layer = ClawdLayer(skin: skin, scale: Self.scale)
                root.addSublayer(layer)
                layers[row.id] = layer
                return layer
            }()
            if appliedStates[row.id] != row.state {
                layer.apply(state: row.state, reduceMotion: reduceMotion)
                appliedStates[row.id] = row.state
            }
            layer.position = CGPoint(
                x: Self.columnWidth * (CGFloat(index) + 0.5),
                y: layer.bounds.height / 2
            )
        }

        let size = NSSize(width: Self.columnWidth * CGFloat(rows.count), height: Self.rowHeight)
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visibleFrame.maxX - size.width - Self.edgeInset, y: visibleFrame.minY + Self.edgeInset)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// One `~/.clawd/app.log` line per change in what's presented (debug mode only).
    private func logIfChanged(_ presentation: FlockPresentation) {
        guard hasSnapshot else { return }
        let line: String
        switch presentation {
        case .empty:
            line = "snapshot empty"
        case .expanded(let shown, _):
            line = "snapshot expanded " + shown.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: " ")
        case .merged(let lead, let counts, let total):
            let countText = counts.map { "\($0.state.rawValue)=\($0.count)" }.joined(separator: ",")
            line = "snapshot merged total=\(total) lead=\(lead.id) counts=\(countText) "
                + sessions.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: " ")
        }
        guard line != lastLogLine else { return }
        lastLogLine = line
        DiagnosticLog.shared.log(line)
    }
}
