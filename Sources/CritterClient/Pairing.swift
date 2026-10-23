import CritterKit
import Foundation
import os

/// The Mac to pair with: from a scanned pairing URI, or typed in by hand.
public struct PairingTarget: Equatable, Sendable {
    public var endpoint: Endpoint
    public var fingerprint: String
    public var code: String
    public var macName: String

    public init(endpoint: Endpoint, fingerprint: String, code: String, macName: String) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.code = code
        self.macName = macName
    }

    public init(uri: PairingURI) {
        self.init(
            endpoint: Endpoint(host: uri.host, port: uri.port), fingerprint: uri.fingerprint, code: uri.code, macName: uri.name
        )
    }
}

/// Why a pairing attempt did not end in `paired`; the pairing screen says each one differently.
public enum PairFailure: Equatable, Sendable {
    /// `denied badCode`: a wrong, expired or used pairing code.
    case badCode
    /// `denied rejected`: the user declined on the Mac.
    case rejected
    /// `denied protocol` (or any other reason a pairing should never get).
    case protocolMismatch
    /// The Mac's certificate is not the one pinned. Nothing was sent.
    case certMismatch
    /// Nobody approved on the Mac in time: our own timeout, or the Mac closing without `denied`.
    case noAnswer
    /// No connection: refused, cut off, wrong network, or the Mac is not accepting phones.
    case unreachable

    /// What the pairing screen says (Android `pairFailureText`).
    public var text: String {
        switch self {
        case .badCode: "这个码不对，或者已经过期了。在 Mac 的「添加手机」里点「重新生成」再试。"
        case .rejected: "Mac 上点了「拒绝」。要配对的话重新扫码，这次点「允许」。"
        case .protocolMismatch: "这台 Mac 上的 Critter 版本和手机不一致，把两边都更新到最新再试。"
        case .certMismatch: "这台 Mac 的证书和二维码里的不一样，已经停下。确认扫的是你自己的 Mac。"
        case .noAnswer: "Mac 上一直没人点「允许」。回到 Mac 前，重新扫一次码。"
        case .unreachable: "连不上这台 Mac。确认手机和电脑在同一个 Wi‑Fi，并且 Mac 上开着「允许手机连接」。"
        }
    }
}

public enum PairResult: Equatable, Sendable {
    case paired(deviceId: String, token: String, macName: String)
    case failed(PairFailure)
}

/// How a pairing attempt that was not approved ended (Android `pairFailureOf`): what the Mac
/// said in `denied` first, then a pinned-certificate mismatch, then `timedOut` or a WebSocket close
/// without `denied` (`closedCleanly`, see the protocol doc's "Timeouts and limits"); anything
/// else is unreachable.
public func pairFailure(denied: DenyReason?, pinMismatch: Bool, timedOut: Bool, closedCleanly: Bool) -> PairFailure {
    if let denied {
        switch denied {
        case .badCode: return .badCode
        case .rejected: return .rejected
        case .protocolMismatch, .badToken: return .protocolMismatch
        }
    }
    if pinMismatch { return .certMismatch }
    if timedOut || closedCleanly { return .noAnswer }
    return .unreachable
}

/// First-time pairing over a connection pinned to the target's fingerprint.
public struct Pairer: Sendable {
    private let transport: any BridgeTransport
    private let timeout: Duration

    /// - Parameter timeout: how long to wait for the user to approve on the Mac.
    public init(transport: any BridgeTransport, timeout: Duration = .seconds(120)) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Sends `pair` as the first frame and waits for `paired` (what follows it is not needed:
    /// the connection is closed). `onAwaitingApproval` is called once the connection is open.
    /// Cancelling the task closes the connection at once (the Mac withdraws its request); the
    /// attempt then fails.
    public func pair(
        _ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void
    ) async -> PairResult {
        let socket: any BridgeSocket
        do {
            socket = try await transport.connect(
                host: target.endpoint.host, port: target.endpoint.port, fingerprint: target.fingerprint
            )
        } catch {
            return .failed(failure(after: error, timedOut: false))
        }
        defer { socket.close() }
        onAwaitingApproval()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            socket.close()
        }
        defer { timer.cancel() }

        do {
            // `receive` does not end by itself when the task is cancelled: closing the socket ends it.
            return try await withTaskCancellationHandler {
                let pair = ClientMessage.pair(code: target.code, deviceName: deviceName)
                try await socket.send(String(decoding: pair.encode(), as: UTF8.self))
                while true {
                    switch ServerMessage.decode(Data(try await socket.receive().utf8)) {
                    case .paired(let deviceId, let token, let macName):
                        return .paired(deviceId: deviceId, token: token, macName: macName)
                    case .denied(let reason):
                        return .failed(pairFailure(denied: reason, pinMismatch: false, timedOut: false, closedCleanly: false))
                    default:
                        continue
                    }
                }
            } onCancel: {
                socket.close()
            }
        } catch {
            return .failed(failure(after: error, timedOut: timedOut.withLock { $0 }))
        }
    }

    private func failure(after error: any Error, timedOut: Bool) -> PairFailure {
        let error = error as? TransportError
        return pairFailure(
            denied: nil, pinMismatch: error == .pinMismatch, timedOut: timedOut, closedCleanly: error == .closed(cleanly: true)
        )
    }
}
