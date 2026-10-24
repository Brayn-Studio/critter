// DeepSeek Harness plugin: reports each top-level session to Critter by spawning
// `critter-hook` with Claude-Code-shaped hook JSON, and lets the phone answer DeepSeek's
// approval and question prompts. Runs inside the harness's host process (a cordis plugin),
// so everything here is best-effort: a missing hook, a spawn error or unreadable output
// falls back to DeepSeek's own behaviour and never throws out of a listener.
import { spawn as nodeSpawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { SessionTranslator, askAnswerToDeepSeek, claudeQuestions, isTopLevel, mapTool } from "./translate.js";

export const name = "critter-deepseek";

const EVENT_TIMEOUT_MS = 5000;

/**
 * Spawns `critter-hook` for hook JSON. `event` calls are queued per session (the pet must
 * see PreToolUse before PostToolUse); `ask` is not queued, since it waits for the phone.
 */
export function createRunner({ spawn = nodeSpawn, hookPath, env = {}, eventTimeoutMs = EVENT_TIMEOUT_MS }) {
  const tails = new Map(); // session id -> last queued event

  /** Resolves with the child's stdout; "" for any failure, a kill, or a missing hook. */
  function run(arg, payload, { signal, timeoutMs } = {}) {
    return new Promise((resolve) => {
      if (signal?.aborted || !existsSync(hookPath)) return resolve("");
      let child;
      try {
        child = spawn(hookPath, [arg], { stdio: ["pipe", "pipe", "ignore"], env });
      } catch {
        return resolve("");
      }
      let out = "";
      let timer;
      const finish = () => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", kill);
        resolve(out);
      };
      const kill = () => {
        out = "";
        try { child.kill(); } catch {}
        finish();
      };
      child.on("error", finish);
      child.on("close", finish);
      child.stdout?.on("data", (chunk) => { out += chunk.toString(); });
      child.stdin?.on?.("error", () => {});
      try {
        child.stdin.write(JSON.stringify(payload) + "\n");
        child.stdin.end();
      } catch {}
      signal?.addEventListener("abort", kill, { once: true });
      if (timeoutMs) {
        timer = setTimeout(kill, timeoutMs);
        timer.unref?.();
      }
    });
  }

  return {
    event(payload) {
      const sid = String(payload?.session_id ?? "");
      const next = (tails.get(sid) ?? Promise.resolve()).then(() => run("event", payload, { timeoutMs: eventTimeoutMs }));
      // The queue's tail never rejects, so one failure cannot poison the session's later events.
      const tail = next.then(() => {}, () => {});
      tails.set(sid, tail);
      tail.then(() => { if (tails.get(sid) === tail) tails.delete(sid); });
      return next.then(() => {});
    },
    ask(payload, signal) {
      return run("ask", payload, { signal });
    },
  };
}

/**
 * Lets the phone and DeepSeek's own panel answer the same request; the first to answer wins.
 *
 * `next()` takes no arguments in cordis, and later listeners (the one relaying to the UI)
 * see this same `req`. So the UI's cancellation signal is swapped for one of ours, chained
 * to the original: when the phone wins, aborting ours withdraws DeepSeek's panel (verified
 * against 0.2.1-rc.3). A phone that stays silent or fails leaves the UI in charge.
 */
export async function raceApproval({ req, next, ask, payload, map }) {
  const ours = new AbortController();
  const askAbort = new AbortController();
  try {
    const original = req.signal;
    if (original) {
      if (original.aborted) ours.abort(original.reason);
      else original.addEventListener("abort", () => ours.abort(original.reason), { once: true });
    }
    try { req.signal = ours.signal; } catch {}
    ours.signal.addEventListener("abort", () => askAbort.abort(), { once: true });
    if (ours.signal.aborted) askAbort.abort();
  } catch {
    return next();
  }

  let phone = new Promise(() => {}); // stays pending unless the phone gives a decision
  try {
    phone = Promise.resolve(ask(payload, askAbort.signal)).then(
      (stdout) => {
        let outcome = null;
        try { outcome = map(stdout); } catch {} // an unreadable answer is no answer: keep waiting for the UI
        return outcome === null || outcome === undefined ? new Promise(() => {}) : { from: "phone", outcome };
      },
      () => new Promise(() => {}),
    );
  } catch {}

  const ui = Promise.resolve()
    .then(() => next())
    .then((outcome) => ({ from: "ui", outcome }), (error) => ({ from: "ui", error }));

  const winner = await Promise.race([ui, phone]);
  if (winner.from === "phone") {
    ours.abort(new Error("answered on phone"));
    return winner.outcome;
  }
  askAbort.abort();
  if ("error" in winner) throw winner.error;
  return winner.outcome;
}

export function apply(ctx, config = {}) {
  const hookPath = config.hookPath ?? join(homedir(), ".critter", "bin", "critter-hook");
  const runner = createRunner({ spawn: config.spawn, hookPath, env: { ...process.env, CRITTER_ENTRYPOINT: "deepseek-desktop" } });
  const translators = new Map(); // dsh session id -> SessionTranslator

  const translatorFor = (header) => {
    if (!header?.id || !isTopLevel(header)) return undefined;
    let t = translators.get(header.id);
    if (!t) {
      t = new SessionTranslator(header.id, header.cwd ?? "");
      translators.set(header.id, t);
    }
    return t;
  };
  const send = (payloads) => { for (const p of payloads) runner.event(p).catch(() => {}); };

  ctx.on("session/event", (session, event) => {
    try { send(translatorFor(session?.header)?.feed(event) ?? []); } catch {}
  });

  ctx.on("agent/disposed", ({ agent } = {}) => {
    try {
      const id = agent?.session?.header?.id;
      const t = translators.get(id);
      if (!t) return;
      translators.delete(id);
      send(t.end());
    } catch {}
  });

  const headerOf = (req) => req?.agent?.session?.header;
  const askPayload = (t, tool_name, tool_input) => ({
    session_id: t.sessionId,
    cwd: t.cwd,
    hook_event_name: "PermissionRequest",
    tool_name,
    tool_input,
  });
  const ask = (payload, signal) => runner.ask(payload, signal);

  // Setup problems fall back to next(); once the race runs, a rejection is next()'s own and
  // propagates as DeepSeek would have raised it (calling next() twice would ask the UI twice).
  ctx.on("approval/request", (req, next) => {
    let race;
    try {
      const t = translatorFor(headerOf(req));
      if (!t) return next();
      const { toolName, toolInput } = t.toolInputFor(req.callId) ?? mapTool(String(req.toolName ?? ""), {});
      race = {
        req, next, ask,
        payload: askPayload(t, toolName, toolInput),
        map: (stdout) => askAnswerToDeepSeek("permission", stdout),
      };
    } catch {
      return next();
    }
    return raceApproval(race);
  }, true);

  ctx.on("user-questions/request", (req, next) => {
    let race;
    try {
      const t = translatorFor(headerOf(req));
      if (!t || !Array.isArray(req.questions)) return next();
      race = {
        req, next, ask,
        payload: askPayload(t, "AskUserQuestion", { questions: claudeQuestions(req.questions) }),
        map: (stdout) => askAnswerToDeepSeek("question", stdout, req.questions),
      };
    } catch {
      return next();
    }
    return raceApproval(race);
  }, true);
}
