import CritterClient
import CritterKit
import Observation
import os
import UIKit
@preconcurrency import UserNotifications

/// Where a notification asked the app to go (spec §8.4): a request's answer card (looked up by id, as on the home
/// screen: one that is gone says the computer has it) or a session's details. The home screen takes it once it is up.
@MainActor @Observable
final class NotificationRouter {
    enum Target: Equatable {
        case request(String)
        case session(String)
    }

    static let shared = NotificationRouter()

    var target: Target?
}

/// A delivered notification, read off the system's objects: what the delegate needs of it.
struct NoticeInfo: Sendable {
    /// The system's id for it: the push's `apns-collapse-id` when it had one, otherwise the system's own. A result
    /// shown in its place takes the same one.
    let identifier: String
    /// The push it came from; nil for one that is not Critter's.
    let alert: ParsedPush.Alert?
    /// `categoryIdentifier`: its buttons ("" for a result that dropped them).
    let category: String
    /// What it is about: the request's title as the extension opened it, carried over into a result.
    let about: String
    /// A result shown in a request's place ("已允许", "没送到…").
    let isResult: Bool

    /// The id the Mac's withdrawals and the snapshot rules use (`PushPayload.notificationId`): from the push itself, so
    /// it holds whatever id the system gave the notification (`simctl push` gives none of the collapse id).
    var notificationId: String { alert?.notificationId ?? identifier }

    init(_ request: UNNotificationRequest) {
        let userInfo = request.content.userInfo
        identifier = request.identifier
        if case .alert(let alert)? = PushPayload.parse(userInfo) { self.alert = alert } else { alert = nil }
        category = request.content.categoryIdentifier
        isResult = userInfo[NotificationCenterDelegate.resultKey] != nil
        about = userInfo[NotificationCenterDelegate.aboutKey] as? String ?? request.content.title
    }
}

/// The app's side of its notifications (spec §8.4, §8.7):
/// - the categories and their buttons (`NotificationAnswer.buttons`): every button that answers asks to unlock first;
/// - a tap on a permission request's 「允许」「拒绝」「拒绝并写理由…」 answers it in the background (`BackgroundAnswer`, its
///   own connection, at most 20 s, held up by a background task whose expiry cuts it short) and puts the result in the
///   notification's place, under the same id; one that did not get there keeps its buttons;
/// - a tap on a notification or on 「打开」 brings the app up with the request's card or the session's details
///   (`NotificationRouter`);
/// - in the foreground, a request the screen already shows gets a light tap instead of a banner
///   (`NotificationRules.showBanner`);
/// - withdrawals: the Mac's background pushes (`w`), and once per foreground, after the first live snapshot, whatever
///   the snapshot no longer has (`NotificationRules.staleNotificationIds`).
///
/// It is the notification center's delegate from launch (`AppDelegate`), before the app has finished launching, so a
/// tap that launched the app is not lost.
@MainActor
final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCenterDelegate()

    /// Marks a result notification, and carries what it is about, in its `userInfo`.
    nonisolated static let resultKey = "critterResult"
    nonisolated static let aboutKey = "critterAbout"

    /// Where a background answer goes: the pairing as stored (address, certificate, credentials), the transport and
    /// `hello.app`.
    struct AnswerRoute: Sendable {
        let pairing: @Sendable () -> (StoredPairing, Credentials)?
        let transport: any BridgeTransport
        let app: String
    }

    /// The store whose snapshot says what is on screen; set by the app.
    weak var store: BridgeStore?
    /// Set by the app before it has finished launching; nil until then (an answer then reads as "尚未配对", as it does
    /// when no pairing is stored).
    var answerRoute: AnswerRoute?

    /// Waiting for the first live snapshot of this foreground, to withdraw what it no longer has.
    private var reconcileDue = false

    private let center = UNUserNotificationCenter.current()
    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notifications")

    /// Becomes the notification center's delegate and registers the categories.
    func install() {
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        #if DEBUG
        Task { await logCategories() }
        #endif
    }

    // MARK: - Categories

    /// Every `PushCategory`, with its buttons (spec §8.7): a permission request 「允许」「拒绝」「拒绝并写理由…」 (no
    /// reason for Codex), a question or a plan 「打开」, the rest none.
    static var categories: Set<UNNotificationCategory> {
        Set(PushCategory.allCases.map { category in
            let actions = NotificationAnswer.buttons(for: category).map { button -> UNNotificationAction in
                var options: UNNotificationActionOptions = []
                if button.needsUnlock { options.insert(.authenticationRequired) }
                if button.opensApp { options.insert(.foreground) }
                guard button.takesText else {
                    return UNNotificationAction(identifier: button.action.rawValue, title: button.title, options: options)
                }
                // The answer card's words for the same thing (Android `AnswerSheet`).
                return UNTextInputNotificationAction(
                    identifier: button.action.rawValue, title: button.title, options: options,
                    textInputButtonTitle: "拒绝并发送理由", textInputPlaceholder: "拒绝的理由（可不写）"
                )
            }
            return UNNotificationCategory(identifier: category.rawValue, actions: actions, intentIdentifiers: [])
        })
    }

    // MARK: - The delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await presentation(for: NoticeInfo(notification.request))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let notice = NoticeInfo(response.notification.request)
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await respond(action: response.actionIdentifier, text: text, to: notice)
    }

    /// In the foreground: a request already on screen gets a light tap, anything else a banner with its sound. A
    /// result just put in a request's place shows quietly.
    private func presentation(for notice: NoticeInfo) -> UNNotificationPresentationOptions {
        if notice.isResult { return [.banner, .list] }
        let banner = NotificationRules.showBanner(
            requestId: notice.alert?.requestId, snapshot: store?.snapshot, isForeground: true
        )
        Self.log.notice("in the foreground: \(notice.notificationId, privacy: .public) \(banner ? "banner" : "on screen already: a light tap", privacy: .public)")
        guard banner else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return []
        }
        return [.banner, .list, .sound]
    }

    /// What a tap on a notification or one of its buttons does. Also the way in for `-critterNotificationAction`.
    func respond(action: String, text: String?, to notice: NoticeInfo) async {
        let response = NotificationAnswer.response(action: action, text: text, alert: notice.alert)
        Self.log.notice("\(notice.notificationId, privacy: .public): \(action, privacy: .public) -> \(String(describing: response), privacy: .private)")
        switch response {
        case .answer(let requestId, let payload):
            await answer(payload, requestId: requestId, in: notice)
        case .openRequest(let requestId):
            NotificationRouter.shared.target = .request(requestId)
        case .openSession(let sessionId):
            NotificationRouter.shared.target = .session(sessionId)
        case .openApp, .nothing:
            break
        }
    }

    // MARK: - Answering from a button

    /// Sends the answer over a connection of its own and puts the result in the notification's place. The system's
    /// background time is asked for; if it runs out first, the answer is cut short (as not delivered).
    private func answer(_ payload: AnswerPayload, requestId: String, in notice: NoticeInfo) async {
        let route = answerRoute
        let work = Task { () -> BackgroundAnswerResult in
            guard let route, let (pairing, credentials) = route.pairing() else { return .notPaired("尚未配对") }
            return await BackgroundAnswer.send(
                payload, requestId: requestId, pairing: pairing, credentials: credentials, transport: route.transport,
                app: route.app
            )
        }
        let background = BackgroundTask(name: "Critter: an answer from a notification") {
            Self.log.notice("background time ran out: the answer is cut short")
            work.cancel()
        }
        let result = await work.value
        Self.log.notice("answered \(requestId, privacy: .public) from its notification: \(String(describing: result), privacy: .public)")
        await showResult(result, in: notice)
        background.end()
    }

    /// The result, under the notification's own id: it replaces the request's. Where trying again may help it keeps the
    /// category (the buttons) and the push's keys, so a tap answers again.
    private func showResult(_ result: BackgroundAnswerResult, in notice: NoticeInfo) async {
        let text = result.notificationText(about: notice.about)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        var userInfo: [String: Any] = [Self.resultKey: 1, Self.aboutKey: notice.about]
        if let alert = notice.alert {
            userInfo["c"] = alert.sealed
            userInfo["s"] = alert.sessionId
            userInfo["k"] = alert.category.rawValue
            if let requestId = alert.requestId { userInfo["r"] = requestId }
            content.threadIdentifier = alert.sessionId
        }
        content.userInfo = userInfo
        content.categoryIdentifier = text.keepButtons ? notice.category : ""
        if case .answered = result { content.interruptionLevel = .passive }
        do {
            try await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        } catch {
            Self.log.error("showing the result failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Withdrawals

    /// A background push (`application(_:didReceiveRemoteNotification:)`): the Mac's withdrawal (`w`). Nothing else
    /// comes this way.
    func backgroundPush(_ userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard case .withdraw(let ids)? = PushPayload.parse(userInfo) else { return .noData }
        Self.log.notice("withdrawal push: \(ids.joined(separator: ", "), privacy: .public)")
        await withdraw(ids)
        return .newData
    }

    /// The Mac's withdrawal (a background push's `w`): the delivered notifications with these ids go.
    func withdraw(_ ids: [String]) async {
        let wanted = Set(ids)
        remove(await delivered().filter { wanted.contains($0.notificationId) })
    }

    /// The app came to the foreground: once its first live snapshot is in, what the snapshot no longer has goes.
    func sceneBecameActive() {
        reconcileDue = true
        if store?.isLive == true { Task { await reconcileIfDue() } }
    }

    /// A live snapshot came (or went).
    func liveChanged() {
        Task { await reconcileIfDue() }
    }

    private func reconcileIfDue() async {
        guard reconcileDue, let store, store.isLive, let snapshot = store.snapshot else { return }
        reconcileDue = false
        let notices = await delivered()
        let stale = Set(NotificationRules.staleNotificationIds(
            delivered: notices.map {
                DeliveredNotification(id: $0.notificationId, category: $0.category.isEmpty ? nil : $0.category)
            },
            snapshot: snapshot
        ))
        Self.log.notice("foreground: \(notices.count) delivered, \(stale.count) no longer in the snapshot")
        remove(notices.filter { stale.contains($0.notificationId) })
    }

    private func delivered() async -> [NoticeInfo] {
        await center.deliveredNotifications().map { NoticeInfo($0.request) }
    }

    /// Takes these delivered notifications down (by the system's ids: several may share one of ours).
    private func remove(_ gone: [NoticeInfo]) {
        guard !gone.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: gone.map(\.identifier))
        Self.log.notice("withdrew \(gone.map(\.notificationId).joined(separator: ", "), privacy: .public)")
    }

    #if DEBUG
    /// The categories as the system has them, with their buttons and the buttons' options (the command line cannot
    /// pull a notification down to see them).
    private func logCategories() async {
        let categories = await center.notificationCategories().sorted { $0.identifier < $1.identifier }
        let lines = categories.map { category in
            let actions = category.actions.map { action in
                var options: [String] = []
                if action.options.contains(.authenticationRequired) { options.append("unlock") }
                if action.options.contains(.foreground) { options.append("foreground") }
                if action.options.contains(.destructive) { options.append("destructive") }
                let input = (action as? UNTextInputNotificationAction).map {
                    " text field [\($0.textInputPlaceholder)] send [\($0.textInputButtonTitle)]"
                } ?? ""
                return "「\(action.title)」 \(action.identifier) (\(options.joined(separator: ", ")))\(input)"
            }
            return "\(category.identifier): " + (actions.isEmpty ? "no buttons" : actions.joined(separator: "; "))
        }
        Self.log.notice("categories:\n  \(lines.joined(separator: "\n  "), privacy: .public)")
    }

    /// The delivered notifications, as the log lists them (`-critterNotificationAction`'s checks).
    func logDelivered(_ when: String) async {
        let notices = await center.deliveredNotifications().map(\.request)
        let lines = notices.map { request in
            "\(NoticeInfo(request).notificationId) [\(request.content.categoryIdentifier)] \(request.content.title) / \(request.content.body)"
        }
        Self.log.notice("delivered \(when): \(lines.count)\(lines.isEmpty ? "" : "\n  " + lines.joined(separator: "\n  "), privacy: .public)")
    }

    /// The notification with this id (`PushPayload.notificationId`) as delivered, if it is.
    func delivered(_ notificationId: String) async -> NoticeInfo? {
        await delivered().first { $0.notificationId == notificationId }
    }
    #endif
}

// MARK: - The app delegate's part

extension AppDelegate {
    func application(
        _ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Before the app has finished launching: a tap on a notification that launched it comes to the delegate.
        NotificationCenterDelegate.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushSetup.shared.tokenArrived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushSetup.shared.tokenFailed(error)
    }

    /// A background push: the Mac's withdrawal of notifications (`w`).
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await NotificationCenterDelegate.shared.backgroundPush(userInfo)
    }
}
