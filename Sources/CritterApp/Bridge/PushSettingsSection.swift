import AppKit
import CritterCore
import SwiftUI
import UniformTypeIdentifiers

/// What the "iPhone 推送" section of the settings shows and does (spec 6.4): the APNs key, Key ID, Team ID
/// and bundle id, kept in `~/.critter/bridge/apns/` by `APNsConfigStore` (never in `UserDefaults`); the
/// status; "发送测试通知". The files are read and written off the main thread; the bridge hears about every
/// change (`BridgeController.pushSetupChanged`).
@MainActor
@Observable
final class PushSettingsModel {
    var keyId = ""
    var teamId = ""
    var bundleId = APNsConfig.defaultBundleId
    /// The imported key's file name; nil before one is chosen.
    private(set) var keyFileName: String?
    /// What the files on disk amount to; nil until they have been read.
    private(set) var setup: APNsSetup?
    private(set) var status = PushCoordinator.Status()
    /// Why the chosen file was not taken, or the setup not saved.
    private(set) var note: String?
    private(set) var busy = false
    /// A test was just sent: the button rests for a moment.
    private(set) var testing = false

    @ObservationIgnored private let bridge: BridgeController
    @ObservationIgnored private let store: APNsConfigStore
    /// What is on disk, so an unchanged field is not saved again.
    @ObservationIgnored private var saved: APNsConfig?
    @ObservationIgnored private var hasRead = false

    init(bridge: BridgeController, paths: CritterPaths) {
        self.bridge = bridge
        store = APNsConfigStore(paths: paths)
    }

    // MARK: - Reading

    /// The bridge's push status; the files the first time.
    func refresh() {
        status = bridge.pushStatus()
        if !hasRead {
            hasRead = true
            reread()
        }
    }

    /// The setup the bridge can push with: its bundle id, nil when it is not ready.
    var readyBundleId: String? {
        if case .ready(let config, _)? = setup { return config.bundleId }
        return nil
    }

    private func reread() {
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = store.saved()
            let setup = store.load()
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self.show(saved: saved, setup: setup) }
            }
        }
    }

    private func show(saved: APNsConfig?, setup: APNsSetup) {
        self.saved = saved
        self.setup = setup
        guard let saved else { return }
        keyId = saved.keyId
        teamId = saved.teamId
        bundleId = saved.bundleId
        keyFileName = store.hasKey(saved) ? saved.keyFile.lastPathComponent : nil
    }

    // MARK: - Changing

    /// "选择 .p8 文件…": a non-modal open panel (the pet stays draggable) that takes only `.p8` files.
    func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 APNs 密钥"
        panel.message = "在 Apple 开发者网站的 Keys 里下载的 AuthKey_<Key ID>.p8"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let p8 = UTType(filenameExtension: "p8") { panel.allowedContentTypes = [p8] }
        panel.begin { response in
            // Safe: an open panel's completion runs on the main thread.
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, url.pathExtension.lowercased() == "p8" else { return }
                self.importKey(from: url)
            }
        }
    }

    /// Copies the key in, fills the Key ID from its name and saves.
    private func importKey(from source: URL) {
        busy = true
        note = nil
        let store = store
        let fields = fieldsConfig()
        DispatchQueue.global(qos: .userInitiated).async {
            var note: String?
            do {
                let imported = try store.importKey(from: source)
                var config = fields
                config.keyFile = imported.keyFile
                if let keyId = imported.keyId { config.keyId = keyId }
                do { try store.save(config) } catch { note = "保存失败" }
            } catch {
                note = APNsSetup.unreadableKey
            }
            let saved = store.saved()
            let setup = store.load()
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self.finish(note: note, saved: saved, setup: setup) }
            }
        }
    }

    /// The fields are saved when one loses focus or Return is pressed; nothing happens if they are as saved.
    func commit() {
        guard !busy else { return }
        let config = fieldsConfig()
        if let saved, config == saved { return }
        // Nothing entered and nothing saved yet: no file for it.
        if saved == nil, config.keyId.isEmpty, config.teamId.isEmpty, config.bundleId == APNsConfig.defaultBundleId { return }
        busy = true
        note = nil
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            var note: String?
            do { try store.save(config) } catch { note = "保存失败" }
            let saved = store.saved()
            let setup = store.load()
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated { self.finish(note: note, saved: saved, setup: setup) }
            }
        }
    }

    private func finish(note: String?, saved: APNsConfig?, setup: APNsSetup) {
        busy = false
        self.note = note
        show(saved: saved, setup: setup)
        bridge.pushSetupChanged()
        // The bridge reads the setup again on its own queue; its status follows shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated { self.status = self.bridge.pushStatus() }
        }
    }

    /// The fields as they would be saved: trimmed, the default bundle id when it is left empty, and the key
    /// already imported (or none yet).
    private func fieldsConfig() -> APNsConfig {
        let bundle = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyFile = saved.flatMap { store.hasKey($0) ? $0.keyFile : nil } ?? store.directory
        return APNsConfig(
            keyId: keyId.trimmingCharacters(in: .whitespacesAndNewlines),
            teamId: teamId.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleId: bundle.isEmpty ? APNsConfig.defaultBundleId : bundle, keyFile: keyFile
        )
    }

    /// "发送测试通知": one to every registered iPhone; the status line tells how it went.
    func sendTest() {
        testing = true
        bridge.sendTestPush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated {
                self.testing = false
                self.status = self.bridge.pushStatus()
            }
        }
    }
}

/// The "iPhone 推送" rows, below "手机": usable only while "允许手机连接" is on.
struct PushSettingsSection: View {
    @Bindable var store: SettingsStore
    @Bindable var push: PushSettingsModel
    /// The paired devices (`PhoneSettingsModel.devices`).
    let devices: [DeviceRecord]

    private enum Field: Hashable { case keyId, teamId, bundleId }
    @FocusState private var focused: Field?

    var body: some View {
        Section("iPhone 推送") {
            LabeledContent {
                Button("选择 .p8 文件…") { push.chooseKey() }
                    .disabled(push.busy)
            } label: {
                Text("APNs 密钥")
                Text(push.keyFileName ?? "还没有选择")
            }
            if let note = push.note {
                Text(note).foregroundStyle(.red)
            }

            TextField("Key ID", text: $push.keyId)
                .focused($focused, equals: .keyId)
                .onSubmit { push.commit() }
            TextField("Team ID", text: $push.teamId)
                .focused($focused, equals: .teamId)
                .onSubmit { push.commit() }
            TextField("Bundle ID", text: $push.bundleId)
                .focused($focused, equals: .bundleId)
                .onSubmit { push.commit() }

            LabeledContent("状态") {
                // "上次发送 x 分钟前" moves on by itself.
                TimelineView(.everyMinute) { timeline in
                    let line = statusLine(now: timeline.date)
                    Text(line.text)
                        .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                }
            }

            LabeledContent {
                Button("发送测试通知") { push.sendTest() }
                    .disabled(!canTest)
            } label: {
                Text("测试")
                if let hint = testHint { Text(hint) }
            }
        }
        .disabled(!store.bridgeEnabled)
        .onChange(of: focused) { old, _ in
            if old != nil { push.commit() }
        }
        .onDisappear { push.commit() }
    }

    private var registered: Int { devices.filter { $0.push != nil }.count }

    private var reachable: Int {
        devices.filter { PushCoordinatorRules.canPush($0.push, bundleId: push.readyBundleId) }.count
    }

    private var testHint: String? {
        PushStatusText.testHint(registered: registered, reachable: reachable, setUp: push.readyBundleId != nil)
    }

    private var canTest: Bool {
        store.bridgeEnabled && push.readyBundleId != nil && reachable > 0 && push.status.blockedReason == nil
            && !push.testing && !push.busy
    }

    private func statusLine(now: Date) -> PushStatusText.Line {
        PushStatusText.line(
            setup: push.setup, blockedReason: push.status.blockedReason, lastFailure: push.status.lastFailure,
            lastSentAt: push.status.lastSentAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            now: Int64(now.timeIntervalSince1970 * 1000)
        )
    }
}
