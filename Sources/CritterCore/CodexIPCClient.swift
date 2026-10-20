import Foundation
import Darwin

/// A second client of Codex's existing local coordinator. Never starts/resumes a thread or
/// creates a server. Only positively discovered current owners receive phone operations.
public final class CodexIPCClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.critter.codex.control", qos: .utility)
    private let socketPath: String
    private let timeout: TimeInterval
    private let onChange: @Sendable () -> Void
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var framing = CodexIPCFraming()
    private var clientID: String?
    private var enabled = false
    private var generation = 0
    private var retryScheduled = false
    private var retryDelay: TimeInterval = 1
    private var desired: Set<String> = []
    private var conversations: [String: CodexIPCConversation] = [:]
    private var prompts: [String: CodexIPCPhoneRequest] = [:]
    private var answering: Set<String> = []
    private var discovering: Set<String> = []
    private var reason = "尚未连接 Codex 控制通道"
    private enum Reply { case success(JSONValue), failure, timeout, resolved }
    private struct Waiting {
        let method: String
        let owner: String?
        let complete: @Sendable (Reply) -> Void
    }
    private var waiting: [String: Waiting] = [:]
    private var issuedPrompts: [String: (owner: String, prompt: CodexIPCPhoneRequest)] = [:]

    public init(socketPath: String, timeout: TimeInterval = 5, onChange: @escaping @Sendable () -> Void = {}) {
        self.socketPath = socketPath; self.timeout = timeout; self.onChange = onChange
    }
    public func start(sessionIDs: [String]) {
        queue.async { [self] in enabled = true; reconcile(sessionIDs) }
    }
    public func update(sessionIDs: [String]) { queue.async { [self] in reconcile(sessionIDs) } }
    public func stop() { queue.async { [self] in enabled = false; disconnect() } }
    public func reconnect() { queue.async { [self] in disconnect(); if enabled { connectIfNeeded() } } }

    public var capabilities: [String: BridgeCapabilities] {
        queue.sync {
            Dictionary(uniqueKeysWithValues: desired.map { thread in
                ("codex-" + thread, conversations[thread]?.capabilities ?? BridgeCapabilities(readOnlyReason: reason))
            })
        }
    }
    public var requests: [CodexIPCPhoneRequest] { queue.sync { Array(prompts.values) } }
    public var waitingSessionIDs: Set<String> {
        queue.sync { Set(conversations.filter { $0.value.isWaiting }.keys.map { "codex-" + $0 }) }
    }
    public var telemetry: [String: CodexTelemetry] {
        queue.sync { Dictionary(uniqueKeysWithValues: conversations.compactMap { key, value in value.telemetry.map { ("codex-" + key, $0) } }) }
    }
    public var statusText: String {
        queue.sync {
            clientID == nil ? reason : "已连接 Codex 控制通道，\(conversations.values.filter { $0.capabilities.canSay }.count) 个会话可操作"
        }
    }

    private final class ResultBox: @unchecked Sendable {
        let lock = NSLock()
        var value: Reply = .failure
        let done = DispatchSemaphore(value: 0)
        func finish(_ value: Reply) { lock.withLock { self.value = value }; done.signal() }
    }
    public func say(text: String, sessionID: String) -> SayOutcome {
        perform(sessionID: sessionID) { $0.message(text) }
    }
    public func interrupt(sessionID: String) -> SayOutcome {
        perform(sessionID: sessionID) { $0.interrupt() }
    }
    private func perform(sessionID: String, operation: @escaping @Sendable (CodexIPCConversation) -> CodexIPCOperation?) -> SayOutcome {
        let box = ResultBox()
        queue.async { [self] in
            guard enabled, let thread = Self.threadID(sessionID), desired.contains(thread),
                  let conversation = conversations[thread], let action = operation(conversation) else { box.finish(.failure); return }
            request(action, owner: conversation.ownerID) { [weak self] reply in
                if case .failure = reply { self?.invalidate(thread) }
                box.finish(reply)
            }
        }
        guard box.done.wait(timeout: .now() + timeout + 1) == .success else { return .unconfirmed }
        switch box.lock.withLock({ box.value }) {
        case .success: return .sent
        case .failure, .resolved: return .unavailable
        case .timeout: return .unconfirmed
        }
    }
    public func answer(_ payload: AnswerPayload, requestID: String) -> AnswerOutcome {
        let box = ResultBox()
        queue.async { [self] in
            guard !answering.contains(requestID), let prompt = prompts[requestID],
                  let thread = Self.threadID(prompt.pending.sessionId), let conversation = conversations[thread],
                  conversation.capabilities.canAnswer, let action = prompt.response(to: payload) else { box.finish(.resolved); return }
            answering.insert(requestID)
            request(action, owner: conversation.ownerID) { [weak self] reply in
                self?.answering.remove(requestID)
                box.finish(reply)
            }
        }
        guard box.done.wait(timeout: .now() + timeout + 1) == .success else { return .failed }
        switch box.lock.withLock({ box.value }) {
        case .success(let result): return result["ok"]?.ipcBool == true ? .accepted : .failed
        case .resolved: return .alreadyAnswered
        case .failure: return .failed
        case .timeout: return .failed
        }
    }

    private static func threadID(_ session: String) -> String? {
        guard session.hasPrefix("codex-") else { return nil }
        let value = String(session.dropFirst(6))
        return UUID(uuidString: value) == nil ? nil : value
    }
    private func reconcile(_ sessions: [String]) {
        let next = Set(sessions.compactMap(Self.threadID))
        for thread in desired.subtracting(next) {
            if let owner = conversations[thread]?.ownerID { follow(thread, owner: owner, on: false) }
            conversations[thread] = nil
        }
        desired = next
        refreshPrompts()
        guard enabled else { return }
        if desired.isEmpty { disconnect(); return }
        connectIfNeeded()
        if clientID != nil { for thread in desired where conversations[thread] == nil { discover(thread) } }
    }
    private func connectIfNeeded() {
        guard enabled, !desired.isEmpty, fd < 0 else { return }
        var info = stat()
        guard lstat(socketPath, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(),
              let connected = Self.openSocket(socketPath) else {
            reason = "未连接 Codex 本地控制通道；当前会话仅可查看"
            scheduleRetry(); return
        }
        fd = connected; generation += 1
        let token = generation
        framing = CodexIPCFraming()
        let source = DispatchSource.makeReadSource(fileDescriptor: connected, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(fd: connected, generation: token) }
        source.setCancelHandler { close(connected) }
        readSource = source; source.resume()
        request(CodexIPCOperation(method: "initialize", version: 0, params: .object(["clientType": .string("critter")])), owner: nil) { [weak self] reply in
            guard let self else { return }
            guard case .success(let result) = reply, let id = result["clientId"]?.stringValue, !id.isEmpty else {
                disconnect(); scheduleRetry(); return
            }
            clientID = id; retryDelay = 1; reason = "Codex 会话尚未确认归属"
            for thread in desired { discover(thread) }
            onChange()
        }
    }
    private func discover(_ thread: String) {
        guard clientID != nil, !discovering.contains(thread), desired.contains(thread) else { return }
        discovering.insert(thread)
        let id = UUID().uuidString
        sendRequest(id: id, operation: CodexIPCOperation(method: "thread-owner-discovery", version: 1,
            params: .object(["hostId": .string("local"), "conversationId": .string(thread)])), owner: nil) { [weak self] reply, envelope in
            guard let self else { return }
            discovering.remove(thread)
            guard desired.contains(thread), case .success(let result) = reply,
                  let owner = envelope?["handledByClientId"]?.stringValue, !owner.isEmpty,
                  result["supportsUntrustedAppInput"]?.ipcBool == true else { onChange(); return }
            conversations[thread] = CodexIPCConversation(threadID: thread, ownerID: owner, canReceiveInput: true)
            follow(thread, owner: owner, on: true)
        }
    }
    private func follow(_ thread: String, owner: String, on: Bool) {
        guard let clientID else { return }
        _ = send(.object(["type": .string("broadcast"), "method": .string("thread-stream-following-changed"),
            "version": .number(1), "sourceClientId": .string(clientID), "targetClientIds": .array([.string(owner)]),
            "params": .object(["hostId": .string("local"), "conversationId": .string(thread), "following": .bool(on)])]))
    }
    private func request(_ operation: CodexIPCOperation, owner: String?, completion: @escaping @Sendable (Reply) -> Void) {
        sendRequest(id: UUID().uuidString, operation: operation, owner: owner) { reply, _ in completion(reply) }
    }
    private var responseEnvelopes: [String: JSONValue] = [:]
    private func sendRequest(id: String, operation: CodexIPCOperation, owner: String?, completion: @escaping @Sendable (Reply, JSONValue?) -> Void) {
        guard fd >= 0 else { completion(.failure, nil); return }
        var envelope: [String: JSONValue] = ["type": .string("request"), "requestId": .string(id),
            "sourceClientId": .string(clientID ?? "initializing-client"), "method": .string(operation.method),
            "version": .number(Double(operation.version)), "params": operation.params, "timeoutMs": .number(timeout * 1000)]
        if let owner { envelope["targetClientId"] = .string(owner) }
        waiting[id] = Waiting(method: operation.method, owner: owner) { [weak self] reply in
            let raw = self?.responseEnvelopes.removeValue(forKey: id)
            completion(reply, raw)
        }
        guard send(.object(envelope)) else {
            let pending = waiting.removeValue(forKey: id); pending?.complete(.failure)
            disconnect(); scheduleRetry(); return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let pending = waiting.removeValue(forKey: id) else { return }
            pending.complete(.timeout)
        }
    }
    private func readAvailable(fd: Int32, generation: Int) {
        guard self.fd == fd, self.generation == generation else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                do { for message in try framing.append(Data(bytes.prefix(count))) { receive(message) } }
                catch { disconnect(); reason = "Codex 控制协议不兼容，当前仅可查看"; scheduleRetry(); return }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { disconnect(); scheduleRetry(); return }
        }
    }
    private func receive(_ message: JSONValue) {
        if message["type"]?.stringValue == "client-discovery-request", let id = message["requestId"] {
            // Critter follows existing owners; it must never advertise ownership itself.
            _ = send(.object(["type": .string("client-discovery-response"), "requestId": id,
                              "response": .object(["canHandle": .bool(false)])]))
            return
        }
        if message["type"]?.stringValue == "response", let id = message["requestId"]?.stringValue,
           let pending = waiting.removeValue(forKey: id) {
            let success = message["resultType"]?.stringValue == "success" && message["method"]?.stringValue == pending.method
                && (pending.owner == nil || message["handledByClientId"]?.stringValue == pending.owner)
            responseEnvelopes[id] = message
            let error = message["error"]?.stringValue ?? message["error"]?["message"]?.stringValue ?? ""
            let timedOut = error.lowercased().contains("timeout") || error.lowercased().contains("timed out")
            pending.complete(success ? .success(message["result"] ?? .null) : timedOut ? .timeout : .failure)
            return
        }
        guard message["type"]?.stringValue == "broadcast" else { return }
        if message["method"]?.stringValue == "client-status-changed" {
            if message["params"]?["status"]?.stringValue == "disconnected", let owner = message["params"]?["clientId"]?.stringValue {
                for thread in Array(conversations.keys) where conversations[thread]?.ownerID == owner { invalidate(thread) }
            } else if message["params"]?["status"]?.stringValue == "connected" {
                for thread in desired where conversations[thread] == nil { discover(thread) }
            }
            return
        }
        guard message["method"]?.stringValue == "thread-stream-state-changed", let params = message["params"],
              params["hostId"]?.stringValue == "local", let thread = params["conversationId"]?.stringValue,
              desired.contains(thread), var conversation = conversations[thread],
              let source = message["sourceClientId"]?.stringValue, source == conversation.ownerID else { return }
        guard message["version"]?.ipcInt == 11, let change = params["change"] else { invalidate(thread); return }
        if change["type"]?.stringValue == "snapshot" {
            // A fresh snapshot can follow a backend restart whose numeric request ids
            // were reused. Old phone cards never authorize this new local generation.
            issuedPrompts = issuedPrompts.filter { $0.value.prompt.pending.sessionId != "codex-" + thread }
        }
        let applied = conversation.apply(change: change, source: source)
        conversations[thread] = conversation
        refreshPrompts(); onChange()
        if !applied && conversation.revision == nil { follow(thread, owner: source, on: true) }
    }
    private func refreshPrompts() {
        var next: [String: CodexIPCPhoneRequest] = [:]
        var issued: [String: (owner: String, prompt: CodexIPCPhoneRequest)] = [:]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for conversation in conversations.values {
            for prompt in conversation.phoneRequests(now: now) {
                let key = prompt.pending.requestId
                let value: CodexIPCPhoneRequest
                if let old = issuedPrompts[key], old.owner == conversation.ownerID { value = old.prompt }
                else { value = prompt.scoped(to: UUID().uuidString) }
                issued[key] = (conversation.ownerID, value)
                next[value.pending.requestId] = value
            }
        }
        prompts = next
        issuedPrompts = issued
    }
    private func invalidate(_ thread: String) {
        conversations[thread] = nil; refreshPrompts(); onChange()
    }
    private func disconnect() {
        let old = Array(conversations.values)
        for value in old { follow(value.threadID, owner: value.ownerID, on: false) }
        readSource?.cancel(); readSource = nil; fd = -1; clientID = nil
        conversations = [:]; prompts = [:]; issuedPrompts = [:]; discovering = []; answering = []
        let pending = Array(waiting.values); waiting = [:]; responseEnvelopes = [:]
        for value in pending { value.complete(.timeout) }
        onChange()
    }
    private func scheduleRetry() {
        guard enabled, !desired.isEmpty, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay; retryDelay = min(60, retryDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            retryScheduled = false; connectIfNeeded()
        }
    }
    private func send(_ message: JSONValue) -> Bool {
        guard fd >= 0, let frame = try? CodexIPCFraming.encode(message) else { return false }
        var offset = 0
        let deadline = Date().addingTimeInterval(1)
        while offset < frame.count {
            let written = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, frame.count - offset) }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EINTR { continue }
            guard written < 0, errno == EAGAIN, Date() < deadline else { return false }
            var item = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&item, 1, 100) >= 0 else { return false }
        }
        return true
    }
    private static func openSocket(_ path: String) -> Int32? {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in for (i, value) in bytes.enumerated() { buffer[i] = value } }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        var success = false
        defer { if !success { close(socketFD) } }
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL) | O_NONBLOCK) == 0 else { return nil }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var item = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            guard poll(&item, 1, 500) > 0 else { return nil }
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(socketFD, &uid, &gid) == 0, uid == getuid() else { return nil }
        success = true; return socketFD
    }
}
