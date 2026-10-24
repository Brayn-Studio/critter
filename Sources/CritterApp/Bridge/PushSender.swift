import CritterCore
import Foundation

/// Sends pushes to APNs (spec 6.4): one ephemeral `URLSession` (HTTP/2 is negotiated by the system, the system
/// proxy settings apply), requests from `APNsRequest`, replies sorted by `APNsResponse`, retries and the 403 stop
/// by `PushDelivery`. Every completion comes back on the bridge queue. Remembers when a push last went out and
/// why the last one failed, for the settings.
///
/// Bridge queue only. Nothing it logs holds a device token, a payload, the JWT or the key: `PushDelivery` logs
/// statuses and reasons, and this logs nothing of its own but a signing failure.
final class PushSender {
    /// How long one attempt may take before it counts as a network error (and is retried).
    static let timeout: TimeInterval = 30

    private let delivery: PushDelivery
    private let log: (String) -> Void

    /// When APNs last took a push.
    private(set) var lastSentAt: Date?
    /// Why the last push that failed failed (APNs's reason, a status, or "network error"); cleared by the next
    /// push that goes through.
    private(set) var lastFailure: String?
    /// APNs refused the key, Team ID or bundle id: nothing is sent until `configChanged()`.
    var blockedReason: String? { delivery.blockedReason }

    init(queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.log = log
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        let session = URLSession(configuration: configuration)
        delivery = PushDelivery(
            transport: { request, completion in
                let done = Unchecked(completion)
                session.dataTask(with: request) { data, response, error in
                    let result: Result<APNsReply, Error>
                    if let http = response as? HTTPURLResponse {
                        result = .success(APNsReply(status: http.statusCode, body: data ?? Data()))
                    } else {
                        result = .failure(error ?? URLError(.badServerResponse))
                    }
                    queue.async { done.value(result) }
                }.resume()
            },
            schedule: { delay, work in
                let work = Unchecked(work)
                queue.asyncAfter(deadline: .now() + delay) { work.value() }
            },
            log: log
        )
    }

    /// The setup changed: APNs gets another try.
    func configChanged() {
        delivery.configChanged()
    }

    /// Sends `push`; `completion` hears what became of it (never `.retry`).
    func send(_ push: OutgoingPush, config: APNsConfig, signer: APNsToken, completion: @escaping (APNsOutcome) -> Void) {
        let bearer: String
        do {
            bearer = try signer.bearer(now: Date())
        } catch {
            log("push: could not sign the APNs token")
            lastFailure = "signing"
            completion(.rejected("signing"))
            return
        }
        var request = APNsRequest.make(
            push.message, deviceToken: push.target.token, environment: push.target.environment, config: config, bearer: bearer
        )
        request.timeoutInterval = Self.timeout
        delivery.send(request) { [weak self] outcome in
            self?.record(outcome)
            completion(outcome)
        }
    }

    private func record(_ outcome: APNsOutcome) {
        switch outcome {
        case .sent:
            lastSentAt = Date()
            lastFailure = nil
        case .rejected(let reason):
            lastFailure = reason
        case .configError, .dropToken, .retry:
            break
        }
    }
}

/// Carries a closure that is only ever called on the bridge queue across a `@Sendable` boundary.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
