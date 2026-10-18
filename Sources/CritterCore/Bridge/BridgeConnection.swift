import Foundation

public enum SayOutcome: Equatable, Sendable { case sent, unavailable, failed }

/// What a bridge connection needs from the app. `BridgeController` implements it.
public protocol BridgeServices: AnyObject {
    var macName: String { get }
    var version: String { get }
    func verify(deviceId: String, token: String) -> DeviceRecord?
    func consumePairingCode(_ code: String) -> Bool
    func pendingRequest(_ requestId: String) -> PendingRequest?
    /// For validation: the request's original tool input, with the full question text.
    func originalToolInput(_ requestId: String) -> [String: Any]?
    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> Bool
    func markSeen(sessionId: String)
    func say(text: String, sessionId: String) -> SayOutcome
    func skinManifest(name: String) -> JSONValue?
    func snapshotMessage() -> ServerMessage
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

    public init(services: BridgeServices) {
        self.services = services
    }

    public func receive(_ frame: Data) -> [Output] {
        if frame.count > BridgeProtocol.maxFrameBytes { return closeNow([]) }
        switch phase {
        case .closed, .awaitingApproval:
            return []
        case .awaitingFirst:
            return receiveFirst(frame)
        case .ready:
            guard let message = ClientMessage.decode(frame) else { return [] }
            return handle(message)
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

    private func result(_ id: String?, _ reason: ResultReason?, _ message: String? = nil) -> [Output] {
        [.send(.result(id: id, ok: reason == nil, reason: reason, message: message))]
    }

    private func handle(_ message: ClientMessage) -> [Output] {
        switch message {
        case .answer(let id, let requestId, let payload):
            guard let request = services.pendingRequest(requestId) else {
                return result(id, .resolved, "已在电脑上处理")
            }
            let input = services.originalToolInput(requestId) ?? [:]
            guard AskDecision.validate(payload, kind: request.kind, toolInput: input) else {
                return result(id, .invalid, "答案无效")
            }
            guard services.submitAnswer(payload, requestId: requestId) else {
                return result(id, .failed, "提交失败")
            }
            return result(id, nil)
        case .seen(let id, let sessionId):
            services.markSeen(sessionId: sessionId)
            return result(id, nil)
        case .say(let id, let sessionId, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= BridgeProtocol.maxSayChars else {
                return result(id, .invalid, "文字为空或太长")
            }
            switch services.say(text: text, sessionId: sessionId) {
            case .sent: return result(id, nil)
            case .unavailable: return result(id, .unavailable, "该会话现在无法接收文字")
            case .failed: return result(id, .failed, "发送失败")
            }
        case .skin(let id, let name):
            return [.send(.skin(id: id, name: name, manifest: services.skinManifest(name: name)))]
        case .hello, .pair:
            return []
        }
    }
}
