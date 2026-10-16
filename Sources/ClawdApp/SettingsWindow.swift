import AppKit
import ClawdCore
import SwiftUI

/// The settings window (spec §8): a plain titled window hosting `SettingsView`. Opened
/// from "设置…" in the menu-bar menu and the pet's context menu; built on first use and
/// kept afterwards.
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private let recorder: HotKeyRecorder
    private let onResetPosition: () -> Void
    private var window: NSWindow?

    init(store: SettingsStore, onResetPosition: @escaping () -> Void) {
        self.store = store
        self.onResetPosition = onResetPosition
        recorder = HotKeyRecorder(store: store)
    }

    /// Brings the window up in front, activating Clawd (an accessory app is otherwise
    /// never active, and the window needs to be key to record a hot key).
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DiagnosticLog.shared.log("settings shown size=\(Int(window.frame.width))x\(Int(window.frame.height)) key=\(window.isKeyWindow)")
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(store: store, recorder: recorder, onResetPosition: onResetPosition)
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clawd 设置"
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

/// The settings form, in the order of spec §8.
struct SettingsView: View {
    @Bindable var store: SettingsStore
    let recorder: HotKeyRecorder
    let onResetPosition: () -> Void

    var body: some View {
        Form {
            Section {
                Slider(value: $store.petScale, in: SettingsStore.scaleRange, step: SettingsStore.scaleStep) {
                    Text("Clawd 大小")
                } minimumValueLabel: {
                    Text("小")
                } maximumValueLabel: {
                    Text("大")
                }
            }

            Section {
                Toggle("提示音", isOn: $store.soundEnabled)
                Group {
                    Toggle("等你确认", isOn: $store.soundOnWaiting)
                    Toggle("做完了", isOn: $store.soundOnDone)
                    Toggle("出错", isOn: $store.soundOnError)
                }
                .disabled(!store.soundEnabled)
                Text("系统音效占位，后续可替换")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
}
