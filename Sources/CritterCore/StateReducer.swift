import Foundation

/// What `StateStore` should do in response to a single reduced hook event.
public enum ReducerAction: Equatable, Sendable {
    case write(SessionRecord)
    case delete
    case ignore
}

/// Pure function turning one decoded hook event into a `ReducerAction`, given the
/// previous record for that session (if any). See the batch brief's event table for
/// the exact mapping; this is its implementation.
public enum StateReducer {
    private static let waitingNotificationTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    public static func reduce(
        previous: SessionRecord?,
        input: HookInput,
        now: Int64,
        pid: Int32?,
        pidStartTime: Int64?,
        entrypoint: String? = nil
    ) -> ReducerAction {
        func write(state: PetState, detail: String?, activity: WorkActivity? = nil) -> ReducerAction {
            .write(SessionRecord(
                schema: 1,
                sessionId: input.sessionId,
                cwd: input.cwd,
                transcriptPath: input.transcriptPath ?? previous?.transcriptPath,
                state: state,
                detail: detail,
                lastEvent: input.hookEventName,
                eventTime: now,
                createdAt: previous?.createdAt ?? now,
                claudePid: pid ?? previous?.claudePid,
                claudeStartTime: pidStartTime ?? previous?.claudeStartTime,
                entrypoint: entrypoint ?? previous?.entrypoint,
                activity: activity?.rawValue
            ))
        }

        switch input.hookEventName {
        case "SessionStart":
            if input.source == "compact", previous != nil {
                return .ignore
            }
            return write(state: .idle, detail: nil)

        case "UserPromptSubmit":
            let trimmed = (input.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isPetCommand(trimmed) {
                return .ignore
            }
            return write(state: .running, detail: BubbleText.thinking, activity: .think)

        case "PreToolUse":
            switch input.toolName {
            case "AskUserQuestion":
                return write(state: .waiting, detail: BubbleText.askQuestion)
            case "ExitPlanMode":
                return write(state: .waiting, detail: BubbleText.planApproval)
            default:
                let summary = ToolSummary.activity(toolName: input.toolName ?? "", input: input.toolInput)
                return write(state: .running, detail: summary, activity: WorkActivity.forTool(input.toolName ?? ""))
            }

        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            return write(state: .running, detail: BubbleText.thinking, activity: .think)

        case "PermissionRequest":
            let summary = ToolSummary.permission(toolName: input.toolName ?? "", input: input.toolInput)
            return write(state: .waiting, detail: summary)

        case "Notification":
            guard let type = input.notificationType, waitingNotificationTypes.contains(type) else {
                return .ignore
            }
            let detail: String?
            if previous?.state == .waiting, let existing = previous?.detail {
                detail = existing
            } else {
                detail = ToolSummary.truncate(input.message ?? "", max: 60)
            }
            return write(state: .waiting, detail: detail)

        case "Stop":
            let detail: String
            if let last = input.lastAssistantMessage {
                detail = "做完了：" + ToolSummary.firstSentence(last, max: 50)
            } else {
                detail = BubbleText.done
            }
            return write(state: .done, detail: detail)

        case "StopFailure":
            let message = input.errorMessage ?? input.errorType ?? "未知错误"
            return write(state: .error, detail: BubbleText.errorPrefix + ToolSummary.truncate(message, max: 50))

        case "SessionEnd":
            return .delete

        default:
            // UserPromptExpansion, SubagentStop, and any unrecognized event.
            return .ignore
        }
    }

    /// Whether `trimmedPrompt` matches `^/pet(\s|$)`.
    private static func isPetCommand(_ trimmedPrompt: String) -> Bool {
        guard trimmedPrompt.hasPrefix("/pet") else { return false }
        let rest = trimmedPrompt.dropFirst(4)
        guard let firstChar = rest.first else { return true }
        return firstChar.isWhitespace
    }
}
