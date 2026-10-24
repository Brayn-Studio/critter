import Foundation

/// Sends pushes one by one through an injected transport and applies what APNs answers: it retries a busy
/// APNs a few times, stops everything when the key or Team ID is wrong, and hands a dead token back. The
/// transport and the clock are the caller's (`PushSender`'s URLSession and the bridge queue); tests script them.
///
/// Everything happens on one queue: the transport's completion and the scheduled work run there too.
/// Nothing is logged but statuses and reasons -- never a device token, a payload or a key.
public final class PushDelivery {
    /// Sends the request; calls back with the reply, or the error if there was none.
    public typealias Transport = (URLRequest, @escaping (Result<APNsReply, Error>) -> Void) -> Void
    /// Runs the work after the delay, on the same queue.
    public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    /// A push is tried again after these delays, then given up: three retries.
    public static let retryDelays: [TimeInterval] = [1, 2, 4]

    private let transport: Transport
    private let schedule: Schedule
    private let log: (String) -> Void

    /// Why nothing is being sent (the last `configError`), until `configChanged()`.
    public private(set) var blockedReason: String?
    public var isBlocked: Bool { blockedReason != nil }

    public init(transport: @escaping Transport, schedule: @escaping Schedule, log: @escaping (String) -> Void) {
        self.transport = transport
        self.schedule = schedule
        self.log = log
    }

    /// The settings changed (a new key, Team ID or bundle id): try again.
    public func configChanged() {
        blockedReason = nil
    }

    /// Sends `request`. `completion` is called once with what became of it: `.sent`, `.dropToken` (the caller
    /// forgets the token), `.configError` (also when nothing was sent because an earlier push already got
    /// one), or `.rejected` (APNs refused the push, or the retries ran out). Never `.retry`.
    public func send(_ request: URLRequest, completion: @escaping (APNsOutcome) -> Void) {
        attempt(request, retries: 0, completion: completion)
    }

    private func attempt(_ request: URLRequest, retries: Int, completion: @escaping (APNsOutcome) -> Void) {
        if let reason = blockedReason {
            completion(.configError(reason))
            return
        }
        transport(request) { [self] result in
            let outcome: APNsOutcome
            let detail: String
            switch result {
            case .success(let reply):
                outcome = APNsResponse.classify(status: reply.status, body: reply.body)
                detail = Self.detail(outcome, status: reply.status)
            case .failure:
                outcome = .retry
                detail = "network error"
            }
            switch outcome {
            case .retry:
                guard retries < Self.retryDelays.count else {
                    log("APNs push gave up after \(retries) retries: \(detail)")
                    completion(.rejected(detail))
                    return
                }
                let delay = Self.retryDelays[retries]
                log("APNs push will retry in \(Int(delay)) s: \(detail)")
                schedule(delay) { [self] in attempt(request, retries: retries + 1, completion: completion) }
            case .configError(let reason):
                blockedReason = reason
                log("APNs refused the key or settings, pushing stops until they change: \(reason)")
                completion(outcome)
            case .rejected(let reason):
                log("APNs refused a push: \(reason)")
                completion(outcome)
            case .dropToken:
                log("APNs says a device token is gone")
                completion(outcome)
            case .sent:
                completion(outcome)
            }
        }
    }

    /// What goes in the log about a reply that is not a success.
    private static func detail(_ outcome: APNsOutcome, status: Int) -> String {
        switch outcome {
        case .rejected(let reason) where reason != String(status): return "\(status) \(reason)"
        default: return String(status)
        }
    }
}
