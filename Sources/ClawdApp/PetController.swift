import AppKit
import ClawdCore

/// Owns the pet panel: whether it's shown, and what it shows -- the latest session
/// snapshot from `SessionMonitor`, presented as an expanded flock or a merged pile
/// (`FlockModel`), laid out by `FlockLayout` and drawn by `FlockView`.
@MainActor
final class PetController {
    private static let scale: CGFloat = 1
    /// Above this many sessions the flock merges into a pile. UserDefaults `mergeThreshold`
    /// (2…10, default 4) until the settings window takes it over.
    private static var mergeThreshold: Int {
        let stored = UserDefaults.standard.object(forKey: "mergeThreshold") as? Int ?? 4
        return min(max(stored, 2), 10)
    }
    private static let edgeInset: CGFloat = 24

    private(set) var visible = true
    /// Called whenever `visible` changes -- including before the panel exists -- so the
    /// status-item menu title can follow immediately.
    var onVisibilityChange: ((Bool) -> Void)?

    private let monitor: SessionMonitor
    private var panel: PetPanel?
    private var flockView: FlockView?
    private var sessions: [PetSession] = []
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

        // "Reduce motion" (System Settings › Accessibility › Display) stops every animation.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flockView?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        })

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
        let layout = FlockLayout.layout(presentation, metrics: FlockLayout.Metrics(scale: Self.scale))
        guard let panel, let flockView else {
            logIfChanged(presentation, frame: nil)
            return
        }
        flockView.update(presentation, layout: layout)

        // Pinned to the bottom-right corner for now.
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.maxX - layout.size.width - Self.edgeInset,
            y: visibleFrame.minY + Self.edgeInset,
            width: layout.size.width,
            height: layout.size.height
        )
        panel.setFrame(frame, display: true)
        logIfChanged(presentation, frame: frame)
    }

    /// One `~/.clawd/app.log` line per change in what's presented (debug mode only).
    private func logIfChanged(_ presentation: FlockPresentation, frame: NSRect?) {
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
        if let frame {
            line += " frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
        }
        guard line != lastLogLine else { return }
        lastLogLine = line
        DiagnosticLog.shared.log(line)
    }
}
