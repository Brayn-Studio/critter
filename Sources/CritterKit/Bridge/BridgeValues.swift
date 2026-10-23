import Foundation

public enum PendingKind: String, Codable, Sendable {
    case permission, question, plan

    public init(toolName: String) {
        switch toolName {
        case "AskUserQuestion": self = .question
        case "ExitPlanMode": self = .plan
        default: self = .permission
        }
    }
}

/// What the phone decided, written to `~/.critter/answers/<requestId>.json`. Which fields
/// are meaningful depends on the request's `kind`.
public struct AnswerPayload: Codable, Sendable, Equatable {
    public var decision: String?
    public var message: String?
    public var answers: [String: String]?

    public init(decision: String? = nil, message: String? = nil, answers: [String: String]? = nil) {
        self.decision = decision
        self.message = message
        self.answers = answers
    }
}

/// A usage window from the status line's `rate_limits`. `resetsAt` is epoch milliseconds
/// (the status line reports seconds).
public struct RateWindow: Codable, Sendable, Equatable {
    public var usedPercentage: Double
    public var resetsAt: Int64

    public init(usedPercentage: Double, resetsAt: Int64) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}
