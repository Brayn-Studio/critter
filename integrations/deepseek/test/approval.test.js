import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply, createRunner, raceApproval } from "../lib/index.js";
import { askAnswerToDeepSeek } from "../lib/translate.js";

const HOOK = process.execPath; // any file that exists
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A stand-in for child_process.spawn: records every child; the test decides when each exits. */
function fakeSpawn() {
  const children = [];
  const spawn = (cmd, args, opts) => {
    const child = new EventEmitter();
    child.cmd = cmd;
    child.args = args;
    child.opts = opts;
    child.stdinText = "";
    child.killed = false;
    child.stdin = Object.assign(new EventEmitter(), {
      write: (s) => { child.stdinText += s; return true; },
      end: () => {},
    });
    child.stdout = new EventEmitter();
    child.kill = () => { child.killed = true; queueMicrotask(() => child.emit("close", null)); };
    child.finish = (stdout = "") => {
      if (stdout) child.stdout.emit("data", Buffer.from(stdout));
      child.emit("close", 0);
    };
    children.push(child);
    return child;
  };
  return { spawn, children };
}

const ALLOW = JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
const mapPermission = (stdout) => askAnswerToDeepSeek("permission", stdout);
const PAYLOAD = { session_id: "deepseek-s1", cwd: "/w", hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "ls" } };

/** A next() that settles with `outcome` after `ms`, or rejects when `req.signal` aborts. */
function slowNext(req, outcome, ms) {
  return () =>
    new Promise((resolve, reject) => {
      const timer = ms === undefined ? undefined : setTimeout(() => resolve(outcome), ms);
      req.signal?.addEventListener("abort", () => { clearTimeout(timer); reject(new Error("withdrawn")); }, { once: true });
    });
}

/** A runner.ask stand-in that "answers" after `ms` with `stdout` unless its signal aborts first. */
function fakeAsk(stdout, ms) {
  const seen = { aborted: false };
  const ask = (_payload, signal) =>
    new Promise((resolve) => {
      const timer = ms === undefined ? undefined : setTimeout(() => resolve(stdout), ms);
      signal.addEventListener("abort", () => { seen.aborted = true; clearTimeout(timer); resolve(""); }, { once: true });
    });
  return { ask, seen };
}

test("phone wins aborts our signal", async () => {
  const original = new AbortController();
  const req = { signal: original.signal, callId: "c1" };
  let signalAtNext;
  const inner = slowNext(req, "rejected");
  const next = () => { signalAtNext = req.signal; return inner(); };
  const { ask } = fakeAsk(ALLOW, 10);
  const result = await raceApproval({ req, next, ask, payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "allowed-once");
  assert.notEqual(signalAtNext, original.signal, "req.signal was replaced before next()");
  assert.equal(signalAtNext.aborted, true);
  assert.equal(original.signal.aborted, false);
});

test("ui answers first kills ask and returns ui outcome", async () => {
  const req = { signal: new AbortController().signal };
  const { ask, seen } = fakeAsk(ALLOW, 1000);
  const result = await raceApproval({ req, next: slowNext(req, "rejected", 5), ask, payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "rejected");
  assert.equal(seen.aborted, true);
});

test("silent ask defers to ui", async () => {
  const req = { signal: new AbortController().signal };
  let ours;
  const next = async () => { ours = req.signal; await sleep(15); return "allowed-once"; };
  const result = await raceApproval({ req, next, ask: async () => "", payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "allowed-once");
  assert.equal(ours.aborted, false);
});

test("an ask that fails defers to ui too", async () => {
  const req = { signal: new AbortController().signal };
  const next = async () => { await sleep(5); return "rejected"; };
  const result = await raceApproval({ req, next, ask: async () => { throw new Error("spawn failed"); }, payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "rejected");
});

test("original abort propagates", async () => {
  const original = new AbortController();
  const req = { signal: original.signal };
  const { ask, seen } = fakeAsk(ALLOW, 1000);
  const pending = raceApproval({ req, next: slowNext(req, "allowed-once"), ask, payload: PAYLOAD, map: mapPermission });
  await sleep(5);
  original.abort(new Error("turn cancelled"));
  await assert.rejects(pending, /withdrawn/);
  assert.equal(seen.aborted, true);
});

test("a frozen request still races, without the swap", async () => {
  const req = Object.freeze({ signal: new AbortController().signal });
  const { ask } = fakeAsk(ALLOW, 5);
  const result = await raceApproval({ req, next: () => new Promise(() => {}), ask, payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "allowed-once");
});

test("a throwing ask setup falls back to next()", async () => {
  const req = { signal: new AbortController().signal };
  const result = await raceApproval({ req, next: async () => "rejected", ask: () => { throw new Error("boom"); }, payload: PAYLOAD, map: mapPermission });
  assert.equal(result, "rejected");
});

test("events are serialized per session", async () => {
  const { spawn, children } = fakeSpawn();
  const runner = createRunner({ spawn, hookPath: HOOK, env: { CRITTER_ENTRYPOINT: "deepseek-desktop", X: "1" } });
  const first = runner.event({ session_id: "deepseek-s1", hook_event_name: "SessionStart" });
  const second = runner.event({ session_id: "deepseek-s1", hook_event_name: "UserPromptSubmit" });
  const other = runner.event({ session_id: "deepseek-s2", hook_event_name: "SessionStart" });
  await sleep(10);
  assert.equal(children.length, 2, "the second event of s1 waits; s2 is independent");
  assert.deepEqual(children[0].args, ["event"]);
  assert.equal(children[0].cmd, HOOK);
  assert.equal(children[0].opts.env.CRITTER_ENTRYPOINT, "deepseek-desktop");
  assert.deepEqual(children[0].opts.stdio, ["pipe", "pipe", "ignore"]);
  assert.equal(children[0].stdinText, JSON.stringify({ session_id: "deepseek-s1", hook_event_name: "SessionStart" }) + "\n");
  children[0].finish();
  await first;
  await sleep(10);
  assert.equal(children.length, 3);
  assert.equal(children[2].stdinText, JSON.stringify({ session_id: "deepseek-s1", hook_event_name: "UserPromptSubmit" }) + "\n");
  children[1].finish();
  children[2].finish();
  await Promise.all([second, other]);
});

test("a child running too long is killed", async () => {
  const { spawn, children } = fakeSpawn();
  const runner = createRunner({ spawn, hookPath: HOOK, env: {}, eventTimeoutMs: 30 });
  await runner.event({ session_id: "deepseek-s1", hook_event_name: "Stop" });
  assert.equal(children[0].killed, true);
});

test("a spawn error does not break the queue", async () => {
  const children = [];
  const spawn = () => { const c = new EventEmitter(); c.stdin = { write() {}, end() {}, on() {} }; c.stdout = new EventEmitter(); c.kill = () => {}; children.push(c); queueMicrotask(() => c.emit("error", new Error("EACCES"))); return c; };
  const runner = createRunner({ spawn, hookPath: HOOK, env: {} });
  await runner.event({ session_id: "deepseek-s1", hook_event_name: "Stop" });
  await runner.event({ session_id: "deepseek-s1", hook_event_name: "Stop" });
  assert.equal(children.length, 2);
  const throwing = createRunner({ spawn: () => { throw new Error("nope"); }, hookPath: HOOK, env: {} });
  await throwing.event({ session_id: "deepseek-s1", hook_event_name: "Stop" });
});

test("ask returns the child's stdout and is killed by its signal", async () => {
  const { spawn, children } = fakeSpawn();
  const runner = createRunner({ spawn, hookPath: HOOK, env: {} });
  const answered = runner.ask(PAYLOAD, new AbortController().signal);
  await sleep(5);
  assert.deepEqual(children[0].args, ["ask"]);
  children[0].finish(ALLOW);
  assert.equal(await answered, ALLOW);

  const ac = new AbortController();
  const killed = runner.ask(PAYLOAD, ac.signal);
  await sleep(5);
  ac.abort();
  assert.equal(await killed, "");
  assert.equal(children[1].killed, true);

  const already = new AbortController();
  already.abort();
  assert.equal(await runner.ask(PAYLOAD, already.signal), "");
  assert.equal(children.length, 2, "an already-aborted ask never spawns");
});

test("missing hook is a no-op", async () => {
  const { spawn, children } = fakeSpawn();
  const runner = createRunner({ spawn, hookPath: "/nonexistent/critter-hook", env: {} });
  await runner.event({ session_id: "deepseek-s1", hook_event_name: "Stop" });
  assert.equal(await runner.ask(PAYLOAD, new AbortController().signal), "");
  assert.equal(children.length, 0);
  const req = { signal: new AbortController().signal };
  const result = await raceApproval({
    req,
    next: async () => "rejected",
    ask: (p, s) => runner.ask(p, s),
    payload: PAYLOAD,
    map: mapPermission,
  });
  assert.equal(result, "rejected");
  assert.equal(children.length, 0);
});

/** A cordis stand-in that keeps listeners by event name. */
function fakeCtx() {
  const listeners = {};
  return { listeners, on: (name, fn, prepend) => { (listeners[name] ??= []).push({ fn, prepend }); } };
}

test("apply wires session events, approvals and disposal", async () => {
  const { spawn, children } = fakeSpawn();
  const ctx = fakeCtx();
  apply(ctx, { hookPath: HOOK, spawn });
  const header = { id: "session-abc", cwd: "/w", delegationDepth: 0 };
  const session = { header };
  const [onEvent] = ctx.listeners["session/event"].map((l) => l.fn);
  assert.equal(ctx.listeners["approval/request"][0].prepend, true);
  assert.equal(ctx.listeners["user-questions/request"][0].prepend, true);

  onEvent(session, { type: "turn/start", data: { turn: 1 } });
  onEvent({ header: { id: "child", cwd: "/w", delegationDepth: 1 } }, { type: "turn/start", data: { turn: 1 } });
  await sleep(10);
  assert.equal(children.length, 1, "SessionStart; the child session is ignored");
  assert.equal(JSON.parse(children[0].stdinText).session_id, "deepseek-session-abc");
  children[0].finish();
  await sleep(10);
  assert.equal(JSON.parse(children[1].stdinText).hook_event_name, "UserPromptSubmit");
  children[1].finish();

  // The phone answers an approval for a tool call the translator has seen.
  onEvent(session, { type: "tool/call", data: { callId: "c1", name: "bash", arguments: JSON.stringify({ command: "rm x" }) } });
  await sleep(10);
  children[2].finish();
  const [onApproval] = ctx.listeners["approval/request"].map((l) => l.fn);
  const req = { agent: { session }, toolName: "bash", callId: "c1", signal: new AbortController().signal };
  const decided = onApproval(req, () => new Promise(() => {}));
  await sleep(10);
  const askChild = children[3];
  assert.deepEqual(askChild.args, ["ask"]);
  assert.deepEqual(JSON.parse(askChild.stdinText).tool_input, { command: "rm x" });
  askChild.finish(ALLOW);
  assert.equal(await decided, "allowed-once");

  // A child session's approval is left to DeepSeek.
  const childReq = { agent: { session: { header: { id: "child", delegationDepth: 1 } } }, toolName: "bash", callId: "x" };
  assert.equal(await onApproval(childReq, async () => "rejected"), "rejected");

  const [onDisposed] = ctx.listeners["agent/disposed"].map((l) => l.fn);
  onDisposed({ agent: { session } });
  await sleep(10);
  assert.equal(JSON.parse(children.at(-1).stdinText).hook_event_name, "SessionEnd");
  children.at(-1).finish();
});
