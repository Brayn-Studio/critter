import CritterKit
import Foundation
import os

/// What came of an answer sent from a notification's button.
public enum BackgroundAnswerResult: Equatable, Sendable {
    /// The Mac took it (`decision` is the answer's: "allow" or "deny").
    case answered(decision: String?)
    /// The request was already handled: on the computer, or by another phone or tap.
    case resolved
    /// Too late: the hook no longer waits for it.
    case expired
    /// The Mac refused it for another reason, with its words if it had any; `canRetry` when trying again may help.
    case refused(message: String?, canRetry: Bool)
    /// The Mac no longer knows this phone (`denied`): pairing again is the way.
    case notPaired(String)
    /// Not delivered: no connection, no `welcome`, no `result`, or not within 20 seconds.
    case unreachable

    /// The notification shown in the request's place, under the same id (spec §8.7).
    public var notificationText: NotificationResultText {
        switch self {
        case .answered(let decision):
            NotificationResultText(title: decision == "allow" ? "已允许" : "已拒绝", body: "", keepButtons: false)
        case .resolved:
            NotificationResultText(title: "已在电脑上处理", body: "", keepButtons: false)
        case .expired:
            NotificationResultText(title: "已经过期了", body: "", keepButtons: false)
        case .refused(let message, let canRetry):
            NotificationResultText(title: message ?? "没有发送出去", body: "", keepButtons: canRetry)
        case .notPaired(let text):
            NotificationResultText(title: text, body: "", keepButtons: false)
        case .unreachable:
            NotificationResultText(title: "没送到：连不上 Mac（要和电脑在同一个 Wi‑Fi）", body: "", keepButtons: true)
        }
    }
}

/// A result notification's text (Android `Alerts.showHandled`: the title says it all). `keepButtons`: the original
/// buttons stay (its category is kept), so the answer can be tried again.
public struct NotificationResultText: Equatable, Sendable {
    public var title: String
    public var body: String
    public var keepButtons: Bool

    public init(title: String, body: String, keepButtons: Bool) {
        self.title = title
        self.body = body
        self.keepButtons = keepButtons
    }
}

/// Sends an answer from a notification's button while the app is in the background (spec §8.3, §8.7): a connection of
/// its own to the paired Mac, pinned to its certificate, `hello`, then -- only once the Mac has said `welcome` --
/// `answer`, and its `result`. The whole of it within `timeLimit`, and the connection is closed at the end, whatever
/// the end. It shares nothing with the foreground `BridgeClient`: it goes this way also while that one is connected.
public enum BackgroundAnswer {
    /// Connecting, `hello`, `answer` and `result` together.
    public static let timeLimit: Duration = .seconds(20)

    /// - Parameters:
    ///   - pairing, credentials: where the Mac was last reached, its certificate, and what to say `hello` with.
    ///   - app: `hello.app`.
    ///   - clock: waits out `timeLimit`; must throw when its task is cancelled, as `Task.sleep` does.
    public static func send(
        _ payload: AnswerPayload, requestId: String, pairing: StoredPairing, credentials: Credentials,
        transport: any BridgeTransport, app: String,
        clock: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> BackgroundAnswerResult {
        let run = Run()
        return await withCheckedContinuation { continuation in
            run.begin(continuation)
            let work = Task {
                let result = await exchange(
                    payload, requestId: requestId, pairing: pairing, credentials: credentials, transport: transport,
                    app: app, run: run
                )
                run.finish(result)
            }
            let deadline = Task {
                guard (try? await clock(timeLimit)) != nil else { return }
                run.finish(.unreachable)
            }
            run.onFinish {
                work.cancel()
                deadline.cancel()
            }
        }
    }

    private static func exchange(
        _ payload: AnswerPayload, requestId: String, pairing: StoredPairing, credentials: Credentials,
        transport: any BridgeTransport, app: String, run: Run
    ) async -> BackgroundAnswerResult {
        let socket: any BridgeSocket
        do {
            socket = try await transport.connect(host: pairing.endpoint.host, port: pairing.endpoint.port, fingerprint: pairing.fingerprint)
        } catch {
            return .unreachable
        }
        // Over already (the 20 s passed while connecting): closed without a word.
        guard run.adopt(socket) else { return .unreachable }
        let hello = ClientMessage.hello(
            protocolVersion: BridgeProtocol.version, deviceId: credentials.deviceId, token: credentials.token, app: app
        )
        let id = "n1"
        do {
            try await socket.send(BridgeClient.text(hello))
            var welcomed = false
            while true {
                guard let message = ServerMessage.decode(Data(try await socket.receive().utf8)) else { continue }
                switch message {
                case .welcome:
                    // Nothing but `hello` before it (protocol doc, "Connection flow").
                    guard !welcomed else { continue }
                    welcomed = true
                    try await socket.send(BridgeClient.text(.answer(id: id, requestId: requestId, payload: payload)))
                case .denied(let reason):
                    return .notPaired(BridgeClient.deniedText(reason))
                case .result(id, let ok, let reason, let message) where welcomed:
                    return result(ok: ok, reason: reason, message: message, payload: payload)
                case .snapshot, .result, .skin, .paired:
                    continue
                }
            }
        } catch {
            // The connection ended (or was closed at 20 s) before the result: it may or may not have got there.
            return .unreachable
        }
    }

    private static func result(ok: Bool, reason: ResultReason?, message: String?, payload: AnswerPayload) -> BackgroundAnswerResult {
        guard !ok else { return .answered(decision: payload.decision) }
        switch reason {
        case .resolved: return .resolved
        case .expired: return .expired
        // The answer is not acceptable: it would be again. The notification still opens the card.
        case .invalid: return .refused(message: message, canRetry: false)
        case .unavailable, .failed, nil: return .refused(message: message, canRetry: true)
        }
    }

    /// One `send`: its continuation is resumed once, by the first to finish -- the exchange or the deadline -- and
    /// that closes the socket (now, or as soon as it is made) and stops the other.
    private final class Run: Sendable {
        private struct State {
            var continuation: CheckedContinuation<BackgroundAnswerResult, Never>?
            var result: BackgroundAnswerResult?
            var socket: (any BridgeSocket)?
            var stop: (@Sendable () -> Void)?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func begin(_ continuation: CheckedContinuation<BackgroundAnswerResult, Never>) {
            state.withLock { $0.continuation = continuation }
        }

        /// What stops the exchange and the deadline; run at once if it is over already.
        func onFinish(_ stop: @escaping @Sendable () -> Void) {
            let over = state.withLock { s in
                if s.result == nil { s.stop = stop }
                return s.result != nil
            }
            if over { stop() }
        }

        /// The connection is made. False if it is over already: the socket is closed.
        func adopt(_ socket: any BridgeSocket) -> Bool {
            let open = state.withLock { s in
                if s.result == nil { s.socket = socket }
                return s.result == nil
            }
            if !open { socket.close() }
            return open
        }

        func finish(_ result: BackgroundAnswerResult) {
            let ending = state.withLock { s -> (CheckedContinuation<BackgroundAnswerResult, Never>?, (any BridgeSocket)?, (@Sendable () -> Void)?)? in
                guard s.result == nil else { return nil }
                s.result = result
                defer { s.continuation = nil; s.socket = nil; s.stop = nil }
                return (s.continuation, s.socket, s.stop)
            }
            guard let (continuation, socket, stop) = ending else { return }
            socket?.close()
            stop?()
            continuation?.resume(returning: result)
        }
    }
}
