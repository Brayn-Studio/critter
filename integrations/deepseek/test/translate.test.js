import { test } from "node:test";
import assert from "node:assert/strict";
import {
  SessionTranslator,
  mapTool,
  isTopLevel,
  askAnswerToDeepSeek,
  claudeQuestions,
} from "../lib/translate.js";

const HEADER = "session-2e9f86ca-ea7c-4451-a858-9a29326750c5";
const CWD = "/Users/apple/Documents/deepseek-harness/default-workspace";
const newTranslator = () => new SessionTranslator(HEADER, CWD);
const ev = (type, data) => ({ type, data });
const names = (payloads) => payloads.map((p) => p.hook_event_name);

const userMessage = (text, kind = "user") =>
  ev("user/message", {
    content: [{ type: "text", text }],
    source: { kind, rpcId: "f9155b49" },
    role: "user",
    id: "9bb2",
  });

test("agent created alone emits nothing", () => {
  const t = newTranslator();
  assert.deepEqual(t.feed(ev("system/message", { content: [] })), []);
  assert.deepEqual(t.feed(userMessage("hi")), []);
  assert.deepEqual(t.feed(ev("request/header", { header: {} })), []);
  assert.deepEqual(t.feed(ev("step/start", { turn: 1, step: 1 })), []);
});

test("turn start joins, a second turn only prompts", () => {
  const t = newTranslator();
  t.feed(userMessage("first question"));
  const first = t.feed(ev("turn/start", { turn: 1 }));
  assert.deepEqual(first, [
    { session_id: `deepseek-${HEADER}`, cwd: CWD, hook_event_name: "SessionStart", source: "startup" },
    { session_id: `deepseek-${HEADER}`, cwd: CWD, hook_event_name: "UserPromptSubmit", prompt: "first question" },
  ]);
  t.feed(userMessage("second question"));
  const second = t.feed(ev("turn/start", { turn: 2 }));
  assert.deepEqual(names(second), ["UserPromptSubmit"]);
  assert.equal(second[0].prompt, "second question");
});

test("the prompt comes only from user-sourced messages", () => {
  const t = newTranslator();
  t.feed(userMessage("real prompt"));
  t.feed(userMessage("runtime context snapshot", "system"));
  const out = t.feed(ev("turn/start", { turn: 1 }));
  assert.equal(out[1].prompt, "real prompt");
  const none = newTranslator().feed(ev("turn/start", { turn: 1 }));
  assert.equal(none[1].prompt, "");
});

test("a resumed turn does not reuse the previous turn's prompt text", () => {
  const t = newTranslator();
  t.feed(userMessage("old"));
  t.feed(ev("turn/start", { turn: 1 }));
  const again = t.feed(ev("turn/start", { turn: 2 }));
  assert.equal(again[0].prompt, "");
});

const toolCall = (callId, name, args) =>
  ev("tool/call", { turn: 1, step: 1, callId, name, arguments: typeof args === "string" ? args : JSON.stringify(args) });

test("tool call maps to Claude names", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  const [pre] = t.feed(toolCall("c1", "bash", { command: "ls", description: "x" }));
  assert.equal(pre.hook_event_name, "PreToolUse");
  assert.equal(pre.session_id, `deepseek-${HEADER}`);
  assert.equal(pre.tool_name, "Bash");
  assert.deepEqual(pre.tool_input, { command: "ls", description: "x" });
});

test("mapTool covers the tool table", () => {
  assert.deepEqual(mapTool("read", { path: "a.txt" }), {
    toolName: "Read",
    toolInput: { file_path: "a.txt", path: "a.txt" },
  });
  assert.equal(mapTool("edit", { path: "a" }).toolName, "Edit");
  assert.equal(mapTool("str_replace_editor", { path: "a" }).toolName, "Edit");
  assert.equal(mapTool("write", { path: "a", content: "c" }).toolName, "Write");
  assert.equal(mapTool("glob", { pattern: "*" }).toolName, "Glob");
  assert.equal(mapTool("grep", { pattern: "x" }).toolName, "Grep");
  assert.equal(mapTool("web_fetch", { url: "u" }).toolName, "WebFetch");
  assert.equal(mapTool("web_search", { query: "q" }).toolName, "WebSearch");
  assert.equal(mapTool("subagent", {}).toolName, "Agent");
  assert.equal(mapTool("subagent_fork", {}).toolName, "Agent");
  assert.equal(mapTool("exit_plan_mode", {}).toolName, "ExitPlanMode");
  assert.deepEqual(mapTool("todo_write", { todos: [1] }), { toolName: "todo_write", toolInput: { todos: [1] } });
  // An existing file_path is never overwritten by path.
  assert.deepEqual(mapTool("read", { path: "a", file_path: "b" }).toolInput, { path: "a", file_path: "b" });
});

test("ask_user_question converts to the Claude question shape", () => {
  const out = mapTool("ask_user_question", {
    questions: [
      { id: "q1", question: "Pick one?", header: "Pick", options: [{ label: "A", description: "first" }, { label: "B" }], multiSelect: false },
      { id: "q2", question: "Which?" },
    ],
  });
  assert.equal(out.toolName, "AskUserQuestion");
  assert.deepEqual(out.toolInput, {
    questions: [
      { question: "Pick one?", header: "Pick", multiSelect: false, options: [{ label: "A", description: "first" }, { label: "B", description: "" }] },
      { question: "Which?", header: "", multiSelect: false, options: [] },
    ],
  });
});

test("unparseable arguments become an empty input", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  const [pre] = t.feed(toolCall("c1", "bash", "{not json"));
  assert.equal(pre.tool_name, "Bash");
  assert.deepEqual(pre.tool_input, {});
  const [arr] = t.feed(toolCall("c2", "bash", "[1,2]"));
  assert.deepEqual(arr.tool_input, {});
});

test("tool result reuses the call input", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  const [pre] = t.feed(toolCall("c1", "read", { path: "a.txt" }));
  const [post] = t.feed(ev("tool/result", { turn: 1, step: 1, message: { role: "tool", toolCallId: "c1", content: [] } }));
  assert.equal(post.hook_event_name, "PostToolUse");
  assert.equal(post.tool_name, pre.tool_name);
  assert.deepEqual(post.tool_input, pre.tool_input);
  // A result for a call we never saw says nothing we could match.
  assert.deepEqual(t.feed(ev("tool/result", { message: { toolCallId: "nope" } })), []);
});

test("toolInputFor exposes the call map", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  t.feed(toolCall("c1", "bash", { command: "ls" }));
  assert.deepEqual(t.toolInputFor("c1"), { toolName: "Bash", toolInput: { command: "ls" } });
  assert.equal(t.toolInputFor("zzz"), undefined);
});

test("approval asked becomes a PermissionRequest and joins first if needed", () => {
  const t = newTranslator();
  t.feed(toolCall("c1", "bash", { command: "rm x" }));
  const out = t.feed(ev("approval/asked", { id: "a1", toolName: "bash", callId: "c1", reason: "escalate" }));
  assert.deepEqual(names(out), ["SessionStart", "PermissionRequest"]);
  assert.equal(out[1].tool_name, "Bash");
  assert.deepEqual(out[1].tool_input, { command: "rm x" });

  const second = t.feed(ev("approval/asked", { id: "a2", toolName: "write", callId: "unknown", reason: "r" }));
  assert.deepEqual(names(second), ["PermissionRequest"]);
  assert.equal(second[0].tool_name, "Write");
  assert.deepEqual(second[0].tool_input, {});
});

test("approval decided: refusals are PermissionDenied, allowed resumes the tool", () => {
  for (const outcome of ["rejected", "cancelled", "unavailable"]) {
    const t = newTranslator();
    t.feed(ev("turn/start", { turn: 1 }));
    t.feed(toolCall("c1", "bash", { command: "ls" }));
    t.feed(ev("approval/asked", { id: "a1", toolName: "bash", callId: "c1", reason: "r" }));
    const [denied] = t.feed(ev("approval/decided", { id: "a1", outcome }));
    assert.equal(denied.hook_event_name, "PermissionDenied");
    assert.equal(denied.tool_name, "Bash");
    assert.deepEqual(denied.tool_input, { command: "ls" });
  }
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  t.feed(ev("approval/asked", { id: "a1", toolName: "bash", callId: "c1", reason: "r" }));
  assert.deepEqual(t.feed(ev("approval/decided", { id: "never-asked", outcome: "allowed-once" })), []);
  assert.deepEqual(t.feed(ev("approval/decided", { id: "never-asked", outcome: "rejected" })).map((p) => p.hook_event_name), ["PermissionDenied"]);
});

test("approval allowed in DeepSeek's panel retracts the request and shows the tool running", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  const [pre] = t.feed(toolCall("c1", "bash", { command: "rm x" }));
  t.feed(ev("approval/asked", { id: "a1", toolName: "bash", callId: "c1", reason: "r" }));
  const out = t.feed(ev("approval/decided", { id: "a1", outcome: "allowed-once" }));
  assert.deepEqual(names(out), ["PostToolUse", "PreToolUse"]);
  assert.equal(out[0].tool_name, pre.tool_name);
  assert.deepEqual(out[0].tool_input, pre.tool_input);
  assert.deepEqual(out[1].tool_input, pre.tool_input);
  assert.equal(out[1].tool_name, pre.tool_name);
  // Decided twice (or an unknown id) is nothing.
  assert.deepEqual(t.feed(ev("approval/decided", { id: "a1", outcome: "allowed-once" })), []);
});

test("a session that never joined emits nothing on turn end or approval decided", () => {
  const t = newTranslator();
  assert.deepEqual(t.feed(ev("approval/decided", { id: "a1", outcome: "rejected" })), []);
  assert.deepEqual(t.feed(ev("approval/decided", { id: "a1", outcome: "allowed-once" })), []);
  for (const kind of ["completed", "error", "max-tokens", "aborted", "blocked"]) {
    assert.deepEqual(t.feed(ev("turn/end", { turn: 1, reason: { kind, error: { message: "x" } } })), []);
  }
});

test("questions accept multi_select as well as multiSelect", () => {
  assert.deepEqual(
    claudeQuestions([
      { question: "A?", multi_select: true, options: [] },
      { question: "B?", multiSelect: true, options: [] },
      { question: "C?", multi_select: "yes", options: [] },
    ]).map((q) => q.multiSelect),
    [true, true, false],
  );
  const { toolInput } = mapTool("ask_user_question", { questions: [{ question: "A?", multi_select: true }] });
  assert.equal(toolInput.questions[0].multiSelect, true);
});

const assistant = (content) => ev("assistant/message", { turn: 1, step: 1, message: { role: "assistant", content } });

test("turn end completed carries the last assistant text", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  t.feed(assistant([{ type: "reasoning", text: "thinking" }, { type: "text", text: "early" }]));
  t.feed(assistant([{ type: "reasoning", text: "more" }, { type: "text", text: "part one" }, { type: "text", text: "final answer" }]));
  const [stop] = t.feed(ev("turn/end", { turn: 1, reason: { kind: "completed" } }));
  assert.equal(stop.hook_event_name, "Stop");
  assert.equal(stop.last_assistant_message, "final answer");

  t.feed(ev("turn/start", { turn: 2 }));
  t.feed(assistant([{ type: "reasoning", text: "only thoughts" }]));
  const [bare] = t.feed(ev("turn/end", { turn: 2, reason: { kind: "completed" } }));
  assert.equal("last_assistant_message" in bare, false);

  t.feed(ev("turn/start", { turn: 3 }));
  const [empty] = t.feed(ev("turn/end", { turn: 3, reason: { kind: "completed" } }));
  assert.equal("last_assistant_message" in empty, false);
});

test("turn end failures and interruptions", () => {
  const t = newTranslator();
  t.feed(ev("turn/start", { turn: 1 }));
  const [err] = t.feed(ev("turn/end", { turn: 1, reason: { kind: "error", error: { message: "boom" } } }));
  assert.equal(err.hook_event_name, "StopFailure");
  assert.equal(err.error_type, "error");
  assert.equal(err.error_message, "boom");

  const [max] = t.feed(ev("turn/end", { turn: 2, reason: { kind: "max-tokens" } }));
  assert.equal(max.hook_event_name, "StopFailure");
  assert.equal(max.error_message, "max-tokens");

  for (const kind of ["aborted", "blocked"]) {
    const [i] = t.feed(ev("turn/end", { turn: 3, reason: { kind } }));
    assert.equal(i.hook_event_name, "Interrupted");
  }
});

test("end emits SessionEnd only for a joined session", () => {
  const t = newTranslator();
  assert.deepEqual(t.end(), []);
  t.feed(ev("turn/start", { turn: 1 }));
  assert.deepEqual(t.end(), [{ session_id: `deepseek-${HEADER}`, cwd: CWD, hook_event_name: "SessionEnd" }]);
});

test("child sessions are not top level", () => {
  assert.equal(isTopLevel({ id: "s", delegationDepth: 0 }), true);
  assert.equal(isTopLevel({ id: "s" }), true);
  assert.equal(isTopLevel({ id: "s", delegationDepth: 1 }), false);
  assert.equal(isTopLevel(undefined), false);
});

const allow = JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
const deny = JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "deny", message: "no" } } });
const answered = (answers) =>
  JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow", updatedInput: { questions: [], answers } } } });
const QUESTIONS = [{ id: "q1", question: "Pick one?", options: [{ label: "A" }, { label: "B" }] }];

test("askAnswerToDeepSeek maps permissions", () => {
  assert.equal(askAnswerToDeepSeek("permission", allow), "allowed-once");
  assert.equal(askAnswerToDeepSeek("permission", deny), "rejected");
  assert.equal(askAnswerToDeepSeek("permission", ""), null);
  assert.equal(askAnswerToDeepSeek("permission", "not json"), null);
  assert.equal(askAnswerToDeepSeek("permission", "{}"), null);
});

test("askAnswerToDeepSeek maps question answers", () => {
  assert.deepEqual(askAnswerToDeepSeek("question", answered({ "Pick one?": "B" }), QUESTIONS), { answers: [{ id: "q1", selected: ["B"] }] });
  assert.deepEqual(askAnswerToDeepSeek("question", answered({ "Pick one?": "A, B" }), QUESTIONS), { answers: [{ id: "q1", selected: ["A", "B"] }] });
  assert.deepEqual(askAnswerToDeepSeek("question", answered({ "Pick one?": "something else" }), QUESTIONS), {
    answers: [{ id: "q1", selected: [], custom: "something else" }],
  });
  assert.equal(askAnswerToDeepSeek("question", "", QUESTIONS), null);
  assert.equal(askAnswerToDeepSeek("question", deny, QUESTIONS), null);
  assert.equal(askAnswerToDeepSeek("question", allow, QUESTIONS), null);
});

test("a label that itself contains a comma stays one choice", () => {
  const qs = [{ id: "q1", question: "Q?", options: [{ label: "Yes, please" }, { label: "No" }] }];
  assert.deepEqual(askAnswerToDeepSeek("question", answered({ "Q?": "Yes, please" }), qs), { answers: [{ id: "q1", selected: ["Yes, please"] }] });
});
