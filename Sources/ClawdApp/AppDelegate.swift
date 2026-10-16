import AppKit
import Carbon.HIToolbox
import ClawdCore

/// Boots the menu-bar app: an accessory-policy process with no Dock icon, a status-bar
/// menu, the `clawd://` URL scheme, and a heartbeat written to `~/.clawd/app.json` so
/// `clawd-hook toggle` can tell the app is alive (and restart it if the heartbeat has gone
/// stale -- see `ToggleDecision`). It assembles the controllers: `SessionMonitor` (the data
/// layer) feeds `PetController` (the always-on-top pet panel and its visibility), whose
/// clicks go to `JumpBackService` (bringing the session's window forward).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let heartbeatInterval: TimeInterval = 2.0

    private let paths = ClawdPaths.fromEnvironment()
    private let appStatusStore: AppStatusStore
    private let heartbeatQueue = DispatchQueue(label: "local.clawd.pet.heartbeat")
    private let sessionMonitor: SessionMonitor
    private let petController: PetController
    private let jumpBackService: JumpBackService

    private var statusItem: NSStatusItem!
    private var visibilityMenuItem: NSMenuItem?
    private var heartbeatTimer: Timer?

    override init() {
        appStatusStore = AppStatusStore(paths: paths)
        sessionMonitor = SessionMonitor(paths: paths)
        petController = PetController(monitor: sessionMonitor)
        jumpBackService = JumpBackService(paths: paths)
        super.init()

        // Visibility lives in `PetController`; the menu title follows it immediately, even
        // for a `clawd://hide` that arrives before the panel has been built.
        petController.onVisibilityChange = { [weak self] visible in
            self?.visibilityMenuItem?.title = Self.visibilityTitle(visible)
        }
        sessionMonitor.onSnapshot = { [weak self] sessions in
            self?.petController.show(sessions: sessions)
        }
        // Clicking a Clawd (or its menu's "跳回会话") brings that session's window forward.
        petController.onJump = { [jumpBackService] session in
            jumpBackService.jump(to: session)
        }
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
        // UI-only work happens here, synchronously, on the main thread.
        buildStatusItem()
        startHeartbeat()
        sessionMonitor.start()

        // `SkinLoader.load` does blocking file I/O (`Data(contentsOf:)`), so it must not
        // run on the main thread (Global Constraint: main thread is UI-only; file/process/
        // AppleScript work goes on a background queue). `Bundle.main.resourceURL` is just
        // path arithmetic (no I/O), but it can be nil outside a real .app bundle, so it's
        // folded in only when present rather than force-unwrapped.
        let searchDirs: [URL] = Bundle.main.resourceURL
            .map { [paths.skinsDir, $0.appending(path: "Skins")] } ?? [paths.skinsDir]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let skin = SkinLoader.load(name: "clawd", searchDirs: searchDirs)
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor, even
                // though the closure's static type isn't actor-isolated (same reasoning
                // as the heartbeat timer below).
                MainActor.assumeIsolated {
                    self?.finishLaunch(with: skin)
                }
            }
        }
    }

    /// Builds the panel once the skin has finished loading off the main thread;
    /// `PetController` then applies whatever visibility was requested in the meantime (the
    /// default, or a `clawd://hide`/`clawd://toggle` that arrived before the panel existed).
    private func finishLaunch(with skin: SkinManifest) {
        petController.install(skin: skin)
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusBarImage()
        item.button?.toolTip = "Clawd"

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: Self.visibilityTitle(petController.visible), action: #selector(toggleVisibility), keyEquivalent: "")
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

    private static func visibilityTitle(_ visible: Bool) -> String {
        visible ? "隐藏宠物" : "显示宠物"
    }

    @objc private func toggleVisibility() {
        petController.setVisible(!petController.visible)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
            petController.setVisible(true)
        case "hide":
            petController.setVisible(false)
        case "toggle":
            petController.setVisible(!petController.visible)
        case "debug-hang":
            if UserDefaults.standard.bool(forKey: "debugEnabled") {
                Thread.sleep(forTimeInterval: 3600)
            }
        case "debug-click":
            // `clawd://debug-click?target=<session id|handle|chips>[&item=<menu title>]`:
            // replays a left click (or, with `item`, a right-click and that menu choice)
            // through the pet's real mouse/menu code, for verifying without a display.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in query.first { $0.name == name }?.value }
            if let target = value("target") {
                petController.debugClick(target: target, menuItem: value("item"))
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

    /// Builds the status value on the main thread (where visibility lives) but performs
    /// the actual file write on a background queue, per the Global Constraint that the
    /// main thread only ever does UI work.
    private func writeHeartbeat() {
        let status = AppStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            visible: petController.visible,
            heartbeat: Int64(Date().timeIntervalSince1970 * 1000),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        let store = appStatusStore
        heartbeatQueue.async {
            try? store.write(status)
        }
    }
}
