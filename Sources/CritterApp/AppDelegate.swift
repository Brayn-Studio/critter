import AppKit
import Carbon.HIToolbox
import CritterCore
import os

/// Boots the menu-bar app: an accessory-policy process with no Dock icon, a status-bar
/// menu, the `critter://` URL scheme, and a heartbeat written to `~/.critter/app.json` so
/// `critter-hook toggle` can tell the app is alive (and restart it if the heartbeat has gone
/// stale -- see `ToggleDecision`). It assembles the controllers: `SessionMonitor` (the data
/// layer) feeds `PetController` (the always-on-top pet panel and its visibility), whose
/// clicks go to `JumpBackService` (bringing the session's window forward). The same sessions
/// go to `BridgeController` (the phone bridge) while it is switched on. `SettingsStore`
/// changes are routed here to the pet, the global `HotKey`, the login item and the bridge.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let heartbeatInterval: TimeInterval = 2.0

    private let paths = CritterPaths.fromEnvironment()
    private let appStatusStore: AppStatusStore
    private let heartbeatQueue = DispatchQueue(label: "local.critter.pet.heartbeat")
    private let sessionMonitor: SessionMonitor
    private let petController: PetController
    private let jumpBackService: JumpBackService
    private let settings: SettingsStore
    private let bridge: BridgeController
    private let soundPlayer = ThemedSoundPlayer()
    private let hotKey = HotKey()
    private let loginItemQueue = DispatchQueue(label: "local.critter.pet.login-item", qos: .utility)
    private lazy var phoneSettings = PhoneSettingsModel(bridge: bridge, paths: paths)
    private lazy var settingsWindow = SettingsWindowController(
        store: settings,
        phone: phoneSettings,
        skinSearchDirs: skinSearchDirs,
        // The same list the "形象" tiles show is what "随机宠物" deals from.
        onSkinsListed: { [weak self] choices in
            guard let self else { return }
            petController.setSkinPool(choices)
            updateBridge()
        },
        onPreviewSound: { [weak self] state in self?.previewSound(state) },
        onResetPosition: { [weak self] in self?.petController.resetPosition() }
    )

    private var statusItem: NSStatusItem!
    private var visibilityMenuItem: NSMenuItem?
    private var heartbeatTimer: Timer?
    private var isTerminating = false
    /// Counts `loadSkin` requests, so only the latest one's skin is put on.
    private var skinRequest = 0
    /// Held for the app's whole lifetime: opts out of App Nap, which could otherwise hold a
    /// hidden pet's heartbeat timer back past the hook's stale threshold and get a healthy
    /// app restarted by `/pet` (also declared via `LSAppNapIsDisabled` in Info.plist).
    private var noAppNapActivity: NSObjectProtocol?

    override init() {
        appStatusStore = AppStatusStore(paths: paths)
        sessionMonitor = SessionMonitor(paths: paths)
        settings = SettingsStore()
        petController = PetController(monitor: sessionMonitor, settings: settings, soundPlayer: soundPlayer)
        jumpBackService = JumpBackService(paths: paths)
        bridge = BridgeController(paths: paths, skinSearchDirs: Self.skinSearchDirs(paths), monitor: sessionMonitor)
        super.init()

        // Visibility lives in `PetController`; the menu title follows it immediately, even
        // for a `critter://hide` that arrives before the panel has been built. So does
        // app.json (written off the main thread): otherwise a second `/pet` within the 2 s
        // heartbeat interval would read the old `visible` and repeat the first one.
        petController.onVisibilityChange = { [weak self] visible in
            self?.visibilityMenuItem?.title = Self.visibilityTitle(visible)
            self?.writeHeartbeat()
        }
        sessionMonitor.onSnapshot = { [weak self] sessions in
            self?.petController.show(sessions: sessions)
            self?.updateBridge(sessions)
        }
        // Clicking a Critter (or its menu's "跳回会话") brings that session's window forward.
        petController.onJump = { [jumpBackService] session in
            jumpBackService.jump(to: session)
        }
        petController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        // A phone that used a pairing code waits for "允许" / "拒绝" in the settings window --
        // brought up if it isn't, and never a modal alert (the pet must stay draggable).
        bridge.onPairRequest = { [weak self] deviceName, answer in
            guard let self else { return answer(false) }
            phoneSettings.receivePairRequest(deviceName: deviceName, answer: answer)
            settingsWindow.show()
        }
        settings.onChange = { [weak self] change in
            self?.settingsChanged(change)
        }
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            DiagnosticLog.shared.log("hotkey pressed")
            petController.setVisible(!petController.visible)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        noAppNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Critter keeps its heartbeat on time so /pet can tell it apart from a hung app"
        )

        // Set early (and also declared via LSUIElement in Info.plist) so the process never
        // shows a Dock icon or steals activation, including when run outside the .app
        // bundle during development.
        NSApp.setActivationPolicy(.accessory)

        // Registered before launch finishes so a `critter://...` Apple Event that triggered
        // this launch (via `open -g critter://show`) is still delivered to us.
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
        if settings.bridgeEnabled { bridge.setEnabled(true) }
        refreshHotKey()
        applyLaunchAtLogin()
        loadSkin()
        // Listed ahead of time, so the settings open with the skins already in place (and
        // "随机宠物" has them to deal from).
        settingsWindow.reloadSkins()
    }

    /// Removes `~/.critter/app.json` (best effort), so a pid that outlives this process can't
    /// be mistaken for Critter later. Queued behind any pending heartbeat write, so that write
    /// can't recreate the file; bounded, so quitting never hangs on it.
    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        isTerminating = true
        let store = appStatusStore
        let removed = DispatchSemaphore(value: 0)
        heartbeatQueue.async {
            store.delete(ifOwnedBy: OwnProcess.pid)
            removed.signal()
        }
        _ = removed.wait(timeout: .now() + 0.5)
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The builtin until the chosen skin has loaded (`wear`).
        item.button?.image = Self.statusBarImage(SkinLoader.builtin())
        item.button?.toolTip = "Critter"

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: Self.visibilityTitle(petController.visible), action: #selector(toggleVisibility), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 Critter", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        visibilityMenuItem = toggleItem
    }

    /// A template image of the skin's standing pose fitted into 16×16 pt, for the
    /// status-bar item.
    private static func statusBarImage(_ skin: SkinManifest) -> NSImage {
        guard let grid = SkinRenderer.portrait(of: skin),
              let cgImage = SkinRenderer.image(grid, palette: skin.palette, dim: false)
        else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let scale = 16 / Double(max(grid.width, grid.height))
        let image = NSImage(cgImage: cgImage, size: NSSize(width: Double(grid.width) * scale, height: Double(grid.height) * scale))
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

    // MARK: - Skin

    /// Where skins are looked for, first match wins: `~/.critter/skins`, then the ones
    /// bundled with the app. `Bundle.main.resourceURL` is just path arithmetic (no I/O), but
    /// it can be nil outside a real .app bundle, so it's folded in only when present rather
    /// than force-unwrapped.
    private var skinSearchDirs: [URL] {
        Self.skinSearchDirs(paths)
    }

    private static func skinSearchDirs(_ paths: CritterPaths) -> [URL] {
        Bundle.main.resourceURL.map { [paths.skinsDir, $0.appending(path: "Skins")] } ?? [paths.skinsDir]
    }

    /// Loads the chosen skin (`settings.skin`; the builtin if that one is missing or invalid)
    /// and puts it on. `SkinLoader.load` does blocking file I/O (`Data(contentsOf:)`), so it
    /// must not run on the main thread (Global Constraint: main thread is UI-only; file/
    /// process/AppleScript work goes on a background queue). Only the latest request is put
    /// on, so skins picked quickly in a row can't end on an earlier one that loaded last.
    private func loadSkin() {
        skinRequest += 1
        let request = skinRequest
        let name = settings.skin
        let searchDirs = skinSearchDirs
        // "随机宠物" at launch: the skins to deal from come along, so the first Critters already
        // wear theirs instead of all switching once the list arrives.
        let listPool = settings.randomSkins && !petController.isInstalled
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pool = listPool ? SkinLibrary.available(searchDirs: searchDirs) : nil
            let found = SkinLoader.find(name: name, searchDirs: searchDirs)
            let skin = found ?? SkinLoader.builtin()
            // Asking for the builtin by name isn't falling back to it.
            let fellBack = found == nil && name.caseInsensitiveCompare(skin.name) != .orderedSame
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor, even
                // though the closure's static type isn't actor-isolated (same reasoning
                // as the heartbeat timer below).
                MainActor.assumeIsolated {
                    guard let self, request == self.skinRequest else { return }
                    if let pool { self.petController.setSkinPool(pool) }
                    self.wear(skin, named: name, fellBack: fellBack)
                }
            }
        }
    }

    /// Puts on a freshly loaded skin, menu-bar icon included, unless it's the one already
    /// worn. The first one builds the panel; `PetController` then applies whatever visibility
    /// was requested in the meantime (the default, or a `critter://hide`/`critter://toggle`
    /// that arrived before the panel existed). Later ones switch the pet over in place.
    private func wear(_ skin: SkinManifest, named name: String, fellBack: Bool) {
        DiagnosticLog.shared.log("event skin=\(name)" + (fellBack ? " fallback=\(skin.name)" : ""))
        guard skin != petController.skin else { return }
        statusItem.button?.image = Self.statusBarImage(skin)
        if petController.isInstalled {
            petController.setSkin(skin)
        } else {
            petController.install(skin: skin)
        }
        // Skins are dealt anew for it under "随机宠物".
        updateBridge()
    }

    // MARK: - Settings

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// A ▶ in settings: plays that state's sound from the chosen set, whether or not the pet
    /// is visible or that state's own switch is on.
    private func previewSound(_ state: PetState) {
        DiagnosticLog.shared.log("sound preview state=\(state.rawValue) theme=\(settings.soundTheme.rawValue)")
        soundPlayer.play(state, theme: settings.soundTheme)
    }

    private func settingsChanged(_ change: SettingsStore.Change) {
        switch change {
        case .skin:
            loadSkin()
        case .randomSkins:
            DiagnosticLog.shared.log("event random-skins \(settings.randomSkins ? "on" : "off")")
            petController.randomSkinsDidChange()
            // Dealt from a fresh list, in case skins came or went since the last one.
            if settings.randomSkins { settingsWindow.reloadSkins() }
        case .petScale:
            petController.scaleDidChange()
        case .idleDim:
            petController.idleDimDidChange()
        case .mergeThreshold:
            petController.layoutSettingsDidChange()
        case .sounds:
            break // read when a sound is due
        case .hotKey:
            refreshHotKey()
        case .launchAtLogin:
            applyLaunchAtLogin()
        case .bridge:
            DiagnosticLog.shared.log("event bridge \(settings.bridgeEnabled ? "on" : "off")")
            bridge.setEnabled(settings.bridgeEnabled)
            writeHeartbeat()
        }
        // What the phone mirrors: the skins and these settings.
        switch change {
        case .skin, .randomSkins, .idleDim, .mergeThreshold, .sounds, .bridge:
            updateBridge()
        case .petScale, .hotKey, .launchAtLogin:
            break
        }
    }

    // MARK: - Phone bridge

    /// Hands the bridge the sessions (the monitor's latest by default), the skin each one's
    /// Critter wears and the settings the phone mirrors -- only while it's switched on, so
    /// that off, nothing extra runs.
    private func updateBridge(_ sessions: [PetSession]? = nil) {
        guard settings.bridgeEnabled else { return }
        let sessions = sessions ?? sessionMonitor.sessions
        let skins = Dictionary(sessions.map { ($0.id, petController.skinName(for: $0.id)) }) { first, _ in first }
        let prefs = BridgePrefs(
            skin: settings.skin, randomSkins: settings.randomSkins, idleDim: settings.idleDim,
            mergeThreshold: settings.mergeThreshold, soundTheme: settings.soundTheme.rawValue
        )
        bridge.update(sessions: sessions, skins: skins, prefs: prefs)
    }

    /// (Re-)registers the global hot key from the settings -- or keeps it unregistered
    /// while the settings window is recording a new one.
    private func refreshHotKey() {
        guard !settings.isRecordingHotKey else {
            hotKey.unregister()
            DiagnosticLog.shared.log("hotkey suspended while recording")
            return
        }
        let spec = settings.hotKey
        let status = hotKey.register(spec)
        settings.hotKeyUnavailable = status != noErr
        DiagnosticLog.shared.log("hotkey register \(HotKeyFormat.display(spec)) keyCode=\(spec.keyCode) modifiers=0x\(String(spec.modifiers, radix: 16)) status=\(status)")
    }

    /// Writes or deletes `~/Library/LaunchAgents/local.critter.pet.plist` to match the
    /// setting (also at every launch, so the agent follows the app if it was moved). Only
    /// a real `.app` bundle is ever registered -- never a bare development binary.
    private func applyLaunchAtLogin() {
        let enabled = settings.launchAtLogin
        let appURL = Bundle.main.bundleURL
        let dir = LaunchAgent.userLaunchAgentsDir()
        loginItemQueue.async {
            do {
                if enabled {
                    guard appURL.pathExtension == "app" else { return }
                    try LaunchAgent.install(appPath: appURL.path, in: dir)
                } else {
                    try LaunchAgent.remove(in: dir)
                }
                DiagnosticLog.shared.log("launch-at-login \(enabled ? "on" : "off") plist=\(LaunchAgent.isInstalled(in: dir))")
            } catch {
                Logger(subsystem: "local.critter.pet", category: "settings").error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - critter:// URL scheme

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }
        handle(url: url)
    }

    private func handle(url: URL) {
        // Every URL event is answered with a fresh heartbeat: when the heartbeat looked
        // stale, critter-hook sends its request and waits briefly for exactly this before
        // concluding the app is hung (`ToggleAction.probe`).
        defer { writeHeartbeat() }
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
            // `critter://debug-click?target=<session id|handle|chips>[&item=<menu title>]`:
            // replays a left click (or, with `item`, a right-click and that menu choice)
            // through the pet's real mouse/menu code, for verifying without a display.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in query.first { $0.name == name }?.value }
            if let target = value("target") {
                petController.debugClick(target: target, menuItem: value("item"))
            }
        case "debug-snapshot":
            // `critter://debug-snapshot?path=<absolute .png>[&count=N][&interval=<ms>]`: renders
            // the pet's layer tree to PNG(s) (see `DebugSnapshot`), for verifying the
            // animation where screen capture is unavailable.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in query.first { $0.name == name }?.value }
            guard let path = value("path"), path.hasPrefix("/") else {
                DiagnosticLog.shared.log("debug-snapshot needs an absolute path")
                break
            }
            petController.debugSnapshot(
                path: path,
                count: value("count").flatMap(Int.init) ?? 1,
                intervalMs: value("interval").flatMap(Int.init) ?? 150
            )
        case "debug-pointer":
            // `critter://debug-pointer?x=<screen x>&y=<screen y>`: a pointer move there (screen
            // coordinates, origin bottom-left), fed down the mouse monitors' path -- for
            // checking gaze, hover and rubbing without a mouse.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in query.first { $0.name == name }?.value.flatMap(Double.init) }
            if let x = value("x"), let y = value("y") {
                petController.debugPointer(NSPoint(x: x, y: y))
            }
        case "debug-drag":
            // `critter://debug-drag?target=<session id|chips|handle>&dx=<pt>&dy=<pt>[&steps=N]
            // [&interval=<ms>][&wait=<ms>][&hold=<ms>]`: presses on the target, waits, drags
            // (dx, dy) in N steps, holds still, and lets go -- through the pet's real
            // press/drag/release code.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in query.first { $0.name == name }?.value }
            guard let target = value("target") else { break }
            petController.debugDrag(
                target: target,
                dx: value("dx").flatMap(Double.init).map { CGFloat($0) } ?? 0,
                dy: value("dy").flatMap(Double.init).map { CGFloat($0) } ?? 0,
                steps: value("steps").flatMap(Int.init) ?? 10,
                intervalMs: value("interval").flatMap(Int.init) ?? 30,
                waitMs: value("wait").flatMap(Int.init) ?? 0,
                holdMs: value("hold").flatMap(Int.init) ?? 0
            )
        case "debug-set":
            // `critter://debug-set?<setting>=<value>[&…]`: changes settings through the same
            // store the settings window binds to (debug only; see `applyDebugValue`).
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if item.name == "debugReduceMotion" {
                    // Not a setting: stands in for the system's "Reduce motion" (debug only).
                    UserDefaults.standard.set(["1", "true", "yes"].contains(item.value ?? ""), forKey: item.name)
                    DiagnosticLog.shared.log("debug-set \(item.name)=\(item.value ?? "") ok=true")
                    petController.reduceMotionDidChange()
                    continue
                }
                let ok = settings.applyDebugValue(item.value ?? "", forKey: item.name)
                DiagnosticLog.shared.log("debug-set \(item.name)=\(item.value ?? "") ok=\(ok)")
            }
        case "debug-bridge-pair":
            // `critter://debug-bridge-pair?out=<absolute path>`: issues a pairing code that is
            // approved without asking and writes `{"uri": "<pairing URI>"}` to `out`, for
            // pairing `critter-bridge-client` without a display. Waits for the bridge to finish
            // starting if it was only just switched on. `out` must be under ~/.critter or the
            // user's temp directory: the file holds a code that lets a phone in unasked.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let out = query.first(where: { $0.name == "out" })?.value,
                  CritterPaths.isFile(out, under: [paths.critterHome, URL(fileURLWithPath: NSTemporaryDirectory())])
            else {
                DiagnosticLog.shared.log("debug-bridge-pair needs an out path under ~/.critter or the temp directory")
                break
            }
            bridge.beginPairing(autoApprove: true) { uri in
                // On the bridge queue, so the file write stays off the main thread.
                guard let uri else {
                    DiagnosticLog.shared.log("debug-bridge-pair: bridge not listening")
                    return
                }
                let json = try? JSONSerialization.data(withJSONObject: ["uri": uri.string], options: [.withoutEscapingSlashes])
                let written = (try? json?.write(to: URL(fileURLWithPath: out), options: .atomic)) != nil
                DiagnosticLog.shared.log("debug-bridge-pair wrote=\(written)")
            }
        case "debug-bridge-revoke":
            // `critter://debug-bridge-revoke?deviceId=<id>`: unpairs a device that
            // `critter-bridge-client` paired (and no other), so a dev run leaves nothing behind.
            guard UserDefaults.standard.bool(forKey: "debugEnabled") else { break }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let deviceId = query.first(where: { $0.name == "deviceId" })?.value {
                bridge.revokeDevClient(deviceId: deviceId)
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
        guard !isTerminating else { return }
        let visible = petController.visible
        // Read by `critter-hook ask` to decide whether a phone could answer: only while the
        // bridge is switched on and actually reachable.
        let bridgeEnabled = settings.bridgeEnabled && bridge.isServing
        let lastClientSeen = bridge.lastClientSeen
        let heartbeat = Int64(Date().timeIntervalSince1970 * 1000)
        let version = AppVersion.current
        let store = appStatusStore
        heartbeatQueue.async {
            // `startTime` lets critter-hook tell this process from a later one that reuses its
            // pid (see `ToggleDecision.isCritter`).
            let status = AppStatus(
                pid: OwnProcess.pid, visible: visible, heartbeat: heartbeat, version: version,
                startTime: OwnProcess.startTime, bridgeEnabled: bridgeEnabled, lastClientSeen: lastClientSeen
            )
            try? store.write(status)
        }
    }
}

/// This process's identity as recorded in app.json. `startTime` is a process query, so it
/// is only ever first touched from the heartbeat queue (Global Constraint: the main thread
/// only does UI); a `static let` is initialized once, thread-safely.
private enum OwnProcess {
    static let pid = ProcessInfo.processInfo.processIdentifier
    static let startTime = ProcessTools.startTime(of: ProcessInfo.processInfo.processIdentifier)
}
