import CritterCore
import CryptoKit
import Foundation

// A developer's stand-in for the phone app: pairs with Critter's LAN bridge, prints what it
// pushes, and sends the phone's commands -- for checking the bridge without a phone. Speaks
// `docs/critter-bridge-protocol.md`, pinning the Mac's certificate like the phone does.

let usage = """
usage: critter-bridge-client <command> [options]

  pair <uri> [--state <path>]      pair using a critter-pair:// URI; saves the pairing
  watch [--state <path>] [--count N]
                                   print every message as one JSON line; with --count,
                                   exit after the Nth snapshot
  answer <requestId> [--decision allow|deny|approve|revise] [--message M]
                     [--answer "<question text>=<value>"]...
  seen <sessionId>
  say <sessionId> <text>
  skin <name>

answer, seen, say and skin print the reply line and exit (status 1 if it isn't ok).
--state defaults to ~/.critter/dev-client.json.
"""

/// What `pair` saves and every other command connects with.
struct ClientState: Codable {
    var host: String
    var port: UInt16
    var fingerprint: String
    var deviceId: String
    var token: String
}

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("critter-bridge-client: \(message)\n".utf8))
    exit(status)
}

/// One line on stdout, unbuffered (so `watch > file.jsonl` is readable as it goes).
func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Exits if nothing settled the command in time.
func exitAfter(seconds: Double, _ what: String) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { fail("\(what): no reply within \(Int(seconds)) s") }
}

// MARK: - Arguments

var positional: [String] = []
var options: [String: [String]] = [:]
do {
    var rest = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = rest.popFirst() {
        if arg.hasPrefix("--") {
            guard let value = rest.popFirst() else { fail("\(arg) needs a value\n\n\(usage)", status: 64) }
            options[String(arg.dropFirst(2)), default: []].append(value)
        } else {
            positional.append(arg)
        }
    }
}

let statePath = options["state"]?.last.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? CritterPaths.fromEnvironment().critterHome.appendingPathComponent("dev-client.json")

func loadState() -> ClientState {
    guard let data = try? Data(contentsOf: statePath),
          let state = try? JSONDecoder().decode(ClientState.self, from: data) else {
        fail("no pairing at \(statePath.path); run `pair` first")
    }
    return state
}

/// Holds a device token, so 0600, written to a temp file first and renamed into place.
func saveState(_ state: ClientState) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(state) else { fail("could not encode the pairing") }
    let dir = statePath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temp = dir.appendingPathComponent(".\(statePath.lastPathComponent).tmp-\(getpid())")
    guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]),
          rename(temp.path, statePath.path) == 0 else { fail("could not write \(statePath.path)") }
}

// MARK: - Connection

/// Trusts the server only if its leaf certificate's SHA-256 is the pinned fingerprint, and
/// ends the program as soon as the connection is gone (a pending `send`/`receive` may never
/// return once the handshake was refused).
final class PinningDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let seen = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        guard seen == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            fail("certificate fingerprint \(seen) is not the paired one")
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        fail("connection closed" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }
}

final class Link: Sendable {
    let task: URLSessionWebSocketTask

    init(host: String, port: UInt16, fingerprint: String) {
        let bracketed = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        guard let url = URL(string: "wss://\(bracketed):\(port)/") else { fail("bad address \(host):\(port)") }
        let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = BridgeProtocol.maxFrameBytes
        task.resume()
    }

    func send(_ message: ClientMessage) async {
        do {
            try await task.send(.string(String(decoding: message.encode(), as: UTF8.self)))
        } catch {
            fail("send failed: \(error.localizedDescription)")
        }
    }

    /// The next frame's text and what it decodes to (nil for a message this client doesn't know).
    func receive() async -> (text: String, message: ServerMessage?) {
        do {
            let text: String
            switch try await task.receive() {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: text = ""
            }
            return (text, ServerMessage.decode(Data(text.utf8)))
        } catch {
            fail("connection closed: \(error.localizedDescription)")
        }
    }

    /// Connects with the saved pairing and says `hello`; the Mac answers `welcome` (or `denied`).
    static func hello(_ state: ClientState) async -> Link {
        let link = Link(host: state.host, port: state.port, fingerprint: state.fingerprint)
        await link.send(.hello(
            protocolVersion: BridgeProtocol.version, deviceId: state.deviceId, token: state.token, app: "critter-bridge-client/1.0"
        ))
        return link
    }
}

// MARK: - Commands

func pair(_ raw: String) async -> Never {
    guard let uri = PairingURI(string: raw) else { fail("not a pairing URI: \(raw)") }
    exitAfter(seconds: 600, "pair")
    let link = Link(host: uri.host, port: uri.port, fingerprint: uri.fingerprint)
    await link.send(.pair(code: uri.code, deviceName: DeviceRegistry.devClientName))
    while true {
        let (text, message) = await link.receive()
        switch message {
        case .paired(let deviceId, let token, let macName):
            saveState(ClientState(host: uri.host, port: uri.port, fingerprint: uri.fingerprint, deviceId: deviceId, token: token))
            // The token stays in the state file.
            let line: [String: Any] = ["type": "paired", "deviceId": deviceId, "macName": macName, "state": statePath.path]
            let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            emit(String(decoding: data, as: UTF8.self))
            exit(0)
        case .denied:
            emit(text)
            exit(1)
        default:
            continue
        }
    }
}

func watch(count: Int?) async -> Never {
    let link = await Link.hello(loadState())
    // Like the phone's heartbeat: keeps the connection (and `lastClientSeen`) alive.
    let pinger = Thread {
        while true {
            Thread.sleep(forTimeInterval: 30)
            link.task.sendPing { _ in }
        }
    }
    pinger.start()
    var snapshots = 0
    while true {
        let (text, message) = await link.receive()
        emit(text)
        switch message {
        case .snapshot:
            snapshots += 1
            if let count, snapshots >= count { exit(0) }
        case .denied:
            exit(1)
        default:
            continue
        }
    }
}

/// Sends one command once the Mac has said `welcome`, then prints its reply and exits.
func run(_ command: ClientMessage, id: String) async -> Never {
    exitAfter(seconds: 15, "command")
    let link = await Link.hello(loadState())
    while true {
        let (text, message) = await link.receive()
        switch message {
        case .welcome:
            await link.send(command)
        case .denied:
            emit(text)
            exit(1)
        case .result(let replyId, let ok, _, _) where replyId == id:
            emit(text)
            exit(ok ? 0 : 1)
        case .skin(let replyId, _, let manifest) where replyId == id:
            emit(text)
            exit(manifest == nil ? 1 : 0)
        default:
            continue
        }
    }
}

let commandId = "cli-1"
switch positional.first {
case "pair" where positional.count == 2:
    await pair(positional[1])
case "watch" where positional.count == 1:
    let count = options["count"]?.last.map { Int($0) ?? 0 }
    if let count, count < 1 { fail("--count needs a positive number", status: 64) }
    await watch(count: count)
case "answer" where positional.count == 2:
    var answers: [String: String] = [:]
    for pair in options["answer"] ?? [] {
        // The value may contain "="; the question text is taken to end at the first one.
        guard let equals = pair.firstIndex(of: "=") else { fail("--answer needs \"<question>=<value>\"", status: 64) }
        answers[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    let payload = AnswerPayload(
        decision: options["decision"]?.last, message: options["message"]?.last, answers: answers.isEmpty ? nil : answers
    )
    await run(.answer(id: commandId, requestId: positional[1], payload: payload), id: commandId)
case "seen" where positional.count == 2:
    await run(.seen(id: commandId, sessionId: positional[1]), id: commandId)
case "say" where positional.count == 3:
    await run(.say(id: commandId, sessionId: positional[1], text: positional[2]), id: commandId)
case "skin" where positional.count == 2:
    await run(.skin(id: commandId, name: positional[1]), id: commandId)
default:
    fail(usage, status: 64)
}
