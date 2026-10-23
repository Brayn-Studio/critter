import CritterKit
import Foundation

public struct QuestionOption: Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct Question: Equatable, Sendable {
    public var header: String?
    public var text: String
    public var options: [QuestionOption]
    public var multiSelect: Bool

    public init(header: String? = nil, text: String, options: [QuestionOption] = [], multiSelect: Bool = false) {
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// What a request says and asks, read from its `input` (Android `AnswerSheet.kt` and `Alerts.requestTitle`).
public enum RequestText {
    /// "critter 想 swift test": who is waiting and for what (Android `Alerts.requestTitle`). `what` is the
    /// request's summary, else its tool's name.
    public static func title(_ request: BridgePending, session: BridgeSession?) -> String {
        let name = session?.name ?? "会话"
        let what = isBlank(request.summary) ? request.toolName : request.summary
        switch request.kind {
        case .permission: return what.isEmpty ? "\(name) 想执行一个操作" : "\(name) 想 \(what)"
        case .question: return what.isEmpty ? "\(name) 有问题要问你" : "\(name) 问：\(what)"
        case .plan: return "\(name) 的计划等你批准"
        }
    }

    /// The first of `command`, `file_path`, `url` that the request has (and is not blank).
    public static func permissionBody(_ input: JSONValue) -> String? {
        ["command", "file_path", "url"].lazy.compactMap { string(input, $0) }.first { !isBlank($0) }
    }

    /// Codex approvals accept only a decision; Claude's older requests also accept an optional reason.
    public static func acceptsDenyMessage(_ input: JSONValue) -> Bool {
        if case .bool(false)? = input["acceptsDenyMessage"] { return false }
        return true
    }

    public static func planText(_ input: JSONValue) -> String {
        string(input, "plan") ?? ""
    }

    /// The questions of an `AskUserQuestion` request; an entry that is not a question (no text) or an option
    /// that is not one (no label) is left out.
    public static func questions(_ input: JSONValue) -> [Question] {
        guard case .array(let items)? = input["questions"] else { return [] }
        return items.compactMap { item in
            guard let text = string(item, "question") else { return nil }
            var options: [QuestionOption] = []
            if case .array(let raw)? = item["options"] {
                options = raw.compactMap { option in
                    string(option, "label").map { QuestionOption(label: $0, description: string(option, "description")) }
                }
            }
            var multiSelect = false
            if case .bool(true)? = item["multiSelect"] { multiSelect = true }
            return Question(header: string(item, "header"), text: text, options: options, multiSelect: multiSelect)
        }
    }

    /// Whether picking an option should send the answer at once: one single-select question and nothing
    /// else to fill in.
    public static func submitsOnPick(_ questions: [Question]) -> Bool {
        questions.count == 1 && !questions[0].multiSelect
    }

    private static func string(_ value: JSONValue, _ key: String) -> String? {
        value[key]?.stringValue
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the Mac's receipt for an answer means for the card (Android `answerOutcome`).
public enum AnswerOutcome: Equatable, Sendable {
    /// The Mac took it.
    case sent
    /// Someone answered first (on the Mac): not an error, the card says so and closes.
    case handledElsewhere
    /// Too late: the request's time ran out and the hook no longer waits for it. As with
    /// `handledElsewhere` the card says so (the associated text, the Mac's words) and closes.
    case expired(String)
    /// It did not get through; the card stays open with the text over the buttons.
    case failed(String)

    public init(_ result: CommandResult) {
        let message = result.message.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if result.ok {
            self = .sent
        } else if result.reason == .resolved {
            self = .handledElsewhere
        } else if result.reason == .expired {
            self = .expired(message ?? "这个请求已经过期了")
        } else {
            self = .failed(message ?? "没有发送出去，再试一次")
        }
    }
}

/// What the primary button says once the Mac took `payload` ("已允许"); nil for a no (a deny, a revise),
/// which gets no success beat: the card just closes.
public func successLabel(_ payload: AnswerPayload) -> String? {
    if payload.answers != nil { return "已提交" }
    switch payload.decision {
    case "allow": return "已允许"
    case "approve": return "已批准"
    default: return nil
    }
}

/// What an answer card shows for one request.
public enum CardState: Equatable, Sendable {
    /// The request is in the snapshot: its buttons work.
    case open(BridgePending)
    /// The card saw the request, and a snapshot later it is gone: someone answered on the Mac. The card says
    /// "已在电脑上处理" and closes.
    case handledElsewhere
    /// The card never saw the request (it was opened from a stale snapshot): it looks like `handledElsewhere`,
    /// with the words "这个请求已经不在了".
    case unknown

    /// - Parameter everSeen: whether this card has had the request in a snapshot before.
    public init(requestId: String, snapshot: SnapshotBody?, everSeen: Bool) {
        if let request = snapshot?.pending.first(where: { $0.requestId == requestId }) {
            self = .open(request)
        } else if everSeen {
            self = .handledElsewhere
        } else {
            self = .unknown
        }
    }
}
