/// What a card with a lone permission request shows once its 「拒绝」「允许」 were used: on the home list
/// (`SessionRow`) and on the pro board's cards alike.
public enum InlineAnswerState: Equatable, Sendable {
    case idle
    case sending
    /// The Mac took it; the text is the success label ("已允许"), nil for a no.
    case sent(String?)
    /// The request is closed: answered on the Mac, or too late; the text says which.
    case closed(String)
    /// It did not get through; the buttons work again.
    case failed(String)

    /// How the line over the buttons reads; each card has its own colour for each.
    public enum Tone: Equatable, Sendable {
        case quiet, success, failure
    }

    /// The line over the buttons: "正在提交…", the success label, why the request is closed, or why it did not get
    /// through. Nil says nothing (not used yet, or a no that went through).
    public var status: (text: String, tone: Tone)? {
        switch self {
        case .idle: nil
        case .sending: ("正在提交…", .quiet)
        case .sent(let label): label.map { ($0, .success) }
        case .closed(let text): (text, .quiet)
        case .failed(let text): (text, .failure)
        }
    }

    /// Whether 「拒绝」「允许」 can be tapped under `rule` (`HomeRules.inlineAnswer`): only while the phone can act,
    /// and only before an answer is on its way or after one failed.
    public func buttonsEnabled(_ rule: InlineAnswer) -> Bool {
        guard rule == .allowDeny else { return false }
        switch self {
        case .idle, .failed: return true
        case .sending, .sent, .closed: return false
        }
    }
}
