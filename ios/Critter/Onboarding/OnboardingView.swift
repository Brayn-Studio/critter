import CritterClient
import CritterKit
import SwiftUI
import UIKit
import UserNotifications

/// The first-run guide (spec §8.8, visual design §8.2, Android `OnboardingActivity`): the welcome page, pairing, the
/// permission to show notifications, what the Live Activity is, and the Shortcuts automation that brings the board up
/// on the charger. Every step can be skipped and says what that costs; the seeds over each step show "n / 5". Done
/// (the last step's button, or skipping it), the settings remember it (`onboardingDone`) and `onFinish` hands the
/// screen back: the home screen when paired, the pairing screen otherwise.
struct OnboardingView: View {
    let store: BridgeStore
    /// `pair.deviceName`.
    let deviceName: String
    /// A pairing link the app was opened with: the pairing step takes it.
    @Binding var link: IncomingPairLink?
    let onFinish: () -> Void

    @Environment(PhoneSettings.self) private var settings
    @Environment(\.reduceMotion) private var reduceMotion
    @State private var step: OnboardingStep

    init(
        store: BridgeStore, deviceName: String, link: Binding<IncomingPairLink?>, start: OnboardingStep = .welcome,
        onFinish: @escaping () -> Void
    ) {
        self.store = store
        self.deviceName = deviceName
        _link = link
        self.onFinish = onFinish
        _step = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            page(step)
                .id(step)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.15), value: step)
        .background(Theme.bg)
        .onChange(of: link, initial: true) { _, incoming in
            // A link from outside: to the pairing step, whose screen confirms it.
            if incoming != nil, store.pairing == nil, step != .pair { step = .pair }
        }
    }

    @ViewBuilder
    private func page(_ step: OnboardingStep) -> some View {
        let position = OnboardingSteps.position(of: step)
        switch step {
        case .welcome:
            WelcomePage(onStart: next)
        case .pair:
            PairStep(
                store: store, deviceName: deviceName, link: $link, position: position, next: next,
                back: { self.step = .welcome }
            )
        case .notifications:
            NotificationsStep(position: position, next: next)
        case .liveActivity:
            LiveActivityStep(position: position, next: next)
        case .board:
            BoardStep(position: position, finish: next)
        }
    }

    /// The main button or 「跳过」: the next step, or the end of the guide after the last.
    private func next() {
        if let after = OnboardingSteps.next(after: step) {
            step = after
        } else {
            settings.onboardingDone = true
            onFinish()
        }
    }
}

// MARK: - Pairing

/// The pairing screens in the step's frame (Android `PairStep`): the seeds over them, 「跳过」 with what it costs, 「返回」
/// back to the welcome page. A phone paired already when it comes to this step (the guide run again from the settings)
/// sees "已配对" instead, with Sprig done.
private struct PairStep: View {
    let store: BridgeStore
    let deviceName: String
    @Binding var link: IncomingPairLink?
    let position: StepPosition
    let next: () -> Void
    let back: () -> Void

    /// Paired when the step came up, not by pairing on it (that goes on to the next step at once).
    @State private var pairedAlready: Bool

    init(
        store: BridgeStore, deviceName: String, link: Binding<IncomingPairLink?>, position: StepPosition,
        next: @escaping () -> Void, back: @escaping () -> Void
    ) {
        self.store = store
        self.deviceName = deviceName
        _link = link
        self.position = position
        self.next = next
        self.back = back
        _pairedAlready = State(initialValue: store.pairing != nil)
    }

    var body: some View {
        if pairedAlready, let pairing = store.pairing {
            StepPage(
                position: position, title: "已配对", text: "已经和 \(Theme.macName(pairing.macName)) 配对了。",
                primary: "下一步", onPrimary: next
            ) {
                StepStage(state: .done)
            }
        } else {
            PairingView(
                store: store, deviceName: deviceName, link: $link, onClose: back, position: position,
                onSkip: next, skipNote: "之后手机不会连上电脑，要用时在首页配对", onPaired: next
            )
        }
    }
}

// MARK: - Notifications

/// The permission to show notifications (mockup "权限步骤", Android `NotificationsStep`): Mochi waiting with the
/// notification it will bring floating over its meadow. Not asked yet (or only quietly, provisionally): 「允许通知」 asks;
/// refused: 「去打开」 opens the app's notification settings; allowed: done, 「下一步」.
private struct NotificationsStep: View {
    let position: StepPosition
    let next: () -> Void

    @Environment(\.openURL) private var openURL

    private var status: UNAuthorizationStatus {
        #if DEBUG
        if let forced = DebugLaunch.current.onboarding?.notificationStatus { return forced }
        #endif
        return PushSetup.shared.authorization
    }

    var body: some View {
        let status = status
        let done = status == .authorized || status == .ephemeral
        let refused = status == .denied
        StepPage(
            position: position, title: "通知",
            text: "有会话在等你确认时，在锁屏和别的应用上面提醒你。通知上的按钮可以直接允许或拒绝。",
            primary: done ? "下一步" : refused ? "去打开" : "允许通知",
            onPrimary: {
                if done {
                    next()
                } else if refused {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } else {
                    Task { await PushSetup.shared.requestPermission() }
                }
            },
            ghost: "跳过", onGhost: next, note: "跳过后不会收到「等你确认」的提醒，只能打开应用才看得到。", done: done
        ) {
            StepStage(skin: "mochi", state: done ? .done : .waiting, height: 240)
                .overlay(alignment: .top) {
                    SampleNotification()
                        .padding(.horizontal, 30)
                        .padding(.top, 22)
                }
        }
    }
}

/// The notification the user will get, floating over the step's meadow in the system's banner shape: the app's icon,
/// "Critter · 现在" and a request.
private struct SampleNotification: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AppMark(side: 18)
                Text(verbatim: "Critter · 现在")
                    .font(.nunito(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            }
            Text(verbatim: "critter-4c 想运行命令")
                .font(.nunito(size: 12.5, weight: .heavy))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The app's icon, small: Sprig's sprout in white on the brand colour, in the system's rounded square.
private struct AppMark: View {
    let side: CGFloat

    var body: some View {
        PixelIconView(.seedling, cell: max(1, (side / 18).rounded()))
            .foregroundStyle(Color.white)
            .frame(width: side, height: side)
            .background(Color(rgb: 0x6346D6), in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
    }
}

// MARK: - The Live Activity

/// What the Live Activity is (spec §8.5): a drawing of the lock screen with the Dynamic Island and the activity's block,
/// and that it keeps up while the app is closed. On by default: 「下一步」 keeps it, 「关掉实时活动」 switches it off.
/// Off already (the guide run again): 「打开实时活动」 switches it on, 「跳过」 leaves it off. Either way the settings can
/// change it later.
private struct LiveActivityStep: View {
    let position: StepPosition
    let next: () -> Void

    @Environment(PhoneSettings.self) private var settings

    private var on: Bool {
        #if DEBUG
        if DebugLaunch.current.onboarding?.state == "off" { return false }
        #endif
        return settings.liveActivity
    }

    var body: some View {
        let on = on
        StepPage(
            position: position, title: "实时活动",
            text: "锁屏和灵动岛上会显示有几个会话在等你、在运行。App 没开着时，Mac 也会让它跟着更新。",
            primary: on ? "下一步" : "打开实时活动",
            onPrimary: {
                settings.liveActivity = true
                next()
            },
            ghost: on ? "关掉实时活动" : "跳过",
            onGhost: {
                settings.liveActivity = false
                next()
            },
            note: on ? "关掉后锁屏和灵动岛上不显示会话，可以在设置里再打开。" : "跳过后锁屏和灵动岛上不显示会话，可以在设置里打开。"
        ) {
            LockScreenPicture()
        }
    }
}

/// A lock screen as a picture: the night meadow for a wallpaper, the Dynamic Island at the top with the leading
/// Critter and "?2", the clock, and the Live Activity's block at the bottom (a little meadow with Mochi waiting, the
/// counts, "3 个会话"). Not the widget itself: just enough to recognise it.
private struct LockScreenPicture: View {
    @Environment(SkinStore.self) private var skins

    private static let height: CGFloat = 250

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .top) {
                MeadowBackdrop(time: .night, size: size, ground: size.height - 18, moon: CGPoint(x: 0.86, y: 0.3))
                VStack(spacing: 0) {
                    island
                        .padding(.top, 10)
                    Text(verbatim: "9:41")
                        .font(.system(size: 50, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                    block
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(PixelShape(step: 6))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "锁屏和灵动岛上的实时活动：3 个会话，2 个在等你确认"))
    }

    /// The Dynamic Island's compact view: the leading Critter on the left, the waiting count on the right.
    private var island: some View {
        HStack(spacing: 0) {
            CritterPortrait(manifest: skins.previewLibrary.manifest("mochi"), state: .waiting, cell: 1.1, dim: false)
            Spacer(minLength: 0)
            counts(size: 12, color: Theme.wait, count: 2, icon: .q)
        }
        .padding(.horizontal, 12)
        .frame(width: 150, height: 34)
        .background(Color.black, in: Capsule())
    }

    /// The activity's block on the lock screen.
    private var block: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Color(rgb: SkyColors.of(.day).middle)
                    Color(rgb: SkyColors.of(.day).grassHi).frame(height: 2)
                    Color(rgb: SkyColors.of(.day).grass).frame(height: 6)
                }
                CritterPortrait(manifest: skins.previewLibrary.manifest("mochi"), state: .waiting, cell: 2.2, dim: false)
                    .padding(.bottom, 3)
            }
            .frame(width: 56, height: 56)
            .clipShape(PixelShape(step: 3))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    counts(size: 15, color: Theme.waitInk, count: 2, icon: .q)
                    counts(size: 15, color: Theme.run, count: 1, icon: .sun)
                }
                Text(verbatim: "3 个会话")
                    .font(.nunito(size: 12.5, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func counts(size: CGFloat, color: Color, count: Int, icon: PixelIcon) -> some View {
        HStack(spacing: 4) {
            PixelIconView(icon)
            Text(verbatim: "\(count)")
                .font(.silkscreen(size: size))
        }
        .foregroundStyle(color)
    }
}

// MARK: - The board

/// The board opening by itself (spec §8.6): iOS does not let an app come to the front on its own, so a Shortcuts
/// automation "充电器已连接 → 打开 App「Critter」", run at once, opens the app on the charger, and the app turns to the
/// board when the phone lies in landscape. A picture of the automation, the three steps to make it, and 「打开快捷指令」.
/// Back from Shortcuts the button reads 「完成引导」 (whether the automation was made cannot be read back).
private struct BoardStep: View {
    let position: StepPosition
    let finish: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// Shortcuts was opened from here: back in the app, the step is over.
    @State private var opened = false
    @State private var backFromShortcuts = false
    /// Shortcuts would not open (it can be deleted).
    @State private var noShortcuts = false

    private static let shortcuts = URL(string: "shortcuts://")

    var body: some View {
        let back = backFromShortcuts || debugBack
        StepPage(
            position: position, title: "充电时自动打开看板",
            text: "App 没开着时，iOS 不让它自己跳到前面。在「快捷指令」里建一个自动化，插上充电器就打开 Critter，手机一横放就切到看板。",
            primary: back ? "完成引导" : "打开快捷指令",
            onPrimary: { back ? finish() : openShortcuts() },
            ghost: back ? nil : "跳过", onGhost: finish,
            note: back ? nil : "跳过后看板不会自己打开；手机充电横放时，待机模式会显示实时活动。"
        ) {
            VStack(spacing: 8) {
                NumberedStepCard(number: 1, title: "打开「快捷指令」，点「自动化」", detail: "再点右上角的「+」，新建个人自动化。")
                NumberedStepCard(number: 2, title: "选「充电器」", detail: "勾选「已连接」，选「立即运行」，点「下一步」。")
                NumberedStepCard(
                    number: 3, title: "添加操作「打开 App」", detail: "点「新建空白自动化」，搜「打开 App」，App 选「Critter」，点「完成」。"
                )
                if noShortcuts {
                    ErrorNote(text: "打不开「快捷指令」。可以在 App Store 里重新安装它。", pet: false)
                }
            }
            .padding(.top, 4)
        } illustration: {
            StepStage(skin: "peep", state: .idle, height: 176, time: .night, sleeping: true)
                .overlay(alignment: .top) {
                    AutomationPicture()
                        .padding(.horizontal, 30)
                        .padding(.top, 16)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, opened { backFromShortcuts = true }
        }
    }

    private var debugBack: Bool {
        #if DEBUG
        DebugLaunch.current.onboarding?.state == "back"
        #else
        false
        #endif
    }

    private func openShortcuts() {
        guard let url = Self.shortcuts else { return }
        openURL(url) { accepted in
            opened = accepted
            noShortcuts = !accepted
        }
    }
}

/// The automation as Shortcuts lists it: when the charger is connected, open Critter, run at once.
private struct AutomationPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PixelIconView(.battery)
                    .foregroundStyle(Theme.doneGlyph)
                    .frame(width: 22, height: 18)
                Text(verbatim: "充电器已连接")
                    .font(.nunito(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 4)
                Text(verbatim: "立即运行")
                    .font(.nunito(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            }
            PixelIconView(.chevD)
                .foregroundStyle(Theme.ink3)
                .padding(.leading, 4)
            HStack(spacing: 8) {
                AppMark(side: 22)
                Text(verbatim: "打开「Critter」")
                    .font(.nunito(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "自动化：充电器已连接时，打开 Critter，立即运行"))
    }
}
