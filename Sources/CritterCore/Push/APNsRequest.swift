import CritterKit
import Foundation

/// Builds the HTTP/2 request APNs takes for one `APNsMessage`.
public enum APNsRequest {
    public static let sandboxHost = "api.sandbox.push.apple.com"
    public static let productionHost = "api.push.apple.com"

    /// - Parameters:
    ///   - deviceToken: the phone's APNs token, hex. Anything that is not an ASCII hex digit is left out: a
    ///     token cannot reach the rest of the URL.
    ///   - bearer: a JWT from `APNsToken`.
    public static func make(
        _ message: APNsMessage, deviceToken: String, environment: PushEnvironment, config: APNsConfig, bearer: String
    ) -> URLRequest {
        let host = environment == .sandbox ? sandboxHost : productionHost
        let token = deviceToken.filter { $0.isASCII && $0.isHexDigit }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/3/device/\(token)"
        var request = URLRequest(url: components.url ?? URL(fileURLWithPath: "/"))
        request.httpMethod = "POST"
        request.httpBody = message.payload

        let topic: String
        let priority: Int
        switch message.pushType {
        case .alert:
            topic = config.bundleId
            priority = message.priority
        case .background:
            topic = config.bundleId
            priority = 5  // APNs refuses a background push of any other priority
        case .liveActivity:
            topic = "\(config.bundleId).push-type.liveactivity"
            priority = message.priority
        }
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue(message.pushType.rawValue, forHTTPHeaderField: "apns-push-type")
        request.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        if let collapseId = message.collapseId { request.setValue(collapseId, forHTTPHeaderField: "apns-collapse-id") }
        if let expiration = message.expiration { request.setValue(String(expiration), forHTTPHeaderField: "apns-expiration") }
        return request
    }
}
