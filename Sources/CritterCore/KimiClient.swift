import Foundation

/// The WebSocket and REST calls `KimiClient` makes, behind a protocol so tests can play the
/// server. Callbacks may come on any thread.
public protocol KimiTransport: AnyObject, Sendable {
    /// Opens the event socket, replacing any earlier one. `onClose` fires once if it fails or drops.
    func connect(port: Int, token: String, onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)
    func send(_ data: Data)
    func close()
    /// The response body, or nil on a transport error. An HTTP 401 comes back as `{"code":401}`.
    func request(port: Int, token: String, method: String, path: String, body: Data?, completion: @escaping @Sendable (Data?) -> Void)
}

/// `KimiTransport` over `URLSession`: `ws://127.0.0.1:<port>/api/v1/ws` and REST on the same
/// port, both with `Authorization: Bearer <token>`, no proxy, 5 s timeouts.
public final class URLSessionKimiTransport: KimiTransport, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        // Loopback only: a system proxy (or one for 127.0.0.1) must never see the token.
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    public func connect(port: Int, token: String, onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/v1/ws") else { onClose(); return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let next = session.webSocketTask(with: request)
        let old = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { task = next }
            return task
        }
        old?.cancel(with: .goingAway, reason: nil)
        receive(on: next, onFrame: onFrame, onClose: onClose)
        next.resume()
    }

    private func receive(on task: URLSessionWebSocketTask, onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)): onFrame(Data(text.utf8))
            case .success(.data(let data)): onFrame(data)
            case .success: break
            case .failure:
                // A socket closed by `close()` or a newer `connect` reports nothing.
                let current = lock.withLock { () -> Bool in
                    guard self.task === task else { return false }
                    self.task = nil
                    return true
                }
                if current { onClose() }
                return
            }
            receive(on: task, onFrame: onFrame, onClose: onClose)
        }
    }

    public func send(_ data: Data) {
        let current = lock.withLock { task }
        current?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    public func close() {
        let old = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { task = nil }
            return task
        }
        old?.cancel(with: .normalClosure, reason: nil)
    }

    public func request(port: Int, token: String, method: String, path: String, body: Data?, completion: @escaping @Sendable (Data?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)" + path) else { completion(nil); return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: request) { data, response, error in
            guard error == nil else { completion(nil); return }
            if (response as? HTTPURLResponse)?.statusCode == 401 { completion(Data(#"{"code":401}"#.utf8)); return }
            completion(data)
        }.resume()
    }
}

/// A second client of Kimi Code's local server (spec: "Kimi Code"). It never creates sessions or
/// prompts: it turns sessions that do something into pet records in `StateStore` (as
/// `CodexSessionSync` does for rollouts) and answers their approvals and questions for phones.
///
/// Sessions idle when Critter connects stay out (`KimiSessionState.admitted`). Global
/// `event.session.*` frames cover every session; a session that becomes busy is subscribed for
/// its turn, tool, approval and question events. Records belong to the live server's pid: when
/// it changes or goes away, the old ones are deleted. All state lives on one serial queue.
public final class KimiClient: @unchecked Sendable {
    public static let notConnected = "尚未连接 Kimi Code"
    static let readOnlyReason = "Kimi Code 会话暂不支持从手机发消息"
    static let pageSize = 100
    static let sessionsPath = "/api/v1/sessions?busy=false&include_archive=false&exclude_empty=true&archived_only=false&page_size=\(pageSize)"
    /// Codes that mean the approval or question is no longer there to answer.
    static let goneCodes: Set<Int> = [40401, 40404, 40902]

    private let queue = DispatchQueue(label: "local.critter.kimi", qos: .utility)
    private let paths: CritterPaths
    private let store: StateStore
    private let transport: KimiTransport
    private let now: @Sendable () -> Int64
    private let isAlive: @Sendable (Int32) -> Bool
    private let executablePath: @Sendable (Int32) -> String?
    private let startTime: @Sendable (Int32) -> Int64?
    private let onChange: @Sendable () -> Void

    private var enabled = false
    private var watcher: DirectoryWatcher?
    private var retryScheduled = false
    private var retryDelay: TimeInterval = 1
    /// Bumped on every connect and disconnect: callbacks of an older connection are dropped.
    private var generation = 0
    private var instance: KimiInstance?
    private var token: String?
    /// `server_hello` came in.
    private var connected = false
    private var entrypoint = "kimi-desktop"
    private var ownerStartTime: Int64?
    private var sessions: [String: KimiSessionState] = [:]
    private var subscribed: Set<String> = []
    /// Record ids of sessions that were pets on an earlier connection: their capabilities say why
    /// they can't be answered now.
    private var known: Set<String> = []
    private var prompts: [String: KimiPhoneRequest] = [:]
    /// Requests resolved on this connection, so a REST list that crossed the event can't bring one back.
    private var resolved: Set<String> = []
    private var answering: Set<String> = []
    private var listing = false
    private var listAgain = false
    private var frameID = 0

    public init(paths: CritterPaths, transport: KimiTransport = URLSessionKimiTransport(),
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                isAlive: @escaping @Sendable (Int32) -> Bool = ProcessTools.isAlive,
                executablePath: @escaping @Sendable (Int32) -> String? = ProcessTools.executablePath,
                startTime: @escaping @Sendable (Int32) -> Int64? = ProcessTools.startTime,
                onChange: @escaping @Sendable () -> Void = {}) {
        self.paths = paths
        store = StateStore(paths: paths)
        self.transport = transport
        self.now = now
        self.isAlive = isAlive
        self.executablePath = executablePath
        self.startTime = startTime
        self.onChange = onChange
    }

    public func start() { queue.async { [self] in enabled = true; evaluate() } }
    public func stop() {
        queue.async { [self] in
            enabled = false
            watcher?.stop(); watcher = nil
            disconnect()
        }
    }
    /// Looks at the instance files again now (instead of at the next retry).
    public func refresh() { queue.async { [self] in evaluate() } }

    public var requests: [KimiPhoneRequest] {
        queue.sync { prompts.values.sorted { ($0.pending.createdAt, $0.pending.requestId) < ($1.pending.createdAt, $1.pending.requestId) } }
    }
    public var capabilities: [String: BridgeCapabilities] {
        queue.sync {
            let value = connected
                ? BridgeCapabilities(canSay: false, canAnswer: true, canInterrupt: false, readOnlyReason: Self.readOnlyReason)
                : BridgeCapabilities(readOnlyReason: Self.notConnected)
            let ids = known.union(sessions.values.filter(\.admitted).map { KimiReducer.sessionId($0.id) })
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, value) })
        }
    }
    public var statusText: String { queue.sync { connected ? "已连接 Kimi Code" : Self.notConnected } }
    /// Kimi session ids known on this connection, pets or not.
    var trackedSessionIDs: Set<String> { queue.sync { Set(sessions.keys) } }

    private final class AnswerBox: @unchecked Sendable {
        let lock = NSLock()
        var value: AnswerOutcome = .failed
        let done = DispatchSemaphore(value: 0)
        func finish(_ value: AnswerOutcome) { lock.withLock { self.value = value }; done.signal() }
    }

    public func answer(_ payload: AnswerPayload, requestID: String) -> AnswerOutcome {
        let box = AnswerBox()
        queue.async { [self] in
            guard connected, !answering.contains(requestID), let prompt = prompts[requestID], let instance, let token else {
                box.finish(.alreadyAnswered); return
            }
            guard let (path, json) = prompt.body(for: payload), let body = try? JSONSerialization.data(withJSONObject: json) else {
                box.finish(.failed); return
            }
            answering.insert(requestID)
            transport.request(port: instance.port, token: token, method: "POST", path: path, body: body) { [weak self] data in
                guard let self else { box.finish(.failed); return }
                queue.async { [self] in
                    answering.remove(requestID)
                    let code = Self.envelope(data)?.code
                    let outcome: AnswerOutcome = code == 0 ? .accepted : code.map(Self.goneCodes.contains) == true ? .alreadyAnswered : .failed
                    if outcome != .failed { withdraw(requestID) }
                    box.finish(outcome)
                }
            }
        }
        guard box.done.wait(timeout: .now() + 6) == .success else { return .failed }
        return box.lock.withLock { box.value }
    }

    // MARK: - Connection

    private func evaluate() {
        guard enabled else { return }
        watchInstances()
        guard let live = KimiDiscovery.live(KimiDiscovery.instances(in: paths.kimiInstancesDir), now: now(), isAlive: isAlive) else {
            if instance != nil { disconnect() }
            removeRecords { _ in true }
            scheduleRetry()
            return
        }
        if let instance, instance.serverId == live.serverId, instance.pid == live.pid, instance.port == live.port { return }
        if instance != nil { disconnect() }
        removeRecords { $0.claudePid != live.pid }
        connect(to: live)
    }

    /// Watched once Kimi Code's home exists; until then (Kimi not installed) the retries look.
    private func watchInstances() {
        guard watcher == nil, FileManager.default.fileExists(atPath: paths.kimiHome.path) else { return }
        let next = DirectoryWatcher(url: paths.kimiInstancesDir, queue: queue, debounce: 0.2) { [weak self] in self?.evaluate() }
        watcher = next
        next.start()
    }

    private func connect(to live: KimiInstance) {
        // Read fresh every time: Kimi Code may have made a new one.
        guard let raw = try? String(contentsOf: paths.kimiTokenFile, encoding: .utf8),
              case let token = raw.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { scheduleRetry(); return }
        generation += 1
        let current = generation
        instance = live
        self.token = token
        entrypoint = executablePath(live.pid)?.contains("/Kimi Code.app/") == true ? "kimi-desktop" : "kimi-cli"
        ownerStartTime = startTime(live.pid)
        transport.connect(port: live.port, token: token, onFrame: { [weak self] data in
            self?.queue.async { [weak self] in
                guard let self, generation == current else { return }
                receive(data)
            }
        }, onClose: { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, generation == current else { return }
                disconnect()
                scheduleRetry()
            }
        })
    }

    /// Keeps the records (the server may be back in a moment); `evaluate` decides about them.
    private func disconnect() {
        generation += 1
        if instance != nil { transport.close() }
        let changed = connected || !prompts.isEmpty
        known.formUnion(sessions.values.filter(\.admitted).map { KimiReducer.sessionId($0.id) })
        instance = nil; token = nil; connected = false
        sessions = [:]; subscribed = []; prompts = [:]; resolved = []; answering = []
        listing = false; listAgain = false
        if changed { onChange() }
    }

    /// 1 s, doubling up to 30 s, while there is nothing to talk to.
    private func scheduleRetry() {
        guard enabled, !retryScheduled else { return }
        retryScheduled = true
        let delay = retryDelay
        retryDelay = min(30, retryDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            evaluate()
        }
    }

    // MARK: - Frames

    private func receive(_ data: Data) {
        guard let frame = KimiFrame.decode(data) else { return }
        let payload = frame.payload
        switch frame.type {
        case "server_hello":
            connected = true
            retryDelay = 1
            send(["type": .string("client_hello"), "id": nextID(), "payload": .object(["client_id": .string("critter")])])
            listSessions()
            onChange()
        case "ping":
            send(["type": .string("pong"), "payload": .object(["nonce": payload["nonce"] ?? .string("")])])
        case "ack":
            for case .string(let id) in payload["resync_required"]?.ipcArray ?? [] { resync(id) }
        case "resync_required":
            if let id = payload["session_id"]?.stringValue ?? frame.sessionId { resync(id) }
        case "event.session.created":
            guard let fresh = KimiReducer.initial(session: payload["session"] ?? .null), KimiPhoneRequest.isPlainId(fresh.id),
                  sessions[fresh.id] == nil else { return }
            sessions[fresh.id] = fresh
            settle(fresh.id, previous: nil)
        case "event.session.archived", "event.session.deleted":
            if let id = frame.sessionId { forget(id) }
        default:
            guard let id = frame.sessionId else { return }
            guard let old = sessions[id] else {
                // Made before Critter listed, or missed: the list has its cwd.
                if frame.type == "event.session.work_changed" { listSessions() }
                return
            }
            track(frame, session: id)
            sessions[id] = KimiReducer.reduce(old, frame: frame)
            settle(id, previous: old)
        }
    }

    /// Phone requests come and go with these frames.
    private func track(_ frame: KimiFrame, session id: String) {
        switch frame.type {
        case "event.approval.requested", "event.question.requested":
            add(frame)
        case "event.approval.resolved":
            if let approval = frame.payload["approval_id"]?.stringValue { withdraw("kimi-" + approval) }
        case "event.question.answered", "event.question.dismissed":
            if let question = frame.payload["question_id"]?.stringValue { withdraw("kimi-" + question) }
        case "turn.ended" where KimiReducer.isMainAgent(frame.payload):
            let before = prompts.count
            prompts = prompts.filter { $0.value.kimiSessionId != id }
            if prompts.count != before { onChange() }
        default:
            break
        }
    }

    private func add(_ frame: KimiFrame) {
        guard let instance, let request = KimiPhoneRequest(frame: frame, now: now(), ownerPid: instance.pid),
              !resolved.contains(request.pending.requestId), prompts[request.pending.requestId] == nil else { return }
        prompts[request.pending.requestId] = request
        onChange()
    }

    private func withdraw(_ requestID: String) {
        if resolved.count > 1_000 { resolved = [] }
        resolved.insert(requestID)
        if prompts.removeValue(forKey: requestID) != nil { onChange() }
    }

    /// An admitted session is subscribed and has its record; a turn that just completed fetches
    /// its last assistant message for the bubble.
    private func settle(_ id: String, previous: KimiSessionState?) {
        guard let state = sessions[id], state.admitted else { return }
        if !subscribed.contains(id) {
            subscribed.insert(id)
            send(["type": .string("subscribe"), "id": nextID(), "payload": .object(["session_ids": .array([.string(id)])])])
            fetchPending(id, replace: false)
        }
        write(state)
        if let previous, previous.state != .done, state.state == .done { fetchLastMessage(id) }
    }

    private func write(_ state: KimiSessionState) {
        guard let instance else { return }
        var changed = false
        try? store.update(sessionId: KimiReducer.sessionId(state.id)) { previous in
            let next = KimiReducer.record(for: state, owner: instance, ownerStartTime: ownerStartTime, entrypoint: entrypoint,
                                          previous: previous, now: now())
            guard next != previous else { return .ignore }
            changed = true
            return .write(next)
        }
        if changed { onChange() }
    }

    private func forget(_ id: String) {
        sessions[id] = nil
        subscribed.remove(id)
        known.remove(KimiReducer.sessionId(id))
        prompts = prompts.filter { $0.value.kimiSessionId != id }
        store.delete(sessionId: KimiReducer.sessionId(id))
        onChange()
    }

    private func resync(_ id: String) {
        listSessions()
        if sessions[id] != nil { fetchPending(id, replace: true) }
    }

    /// Deletes Kimi records `predicate` picks, each only if it is still the one judged.
    private func removeRecords(_ predicate: (SessionRecord) -> Bool) {
        var removed = false
        for record in store.readAll() where SessionSource(entrypoint: record.entrypoint).isKimi && predicate(record) {
            try? store.update(sessionId: record.sessionId) { current in
                guard current?.claudePid == record.claudePid else { return .ignore }
                removed = true
                return .delete
            }
        }
        if removed { onChange() }
    }

    // MARK: - REST

    private func listSessions() {
        guard connected else { return }
        if listing { listAgain = true; return }
        listing = true
        get(Self.sessionsPath) { [self] data in
            listing = false
            if let items = data?["items"]?.ipcArray { merge(items) }
            if listAgain { listAgain = false; listSessions() }
        }
    }

    /// New sessions join (a record of this server's from before makes them pets again); known
    /// ones are corrected like `work_changed`. A complete list also drops what is gone.
    private func merge(_ items: [JSONValue]) {
        guard let instance else { return }
        let records = Dictionary(store.readAll().filter { SessionSource(entrypoint: $0.entrypoint).isKimi && $0.claudePid == instance.pid }
            .map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        var listed: Set<String> = []
        for item in items {
            guard var fresh = KimiReducer.initial(session: item), KimiPhoneRequest.isPlainId(fresh.id) else { continue }
            listed.insert(fresh.id)
            if var old = sessions[fresh.id] {
                old.cwd = fresh.cwd; old.title = fresh.title
                sessions[fresh.id] = KimiReducer.reduce(old, frame: KimiFrame(type: "event.session.work_changed", sessionId: fresh.id, payload: item))
                settle(fresh.id, previous: old)
                continue
            }
            if let record = records[KimiReducer.sessionId(fresh.id)] {
                if !fresh.admitted, [.idle, .done, .error].contains(record.state) {
                    fresh.state = record.state
                    fresh.detail = record.detail
                    fresh.activity = record.activity.flatMap(WorkActivity.init(rawValue:))
                    fresh.lastEvent = record.lastEvent.hasPrefix("Kimi:") ? String(record.lastEvent.dropFirst(5)) : fresh.lastEvent
                }
                fresh.admitted = true
            }
            sessions[fresh.id] = fresh
            settle(fresh.id, previous: nil)
        }
        guard items.count < Self.pageSize else { return }
        for id in Array(sessions.keys) where !listed.contains(id) { forget(id) }
        removeRecords { record in !listed.contains(String(record.sessionId.dropFirst(5))) }
    }

    /// Pending approvals and questions, as if their events had just come in. `replace` (after a
    /// resync, which means events were lost) first drops what the session had.
    private func fetchPending(_ id: String, replace: Bool) {
        for (route, type) in [("approvals", "event.approval.requested"), ("questions", "event.question.requested")] {
            get("/api/v1/sessions/\(id)/\(route)?status=pending") { [self] data in
                guard let items = data?["items"]?.ipcArray, let old = sessions[id] else { return }
                if replace {
                    let before = prompts.count
                    prompts = prompts.filter { $0.value.kimiSessionId != id || $0.value.isQuestion != (route == "questions") }
                    if prompts.count != before { onChange() }
                }
                var next = old
                for item in items {
                    let frame = KimiFrame(type: type, sessionId: id, payload: item)
                    guard let request = KimiPhoneRequest(frame: frame, now: now(), ownerPid: instance?.pid ?? 0),
                          !resolved.contains(request.pending.requestId) else { continue }
                    add(frame)
                    next = KimiReducer.reduce(next, frame: frame)
                }
                sessions[id] = next
                settle(id, previous: old)
            }
        }
    }

    private func fetchLastMessage(_ id: String) {
        get("/api/v1/sessions/\(id)/messages?role=assistant&page_size=20") { [self] data in
            guard var state = sessions[id], state.state == .done, let items = data?["items"]?.ipcArray,
                  let text = Self.lastAssistantText(items), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            state.detail = ToolSummary.firstSentence(text, max: 50)
            sessions[id] = state
            write(state)
        }
    }

    /// The text parts of the newest message: the greatest `created_at` where there is one, else the last.
    static func lastAssistantText(_ items: [JSONValue]) -> String? {
        let timed = items.compactMap { item in time(item["created_at"]).map { (item, $0) } }
        guard let newest = timed.max(by: { $0.1 < $1.1 })?.0 ?? items.last else { return nil }
        let parts = (newest["content"]?.ipcArray ?? []).filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func time(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number
        case .string(let text)?:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
        default: return nil
        }
    }

    /// GET on this connection; `completion` runs on the queue with the envelope's `data`, and not
    /// at all once the connection is gone. A 401 (the token changed) drops the connection.
    private func get(_ path: String, _ completion: @escaping @Sendable (JSONValue?) -> Void) {
        guard let instance, let token else { return }
        let current = generation
        transport.request(port: instance.port, token: token, method: "GET", path: path, body: nil) { [weak self] data in
            self?.queue.async { [weak self] in
                guard let self, generation == current else { return }
                let envelope = Self.envelope(data)
                if envelope?.code == 401 { disconnect(); scheduleRetry(); return }
                completion(envelope?.code == 0 ? envelope?.data : nil)
            }
        }
    }

    /// `{code, msg, data, request_id}`: anything but code 0 is a failure, even with HTTP 200.
    static func envelope(_ data: Data?) -> (code: Int, data: JSONValue)? {
        guard let data, let root = try? JSONDecoder().decode(JSONValue.self, from: data), let code = root["code"]?.ipcInt else { return nil }
        return (code, root["data"] ?? .null)
    }

    private func send(_ frame: [String: JSONValue]) {
        guard instance != nil, let data = try? JSONEncoder().encode(JSONValue.object(frame)) else { return }
        transport.send(data)
    }

    private func nextID() -> JSONValue {
        frameID += 1
        return .string(String(frameID))
    }
}
