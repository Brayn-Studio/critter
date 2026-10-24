import Foundation

// Kimi Code's local server, as seen by a second, read-mostly client (design spec, "Kimi Code
// 1.1.2"). Everything here is pure -- but for `KimiDiscovery.instances`, which reads the
// instance files -- so `KimiClient` only moves frames and REST bodies through it.

/// One running Kimi Code server, from `~/.kimi-code/server/instances/<server_id>.json`. The pid
/// is the Kimi Code app's main process (or the CLI's), which owns every session it serves.
public struct KimiInstance: Equatable, Sendable {
    public var serverId: String
    public var pid: Int32
    public var host: String
    public var port: Int
    /// Epoch milliseconds.
    public var startedAt: Int64
    /// Epoch milliseconds; the server rewrites its file while it runs.
    public var heartbeatAt: Int64

    public init(serverId: String, pid: Int32, host: String, port: Int, startedAt: Int64, heartbeatAt: Int64) {
        self.serverId = serverId
        self.pid = pid
        self.host = host
        self.port = port
        self.startedAt = startedAt
        self.heartbeatAt = heartbeatAt
    }
}

public enum KimiDiscovery {
    /// An instance whose heartbeat is older than this is gone, even if its pid lives on.
    public static let heartbeatTimeoutMs: Int64 = 60_000

    /// Every well-formed instance file in `dir`; malformed and hidden files are skipped.
    public static func instances(in dir: URL) -> [KimiInstance] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let serverId = root["server_id"] as? String, !serverId.isEmpty,
                  let pid = (root["pid"] as? NSNumber)?.int32Value, pid > 0,
                  let port = (root["port"] as? NSNumber)?.intValue, (1...65_535).contains(port),
                  let startedAt = (root["started_at"] as? NSNumber)?.int64Value,
                  let heartbeatAt = (root["heartbeat_at"] as? NSNumber)?.int64Value else { return nil }
            return KimiInstance(serverId: serverId, pid: pid, host: root["host"] as? String ?? "127.0.0.1",
                                port: port, startedAt: startedAt, heartbeatAt: heartbeatAt)
        }
    }

    /// The instance to connect to: its pid alive and its heartbeat fresh; the newest start wins.
    public static func live(_ all: [KimiInstance], now: Int64, isAlive: (Int32) -> Bool) -> KimiInstance? {
        all.filter { isAlive($0.pid) && now - $0.heartbeatAt <= heartbeatTimeoutMs }.max { $0.startedAt < $1.startedAt }
    }
}

/// One WebSocket frame: `{type, seq, epoch, session_id, timestamp, payload}`. The type is read
/// from the top level (the payload repeats it); global frames carry `session_id: "__global__"`
/// and name their session inside the payload instead.
public struct KimiFrame: Equatable, Sendable {
    public var type: String
    public var sessionId: String?
    public var payload: JSONValue

    public static let globalSession = "__global__"

    public init(type: String, sessionId: String?, payload: JSONValue) {
        self.type = type
        self.sessionId = sessionId
        self.payload = payload
    }

    public static func decode(_ data: Data) -> KimiFrame? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = root["type"]?.stringValue, !type.isEmpty else { return nil }
        let payload = root["payload"] ?? .object([:])
        var session = root["session_id"]?.stringValue
        if session == nil || session == globalSession {
            session = payload["sessionId"]?.stringValue ?? payload["session_id"]?.stringValue ?? payload["session"]?["id"]?.stringValue
        }
        return KimiFrame(type: type, sessionId: session == globalSession ? nil : session, payload: payload)
    }
}

/// What Critter knows about one Kimi session. `admitted`: it has done something since Critter
/// connected -- only admitted sessions become pets, so a long list of old, idle chats doesn't.
public struct KimiSessionState: Equatable, Sendable {
    public var id: String
    public var cwd: String
    public var title: String?
    public var state: PetState
    public var detail: String?
    public var activity: WorkActivity?
    public var admitted: Bool
    /// The frame type that last changed this state (`KimiSession` for the initial one).
    public var lastEvent: String
    /// Approval and question ids still open in the session: it keeps waiting until the last one closes.
    public var openRequests: Set<String>

    public init(id: String, cwd: String, title: String?, state: PetState, detail: String?,
                activity: WorkActivity?, admitted: Bool, lastEvent: String, openRequests: Set<String> = []) {
        self.openRequests = openRequests
        self.id = id
        self.cwd = cwd
        self.title = title
        self.state = state
        self.detail = detail
        self.activity = activity
        self.admitted = admitted
        self.lastEvent = lastEvent
    }
}

extension KimiSessionState {
    fileprivate func with(openRequests: Set<String>) -> KimiSessionState {
        var copy = self
        copy.openRequests = openRequests
        return copy
    }
}

public enum KimiReducer {
    static let confirm = "需要你确认"
    static let failed = "出错了"
    /// Both Kimi entrypoints read the same; the desktop one stands for them.
    static let question = BubbleText.askQuestion(entrypoint: "kimi-desktop")

    /// The record id for a Kimi session id.
    public static func sessionId(_ kimiId: String) -> String { "kimi-" + kimiId }

    /// From a session object (REST list, `event.session.created`): `id`, `metadata.cwd`, `title`,
    /// `busy`, `pending_interaction`. Nil without an id or a cwd.
    public static func initial(session: JSONValue) -> KimiSessionState? {
        guard let id = session["id"]?.stringValue, !id.isEmpty,
              let cwd = session["metadata"]?["cwd"]?.stringValue, !cwd.isEmpty else { return nil }
        var next = KimiSessionState(id: id, cwd: cwd, title: session["title"]?.stringValue, state: .idle, detail: nil,
                                    activity: nil, admitted: false, lastEvent: "KimiSession")
        switch session["pending_interaction"]?.stringValue {
        case "approval": wait(&next, confirm)
        case "question": wait(&next, question)
        default: if session["busy"]?.ipcBool == true { think(&next) }
        }
        return next
    }

    public static func reduce(_ s: KimiSessionState, frame: KimiFrame) -> KimiSessionState {
        let payload = frame.payload
        var next = s
        switch frame.type {
        case "turn.started":
            guard isMainAgent(payload) else { return s }
            next.openRequests = []
            think(&next)
        case "tool.call.started":
            // A call that starts while a request is open does not answer it.
            guard s.state != .waiting else { return s }
            let name = payload["name"]?.stringValue ?? "Kimi"
            next.admitted = true
            next.state = .running
            next.activity = WorkActivity.forTool(claudeName(name))
            next.detail = ToolSummary.activity(toolName: claudeName(name), input: claudeInput(payload["args"]))
        case "tool.result":
            guard s.state != .waiting else { return s }
            think(&next)
        case "event.approval.requested":
            if let id = payload["approval_id"]?.stringValue { next.openRequests.insert(id) }
            wait(&next, ToolSummary.permission(toolName: payload["tool_name"]?.stringValue ?? "Kimi",
                                               input: displayInput(payload["tool_input_display"])))
        case "event.question.requested":
            if let id = payload["question_id"]?.stringValue { next.openRequests.insert(id) }
            wait(&next, question)
        case "event.approval.resolved", "event.question.answered", "event.question.dismissed":
            guard s.state == .waiting else { return s }
            for key in ["approval_id", "question_id"] {
                if let id = payload[key]?.stringValue { next.openRequests.remove(id) }
            }
            guard next.openRequests.isEmpty else { return s.with(openRequests: next.openRequests) }
            think(&next)
        case "turn.ended":
            guard isMainAgent(payload) else { return s }
            switch payload["reason"]?.stringValue {
            case "completed": settle(&next, .done, BubbleText.done)
            case "failed":
                let message = payload["error"]?["message"]?.stringValue ?? ""
                settle(&next, .error, message.isEmpty ? failed : BubbleText.errorPrefix + ToolSummary.truncate(message, max: 50))
            default: settle(&next, .idle, nil) // cancelled, blocked
            }
            next.openRequests = []
        case "event.session.work_changed":
            guard let changed = workChanged(s, payload) else { return s }
            next = changed
        default:
            return s
        }
        next.lastEvent = frame.type
        return next
    }

    /// `work_changed` arrives for every session, subscribed or not, so it only corrects for
    /// events Critter missed; nil leaves the state as it is.
    private static func workChanged(_ s: KimiSessionState, _ payload: JSONValue) -> KimiSessionState? {
        var next = s
        switch payload["pending_interaction"]?.stringValue {
        case "approval", "question":
            guard s.state != .waiting else { return nil }
            wait(&next, payload["pending_interaction"]?.stringValue == "approval" ? confirm : question)
        default:
            if payload["busy"]?.ipcBool == true {
                guard !s.admitted || [.idle, .done, .error].contains(s.state) else { return nil }
                think(&next)
            } else {
                guard s.state == .running || s.state == .waiting else { return nil }
                switch payload["last_turn_reason"]?.stringValue {
                case "completed": settle(&next, .done, BubbleText.done)
                case "failed": settle(&next, .error, failed)
                default: settle(&next, .idle, nil)
                }
            }
        }
        return next
    }

    /// The pet's record. Unchanged state keeps the previous record as it is (event time
    /// included), and a result the user has already seen (`Seen`) stays seen.
    public static func record(for s: KimiSessionState, owner: KimiInstance, ownerStartTime: Int64?, entrypoint: String,
                              previous: SessionRecord?, now: Int64) -> SessionRecord {
        var next = SessionRecord(schema: 1, sessionId: sessionId(s.id), cwd: s.cwd, transcriptPath: nil, state: s.state,
                                 detail: s.detail, lastEvent: "Kimi:" + s.lastEvent, eventTime: now,
                                 createdAt: previous?.createdAt ?? now, claudePid: owner.pid, claudeStartTime: ownerStartTime,
                                 entrypoint: entrypoint, activity: s.activity?.rawValue)
        guard let previous else { return next }
        if previous.lastEvent == "Seen", s.state == .done {
            next.state = previous.state
            next.detail = previous.detail
            next.lastEvent = previous.lastEvent
            next.activity = previous.activity
        }
        var same = next
        same.eventTime = previous.eventTime
        if same == previous { return previous }
        next.eventTime = max(now, previous.eventTime)
        return next
    }

    // MARK: Helpers

    private static func think(_ s: inout KimiSessionState) {
        s.admitted = true; s.state = .running; s.activity = .think; s.detail = BubbleText.thinking
    }
    private static func wait(_ s: inout KimiSessionState, _ detail: String) {
        s.admitted = true; s.state = .waiting; s.activity = nil; s.detail = detail
    }
    private static func settle(_ s: inout KimiSessionState, _ state: PetState, _ detail: String?) {
        s.state = state; s.activity = nil; s.detail = detail
    }

    /// Subagents run turns of their own; only the main agent's start and end the session's.
    static func isMainAgent(_ payload: JSONValue) -> Bool {
        let agent = payload["agentId"]?.stringValue ?? payload["agent_id"]?.stringValue
        return agent == nil || agent == "main"
    }

    /// Kimi's built-in tools under the Claude names `WorkActivity` and `ToolSummary` know
    /// (Bash, Read, Write, Edit, Glob, Grep, WebSearch and Agent are the same).
    static func claudeName(_ name: String) -> String {
        switch name {
        case "FetchURL": return "WebFetch"
        case "AgentSwarm": return "Agent"
        default: return name
        }
    }

    /// Kimi's file tools name their file `path`; Claude's `file_path`.
    static func claudeInput(_ args: JSONValue?) -> JSONValue? {
        guard case .object(var values)? = args else { return args }
        if values["file_path"] == nil, let path = values["path"] { values["file_path"] = path }
        return .object(values)
    }

    /// An approval's `tool_input_display` as the input a phone shows, in Claude's keys.
    static func displayInput(_ display: JSONValue?) -> JSONValue {
        var input: [String: JSONValue] = [:]
        func copy(_ from: String, to key: String, limit: Int? = nil) {
            guard let value = display?[from]?.stringValue, !value.isEmpty else { return }
            input[key] = .string(limit.map { value.count > $0 ? String(value.prefix($0)) + "…" : value } ?? value)
        }
        switch display?["kind"]?.stringValue {
        case "command": copy("command", to: "command")
        case "file_io", "diff": copy("path", to: "file_path")
        case "url_fetch": copy("url", to: "url")
        case "search": copy("query", to: "query", limit: 4096)
        case "agent_call": copy("agent_name", to: "description", limit: 4096); copy("prompt", to: "prompt", limit: 4096)
        default: copy("summary", to: "description", limit: 4096)
        }
        return .object(input)
    }
}

/// An approval or question a phone can answer, published beside the hook-written requests.
/// Kimi's own window may answer first; `event.approval.resolved` / `event.question.*` then
/// withdraw it, and a late phone answer finds it gone.
public struct KimiPhoneRequest: Equatable, Sendable {
    public var pending: PendingRequest
    public var kimiSessionId: String
    /// The approval or question id.
    public var kimiId: String
    public var isQuestion: Bool
    /// Kimi's questions as asked, with the option ids answers must name.
    public var questions: [JSONValue]

    /// Ids end up in REST paths: only plain ones are taken.
    static func isPlainId(_ id: String?) -> Bool {
        guard let id, (1...120).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// From `event.approval.requested` / `event.question.requested` -- or a REST pending item
    /// handed in under that frame type.
    public init?(frame: KimiFrame, now: Int64, ownerPid: Int32) {
        let payload = frame.payload
        let session = payload["session_id"]?.stringValue ?? frame.sessionId
        guard Self.isPlainId(session), let session else { return nil }
        let kind: PendingKind
        let toolName: String
        let summary: String
        let input: JSONValue
        let id: String?
        var questions: [JSONValue] = []
        switch frame.type {
        case "event.approval.requested":
            id = payload["approval_id"]?.stringValue
            toolName = payload["tool_name"]?.stringValue ?? "Kimi"
            input = KimiReducer.displayInput(payload["tool_input_display"])
            kind = .permission
            summary = ToolSummary.permission(toolName: toolName, input: input)
        case "event.question.requested":
            id = payload["question_id"]?.stringValue
            guard let asked = payload["questions"]?.ipcArray, !asked.isEmpty, asked.count <= 8 else { return nil }
            var texts: Set<String> = []
            var normalized: [JSONValue] = []
            for question in asked {
                guard let text = question["question"]?.stringValue, !text.isEmpty, texts.insert(text).inserted,
                      Self.isPlainId(question["id"]?.stringValue) else { return nil }
                let options: [JSONValue] = (question["options"]?.ipcArray ?? []).compactMap { option in
                    guard let label = option["label"]?.stringValue else { return nil }
                    var shown: [String: JSONValue] = ["label": .string(label)]
                    if let description = option["description"]?.stringValue, !description.isEmpty { shown["description"] = .string(description) }
                    return .object(shown)
                }
                normalized.append(.object(["question": .string(text), "header": .string(question["header"]?.stringValue ?? "Kimi"),
                                           "multiSelect": .bool(question["multi_select"]?.ipcBool == true), "options": .array(options)]))
            }
            questions = asked
            toolName = "AskUserQuestion"
            input = .object(["questions": .array(normalized)])
            kind = .question
            summary = KimiReducer.question
        default:
            return nil
        }
        guard Self.isPlainId(id), let id else { return nil }
        self.kimiSessionId = session
        self.kimiId = id
        self.isQuestion = kind == .question
        self.questions = questions
        pending = PendingRequest(requestId: "kimi-" + id, sessionId: KimiReducer.sessionId(session), kind: kind, toolName: toolName,
                                 summary: summary, input: input, matchKey: id, createdAt: now, expiresAt: .max, hookPid: ownerPid)
    }

    /// The REST route and body that answer this request, or nil when the answer isn't one it
    /// can take (`AskDecision.validate`, or a free-text answer to a question that allows none).
    public func body(for answer: AnswerPayload) -> (path: String, json: [String: Any])? {
        guard let data = try? JSONEncoder().encode(pending.input),
              let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              AskDecision.validate(answer, kind: pending.kind, toolInput: input) else { return nil }
        let base = "/api/v1/sessions/\(kimiSessionId)"
        guard isQuestion else {
            var json: [String: Any] = ["decision": answer.decision == "allow" ? "approved" : "rejected"]
            let feedback = (answer.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.decision == "deny", !feedback.isEmpty { json["feedback"] = feedback }
            return (base + "/approvals/\(kimiId)", json)
        }
        var answers: [String: Any] = [:]
        for question in questions {
            guard let id = question["id"]?.stringValue, let text = question["question"]?.stringValue,
                  let value = answer.answers?[text]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let options = (question["options"]?.ipcArray ?? []).compactMap { option -> (label: String, id: String)? in
                guard let label = option["label"]?.stringValue, let id = option["id"]?.stringValue else { return nil }
                return (label, id)
            }
            func optionId(_ label: String) -> String? { options.first { $0.label == label }?.id }
            if question["multi_select"]?.ipcBool == true {
                let labels = value.components(separatedBy: AskDecision.multiSelectSeparator).map { $0.trimmingCharacters(in: .whitespaces) }
                let ids = labels.compactMap(optionId)
                if !ids.isEmpty, ids.count == labels.count {
                    answers[id] = ["kind": "multi", "option_ids": ids]
                    continue
                }
            } else if let option = optionId(value) {
                answers[id] = ["kind": "single", "option_id": option]
                continue
            }
            guard question["allow_other"]?.ipcBool != false else { return nil }
            answers[id] = ["kind": "other", "text": value]
        }
        return (base + "/questions/\(kimiId)", ["answers": answers])
    }
}
