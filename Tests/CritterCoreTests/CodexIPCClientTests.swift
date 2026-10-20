import Darwin
import Foundation
import Testing
@testable import CritterCore

private let controlThread = "11111111-2222-4333-8444-555555555555"
private final class LocalCodexFixture: @unchecked Sendable {
    let directory: URL
    let path: String
    private let queue = DispatchQueue(label: "test.codex.ipc.server")
    private let lock = NSLock()
    private var captured: [JSONValue] = []
    private var listener: DispatchSourceRead?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var decoders: [Int32: CodexIPCFraming] = [:]
    private let silenceMessages: Bool
    private let closeAfterAction: Bool
    private let listenerFD: Int32
    var messages: [JSONValue] { lock.withLock { captured } }

    init(silenceMessages: Bool = false, closeAfterAction: Bool = false) throws {
        self.closeAfterAction = closeAfterAction
        self.silenceMessages = silenceMessages
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("ipc.sock").path
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileWriteInvalidFileName) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (i, byte) in bytes.enumerated() { buffer[i] = byte } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listenerFD, 4) == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = fcntl(listenerFD, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [listenerFD] in close(listenerFD) }
        listener = source; source.resume()
    }
    func stop() {
        queue.sync {
            for source in clients.values { source.cancel() }
            clients = [:]; decoders = [:]; listener?.cancel(); listener = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }
    func republishApproval(revision: Int) {
        queue.async { [self] in
            let request: [String:Any] = ["id":42,"method":"item/commandExecution/requestApproval","params":["threadId":controlThread,"command":"swift test"]]
            for fd in clients.keys {
                send(["type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":"owner",
                      "params":["conversationId":controlThread,"hostId":"local","change":["type":"snapshot","revision":revision,
                        "conversationState":["cwd":"/work/project","requests":[request],"threadRuntimeStatus":["type":"idle"]]]]],fd:fd)
            }
        }
    }
    private func acceptClient() {
        let peer = accept(listenerFD, nil, nil)
        guard peer >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        decoders[peer] = CodexIPCFraming()
        let source = DispatchSource.makeReadSource(fileDescriptor: peer, queue: queue)
        source.setEventHandler { [weak self] in self?.read(peer) }
        source.setCancelHandler { close(peer) }
        clients[peer] = source; source.resume()
    }
    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                guard var decoder = decoders[fd], let values = try? decoder.append(Data(buffer.prefix(n))) else { return }
                decoders[fd] = decoder
                for value in values { handle(value, fd: fd) }
            } else if n < 0 && errno == EINTR { continue }
            else if n < 0 && errno == EAGAIN { return }
            else { clients.removeValue(forKey: fd)?.cancel(); decoders[fd] = nil; return }
        }
    }
    private func send(_ object: [String: Any], fd: Int32) {
        guard let data = try? CodexIPCFraming.encode(JSONValue(any: object)) else { return }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
            guard n > 0 else { return }; offset += n
        }
    }
    private func handle(_ value: JSONValue, fd: Int32) {
        lock.withLock { captured.append(value) }
        guard let method = value["method"]?.stringValue else { return }
        if value["type"]?.stringValue == "broadcast", method == "thread-stream-following-changed" {
            guard value["params"]?["following"]?.ipcBool == true else { return }
            let request: [String: Any] = ["id": 42, "method": "item/commandExecution/requestApproval", "params": ["threadId": controlThread, "command": "swift test"]]
            send(["type":"broadcast","method":"thread-stream-state-changed","version":11,"sourceClientId":"owner",
                  "params":["conversationId":controlThread,"hostId":"local","change":["type":"snapshot","revision":1,
                    "conversationState":["cwd":"/work/project","requests":[request],"threadRuntimeStatus":["type":"idle"]]]]], fd:fd)
            return
        }
        guard value["type"]?.stringValue == "request", let id = value["requestId"]?.stringValue else { return }
        if closeAfterAction && method.hasPrefix("thread-follower-") {
            clients.removeValue(forKey:fd)?.cancel(); decoders[fd] = nil; return
        }
        var response: [String:Any] = ["type":"response","requestId":id,"resultType":"success","method":method,"handledByClientId":"owner"]
        switch method {
        case "initialize": response["result"] = ["clientId":"critter-test"]
        case "thread-owner-discovery": response["result"] = ["supportsUntrustedAppInput":true]
        case "thread-follower-start-turn", "thread-follower-steer-turn":
            if silenceMessages { return }
            response["result"] = ["result":["turnId":"turn-2"]]
        default: response["result"] = ["ok":true]
        }
        send(response, fd:fd)
    }
}
private func waitForControl(_ client: CodexIPCClient) async throws {
    let deadline = Date().addingTimeInterval(3)
    while client.capabilities["codex-" + controlThread]?.canSay != true && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(client.capabilities["codex-" + controlThread]?.canSay == true)
}

@Test func codexIPCClientUsesExistingOwnerAndOriginalApproval() async throws {
    let server = try LocalCodexFixture()
    let client = CodexIPCClient(socketPath: server.path, timeout: 0.5)
    defer { client.stop(); server.stop() }
    client.start(sessionIDs:["codex-" + controlThread])
    try await waitForControl(client)
    #expect(client.requests.count == 1)
    #expect(client.say(text:"从手机继续",sessionID:"codex-" + controlThread) == .sent)
    let prompt = try #require(client.requests.first)
    #expect(client.answer(AnswerPayload(decision:"allow"),requestID:prompt.pending.requestId) == .accepted)
    let operations = server.messages.filter { $0["method"]?.stringValue?.hasPrefix("thread-follower-") == true }
    #expect(operations.map { $0["method"]?.stringValue } == ["thread-follower-start-turn", "thread-follower-command-approval-decision"])
    #expect(operations.allSatisfy { $0["targetClientId"] == .string("owner") })
    #expect(operations.last?["params"]?["requestId"] == .number(42))
    #expect(operations.first?["params"]?["turnStart"]?["context"]?["inheritThreadSettings"] == .bool(true))
    #expect(client.say(text:"wrong target", sessionID:"codex-22222222-2222-4333-8444-555555555555") == .unavailable)
}

@Test func codexIPCClientDoesNotRetryAnUnconfirmedMessage() async throws {
    let server = try LocalCodexFixture(silenceMessages:true)
    let client = CodexIPCClient(socketPath:server.path,timeout:0.08)
    defer { client.stop(); server.stop() }
    client.start(sessionIDs:["codex-" + controlThread])
    try await waitForControl(client)
    #expect(client.say(text:"只发一次",sessionID:"codex-" + controlThread) == .unconfirmed)
    try await Task.sleep(for:.milliseconds(150))
    #expect(server.messages.filter { $0["method"]?.stringValue == "thread-follower-start-turn" }.count == 1)
}

@Test func codexIPCDisconnectAfterWritingDoesNotClaimDefiniteFailure() async throws {
    let server = try LocalCodexFixture(closeAfterAction:true)
    let client = CodexIPCClient(socketPath:server.path,timeout:0.3)
    defer { client.stop(); server.stop() }
    client.start(sessionIDs:["codex-"+controlThread]); try await waitForControl(client)
    #expect(client.say(text:"可能已送达",sessionID:"codex-"+controlThread) == .unconfirmed)
}
@Test func codexIPCDisconnectAfterAnAnswerDoesNotClaimAlreadyAnswered() async throws {
    let server = try LocalCodexFixture(closeAfterAction:true)
    let client = CodexIPCClient(socketPath:server.path,timeout:0.3)
    defer { client.stop(); server.stop() }
    client.start(sessionIDs:["codex-"+controlThread]); try await waitForControl(client)
    let prompt = try #require(client.requests.first)
    #expect(client.answer(AnswerPayload(decision:"allow"),requestID:prompt.pending.requestId) == .failed)
}

@Test func codexIPCApprovalCardsCannotSurviveANewSnapshotGeneration() async throws {
    let server = try LocalCodexFixture()
    let client = CodexIPCClient(socketPath:server.path,timeout:0.3)
    defer { client.stop(); server.stop() }
    client.start(sessionIDs:["codex-"+controlThread]); try await waitForControl(client)
    let old = try #require(client.requests.first).pending.requestId
    server.republishApproval(revision:2)
    let deadline = Date().addingTimeInterval(2)
    while client.requests.first?.pending.requestId == old && Date() < deadline { try await Task.sleep(for:.milliseconds(10)) }
    #expect(client.requests.first?.pending.requestId != old)
    #expect(client.answer(AnswerPayload(decision:"allow"),requestID:old) == .alreadyAnswered)
    #expect(!server.messages.contains { $0["method"]?.stringValue == "thread-follower-command-approval-decision" })
}
