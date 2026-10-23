import Foundation

/// Incremental, read-only adapter for Codex's local rollout JSONL. The initial read is
/// bounded to metadata plus a tail; subsequent reads only consume newly appended bytes.
/// Unknown records and incomplete final lines never change the current state.
public struct CodexRolloutReader {
    private var path: String?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var record: SessionRecord?
    private struct ActiveTool {
        var activity: WorkActivity
        var waiting: Bool
        var detail: String
        var references: Set<String>
    }
    private var activeTools: [String: ActiveTool] = [:]
    private var toolOrder: [String] = []
    private var backgroundCommands: Set<String> = []
    private var turnClosed = false
    private var creationEntrypoint: String?
    private static let initialTailBytes = 256 * 1024
    private static let maxLineBytes = 4 * 1024 * 1024
    private var droppingLongLine = false

    public init() {}

    public mutating func read(owner: CodexRolloutOwner) -> SessionRecord? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: owner.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let handle = FileHandle(forReadingAtPath: owner.path) else { return nil }
        defer { try? handle.close() }
        let fileID = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        if path != owner.path || inode != fileID || size < offset {
            self = CodexRolloutReader()
            path = owner.path
            inode = fileID
        }
        if record == nil {
            guard let header = try? handle.read(upToCount: Self.maxLineBytes),
                  let newline = header.firstIndex(of: 10),
                  let root = Self.json(Data(header[..<newline])),
                  root["type"] as? String == "session_meta",
                  let meta = root["payload"] as? [String: Any],
                  let id = meta["id"] as? String, UUID(uuidString: id) != nil,
                  let source = meta["source"] as? String,
                  !["exec", "mcp", "internal", "subagent"].contains(source.lowercased()),
                  let cwd = meta["cwd"] as? String else { return nil }
            let desktop = (meta["originator"] as? String)?.lowercased().contains("codex desktop") == true || source == "desktop"
            let metadataSource = SessionSource(entrypoint: source)
            let entrypoint = desktop ? "codex-desktop" : source == "cli" ? "codex-cli" : source == "vscode" ? "codex-vscode"
                : metadataSource.isCodex ? Self.entrypoint(for: metadataSource) : "codex"
            creationEntrypoint = entrypoint
            let created = Self.milliseconds(meta["timestamp"] as? String) ?? Self.milliseconds(root["timestamp"] as? String) ?? 0
            record = SessionRecord(schema: 1, sessionId: "codex-" + id, cwd: cwd, transcriptPath: owner.path,
                                   state: .idle, detail: nil, lastEvent: "CodexSession", eventTime: created, createdAt: created,
                                   claudePid: owner.pid, claudeStartTime: owner.startTime, entrypoint: entrypoint,
                                   telemetry: CodexTelemetry.updated(from: root, previous: nil))
            // Skip only the first partial line when beginning inside a large rollout.
            offset = size > UInt64(Self.initialTailBytes) ? size - UInt64(Self.initialTailBytes) : 0
            if offset > 0 {
                // Recover the line that spans the window boundary, including a large
                // completion. Bound the lookback so enormous outputs can't read history.
                let start = offset > UInt64(Self.maxLineBytes) ? offset - UInt64(Self.maxLineBytes) : 0
                guard (try? handle.seek(toOffset: start)) != nil,
                      let prefix = try? handle.read(upToCount: Int(offset - start)) else { return nil }
                if let newline = prefix.lastIndex(of: 10) {
                    offset = start + UInt64(prefix.distance(from: prefix.startIndex, to: newline)) + 1
                } else if start == 0 {
                    offset = 0
                } else {
                    droppingLongLine = true
                }
            }
        }
        guard (try? handle.seek(toOffset: offset)) != nil else { return record }
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            consume(chunk)
        }
        record?.claudePid = owner.pid
        record?.claudeStartTime = owner.startTime
        record?.entrypoint = owner.entrypoint.flatMap { SessionSource(entrypoint: $0).isCodex ? $0 : nil } ?? creationEntrypoint
        return record
    }

    private mutating func consume(_ chunk: Data) {
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if droppingLongLine { droppingLongLine = false; continue }
            if line.count <= Self.maxLineBytes, let root = Self.json(line) { apply(root) }
        }
        if pending.count > Self.maxLineBytes {
            pending.removeAll(keepingCapacity: false)
            droppingLongLine = true
        }
    }

    private mutating func apply(_ root: [String: Any]) {
        guard var next = record else { return }
        next.telemetry = CodexTelemetry.updated(from: root, previous: next.telemetry)
        record = next
        guard let payload = root["payload"] as? [String: Any], let type = payload["type"] as? String else { return }
        let envelope = root["type"] as? String
        let opensTurn = envelope == "event_msg" && ["task_started", "turn_started", "user_message"].contains(type)
        if turnClosed && !opensTurn { return }
        if let text = Self.publicProgress(payload, envelope: envelope), next.state != .done {
            if let timestamp = Self.milliseconds(root["timestamp"] as? String), timestamp < next.eventTime { return }
            next.progress = text
            if next.state != .waiting && next.state != .error {
                next.state = .running
                next.activity = currentActivity?.rawValue ?? "think"
                next.detail = text
            }
            next.lastEvent = "Codex:progress"
            next.eventTime = Self.milliseconds(root["timestamp"] as? String) ?? next.eventTime
            record = next
            return
        }
        var changed = true
        if envelope == "event_msg" {
            switch type {
            case "task_started", "turn_started":
                turnClosed = false
                activeTools = [:]; toolOrder = []; backgroundCommands = []; next.progress = nil
                next.state = .running; next.detail = BubbleText.thinking; next.activity = "think"
            case "user_message":
                turnClosed = false
                next.progress = nil
                next.state = .running; next.activity = currentActivity?.rawValue ?? "think"
                next.detail = currentDetail ?? BubbleText.thinking
            case "task_complete", "turn_complete":
                turnClosed = true
                activeTools = [:]; toolOrder = []; backgroundCommands = []
                next.state = .done; next.activity = nil
                let message = payload["last_agent_message"] as? String ?? ""
                next.detail = message.isEmpty ? BubbleText.done : ToolSummary.firstSentence(message, max: 80)
            case "turn_aborted":
                turnClosed = true
                activeTools = [:]; toolOrder = []; backgroundCommands = []; next.progress = nil
                next.state = .idle; next.detail = nil; next.activity = nil
            case "error":
                next.state = .error; next.activity = nil
                next.detail = BubbleText.errorPrefix + ToolSummary.truncate(payload["message"] as? String ?? "Codex", max: 80)
            case "exec_approval_request", "apply_patch_approval_request", "request_user_input":
                next.state = .waiting; next.activity = nil
                next.detail = type == "request_user_input" ? "Codex 在问你问题" : "需要你确认：Codex 操作"
            default: changed = false
            }
        } else if envelope == "response_item" {
            switch type {
            case "function_call", "custom_tool_call":
                let name = payload["name"] as? String ?? "Codex"
                let shortName = name.components(separatedBy: ".").last ?? name
                let input = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
                let args = Self.json(Data(input.utf8))
                let waiting = ["request_user_input", "request_user_input_async"].contains(shortName)
                let references = Self.toolReferences(input: input, args: args)
                let activity: WorkActivity = references.isDisjoint(with: backgroundCommands) ? Self.activity(shortName, input: input) : .bash
                let command = args?["cmd"] as? String ?? args?["command"] as? String
                let summary = waiting ? "Codex 在问你问题" : ToolSummary.truncate(command.map { "命令：" + $0 } ?? (activity == .bash ? "正在执行命令…" : name), max: 80)
                let callID = payload["call_id"] as? String ?? "anonymous"
                toolOrder.removeAll { $0 == callID }
                toolOrder.append(callID)
                activeTools[callID] = ActiveTool(activity: activity, waiting: waiting, detail: summary, references: references)
                next.state = waiting ? .waiting : .running
                next.activity = waiting ? nil : activity.rawValue
                next.detail = waiting ? summary : next.progress ?? summary
            case "function_call_output", "custom_tool_call_output":
                guard next.state != .done else { return }
                let callID = payload["call_id"] as? String ?? "anonymous"
                if let completed = activeTools[callID], completed.activity == .bash {
                    backgroundCommands.subtract(completed.references)
                    backgroundCommands.formUnion(Self.pendingCommands(in: payload["output"]))
                }
                activeTools[callID] = nil
                toolOrder.removeAll { $0 == callID }
                let tool = currentTool
                next.state = tool?.waiting == true ? .waiting : .running
                next.activity = tool?.waiting == true ? nil : currentActivity?.rawValue ?? "think"
                next.detail = tool?.waiting == true ? tool?.detail : next.progress ?? currentDetail ?? BubbleText.thinking
            case "reasoning":
                guard next.state != .done else { return }
                if next.state != .waiting {
                    next.state = .running
                    next.activity = currentActivity?.rawValue ?? "think"
                    next.detail = next.progress ?? currentDetail ?? BubbleText.thinking
                }
            default: changed = false
            }
        } else { changed = false }
        guard changed else { return }
        next.lastEvent = "Codex:" + type
        next.eventTime = Self.milliseconds(root["timestamp"] as? String) ?? next.eventTime
        record = next
    }

    private var currentTool: ActiveTool? { toolOrder.reversed().compactMap { activeTools[$0] }.first }
    private var currentActivity: WorkActivity? { currentTool?.activity ?? (backgroundCommands.isEmpty ? nil : .bash) }
    private var currentDetail: String? { currentTool?.detail ?? (backgroundCommands.isEmpty ? nil : "正在执行命令…") }

    private static func toolReferences(input: String, args: [String: Any]?) -> Set<String> {
        var refs: Set<String> = []
        for key in ["session_id", "cell_id"] {
            if let value = args?[key] { refs.insert((key == "cell_id" ? "cell:" : "session:") + String(describing: value)) }
        }
        let pattern = #"\b(session_id|cell_id)\s*:\s*[\"']?([0-9]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let text = input as NSString
            for match in regex.matches(in: input, range: NSRange(location: 0, length: text.length)) {
                let prefix = text.substring(with: match.range(at: 1)) == "cell_id" ? "cell:" : "session:"
                refs.insert(prefix + text.substring(with: match.range(at: 2)))
            }
        }
        return refs
    }

    /// Only tool-result envelopes are inspected: stdout inside their `output` field can
    /// itself contain arbitrary JSON and must not manufacture a running command session.
    private static func pendingCommands(in raw: Any?, depth: Int = 0) -> Set<String> {
        guard depth < 6 else { return [] }
        if let values = raw as? [Any] { return values.reduce(into: Set<String>()) { $0.formUnion(pendingCommands(in: $1, depth: depth + 1)) } }
        if let object = raw as? [String: Any] {
            var refs: Set<String> = []
            if let session = object["session_id"], object["exit_code"] == nil || object["exit_code"] is NSNull {
                refs.insert("session:" + String(describing: session))
            }
            if let text = object["text"] as? String { refs.formUnion(pendingCommands(in: text, depth: depth + 1)) }
            if let content = object["content"] { refs.formUnion(pendingCommands(in: content, depth: depth + 1)) }
            return refs
        }
        guard let text = raw as? String else { return [] }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { return pendingCommands(in: json, depth: depth + 1) }
        let header = text.components(separatedBy: "\n").prefix {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line != "Output:" && line != "Final output:"
        }.joined(separator: "\n")
        guard (header.hasPrefix("Script running with cell ID") || header.hasPrefix("Chunk ID:")),
              !header.contains("Process exited with code") else { return [] }
        for (pattern, prefix) in [(#"^Script running with cell ID\s+([A-Za-z0-9-]+)"#, "cell:"), (#"(?m)^Process running with session ID\s+([0-9]+)"#, "session:")] {
            if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                return [prefix + (header as NSString).substring(with: match.range(at: 1))]
            }
        }
        return []
    }

    private static func publicProgress(_ payload: [String: Any], envelope: String?) -> String? {
        guard payload["phase"] as? String == "commentary" else { return nil }
        let text: String
        if envelope == "event_msg", payload["type"] as? String == "agent_message" {
            text = payload["message"] as? String ?? ""
        } else if envelope == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "assistant" {
            text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(4000))
    }

    private static func entrypoint(for source: SessionSource) -> String {
        switch source {
        case .codexTerminal: return "codex-cli"
        case .codexVSCode: return "codex-vscode"
        case .codexDesktop: return "codex-desktop"
        default: return "codex"
        }
    }

    private static func activity(_ name: String, input: String) -> WorkActivity {
        if ["exec_command", "shell", "shell_command", "write_stdin"].contains(name)
            || input.range(of: #"(?:tools\.|functions\.)?(?:exec_command|write_stdin)\s*\("#, options: .regularExpression) != nil { return .bash }
        if ["spawn_agent", "send_input", "wait_agent", "wait"].contains(name) { return .juggle }
        if ["read_file", "list_dir", "grep_files", "web", "web_search"].contains(name) { return .read }
        return .laptop
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func milliseconds(_ string: String?) -> Int64? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        return date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

/// Adapts open rollouts into Critter's state store without overwriting a `Seen` event.
/// Queue-confined by the caller. Closing one rollout doesn't affect its process's siblings.
public struct CodexSessionSync {
    private var readers: [String: CodexRolloutReader] = [:]
    public init() {}

    public mutating func refresh(owners: [CodexRolloutOwner], store: StateStore) {
        let paths = Set(owners.map(\.path))
        readers = readers.filter { paths.contains($0.key) }
        var liveIDs: Set<String> = []
        for owner in owners {
            var reader = readers[owner.path] ?? CodexRolloutReader()
            let incoming = reader.read(owner: owner)
            readers[owner.path] = reader
            guard let incoming else { continue }
            liveIDs.insert(incoming.sessionId)
            let legacyID = SessionSource.codexConversationID(sessionId: incoming.sessionId)
            let legacy = legacyID.flatMap { store.read(sessionId: $0) }.flatMap { Self.matchesLegacy($0, incoming: incoming) ? $0 : nil }
            if let legacy { liveIDs.insert(legacy.sessionId) }
            var saved = false
            do {
                try store.update(sessionId: incoming.sessionId) { previous in
                    var candidate = incoming
                    if let legacy, legacy.lastEvent == "Seen", legacy.eventTime >= candidate.eventTime {
                        candidate = Self.keepingState(of: legacy, from: incoming)
                    }
                    if previous == candidate { return .ignore }
                    if let previous, previous.eventTime > candidate.eventTime || (previous.lastEvent == "Seen" && previous.eventTime >= candidate.eventTime) {
                        // A resumed conversation can have a new owner without a new turn.
                        // Keep seen state while refreshing ownership, source and telemetry.
                        let kept = Self.keepingState(of: previous, from: incoming)
                        return kept == previous ? .ignore : .write(kept)
                    }
                    return .write(candidate)
                }
                saved = true
            } catch {
                // Leave the legacy state intact if its canonical replacement failed.
            }
            if saved, store.read(sessionId: incoming.sessionId) != nil, let legacy {
                try? store.update(sessionId: legacy.sessionId) { current in current == legacy ? .delete : .ignore }
            }
        }
        for record in store.readAll() where SessionSource(entrypoint: record.entrypoint).isCodex && !liveIDs.contains(record.sessionId) {
            try? store.update(sessionId: record.sessionId) { current in
                current == record ? .delete : .ignore
            }
        }
    }

    private static func keepingState(of previous: SessionRecord, from incoming: SessionRecord) -> SessionRecord {
        var kept = incoming
        kept.state = previous.state
        kept.detail = previous.detail
        kept.lastEvent = previous.lastEvent
        kept.eventTime = previous.eventTime
        kept.createdAt = previous.createdAt
        kept.activity = previous.activity
        kept.telemetry = incoming.telemetry ?? previous.telemetry
        return kept
    }

    private static func matchesLegacy(_ legacy: SessionRecord, incoming: SessionRecord) -> Bool {
        guard legacy.sessionId == SessionSource.codexConversationID(sessionId: incoming.sessionId),
              let path = legacy.transcriptPath, path.hasPrefix("/"), let incomingPath = incoming.transcriptPath else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            == URL(fileURLWithPath: incomingPath).standardizedFileURL.resolvingSymlinksInPath()
    }
}
