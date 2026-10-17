import AppKit
import CritterCore
import SwiftUI

/// The settings window (spec §8): a plain titled window hosting `SettingsView`. Opened
/// from "设置…" in the menu-bar menu and the pet's context menu; built on first use and
/// kept afterwards.
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private let recorder: HotKeyRecorder
    private let skinPicker = SkinPicker()
    private let skinSearchDirs: [URL]
    /// Counts `reloadSkins` requests, so a listing that finishes late can't replace a newer one.
    private var skinListRequest = 0
    private let onPreviewSound: (PetState) -> Void
    private let onResetPosition: () -> Void
    private var window: NSWindow?

    init(store: SettingsStore, skinSearchDirs: [URL], onPreviewSound: @escaping (PetState) -> Void, onResetPosition: @escaping () -> Void) {
        self.store = store
        self.skinSearchDirs = skinSearchDirs
        self.onPreviewSound = onPreviewSound
        self.onResetPosition = onResetPosition
        recorder = HotKeyRecorder(store: store)
    }

    /// Lists the skins for "形象" again, off the main thread (it reads every manifest), so
    /// one dropped into `~/.critter/skins` shows up the next time the window opens.
    func reloadSkins() {
        skinListRequest += 1
        let request = skinListRequest
        let searchDirs = skinSearchDirs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let choices = SkinLibrary.available(searchDirs: searchDirs)
            DispatchQueue.main.async {
                // Safe: `DispatchQueue.main` always runs on the main thread/actor.
                MainActor.assumeIsolated {
                    guard let self, request == self.skinListRequest else { return }
                    self.skinPicker.update(choices)
                }
            }
        }
    }

    /// Brings the window up in front, activating Critter (an accessory app is otherwise
    /// never active, and the window needs to be key to record a hot key).
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DiagnosticLog.shared.log("settings shown size=\(Int(window.frame.width))x\(Int(window.frame.height)) key=\(window.isKeyWindow)")
        reloadSkins()
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            store: store, skinPicker: skinPicker, recorder: recorder,
            onPreviewSound: onPreviewSound, onResetPosition: onResetPosition
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Critter 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // The hosting view has no size until SwiftUI lays it out; size the window to the
        // form up front so it opens at full size and centered.
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // Closing the window abandons a recording in progress.
            MainActor.assumeIsolated { self?.recorder.stop() }
        }
        return window
    }
}

/// "录制": captures the next key combination pressed in the settings window with a local
/// key-down monitor. It must include ⌃, ⌥ or ⌘ (`HotKeySpec.isRecordable`); other keys are
/// ignored, and Esc cancels.
@MainActor
final class HotKeyRecorder {
    private static let escapeKeyCode: UInt16 = 53

    private let store: SettingsStore
    private var monitor: Any?

    init(store: SettingsStore) {
        self.store = store
    }

    func start() {
        guard monitor == nil else { return }
        store.isRecordingHotKey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.rawValue
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handle(keyCode: keyCode, cocoaFlags: flags) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        store.isRecordingHotKey = false
    }

    /// Returns whether the key press was used up by the recording.
    private func handle(keyCode: UInt16, cocoaFlags: UInt) -> Bool {
        let spec = HotKeySpec(keyCode: UInt32(keyCode), modifiers: HotKeySpec.carbonModifiers(cocoaFlags: cocoaFlags))
        if spec.modifiers == 0, keyCode == Self.escapeKeyCode {
            stop()
        } else if spec.isRecordable {
            // Saved while still recording, so the new combination is registered once,
            // when `stop()` ends the recording.
            store.hotKey = spec
            stop()
        }
        return true
    }
}

/// The skins "形象" offers, each drawn once as it arrives from `SkinLibrary`.
@MainActor
@Observable
final class SkinPicker {
    /// Nil until the first list arrives.
    private(set) var tiles: [SkinTile]?
    @ObservationIgnored private var choices: [SkinChoice]?

    func update(_ choices: [SkinChoice]) {
        guard choices != self.choices else { return }
        self.choices = choices
        tiles = choices.map(SkinTile.init)
    }
}

/// One skin in "形象": its name, title and standing pose (`SkinRenderer.portrait`) drawn
/// one pixel per cell, for SwiftUI to scale up without smoothing.
struct SkinTile: Identifiable {
    let name: String
    let title: String
    let image: NSImage?
    /// The pose's size in cells.
    let cells: CGSize

    var id: String { name }

    init(_ choice: SkinChoice) {
        name = choice.name
        title = choice.title
        let grid = SkinRenderer.portrait(of: choice.manifest)
        let cgImage = grid.flatMap { SkinRenderer.image($0, palette: choice.manifest.palette, dim: false) }
        let cells = CGSize(width: grid?.width ?? 1, height: grid?.height ?? 1)
        self.cells = cells
        image = cgImage.map { NSImage(cgImage: $0, size: cells) }
    }
}

/// The settings form, in the order of spec §8, with "形象" first.
struct SettingsView: View {
    @Bindable var store: SettingsStore
    let skinPicker: SkinPicker
    let recorder: HotKeyRecorder
    let onPreviewSound: (PetState) -> Void
    let onResetPosition: () -> Void

    var body: some View {
        Form {
            Section("形象") {
                if let tiles = skinPicker.tiles, !tiles.isEmpty {
                    let worn = wornTile(in: tiles)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: SkinTileButton.width), spacing: 8)], spacing: 8) {
                        ForEach(tiles) { tile in
                            SkinTileButton(tile: tile, selected: tile.name == worn) {
                                store.skin = tile.name
                            }
                        }
                    }
                } else {
                    LabeledContent("当前形象", value: store.skin)
                }
            }

            Section {
                Slider(value: $store.petScale, in: SettingsStore.scaleRange, step: SettingsStore.scaleStep) {
                    Text("Critter 大小")
                } minimumValueLabel: {
                    Text("小")
                } maximumValueLabel: {
                    Text("大")
                }
            }

            Section {
                Toggle("提示音", isOn: $store.soundEnabled)
                Group {
                    Picker("声音", selection: $store.soundTheme) {
                        ForEach(SoundTheme.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    soundToggle(.waiting, isOn: $store.soundOnWaiting)
                    soundToggle(.done, isOn: $store.soundOnDone)
                    soundToggle(.error, isOn: $store.soundOnError)
                }
                .disabled(!store.soundEnabled)
            }

            Section {
                Stepper(value: $store.mergeThreshold, in: SettingsStore.mergeThresholdRange) {
                    LabeledContent("自动合并阈值", value: "超过 \(store.mergeThreshold) 个会话时合并")
                }
            }

            Section {
                LabeledContent("全局快捷键") {
                    HStack {
                        Text(store.isRecordingHotKey ? "请按下新的组合键…" : HotKeyFormat.display(store.hotKey))
                            .monospaced()
                        Button(store.isRecordingHotKey ? "取消" : "录制") {
                            if store.isRecordingHotKey { recorder.stop() } else { recorder.start() }
                        }
                        Button("恢复默认") {
                            recorder.stop()
                            store.hotKey = .default
                        }
                        .disabled(store.hotKey == .default && !store.isRecordingHotKey)
                    }
                }
                if store.hotKeyUnavailable && !store.isRecordingHotKey {
                    Text("该快捷键已被占用")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("登录时自动启动", isOn: $store.launchAtLogin)
                LabeledContent("宠物位置") {
                    Button("重置位置", action: onResetPosition)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The name of the tile the pet is wearing: `store.skin`'s (ignoring case, like the
    /// default macOS volume `SkinLoader.load` reads from), or the builtin's, first in the
    /// list, when that skin can't be loaded and the pet fell back to the builtin.
    private func wornTile(in tiles: [SkinTile]) -> String? {
        (tiles.first { $0.name.caseInsensitiveCompare(store.skin) == .orderedSame } ?? tiles.first)?.name
    }

    /// One state's switch, with a ▶ that plays its sound from the chosen set.
    private func soundToggle(_ state: PetState, isOn: Binding<Bool>) -> some View {
        LabeledContent(state.label) {
            HStack {
                Button {
                    onPreviewSound(state)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("试听")
                .accessibilityLabel("试听\(state.label)")
                // Out of its own form row a toggle would draw as a checkbox.
                Toggle(state.label, isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

/// A skin's tile in "形象": its portrait over its title, ringed in the accent color when
/// it's the one being worn. Clicking it (or Space, once focused) puts it on.
private struct SkinTileButton: View {
    static let width: CGFloat = 76
    /// The box the portrait is scaled into: by a whole number of points per cell, or by
    /// less than one for a pose bigger than the box.
    private static let portraitBox = CGSize(width: 60, height: 44)

    let tile: SkinTile
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                portrait
                    .frame(width: Self.portraitBox.width, height: Self.portraitBox.height)
                Text(tile.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(tile.title)
        .accessibilityLabel(tile.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var portrait: some View {
        if let image = tile.image {
            let fit = min(Self.portraitBox.width / tile.cells.width, Self.portraitBox.height / tile.cells.height)
            let scale = fit >= 1 ? fit.rounded(.down) : fit
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: tile.cells.width * scale, height: tile.cells.height * scale)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
