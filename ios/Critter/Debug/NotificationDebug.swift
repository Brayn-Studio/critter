#if DEBUG
import CritterClient
import CritterKit
import Foundation
import os
@preconcurrency import UserNotifications

/// `-critterNotificationAction <id>:<allow|deny|open|reason:<text>>[@<seconds>]`: the command line cannot tap a
/// notification or its buttons, so this goes through the same handler as a tap would
/// (`NotificationCenterDelegate.respond`), that many seconds after launch (default 1.5). `<id>` is a notification's id
/// (`PushPayload.notificationId`): a request id, or `done:<session id>` and the like. The delivered notification with
/// that id is the one answered (as `xcrun simctl push` left it); without one, a notification is made up from the
/// snapshot (a request's category by its kind). The log lists the delivered notifications before and after
/// (category `notifications`).
enum NotificationActionDebug {
    struct Step: Equatable {
        enum Action: Equatable {
            case allow, deny, open
            case reason(String)
        }

        var notificationId: String
        var action: Action
        var at: Double

        /// `<id>:<action>[@<seconds>]`; the id may hold ":" itself (`done:s1`).
        init?(_ argument: String) {
            var spec = argument
            at = 1.5
            if let range = spec.range(of: #"@\d+(\.\d+)?$"#, options: .regularExpression),
               let seconds = Double(spec[range].dropFirst()) {
                at = seconds
                spec.removeSubrange(range)
            }
            if let range = spec.range(of: ":reason:") {
                notificationId = String(spec[..<range.lowerBound])
                action = .reason(String(spec[range.upperBound...]))
            } else {
                guard let colon = spec.lastIndex(of: ":") else { return nil }
                notificationId = String(spec[..<colon])
                switch spec[spec.index(after: colon)...] {
                case "allow": action = .allow
                case "deny": action = .deny
                case "open": action = .open
                default: return nil
                }
            }
            if notificationId.isEmpty { return nil }
        }
    }

    private static let log = Logger(subsystem: "com.braynlabs.critter", category: "notifications")

    @MainActor
    static func run(_ step: Step, store: BridgeStore) async {
        let launch = DebugLaunch.current
        let wait = step.at - (ProcessInfo.processInfo.systemUptime - launch.launchUptime)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        let delegate = NotificationCenterDelegate.shared
        await delegate.logDelivered("before -critterNotificationAction")
        let notice: NoticeInfo
        if let delivered = await delegate.delivered(step.notificationId) {
            notice = delivered
        } else {
            log.notice("-critterNotificationAction: \(step.notificationId, privacy: .public) is not delivered; made up from the snapshot")
            notice = NoticeInfo(madeUp(step.notificationId, snapshot: store.snapshot))
        }
        let (action, text): (String, String?) = switch step.action {
        case .allow: (NotificationAction.allow.rawValue, nil)
        case .deny: (NotificationAction.deny.rawValue, nil)
        case .reason(let reason): (NotificationAction.denyWithReason.rawValue, reason)
        case .open: (NotificationAnswer.tapAction, nil)
        }
        await delegate.respond(action: action, text: text, to: notice)
        await delegate.logDelivered("after -critterNotificationAction")
    }

    /// A notification as the Mac would have pushed it for `id`, as delivered (the text not opened).
    private static func madeUp(_ id: String, snapshot: SnapshotBody?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = PushPayload.title
        content.body = PushPayload.body
        var category = PushCategory.permission
        var requestId: String? = id
        var sessionId = ""
        if let prefix = [PushCategory.done, .error, .waitingElsewhere, .test].first(where: { id.hasPrefix($0.rawValue + ":") }) {
            category = prefix
            requestId = nil
            sessionId = String(id.dropFirst(prefix.rawValue.count + 1))
        } else if let request = snapshot?.pending.first(where: { $0.requestId == id }) {
            sessionId = request.sessionId
            switch request.kind {
            case .permission: category = NotificationText.acceptsDenyMessage(request.input) ? .permission : .permissionNoReason
            case .question: category = .question
            case .plan: category = .plan
            }
            content.title = NotificationText.title(request, session: snapshot?.sessions.first { $0.id == request.sessionId })
        }
        var userInfo: [String: Any] = ["c": "", "s": sessionId, "k": category.rawValue]
        if let requestId { userInfo["r"] = requestId }
        content.userInfo = userInfo
        content.categoryIdentifier = category.rawValue
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }
}

/// `-critterWithdrawPush <id>[,<id>…][@<seconds>]`: that long after launch (default 3 s), the Mac's withdrawal push
/// (`PushPayload.withdraw`) goes through the app's handler for background pushes, as `didReceiveRemoteNotification`
/// would hand it over (`xcrun simctl push` turns a background push into a background fetch, without the payload). The
/// log lists the delivered notifications before and after.
enum WithdrawPushDebug {
    struct Step: Equatable {
        var ids: [String]
        var at: Double

        init?(_ argument: String) {
            var spec = argument
            at = 3
            if let range = spec.range(of: #"@\d+(\.\d+)?$"#, options: .regularExpression),
               let seconds = Double(spec[range].dropFirst()) {
                at = seconds
                spec.removeSubrange(range)
            }
            ids = spec.split(separator: ",").map(String.init)
            if ids.isEmpty { return nil }
        }
    }

    @MainActor
    static func run(_ step: Step) async {
        let wait = step.at - (ProcessInfo.processInfo.systemUptime - DebugLaunch.current.launchUptime)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        let delegate = NotificationCenterDelegate.shared
        await delegate.logDelivered("before -critterWithdrawPush")
        _ = await delegate.backgroundPush(PushPayload.withdraw(ids: step.ids))
        await delegate.logDelivered("after -critterWithdrawPush")
    }
}

/// The fixture Mac as the background answers reach it (`-critterFixture`): a connection of their own, as on a phone.
/// It says `welcome` to `hello` and answers an `answer` with `-critterFixtureResult` (a taken answer leaves the
/// snapshot the app shows, as on the Mac). `-critterFixtureMacAway`: no connection can be made, as when the phone is
/// not on the Mac's network. `-critterFixtureMacSilent`: the connection is made and nothing ever comes back.
struct FixtureTransport: BridgeTransport {
    let result: CommandResult
    let away: Bool
    let silent: Bool

    func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket {
        try await Task.sleep(for: .milliseconds(300))
        if away { throw TransportError.unreachable }
        return FixtureSocket(result: result, silent: silent)
    }
}

private final class FixtureSocket: BridgeSocket, @unchecked Sendable {
    private let result: CommandResult
    private let silent: Bool
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiting: CheckedContinuation<String, any Error>?
    private var closed = false

    init(result: CommandResult, silent: Bool) {
        self.result = result
        self.silent = silent
    }

    var peerFingerprint: String? { String(repeating: "0", count: 64) }

    func send(_ text: String) async throws {
        if silent { return }
        switch ClientMessage.decode(Data(text.utf8)) {
        case .hello?:
            deliver(.welcome(macName: DebugLaunch.fixtureMacName, version: "fixture"))
        case .answer(let id, let requestId, _)?:
            try await Task.sleep(for: .milliseconds(200))
            if result.ok, let link = await MainActor.run(body: { FixtureLink.current }) {
                await link.answeredElsewhere(requestId)
            }
            deliver(.result(id: id, ok: result.ok, reason: result.reason, message: result.message))
        default:
            break
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if closed { return continuation.resume(throwing: TransportError.closed(cleanly: true)) }
            if !inbox.isEmpty { return continuation.resume(returning: inbox.removeFirst()) }
            waiting = continuation
        }
    }

    func sendPing() async throws {}

    func close() {
        lock.lock()
        closed = true
        let waiter = waiting
        waiting = nil
        lock.unlock()
        waiter?.resume(throwing: TransportError.closed(cleanly: true))
    }

    private func deliver(_ message: ServerMessage) {
        let text = String(decoding: message.encode(), as: UTF8.self)
        lock.lock()
        if let waiter = waiting {
            waiting = nil
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            inbox.append(text)
            lock.unlock()
        }
    }
}
#endif
