import Foundation

/// The existing Desktop/VS Code coordinator uses length-prefixed UTF-8 JSON, not JSONL.
/// Only the observed versions below are accepted; unknown coordinator versions stay read-only.
public struct CodexIPCFraming {
    public enum Failure: Error { case invalidLength, invalidJSON }
    public static let maxBytes = 32 * 1024 * 1024
    private var buffer = Data()
    public init() {}
    public static func encode(_ value: JSONValue) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= maxBytes else { throw Failure.invalidLength }
        var count = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(body)
        return frame
    }
    public mutating func append(_ bytes: Data) throws -> [JSONValue] {
        buffer.append(bytes)
        var values: [JSONValue] = []
        while buffer.count >= 4 {
            let count = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
            guard count > 0, count <= Self.maxBytes else { throw Failure.invalidLength }
            guard buffer.count >= count + 4 else { break }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(buffer.dropFirst(4).prefix(count))) else { throw Failure.invalidJSON }
            values.append(value)
            buffer.removeFirst(count + 4)
        }
        return values
    }
}

extension JSONValue {
    var ipcObject: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var ipcArray: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var ipcBool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var ipcInt: Int? { if case .number(let v) = self, v.isFinite, v.rounded(.towardZero) == v, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }; return nil }
}

public struct CodexIPCOperation: Sendable, Equatable {
    public var method: String
    public var version: Int
    public var params: JSONValue
}

public struct CodexIPCPhoneRequest: Sendable, Equatable {
    public private(set) var pending: PendingRequest
    public let originalID: JSONValue
    private let method: String
    private let params: JSONValue
    private let threadID: String

    public init?(threadID: String, raw: JSONValue, now: Int64) {
        guard UUID(uuidString: threadID) != nil, let id = raw["id"],
              id.stringValue != nil || id.ipcInt != nil,
              let method = raw["method"]?.stringValue, let params = raw["params"],
              params["threadId"]?.stringValue == nil || params["threadId"]?.stringValue == threadID else { return nil }
        var input: [String: JSONValue]
        let kind: PendingKind
        let summary: String
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            // Never silently expand a one-off approval into a session-wide policy grant.
            if let choices = params["availableDecisions"]?.ipcArray,
               !choices.contains(.string("accept")) || !choices.contains(.string("decline")) { return nil }
            input = ["command": .string(params["command"]?.stringValue ?? params["reason"]?.stringValue ?? "修改文件"),
                     "acceptsDenyMessage": .bool(false)]
            if let cwd = params["cwd"] { input["cwd"] = cwd }
            if let root = params["grantRoot"] { input["file_path"] = root }
            if let network = params["networkApprovalContext"] {
                input["command"] = .string("网络访问：" + (network["host"]?.stringValue ?? "") + " " + (network["protocol"]?.stringValue ?? ""))
            }
            kind = .permission; summary = method.contains("fileChange") ? "Codex 请求修改文件" : "Codex 请求执行操作"
        case "item/permissions/requestApproval":
            guard let permissions = params["permissions"], permissions.ipcObject != nil,
                  let data = try? JSONEncoder().encode(permissions), let text = String(data: data, encoding: .utf8), text.count <= 16_384 else { return nil }
            input = ["command": .string((params["reason"]?.stringValue ?? "Codex 请求本回合权限") + "\n" + text), "acceptsDenyMessage": .bool(false)]
            kind = .permission; summary = "Codex 请求本回合权限"
        case "item/tool/requestUserInput":
            guard let questions = params["questions"]?.ipcArray, !questions.isEmpty, questions.count <= 8 else { return nil }
            var texts: Set<String> = []; var ids: Set<String> = []; var normalized: [JSONValue] = []
            for question in questions {
                guard question["isSecret"]?.ipcBool != true,
                      let text = question["question"]?.stringValue, !text.isEmpty,
                      let id = question["id"]?.stringValue, !id.isEmpty,
                      texts.insert(text).inserted, ids.insert(id).inserted else { return nil }
                normalized.append(.object(["question": .string(text), "header": question["header"] ?? .string("Codex"),
                    "options": question["options"]?.ipcArray.map(JSONValue.array) ?? .array([]), "multiSelect": .bool(false)]))
            }
            input = ["questions": .array(normalized)]
            kind = .question; summary = "Codex 在问你问题"
        default: return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Hex.sha256((try? encoder.encode(JSONValue.array([.string(threadID), id, .string(method), params]))) ?? Data())
        self.threadID = threadID; self.method = method; self.params = params; originalID = id
        pending = PendingRequest(requestId: "codex-" + String(digest.prefix(40)), sessionId: "codex-" + threadID,
            kind: kind, toolName: "Codex", summary: summary, input: .object(input), matchKey: digest,
            createdAt: now, expiresAt: Int64.max, hookPid: getpid())
    }

    func scoped(to generation: String) -> CodexIPCPhoneRequest {
        var copy = self
        copy.pending.requestId = "codex-" + String(Hex.sha256(Data((generation + ":" + pending.requestId).utf8)).prefix(40))
        return copy
    }

    public func response(to answer: AnswerPayload) -> CodexIPCOperation? {
        guard let data = try? JSONEncoder().encode(pending.input),
              let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              AskDecision.validate(answer, kind: pending.kind, toolInput: input) else { return nil }
        var values: [String: JSONValue] = ["conversationId": .string(threadID), "requestId": originalID]
        let route: String
        switch method {
        case "item/commandExecution/requestApproval": route = "thread-follower-command-approval-decision"
        case "item/fileChange/requestApproval": route = "thread-follower-file-approval-decision"
        case "item/permissions/requestApproval":
            route = "thread-follower-permissions-request-approval-response"
            values["response"] = .object(["permissions": answer.decision == "allow" ? params["permissions"]! : .object([:]), "scope": .string("turn")])
        case "item/tool/requestUserInput":
            route = "thread-follower-submit-user-input"
            var result: [String: JSONValue] = [:]
            for question in params["questions"]?.ipcArray ?? [] {
                guard let id = question["id"]?.stringValue, let text = question["question"]?.stringValue,
                      let value = answer.answers?[text]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                result[id] = .object(["answers": .array([.string(value)])])
            }
            values["response"] = .object(["answers": .object(result)])
        default: return nil
        }
        if values["response"] == nil { values["decision"] = .string(answer.decision == "allow" ? "accept" : "decline") }
        return CodexIPCOperation(method: route, version: 1, params: .object(values))
    }
}

/// A versioned snapshot from one positively discovered current thread owner.
public struct CodexIPCConversation: Sendable, Equatable {
    public let threadID: String
    public let ownerID: String
    public let canReceiveInput: Bool
    public private(set) var revision: Int?
    private var state: JSONValue = .object([:])

    public init(threadID: String, ownerID: String, canReceiveInput: Bool) {
        self.threadID = threadID; self.ownerID = ownerID; self.canReceiveInput = canReceiveInput
    }
    public mutating func apply(change: JSONValue, source: String) -> Bool {
        guard source == ownerID else { return false }
        guard let next = change["revision"]?.ipcInt else { revision = nil; return false }
        if change["type"]?.stringValue == "snapshot", let snapshot = change["conversationState"], snapshot.ipcObject != nil {
            guard revision == nil || next >= revision! else { revision = nil; return false }
            state = snapshot; revision = next; return true
        }
        guard change["type"]?.stringValue == "patches", change["baseRevision"]?.ipcInt == revision,
              let previous = revision, next > previous, let patches = change["patches"]?.ipcArray, patches.count <= 100_000 else { revision = nil; return false }
        var copy = state
        for patch in patches {
            guard let path = patch["path"]?.ipcArray, path.count <= 64,
                  let op = patch["op"]?.stringValue,
                  let updated = Self.patch(copy, path: ArraySlice(path), op: op, value: patch["value"]) else { revision = nil; return false }
            copy = updated
        }
        guard copy.ipcObject != nil else { revision = nil; return false }
        state = copy; revision = next; return true
    }
    private static func patch(_ root: JSONValue, path: ArraySlice<JSONValue>, op: String, value: JSONValue?) -> JSONValue? {
        guard let head = path.first else { return op == "remove" ? nil : value }
        let rest = path.dropFirst()
        if let key = head.stringValue, var object = root.ipcObject {
            if rest.isEmpty {
                switch op {
                case "remove": guard object.removeValue(forKey: key) != nil else { return nil }
                case "replace": guard object[key] != nil, let value else { return nil }; object[key] = value
                case "add": guard let value else { return nil }; object[key] = value
                default: return nil
                }
            } else {
                guard let child = object[key], let updated = patch(child, path: rest, op: op, value: value) else { return nil }
                object[key] = updated
            }
            return .object(object)
        }
        if let index = head.ipcInt, var array = root.ipcArray, index >= 0 {
            if rest.isEmpty {
                switch op {
                case "add": guard index <= array.count, let value else { return nil }; array.insert(value, at: index)
                case "replace": guard index < array.count, let value else { return nil }; array[index] = value
                case "remove": guard index < array.count else { return nil }; array.remove(at: index)
                default: return nil
                }
            } else {
                guard index < array.count, let updated = patch(array[index], path: rest, op: op, value: value) else { return nil }
                array[index] = updated
            }
            return .array(array)
        }
        return nil
    }
    public var isActive: Bool { revision != nil && state["threadRuntimeStatus"]?["type"]?.stringValue == "active" }
    public var isWaiting: Bool {
        guard revision != nil else { return false }
        if !(state["requests"]?.ipcArray ?? []).isEmpty { return true }
        return (state["threadRuntimeStatus"]?["activeFlags"]?.ipcArray ?? []).contains {
            $0.stringValue == "waitingOnApproval" || $0.stringValue == "waitingOnUserInput"
        }
    }
    public var activeTurnID: String? {
        guard isActive else { return nil }
        let canonical = state["turnHistory"]?["history"]?["entitiesByKey"]?.ipcObject.map { Array($0.values) } ?? []
        let legacy = state["turns"]?.ipcArray ?? []
        return (canonical + legacy).filter { $0["status"]?.stringValue == "inProgress" }
            .max { ($0["turnStartedAtMs"]?.ipcInt ?? 0) < ($1["turnStartedAtMs"]?.ipcInt ?? 0) }
            .flatMap { $0["turnId"]?.stringValue ?? $0["id"]?.stringValue }
    }
    public func phoneRequests(now: Int64) -> [CodexIPCPhoneRequest] {
        guard revision != nil, canReceiveInput else { return [] }
        return (state["requests"]?.ipcArray ?? []).compactMap { CodexIPCPhoneRequest(threadID: threadID, raw: $0, now: now) }
    }
    public var capabilities: BridgeCapabilities {
        let ready = revision != nil && canReceiveInput
        return BridgeCapabilities(canSay: ready, canAnswer: ready && !phoneRequests(now: 0).isEmpty,
            canInterrupt: ready && activeTurnID != nil, readOnlyReason: ready ? nil : "尚未连接此 Codex 会话的控制通道")
    }
    public var telemetry: CodexTelemetry? {
        guard revision != nil else { return nil }
        let info = state["latestTokenUsageInfo"]
        let usage = info?["last"] ?? info?["last_token_usage"] ?? info?["lastTokenUsage"]
        let model = state["latestModel"]?.stringValue
        let used = usage?["total_tokens"]?.ipcInt ?? usage?["totalTokens"]?.ipcInt
        let window = info?["model_context_window"]?.ipcInt ?? info?["modelContextWindow"]?.ipcInt
        guard model != nil || used != nil || window != nil else { return nil }
        return CodexTelemetry(model: model, usedTokens: used, contextWindow: window)
    }
    public func message(_ text: String) -> CodexIPCOperation? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard capabilities.canSay, !text.isEmpty, text.utf16.count <= BridgeProtocol.maxSayUTF16Units,
              let cwd = state["cwd"]?.stringValue, cwd.hasPrefix("/") else { return nil }
        let input = JSONValue.array([.object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])])
        let messageID = JSONValue.string(UUID().uuidString)
        let restore: JSONValue = .object(["id": messageID, "text": .string(text), "cwd": .string(cwd),
            "createdAt": .number(Date().timeIntervalSince1970 * 1000), "context": .object([
                "prompt": .string(text), "addedFiles": .array([]), "fileAttachments": .array([]),
                "ideContext": .null, "imageAttachments": .array([]), "workspaceRoots": .array([.string(cwd)])])])
        if isActive {
            return CodexIPCOperation(method: "thread-follower-steer-turn", version: 1,
                params: .object(["conversationId": .string(threadID), "input": input, "clientUserMessageId": messageID, "restoreMessage": restore]))
        }
        return CodexIPCOperation(method: "thread-follower-start-turn", version: 2, params: .object(["conversationId": .string(threadID),
            "turnStart": .object(["request": .object(["threadId": .string(threadID), "input": input, "clientUserMessageId": messageID]),
                                 "context": .object(["inheritThreadSettings": .bool(true), "restoreMessage": restore])])]))
    }
    public func interrupt() -> CodexIPCOperation? {
        guard capabilities.canInterrupt, let turn = activeTurnID else { return nil }
        return CodexIPCOperation(method: "thread-follower-interrupt-turn", version: 4,
            params: .object(["conversationId": .string(threadID), "mode": .string("user-stop"), "expectedTurnId": .string(turn)]))
    }
}
