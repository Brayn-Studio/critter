// Pure translation from DeepSeek Harness session events to the Claude-Code-shaped hook
// payloads that `critter-hook` already understands. No I/O here, so every mapping can be
// tested against recorded event shapes; lib/index.js does the spawning.

/** DeepSeek tool name -> the Claude Code name Critter's tool labels and matchKey know. */
const TOOL_NAMES = {
  bash: "Bash",
  read: "Read",
  edit: "Edit",
  str_replace_editor: "Edit",
  write: "Write",
  glob: "Glob",
  grep: "Grep",
  web_fetch: "WebFetch",
  web_search: "WebSearch",
  subagent: "Agent",
  subagent_fork: "Agent",
  ask_user_question: "AskUserQuestion",
  exit_plan_mode: "ExitPlanMode",
};

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/** DeepSeek sends tool arguments as a JSON string; anything unparseable is just "no input". */
function parseArgs(raw) {
  if (isObject(raw)) return raw;
  if (typeof raw !== "string") return {};
  try {
    const parsed = JSON.parse(raw);
    return isObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/** DeepSeek question -> Claude's AskUserQuestion question (header/multiSelect/options always present). */
function claudeQuestions(questions) {
  if (!Array.isArray(questions)) return [];
  return questions.filter(isObject).map((q) => ({
    question: String(q.question ?? ""),
    header: String(q.header ?? ""),
    multiSelect: q.multiSelect === true,
    options: (Array.isArray(q.options) ? q.options : []).filter(isObject).map((o) => ({
      label: String(o.label ?? ""),
      description: String(o.description ?? ""),
    })),
  }));
}

/** Exported for the host wiring, which turns a question request into an AskUserQuestion ask. */
export { claudeQuestions };

/**
 * Maps one DeepSeek tool call to the Claude tool name and input. Arguments are copied whole;
 * `path` additionally appears as `file_path`, the key Claude's file tools use.
 */
export function mapTool(name, args) {
  const toolName = TOOL_NAMES[name] ?? name;
  const parsed = isObject(args) ? args : {};
  if (toolName === "AskUserQuestion") {
    return { toolName, toolInput: { questions: claudeQuestions(parsed.questions) } };
  }
  const toolInput = { ...parsed };
  if (toolInput.path !== undefined && toolInput.file_path === undefined) toolInput.file_path = toolInput.path;
  return { toolName, toolInput };
}

/** Delegated (sub-agent) sessions are part of their parent's story, not pets of their own. */
export function isTopLevel(header) {
  return isObject(header) && !(Number(header.delegationDepth) > 0);
}

const REFUSED = new Set(["rejected", "cancelled", "unavailable"]);

function lastText(content) {
  if (!Array.isArray(content)) return undefined;
  for (let i = content.length - 1; i >= 0; i--) {
    const block = content[i];
    if (isObject(block) && block.type === "text" && typeof block.text === "string") return block.text;
  }
  return undefined;
}

export class SessionTranslator {
  constructor(headerId, cwd) {
    this.sessionId = `deepseek-${headerId}`;
    this.cwd = cwd;
    this.joined = false;
    this.callMap = new Map(); // callId -> {toolName, toolInput}
    this.approvals = new Map(); // approval id -> {toolName, toolInput}
    this.turnLastText = undefined;
    this.lastUserText = "";
  }

  #payload(hook_event_name, extra = {}) {
    return { session_id: this.sessionId, cwd: this.cwd, hook_event_name, ...extra };
  }

  /** A session only appears in Critter once something happens in it, not when DeepSeek merely loads it. */
  #join() {
    if (this.joined) return [];
    this.joined = true;
    return [this.#payload("SessionStart", { source: "startup" })];
  }

  toolInputFor(callId) {
    return this.callMap.get(callId);
  }

  /** SessionEnd for a session that was ever shown; nothing for one that never joined. */
  end() {
    return this.joined ? [this.#payload("SessionEnd")] : [];
  }

  feed(event) {
    const type = event?.type;
    const data = isObject(event?.data) ? event.data : {};
    switch (type) {
      case "user/message": {
        if (data.source?.kind === "user") this.lastUserText = lastText(data.content) ?? "";
        return [];
      }
      case "turn/start": {
        const out = this.#join();
        out.push(this.#payload("UserPromptSubmit", { prompt: this.lastUserText }));
        this.lastUserText = "";
        this.turnLastText = undefined;
        return out;
      }
      case "assistant/message":
        // Only the final message's text is the answer; an earlier one that carried tool calls is not.
        this.turnLastText = lastText(data.message?.content);
        return [];
      case "tool/call": {
        const { toolName, toolInput } = mapTool(String(data.name ?? ""), parseArgs(data.arguments));
        if (typeof data.callId === "string") this.callMap.set(data.callId, { toolName, toolInput });
        return [this.#payload("PreToolUse", { tool_name: toolName, tool_input: toolInput })];
      }
      case "tool/result": {
        // PostToolUse must carry exactly what PreToolUse did, or Critter cannot pair them.
        const call = this.callMap.get(data.message?.toolCallId);
        if (!call) return [];
        return [this.#payload("PostToolUse", { tool_name: call.toolName, tool_input: call.toolInput })];
      }
      case "approval/asked": {
        const call = this.callMap.get(data.callId) ?? mapTool(String(data.toolName ?? ""), {});
        if (typeof data.id === "string") this.approvals.set(data.id, call);
        return [...this.#join(), this.#payload("PermissionRequest", { tool_name: call.toolName, tool_input: call.toolInput })];
      }
      case "approval/decided": {
        const call = this.approvals.get(data.id);
        this.approvals.delete(data.id);
        if (!REFUSED.has(data.outcome)) return [];
        const { toolName, toolInput } = call ?? { toolName: "", toolInput: {} };
        return [this.#payload("PermissionDenied", { tool_name: toolName, tool_input: toolInput })];
      }
      case "turn/end": {
        const text = this.turnLastText;
        this.turnLastText = undefined;
        this.callMap.clear();
        this.approvals.clear();
        const reason = data.reason ?? {};
        switch (reason.kind) {
          case "completed":
            return [this.#payload("Stop", text === undefined ? {} : { last_assistant_message: text })];
          case "error":
            return [this.#payload("StopFailure", { error_type: "error", error_message: String(reason.error?.message ?? "error") })];
          case "max-tokens":
            return [this.#payload("StopFailure", { error_type: "error", error_message: "max-tokens" })];
          case "aborted":
          case "blocked":
            return [this.#payload("Interrupted")];
          default:
            return [];
        }
      }
      default:
        return [];
    }
  }
}

/** The phone's answer is a Claude PermissionRequest decision; this is the same thing in DeepSeek's terms. */
function decisionOf(hookStdout) {
  if (typeof hookStdout !== "string" || hookStdout.trim() === "") return null;
  try {
    const decision = JSON.parse(hookStdout)?.hookSpecificOutput?.decision;
    return isObject(decision) ? decision : null;
  } catch {
    return null;
  }
}

/** One answer string -> the labels it names, or free text when it is not made of labels. */
function selection(answer, options) {
  const labels = options.map((o) => String(o?.label ?? ""));
  if (labels.includes(answer)) return { selected: [answer] };
  const parts = answer.split(", ");
  if (parts.length > 1 && parts.every((p) => labels.includes(p))) return { selected: parts };
  return { selected: [], custom: answer };
}

/**
 * `critter-hook ask` stdout -> what DeepSeek's waterfall expects, or null when the phone gave
 * no usable answer (the caller then keeps waiting for DeepSeek's own panel).
 */
export function askAnswerToDeepSeek(kind, hookStdout, questions = []) {
  const decision = decisionOf(hookStdout);
  if (!decision) return null;
  if (kind === "permission") {
    if (decision.behavior === "allow") return "allowed-once";
    if (decision.behavior === "deny") return "rejected";
    return null;
  }
  if (decision.behavior !== "allow" || !isObject(decision.updatedInput?.answers)) return null;
  const answers = decision.updatedInput.answers;
  const out = [];
  for (const q of Array.isArray(questions) ? questions : []) {
    const answer = answers[q?.question];
    out.push(typeof answer === "string" ? { id: q.id, ...selection(answer, q.options ?? []) } : { id: q.id, selected: [] });
  }
  return out.length > 0 ? { answers: out } : null;
}
