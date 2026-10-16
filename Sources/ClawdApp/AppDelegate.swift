import AppKit
import Carbon.HIToolbox
import ClawdCore

/// Boots the menu-bar app: an accessory-policy process with no Dock icon, a transparent
/// always-on-top pet panel, a status-bar menu, the `clawd://` URL scheme, and a heartbeat
/// written to `~/.clawd/app.json` so `clawd-hook toggle` can tell the app is alive (and
/// restart it if the heartbeat has gone stale -- see `ToggleDecision`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let scale: CGFloat = 2
    private static let spriteWidth = CGFloat(ClawdLayer.pixelColumns) * ClawdLayer.pixelWidthPt * scale
    private static let spriteHeight = CGFloat(ClawdLayer.pixelRows) * ClawdLayer.pixelHeightPt * scale
    private static let accessoryHeight: CGFloat = 16 * scale
    private static let edgeInset: CGFloat = 24
    private static let heartbeatInterval: TimeInterval = 2.0

    private let paths = ClawdPaths.fromEnvironment()
    private let appStatusStore: AppStatusStore
    private let heartbeatQueue = DispatchQueue(label: "local.clawd.pet.heartbeat")

    private var panel: PetPanel!
    private var clawdLayer: ClawdLayer!
    private var statusItem: NSStatusItem!
    private var visibilityMenuItem: NSMenuItem!
    private var heartbeatTimer: Timer?

    private(set) var isVisible = true

    override init() {
        appStatusStore = AppStatusStore(paths: paths)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set early (and also declared via LSUIElement in Info.plist) so the process never
        // shows a Dock icon or steals activation, including when run outside the .app
        // bundle during development.
        NSApp.setActivationPolicy(.accessory)

        // Registered before launch finishes so a `clawd://...` Apple Event that triggered
        // this launch (via `open -g clawd://show`) is still delivered to us.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let skin = SkinLoader.load(
            name: "clawd",
            searchDirs: [paths.skinsDir, Bundle.main.resourceURL!.appending(path: "Skins")]
        )
        buildPanel(skin: skin)
        buildStatusItem()
        // Default to shown, unless a `clawd://hide`/`clawd://toggle` Apple Event that
        // triggered this launch already arrived (and was recorded into `isVisible` by
        // `requestVisible`, since the panel didn't exist yet to apply it to).
        setVisible(isVisible)
        startHeartbeat()
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Panel

    private func buildPanel(skin: SkinManifest) {
        let size = NSSize(width: Self.spriteWidth, height: Self.spriteHeight + Self.accessoryHeight)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - Self.edgeInset,
            y: visibleFrame.minY + Self.edgeInset
        )

        let newPanel = PetPanel(contentRect: NSRect(origin: origin, size: size))

        let layer = ClawdLayer(skin: skin, scale: Self.scale)
        layer.position = CGPoint(x: size.width / 2, y: Self.spriteHeight / 2)
        layer.apply(state: .idle, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        newPanel.contentView?.layer?.addSublayer(layer)

        panel = newPanel
        clawdLayer = layer
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusBarImage()
        item.button?.toolTip = "Clawd"

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "隐藏宠物", action: #selector(toggleVisibility), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: nil, keyEquivalent: "")
        settingsItem.isEnabled = false // enabled in Task 14
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Clawd", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        visibilityMenuItem = toggleItem
    }

    /// A 16pt template image of Clawd's base frame, for the status-bar item.
    private static func statusBarImage() -> NSImage {
        let skin = SkinLoader.builtin()
        guard let frame = skin.frames["base"],
              let cgImage = SkinRenderer.image(frame: frame, palette: skin.palette, dim: false)
        else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let aspect = Double(ClawdLayer.pixelRows * 2) / Double(ClawdLayer.pixelColumns)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16 * aspect))
        image.isTemplate = true
        return image
    }

    @objc private func toggleVisibility() {
        requestVisible(!isVisible)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Visibility

    /// Applies visibility to the actual panel/menu. Safe to call only once the panel
    /// exists (see `requestVisible`, which guards the race where a `clawd://...` Apple
    /// Event is dispatched to `handleGetURLEvent` before `applicationDidFinishLaunching`
    /// has built the panel -- that used to crash on a nil `panel` force-unwrap).
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        visibilityMenuItem?.title = visible ? "隐藏宠物" : "显示宠物"
    }

    /// The entry point for anything that wants to show/hide the pet (the URL scheme, the
    /// menu, and the initial default-shown state): applies immediately if the panel
    /// already exists, or just records the request for `applicationDidFinishLaunching`
    /// to apply once it's built the panel.
    private func requestVisible(_ visible: Bool) {
        guard panel != nil else {
            isVisible = visible
            return
        }
        setVisible(visible)
    }

    // MARK: - clawd:// URL scheme

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }
        handle(url: url)
    }

    private func handle(url: URL) {
        switch url.host {
        case "show":
            requestVisible(true)
        case "hide":
            requestVisible(false)
        case "toggle":
            requestVisible(!isVisible)
        case "debug-hang":
            if UserDefaults.standard.bool(forKey: "debugEnabled") {
                Thread.sleep(forTimeInterval: 3600)
            }
        default:
            break
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        writeHeartbeat()
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            // Safe: this timer is only ever added to `RunLoop.main`, so it always fires
            // on the main thread/actor even though `Timer`'s closure type isn't isolated.
            MainActor.assumeIsolated {
                self?.writeHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// Builds the status value on the main thread (where `isVisible` lives) but performs
    /// the actual file write on a background queue, per the Global Constraint that the
    /// main thread only ever does UI work.
    private func writeHeartbeat() {
        let status = AppStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            visible: isVisible,
            heartbeat: Int64(Date().timeIntervalSince1970 * 1000),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        let store = appStatusStore
        heartbeatQueue.async {
            try? store.write(status)
        }
    }
}
