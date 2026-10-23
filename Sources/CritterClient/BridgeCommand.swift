import CritterKit

/// What the phone asks the Mac to do; each is answered with a `result`.
public enum BridgeCommand: Equatable, Sendable {
    case answer(requestId: String, payload: AnswerPayload)
    case seen(sessionId: String)
    case say(sessionId: String, text: String)
    case interrupt(sessionId: String)

    /// The frame for this command with correlation id `id`.
    func message(id: String) -> ClientMessage {
        switch self {
        case .answer(let requestId, let payload): .answer(id: id, requestId: requestId, payload: payload)
        case .seen(let sessionId): .seen(id: id, sessionId: sessionId)
        case .say(let sessionId, let text): .say(id: id, sessionId: sessionId, text: text)
        case .interrupt(let sessionId): .interrupt(id: id, sessionId: sessionId)
        }
    }
}
