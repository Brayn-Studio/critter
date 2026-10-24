#if DEBUG
import ActivityKit
import CritterKit
import os
import SwiftUI
import UIKit

/// `-critterActivityDemo <many|waiting|idle|stale>` (see `DebugLaunch`): the Live Activity with made-up content, for
/// screenshots, without a Mac. Once launched (in front) the app ends any `CritterActivity`, starts one showing `kind`'s
/// content (no push token: nothing is registered for it), and shows, instead of the home screen, the lock screen's
/// block drawn by the widget's own views (`CritterActivityViews.swift`, compiled into the app too) in the current theme,
/// in StandBy's look and stale: the simulator's lock screen cannot be reached from the command line. Once the app is in
/// the background (`xcrun simctl launch <device> com.apple.Preferences`), the Dynamic Island shows the compact view;
/// three seconds later the app updates the activity once with an alert, so the island opens to the expanded view for a
/// few seconds (the app keeps running that long with a background task). `stale` sets the stale date three seconds
/// after the start and sends no alert (the system shows none for a stale update): the system marks the activity stale
/// no sooner than about two minutes after the start (it holds a stale date that close off that long), and then it
/// turns grey with "可能不是最新的".
///
/// It also decodes the protocol doc's Live Activity pushes as the system would: `attributes` of the push-to-start as
/// `CritterActivity`, and each `content-state` as its `ContentState`, the `end`'s empty one included. The log (subsystem
/// `com.braynlabs.critter`, category `activity`) says what came of each step.
enum ActivityDemo {
    enum Kind: String, CaseIterable {
        case many, waiting, idle, stale
    }

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "activity")

    /// What `kind` shows, as of `now`.
    static func content(_ kind: Kind, now: Date) -> LiveActivityContent {
        func ago(_ seconds: Double) -> Int64 { Int64((now.timeIntervalSince1970 - seconds) * 1000) }
        switch kind {
        case .many, .stale:
            return LiveActivityContent(
                counts: [
                    StateCount(state: .waiting, count: 1), StateCount(state: .error, count: 1),
                    StateCount(state: .done, count: 1), StateCount(state: .running, count: 2),
                    StateCount(state: .idle, count: 1),
                ],
                lead: PetBadge(skin: "sprig", state: .waiting),
                back: [PetBadge(skin: "peep", state: .error), PetBadge(skin: "mochi", state: .done)],
                total: 6, fiveHour: 42, sevenDay: 63, updatedAt: ago(kind == .stale ? 20 * 60 : 3 * 60)
            )
        case .waiting:
            return LiveActivityContent(
                counts: [StateCount(state: .waiting, count: 2)],
                lead: PetBadge(skin: "bristle", state: .waiting), back: [PetBadge(skin: "sprig", state: .waiting)],
                total: 2, fiveHour: 88, sevenDay: 71, updatedAt: ago(30)
            )
        case .idle:
            return LiveActivityContent(
                counts: [StateCount(state: .idle, count: 3)],
                lead: PetBadge(skin: "mochi", state: .idle),
                back: [PetBadge(skin: "sprig", state: .idle), PetBadge(skin: "peep", state: .idle)],
                total: 3, fiveHour: 8, sevenDay: nil, updatedAt: ago(10 * 60)
            )
        }
    }

    @MainActor
    static func run(_ kind: Kind) async {
        decodeCheck()
        for activity in Activity<CritterActivity>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
            say("ended \(activity.id)")
        }
        let now = Date()
        let state = content(kind, now: now)
        let stale = now.addingTimeInterval(kind == .stale ? 3 : 15 * 60)
        let activity: Activity<CritterActivity>
        do {
            activity = try Activity.request(attributes: CritterActivity(), content: .init(state: state, staleDate: stale))
            say("started \(activity.id) showing \(kind.rawValue): \(state.total) sessions, lead \(state.lead?.skin ?? "none")")
        } catch {
            say("starting failed: \(error)")
            return
        }
        // The expanded view: an update with an alert while another app is in front. Not for a stale one.
        guard kind != .stale else { return }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
            break
        }
        let task = UIApplication.shared.beginBackgroundTask(withName: "activity demo")
        say("in the background: the alert update in 3 s")
        try? await Task.sleep(for: .seconds(3))
        var again = state
        again.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        await activity.update(
            .init(state: again, staleDate: Date().addingTimeInterval(15 * 60)),
            alertConfiguration: AlertConfiguration(title: "Critter", body: "有会话需要你", sound: .default)
        )
        say("alert update sent, state \(activity.activityState)")
        try? await Task.sleep(for: .seconds(8))
        UIApplication.shared.endBackgroundTask(task)
    }

    /// The protocol doc's pushes (`docs/critter-bridge-protocol.md`, "How the Mac pushes"), decoded as the system
    /// decodes them for this app.
    private static func decodeCheck() {
        let start = #"{"aps":{"alert":{"body":"有会话需要你","title":"Critter"},"attributes":{},"attributes-type":"CritterActivity","content-state":{"back":[{"skin":"mochi","state":"running"}],"counts":[{"count":2,"state":"waiting"},{"count":1,"state":"running"}],"fiveHour":12,"lead":{"skin":"sprig","state":"waiting"},"sevenDay":30,"total":3,"updatedAt":1760000000000},"event":"start","stale-date":1760000900,"timestamp":1760000000}}"#
        let end = #"{"aps":{"content-state":{"back":[],"counts":[],"total":0,"updatedAt":1760000000000},"dismissal-date":1760000000,"event":"end","timestamp":1760000000}}"#
        func aps(_ text: String) -> [String: Any] {
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["aps"] as? [String: Any] ?? [:]
        }
        func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> Result<T, any Error> {
            Result {
                let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: .fragmentsAllowed)
                return try JSONDecoder().decode(T.self, from: data)
            }
        }
        let started = aps(start)
        say("decode check: attributes-type \(started["attributes-type"] as? String ?? "nil") (CritterActivity's name \(String(describing: CritterActivity.self)))")
        switch decode(CritterActivity.self, started["attributes"]) {
        case .success: say("decode check: attributes {} -> CritterActivity ok")
        case .failure(let error): say("decode check: attributes FAILED: \(error)")
        }
        switch decode(CritterActivity.ContentState.self, started["content-state"]) {
        case .success(let state):
            say("decode check: start content-state ok: total \(state.total), lead \(state.lead?.skin ?? "nil") \(state.lead?.state.rawValue ?? ""), counts \(state.counts.map { "\($0.state.rawValue) \($0.count)" })")
        case .failure(let error): say("decode check: start content-state FAILED: \(error)")
        }
        switch decode(CritterActivity.ContentState.self, aps(end)["content-state"]) {
        case .success(let state):
            say("decode check: end content-state ok: total \(state.total), lead \(state.lead.map { $0.skin } ?? "nil"), counts \(state.counts.count)")
        case .failure(let error): say("decode check: end content-state FAILED: \(error)")
        }
    }

    private static func say(_ line: String) {
        log.notice("demo: \(line, privacy: .public)")
        print("activity demo: \(line)")
    }
}

/// The page the app shows during `-critterActivityDemo`: the lock screen's block as the widget draws it, in the current
/// theme, in StandBy's look (black, the board's colours) and stale, each at the lock screen's width on a plain
/// wallpaper.
struct ActivityDemoPage: View {
    let kind: ActivityDemo.Kind

    @Environment(\.colorScheme) private var colorScheme
    private let now = Date()

    var body: some View {
        let state = ActivityDemo.content(kind, now: now)
        let theme: ActivityLook = colorScheme == .dark ? .dark : .light
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(verbatim: "实时活动 · \(kind.rawValue)")
                    .font(.nunito(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                caption("锁屏（\(colorScheme == .dark ? "深色" : "浅色")）")
                card(ActivityLockView(state: state, stale: kind == .stale, look: theme), look: theme)
                caption("待机模式")
                card(ActivityLockView(state: state, stale: kind == .stale, look: .standBy), look: .standBy)
                caption("待机模式 · 夜里调暗")
                card(ActivityLockView(state: state, stale: kind == .stale, look: .standBy, dimmed: true), look: .standBy)
                caption("过期（超过 staleDate）")
                card(ActivityLockView(state: state, stale: true, look: theme), look: theme)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(LinearGradient(
            colors: colorScheme == .dark ? [Color(rgb: 0x1E2A44), Color(rgb: 0x3A2648)] : [Color(rgb: 0x9FC5E8), Color(rgb: 0xE3C7E8)],
            startPoint: .top, endPoint: .bottom
        ).ignoresSafeArea())
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.nunito(size: 12, weight: .heavy))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.8) : Theme.ink2)
    }

    private func card(_ content: ActivityLockView, look: ActivityLook) -> some View {
        content
            .frame(width: 370)
            .background(look.background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
