import Foundation

/// When `critter-hook ask` may bother the phone at all. Both checks read `app.json`, which
/// the app refreshes about once a second while it runs.
public enum AskGate {
    public static let heartbeatFreshMs: Int64 = 10_000
    public static let clientRecentMs: Int64 = 600_000

    /// The app is alive, the bridge is on, and a phone has been seen recently.
    public static func shouldStart(status: AppStatus?, now: Int64) -> Bool {
        guard shouldKeepWaiting(status: status, now: now), let seen = status?.lastClientSeen else { return false }
        return now - seen <= clientRecentMs
    }

    /// While waiting only the app's liveness and the bridge switch matter: a phone that went
    /// quiet may still answer.
    public static func shouldKeepWaiting(status: AppStatus?, now: Int64) -> Bool {
        guard let status, status.bridgeEnabled == true else { return false }
        return now - status.heartbeat <= heartbeatFreshMs
    }
}

/// The clock, sleeping and identity `AskCommand` depends on, so tests can run a ten-minute wait instantly.
public struct AskEnvironment: Sendable {
    public var now: @Sendable () -> Int64
    public var sleep: @Sendable (TimeInterval) -> Void
    public var ownPid: Int32
    public var newRequestId: @Sendable () -> String
    public var maxWaitMs: Int64
    public var pollInterval: TimeInterval

    public init(
        now: @escaping @Sendable () -> Int64,
        sleep: @escaping @Sendable (TimeInterval) -> Void,
        ownPid: Int32,
        newRequestId: @escaping @Sendable () -> String,
        maxWaitMs: Int64 = 590_000,
        pollInterval: TimeInterval = 0.2
    ) {
        self.now = now
        self.sleep = sleep
        self.ownPid = ownPid
        self.newRequestId = newRequestId
        self.maxWaitMs = maxWaitMs
        self.pollInterval = pollInterval
    }

    public static let live = AskEnvironment(
        now: { Int64(Date().timeIntervalSince1970 * 1000) },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        ownPid: getpid(),
        newRequestId: { UUID().uuidString.lowercased() }
    )
}

/// `critter-hook ask`: a `PermissionRequest` hook that publishes the prompt for a paired phone
/// and prints its decision. Printing nothing leaves Claude Code to ask in the terminal, so every
/// failure and give-up path is silent.
public enum AskCommand {
    /// The only `CLAUDE_CODE_ENTRYPOINT` `ask` waits for. The terminal's prompt was verified to
    /// stay up beside a waiting hook (spec 4.1); VS Code, Desktop and SDK sessions were not
    /// (spec 13.3), and a hook waiting there could hold their prompt for up to 590 s.
    public static let entrypoint = "cli"

    /// `environment` is the hook's own (Claude Code sets `CLAUDE_CODE_ENTRYPOINT` for it).
    public static func run(stdin: Data, paths: CritterPaths, environment: [String: String], env: AskEnvironment) -> HookResult {
        let silent = HookResult(stdout: "", exitCode: 0)
        guard environment["CLAUDE_CODE_ENTRYPOINT"] == entrypoint else { return silent }
        guard let root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              root["hook_event_name"] as? String == "PermissionRequest",
              let sessionId = root["session_id"] as? String,
              let toolName = root["tool_name"] as? String,
              let toolInput = root["tool_input"] as? [String: Any] else { return silent }

        let statusStore = AppStatusStore(paths: paths)
        guard AskGate.shouldStart(status: statusStore.read(), now: env.now()) else { return silent }

        let kind = PendingKind(toolName: toolName)
        let createdAt = env.now()
        let request = PendingRequest(
            requestId: env.newRequestId(), sessionId: sessionId, kind: kind, toolName: toolName,
            summary: summary(kind: kind, toolName: toolName, toolInput: toolInput),
            input: AskDecision.displayInput(toolInput),
            matchKey: MatchKey.compute(toolName: toolName, toolInput: toolInput),
            createdAt: createdAt, expiresAt: createdAt + env.maxWaitMs, hookPid: env.ownPid
        )
        let store = PendingStore(paths: paths)
        do { try store.write(request) } catch { return silent }

        while true {
            env.sleep(env.pollInterval)
            let now = env.now()

            if let answer = store.readAnswer(requestId: request.requestId) {
                if let output = AskDecision.output(kind: kind, toolInput: toolInput, answer: answer) {
                    store.remove(requestId: request.requestId)
                    return HookResult(stdout: String(decoding: output, as: UTF8.self), exitCode: 0)
                }
                // Not something Claude Code could act on: drop it and keep waiting for a good one.
                store.removeAnswer(requestId: request.requestId)
            }
            // Retracted (the tool finished in the terminal, the session ended...) -- nothing to clean.
            guard store.read(requestId: request.requestId) != nil else { return silent }
            guard AskGate.shouldKeepWaiting(status: statusStore.read(), now: now), now < request.expiresAt else {
                store.remove(requestId: request.requestId)
                return silent
            }
        }
    }

    private static func summary(kind: PendingKind, toolName: String, toolInput: [String: Any]) -> String {
        switch kind {
        case .question: return BubbleText.askQuestion
        case .plan: return BubbleText.planApproval
        case .permission: return ToolSummary.permission(toolName: toolName, input: JSONValue(any: toolInput))
        }
    }
}
