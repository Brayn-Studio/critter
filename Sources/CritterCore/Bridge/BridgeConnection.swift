import Foundation

public enum SayOutcome: Equatable, Sendable { case sent, unavailable, failed, unconfirmed }

/// What became of an answer handed to `BridgeServices.submitAnswer`. `alreadyAnswered`: the
/// request had an answer already (another phone was first), so this one was dropped.
public enum AnswerOutcome: Equatable, Sendable { case accepted, alreadyAnswered, failed }

/// What became of a push registration handed to `BridgeServices.registerPush`.
public enum PushRegistrationOutcome: Equatable, Sendable {
    /// Kept (or, for an empty token, cleared). `pushReady`: this Mac can push to it now -- its APNs setup works,
    /// APNs has not refused it, and it is for the app the setup names (spec 8.8).
    case stored(pushReady: Bool)
    /// It could not be kept (the devices file could not be written).
    case failed
}

/// What a bridge connection needs from the app. `BridgeController` implements it.
public protocol BridgeServices: AnyObject {
    var macName: String { get }
    var version: String { get }
    func verify(deviceId: String, token: String) -> DeviceRecord?
    func consumePairingCode(_ code: String) -> Bool
    func pendingRequest(_ requestId: String) -> PendingRequest?
    /// For validation: the request's original tool input, with the full question text.
    func originalToolInput(_ requestId: String) -> [String: Any]?
    /// Writes the answer file, unless the request already has one.
    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> AnswerOutcome
    func markSeen(sessionId: String)
    func say(text: String, sessionId: String) -> SayOutcome
    func interrupt(sessionId: String) -> SayOutcome
    func skinManifest(name: String) -> JSONValue?
    func snapshotMessage() -> ServerMessage
    /// Keeps the device's push registration (an empty one takes it back), and says whether the Mac can push to it.
    func registerPush(deviceId: String, _ registration: PushRegistration) -> PushRegistrationOutcome
}

public extension BridgeServices {
    func interrupt(sessionId: String) -> SayOutcome { .unavailable }
}

/// The protocol state machine of one phone connection. Pure: it turns frames into outputs
/// and leaves all I/O to `BridgeServer`.
public final class BridgeConnection {
    public enum Phase: Equatable {
        case awaitingFirst
        case awaitingApproval(deviceName: String)
        case ready(deviceId: String)
        case closed
    }

    public enum Output: Equatable {
        case send(ServerMessage)
        case close
    }

    public private(set) var phase: Phase = .awaitingFirst
    private let services: BridgeServices
    /// Epoch milliseconds, for telling whether a request has expired.
    private let now: () -> Int64

    public init(services: BridgeServices, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.services = services
        self.now = now
    }

    public func receive(_ frame: Data) -> [Output] {
        if frame.count > BridgeProtocol.maxFrameBytes { return closeNow([]) }
        switch phase {
        case .closed, .awaitingApproval:
            return []
        case .awaitingFirst:
            return receiveFirst(frame)
        case .ready(let deviceId):
            guard let message = ClientMessage.decode(frame) else { return [] }
            return handle(message, deviceId: deviceId)
        }
    }

    /// The user approved the pending pairing on the Mac.
    public func approvePairing(deviceId: String, token: String) -> [Output] {
        guard case .awaitingApproval = phase else { return [] }
        phase = .ready(deviceId: deviceId)
        return [
            .send(.paired(deviceId: deviceId, token: token, macName: services.macName)),
            .send(.welcome(macName: services.macName, version: services.version)),
            .send(services.snapshotMessage()),
        ]
    }

    public func rejectPairing() -> [Output] {
        guard case .awaitingApproval = phase else { return [] }
        return closeNow([.send(.denied(reason: .rejected))])
    }

    public func broadcast(_ snapshot: ServerMessage) -> [Output] {
        guard case .ready = phase else { return [] }
        return [.send(snapshot)]
    }

    private func closeNow(_ before: [Output]) -> [Output] {
        phase = .closed
        return before + [.close]
    }

    private func deny(_ reason: DenyReason) -> [Output] {
        closeNow([.send(.denied(reason: reason))])
    }

    private func receiveFirst(_ frame: Data) -> [Output] {
        switch ClientMessage.decode(frame) {
        case .hello(let version, let deviceId, let token, _):
            guard version == BridgeProtocol.version else { return deny(.protocolMismatch) }
            guard services.verify(deviceId: deviceId, token: token) != nil else { return deny(.badToken) }
            phase = .ready(deviceId: deviceId)
            return [
                .send(.welcome(macName: services.macName, version: services.version)),
                .send(services.snapshotMessage()),
            ]
        case .pair(let code, let deviceName):
            guard services.consumePairingCode(code) else { return deny(.badCode) }
            phase = .awaitingApproval(deviceName: deviceName)
            return []
        default:
            return deny(.protocolMismatch)
        }
    }

    /// The `message` of the `ok` reply to a stored push registration: whether this Mac can push to it now.
    static func storedPushMessage(pushReady: Bool) -> String {
        pushReady ? "已登记" : "已登记；这台 Mac 还没配置推送"
    }

    private func result(_ id: String?, _ reason: ResultReason?, _ message: String? = nil) -> [Output] {
        [.send(.result(id: id, ok: reason == nil, reason: reason, message: message))]
    }

    private func handle(_ message: ClientMessage, deviceId: String) -> [Output] {
        switch message {
        case .answer(let id, let requestId, let payload):
            guard let request = services.pendingRequest(requestId) else {
                return result(id, .resolved, "已在电脑上处理")
            }
            // From `expiresAt` on the hook has stopped waiting (it gives up then), so an answer
            // would go nowhere; the request is about to be swept.
            guard now() < request.expiresAt else {
                return result(id, .expired, "这个请求已经过期了")
            }
            let input = services.originalToolInput(requestId) ?? [:]
            guard AskDecision.validate(payload, kind: request.kind, toolInput: input) else {
                return result(id, .invalid, "答案无效")
            }
            switch services.submitAnswer(payload, requestId: requestId) {
            case .accepted: return result(id, nil)
            case .alreadyAnswered: return result(id, .resolved, "已经有人回答过了")
            case .failed: return result(id, .failed, "提交失败")
            }
        case .seen(let id, let sessionId):
            services.markSeen(sessionId: sessionId)
            return result(id, nil)
        case .say(let id, let sessionId, let text):
            // Counted in UTF-16 code units, as phones count it (Kotlin's `String.length`).
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf16.count <= BridgeProtocol.maxSayUTF16Units else {
                return result(id, .invalid, "文字为空或太长")
            }
            switch services.say(text: text, sessionId: sessionId) {
            case .sent: return result(id, nil)
            case .unavailable: return result(id, .unavailable, "该会话现在无法接收文字")
            case .failed: return result(id, .failed, "发送失败")
            case .unconfirmed: return result(id, .failed, "电脑端尚未确认结果，请先查看会话，避免重复发送")
            }
        case .skin(let id, let name):
            return [.send(.skin(id: id, name: name, manifest: services.skinManifest(name: name)))]
        case .interrupt(let id, let sessionId):
            switch services.interrupt(sessionId: sessionId) {
            case .sent: return result(id, nil)
            case .unavailable: return result(id, .unavailable, "该会话当前无法从手机停止")
            case .failed: return result(id, .failed, "停止失败，请检查电脑端状态")
            case .unconfirmed: return result(id, .failed, "电脑端尚未确认停止结果，请先查看会话")
            }
        case .push(let id, let registration):
            // An empty token is an unregistration, whatever else it holds.
            guard registration.token.isEmpty || (registration.hasValidKey && registration.hasValidTokens) else {
                return result(id, .invalid, "推送登记无效")
            }
            switch services.registerPush(deviceId: deviceId, registration) {
            case .stored(let pushReady):
                // The phone's settings show it (spec 8.8). Taken back, there is nothing to say about pushing.
                return result(id, nil, registration.token.isEmpty ? nil : Self.storedPushMessage(pushReady: pushReady))
            case .failed:
                return result(id, .failed, "保存失败")
            }
        case .hello, .pair:
            return []
        }
    }
}
