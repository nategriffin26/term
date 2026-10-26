// Term's omp extension: keeps this omp session's state in its tmux pane as the user option `@agent` (compact JSON),
// so any tmux client can show what each agent is doing and which ones stopped for you. Term reads it with
// `tmux list-panes -a -f '#{@agent}'`. When you prompt or answer omp, it sets the session option `@seen`, so a stop
// you have already seen is not announced again on any device. Outside tmux it does nothing.
//
// The payload, version 1 (fields are omitted when unknown; times are fractional unix seconds):
//   v 1 · state working|ask|approval|done|error|aborted|idle · since (the state began) · t (written; a heartbeat
//   rewrites it every 30 s) · pid · title · doing (current step) · todo [done, total, current] · q and opts (the
//   question and its choices, or the tool waiting for approval) · last (the final answer, cut) · took (seconds the
//   turn ran) · stop {at, why} (the last time it stopped for you) · model · think · ctx (% of the context window) ·
//   cost (USD, subagents included) · subs (subagents running) · cwd · branch
// Strings are cut short and non-ASCII is \u-escaped, so the value survives a tmux without a UTF-8 locale.
//
// It also keeps the Mermaid sources of this session's answers in the pane option `@diagrams`, so Term can draw the
// ASCII diagrams omp prints as real diagrams: {"v":1,"d":[{"h":sha256 of the source, 12 hex, "t":unix s,"src":…}]},
// newest last, written as soon as a ```mermaid fence closes and again when the message ends, at most 12 KB (oldest
// dropped first; tmux refuses an option value near 17 KB), \u-escaped the same way. It outlives omp: its ASCII stays
// in the pane's history. And it tells the model, in the system prompt, how to draw diagrams that read on a phone.
// @ts-nocheck
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";

const HEARTBEAT_MS = 30_000;
/** Progress (current step, todo, context, cost) is written at most this often; state changes at once. */
const PROGRESS_MS = 2_000;
/** After a turn ends, how long to wait for omp to go idle before calling it a stop. */
const SETTLE_POLL_MS = 250;
const SETTLE_MAX_MS = 10_000;
/** Largest `@diagrams` value written. */
const DIAGRAMS_CAP = 12_000;

const DIAGRAMS = [
  "# Diagrams",
  "The user often reads this session in Term, a phone terminal that draws ```mermaid blocks as real diagrams in the terminal's colours; on the Mac the same block shows as ASCII. Draw one when structure is the point — a flow with branches, who calls whom in what order, states and their transitions, how a few records relate — and prose would take a paragraph. Never draw a list, a straight line of two or three steps, or anything one sentence says.",
  "",
  "Make it read on a phone held upright (about 45 characters wide):",
  "- flowchart TD for flows; never LR with more than three nodes in a row. sequenceDiagram for exchanges between parties; stateDiagram-v2 for lifecycles; erDiagram or classDiagram only for a handful of entities.",
  "- At most about 12 nodes, or 4 participants and 10 messages. Split a bigger picture into two diagrams with a sentence between them.",
  "- Node labels two to four words; edge labels one or two words; short ids (A, B, auth). No line breaks, HTML, icons or math in labels.",
  "- No classDef, style, linkStyle, init blocks or themes: Term colours diagrams from the terminal theme.",
  "- One sentence before the block says what it shows. Do not restate the diagram in prose after it.",
].join("\n");

const pane = process.env.TMUX_PANE;
const tmux = process.env.TMUX && pane ? findTmux() : undefined;

function findTmux() {
  const found = globalThis.Bun?.which?.("tmux");
  if (found) return found;
  return ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].find((p) => existsSync(p));
}

// Keep events ordered even when a prompt, answer and stop share a clock tick.
let lastTime = 0;
const now = () => (lastTime = Math.max(Date.now(), lastTime + 1)) / 1000;

/** One line, collapsed whitespace, at most `max` characters. */
function cut(text, max) {
  if (typeof text !== "string") return undefined;
  const line = text.replace(/\s+/g, " ").trim();
  if (!line) return undefined;
  // By code point, so an emoji is never split into half a surrogate pair (invalid once escaped).
  const chars = Array.from(line);
  return chars.length > max ? chars.slice(0, max - 1).join("").trimEnd() + "…" : line;
}

function run(args, timeout = 2_000) {
  const { promise, resolve } = Promise.withResolvers();
  try {
    execFile(tmux, args, { timeout }, (error) => resolve(!error));
  } catch {
    resolve(false);
  }
  return promise;
}

/** done / total / current task from a todo tool's phases. */
function todoFrom(phases) {
  if (!Array.isArray(phases)) return undefined;
  const tasks = phases.flatMap((p) => (Array.isArray(p?.tasks) ? p.tasks : [])).filter((t) => t?.status !== "abandoned");
  if (tasks.length === 0) return undefined;
  const done = tasks.filter((t) => t.status === "completed").length;
  const current = tasks.find((t) => t.status === "in_progress")?.content;
  return [done, tasks.length, cut(current, 80) ?? null];
}

function textOf(message) {
  if (!Array.isArray(message?.content)) return typeof message?.content === "string" ? message.content : "";
  return message.content.filter((b) => b?.type === "text").map((b) => b.text).join("\n");
}

/** Only an explicit terminal response is success; a tool-only or pre-model end is interrupted. */
function stopKind(message) {
  switch (message?.stopReason) {
    case "stop":
      return "done";
    case "error":
    case "length":
      return "error";
    default:
      return "aborted";
  }
}

// One omp process runs in one pane; subagent sessions in the same process share this module and are ignored.
const s = {
  ctx: undefined,
  state: "idle",
  since: now(),
  workStart: undefined,
  title: undefined,
  doing: undefined,
  todo: undefined,
  q: undefined,
  opts: undefined,
  last: undefined,
  took: undefined,
  stop: undefined,
  branch: undefined,
  /** A turn ended and omp may be about to go idle: { kind, last, deadline }. */
  ending: undefined,
  written: "",
  lastWrite: 0,
  timer: undefined,
  writing: undefined,
  closing: false,
  again: false,
  heartbeat: undefined,
  settle: undefined,
};

function later(fn, ms) {
  const ctx = s.ctx;
  if (ctx?.setTimeout) return ctx.setTimeout(fn, ms);
  const t = setTimeout(() => {
    try {
      fn();
    } catch {}
  }, ms);
  t.unref?.();
  return t;
}

function cancel(timer) {
  if (!timer) return;
  if (s.ctx?.clearTimer) s.ctx.clearTimer(timer);
  else clearTimeout(timer);
}

function payload() {
  const ctx = s.ctx;
  const p = { v: 1, state: s.state, since: s.since, t: now(), pid: process.pid };
  const put = (k, v) => {
    if (v !== undefined && v !== null && v !== "") p[k] = v;
  };
  put("title", cut(s.title, 80));
  put("doing", s.state === "working" ? s.doing : undefined);
  put("todo", s.todo);
  put("q", s.q);
  put("opts", s.opts?.length ? s.opts : undefined);
  put("last", s.last);
  put("took", s.took);
  put("stop", s.stop);
  try {
    put("model", cut(ctx?.model?.name ?? ctx?.model?.id, 40));
  } catch {}
  try {
    put("think", s.api?.getThinkingLevel?.());
  } catch {}
  try {
    const usage = ctx?.getContextUsage?.();
    if (usage && Number.isFinite(usage.percent)) put("ctx", Math.round(usage.percent));
  } catch {}
  try {
    const cost = Math.round((ctx?.sessionManager?.getUsageStatistics?.()?.cost ?? 0) * 100) / 100;
    if (cost > 0) put("cost", cost);
  } catch {}
  try {
    const subs = ctx?.getAsyncJobSnapshot?.()?.running?.filter((j) => j?.type === "task").length;
    if (subs) put("subs", subs);
  } catch {}
  put("cwd", ctx?.cwd);
  put("branch", s.branch);
  return p;
}

async function write(force) {
  if (!tmux || !s.ctx || s.closing) return;
  if (s.writing) {
    s.again = true;
    return;
  }
  let json;
  try {
    json = ascii(JSON.stringify(payload()));
  } catch {
    return;
  }
  // Ignore the heartbeat timestamp when comparing real changes.
  const key = json.replace(/"t":[\d.]+,/, "");
  if (!force && key === s.written) return;
  s.lastWrite = Date.now();
  s.writing = run(["set-option", "-p", "-t", pane, "@agent", json]);
  if (await s.writing) s.written = key;
  s.writing = undefined;
  if (s.again) {
    s.again = false;
    void write(false);
  }
}

/** JSON with non-ASCII \u-escaped. */
function ascii(json) {
  return json.replace(/[\u007f-\uffff]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
}

// `@diagrams`: published sources oldest first, the value last written, and the hashes this message already added.
const d = { list: [], json: "", writing: undefined, again: false, current: new Set() };

/** The sources of the closed ```mermaid fences in a message's text. */
function fences(text) {
  if (!text.includes("```mermaid")) return [];
  const out = [];
  const re = /^[ \t]*```mermaid[ \t]*\n([\s\S]*?)\n[ \t]*```[ \t]*$/gm;
  for (let m; (m = re.exec(text)); ) if (m[1].trim()) out.push(m[1]);
  return out;
}

/** Adds a message's closed fences to `@diagrams`, newest last; a source drawn again moves to the end. */
function publishDiagrams(message) {
  if (!tmux || s.closing || message?.role !== "assistant") return;
  let added = false;
  for (const src of fences(textOf(message))) {
    const h = createHash("sha256").update(src).digest("hex").slice(0, 12);
    if (d.current.has(h)) continue;
    d.current.add(h);
    const entry = { h, t: Math.floor(Date.now() / 1000), src };
    // One source over the cap alone would empty the list; it stays ASCII instead.
    if (ascii(JSON.stringify(entry)).length > DIAGRAMS_CAP - 16) continue;
    d.list = d.list.filter((e) => e.h !== h);
    d.list.push(entry);
    added = true;
  }
  if (!added) return;
  let json = ascii(JSON.stringify({ v: 1, d: d.list }));
  while (json.length > DIAGRAMS_CAP) {
    d.list.shift();
    json = ascii(JSON.stringify({ v: 1, d: d.list }));
  }
  d.json = json;
  void writeDiagrams();
}

async function writeDiagrams() {
  if (d.writing) {
    d.again = true;
    return;
  }
  d.writing = run(["set-option", "-p", "-t", pane, "@diagrams", d.json]);
  await d.writing;
  d.writing = undefined;
  if (d.again) {
    d.again = false;
    void writeDiagrams();
  }
}

/** A state change writes at once; progress at most every PROGRESS_MS. */
function changed(progress = false) {
  if (!tmux || !s.ctx || s.closing) return;
  const wait = progress ? Math.max(0, s.lastWrite + PROGRESS_MS - Date.now()) : 0;
  if (s.timer) {
    if (progress) return;
    cancel(s.timer);
  }
  s.timer = later(() => {
    s.timer = undefined;
    void write(false);
  }, wait);
}

function setState(state) {
  if (s.state !== state) s.since = now();
  s.state = state;
}

/** He prompted or answered: whatever stopped for him is seen, on every device. */
function seen() {
  if (!tmux || s.closing) return;
  const at = now();
  // A delayed acknowledgement must never move the shared watermark backwards.
  const value = `#{?#{e|>|f|0:#{?@seen,#{@seen},0},${at}},#{@seen},${at}}`;
  void run(["set-option", "-F", "-t", pane, "@seen", value]);
}

function refreshBranch() {
  const api = s.api;
  if (!api?.exec || !s.ctx?.cwd) return;
  api
    .exec("git", ["-C", s.ctx.cwd, "branch", "--show-current"], { timeout: 2_000 })
    .then((r) => {
      const branch = r?.code === 0 ? cut(r.stdout, 60) : undefined;
      if (branch !== s.branch) {
        s.branch = branch;
        changed(true);
      }
    })
    .catch(() => {});
}

/** The session's state as it stands: a fresh start, a resume, or a switch. */
function start(api, ctx) {
  s.api = api;
  s.ctx = ctx;
  s.ending = undefined;
  s.q = s.opts = s.doing = s.last = s.took = s.stop = undefined;
  s.state = ctx.isIdle?.() === false ? "working" : "idle";
  s.since = now();
  s.title = api.getSessionName?.();
  s.todo = undefined;
  try {
    // The branch's last todo result says where the plan stands.
    const branch = ctx.sessionManager?.getBranch?.() ?? [];
    for (let i = branch.length - 1; i >= 0; i--) {
      const m = branch[i]?.message;
      if (m?.role === "toolResult" && m.toolName === "todo" && Array.isArray(m.details?.phases)) {
        s.todo = todoFrom(m.details.phases);
        break;
      }
    }
  } catch {}
  refreshBranch();
  cancel(s.heartbeat);
  if (ctx.setInterval) {
    s.heartbeat = ctx.setInterval(beat, HEARTBEAT_MS);
  } else {
    s.heartbeat = setInterval(() => {
      try {
        beat();
      } catch {}
    }, HEARTBEAT_MS);
    s.heartbeat.unref?.();
  }
  void write(true);
}

function beat() {
  settle();
  void write(true);
}

/** Commits a turn's end once omp is idle with nothing queued and no subagents still running for it. */
function settle() {
  const e = s.ending;
  const ctx = s.ctx;
  if (!e || !ctx) return false;
  let idle = true;
  try {
    idle = ctx.isIdle?.() !== false && !ctx.hasPendingMessages?.();
    if (idle && ctx.getAsyncJobSnapshot?.()?.running?.some((j) => j?.type === "task")) idle = false;
  } catch {}
  if (!idle) return false;
  s.ending = undefined;
  if (s.state === "ask" || s.state === "approval") return true;
  setState(e.kind);
  s.stop = { at: now(), why: e.kind };
  s.took = s.workStart ? s.since - s.workStart : undefined;
  s.last = e.last;
  s.q = s.opts = s.doing = undefined;
  refreshBranch();
  changed();
  return true;
}

function waitForIdle() {
  cancel(s.settle);
  const step = () => {
    s.settle = undefined;
    if (!s.ending || settle()) return;
    if (Date.now() < s.ending.deadline) s.settle = later(step, SETTLE_POLL_MS);
    // Still busy (subagents, queued messages): the heartbeat or the next turn settles it.
  };
  s.settle = later(step, SETTLE_POLL_MS);
}

function stopFor(why, q, opts) {
  setState(why);
  s.stop = { at: now(), why };
  s.q = q;
  s.opts = opts;
  changed();
}

function resume() {
  s.q = s.opts = undefined;
  setState("working");
  changed();
}

export default function termAgent(pi) {
  if (!tmux) return;
  // The interactive session of this pane only: not subagents, and not an `omp -p` a tool ran in the same pane.
  const main = (ctx) => ctx?.agent?.kind !== "sub" && (ctx?.mode === undefined || ctx.mode === "tui");
  const on = (event, handler) =>
    pi.on(event, async (e, ctx) => {
      if (!main(ctx) || s.closing) return;
      try {
        if (event !== "session_start" && event !== "session_switch" && ctx) s.ctx = ctx;
        handler(e ?? {}, ctx);
      } catch {}
    });

  on("session_start", (_e, ctx) => start(pi, ctx));
  on("session_switch", (_e, ctx) => start(pi, ctx));

  on("input", (e) => {
    if (e.source !== "extension") seen();
  });

  on("agent_start", () => {
    s.ending = undefined;
    cancel(s.settle);
    if (s.state !== "working") s.workStart = now();
    // The answer and duration describe the turn that ended; a new one starts without them.
    s.q = s.opts = s.last = s.took = undefined;
    s.title = pi.getSessionName?.() ?? s.title;
    setState("working");
    changed();
  });

  on("agent_end", (e) => {
    if (e.willContinue === true) return;
    const messages = Array.isArray(e.messages) ? e.messages : [];
    const final = [...messages].reverse().find((m) => m?.role === "assistant");
    s.ending = { kind: stopKind(final), last: cut(textOf(final), 280), deadline: Date.now() + SETTLE_MAX_MS };
    s.title = pi.getSessionName?.() ?? s.title;
    waitForIdle();
  });

  on("message_start", () => {
    d.current = new Set();
  });
  on("message_update", (e) => publishDiagrams(e.message));
  on("message_end", (e) => {
    publishDiagrams(e.message);
    d.current = new Set();
  });

  // Chains from the current base prompt; a retried preparation sees the section already there.
  pi.on("before_agent_start", async (e, ctx) => {
    if (!main(ctx)) return;
    const base = Array.isArray(e?.systemPrompt) ? e.systemPrompt : typeof e?.systemPrompt === "string" ? [e.systemPrompt] : undefined;
    if (!base || base.includes(DIAGRAMS)) return;
    return { systemPrompt: [...base, DIAGRAMS] };
  });

  on("tool_execution_start", (e) => {
    if (e.toolName === "ask") {
      const first = Array.isArray(e.args?.questions) ? e.args.questions[0] : undefined;
      const opts = Array.isArray(first?.options) ? first.options.slice(0, 6).map((o) => cut(o?.label, 40)).filter(Boolean) : [];
      stopFor("ask", cut(first?.question, 120), opts);
      return;
    }
    const doing = cut(e.intent, 80);
    if (doing && doing !== s.doing) {
      s.doing = doing;
      changed(true);
    }
  });

  on("tool_execution_end", (e) => {
    if (e.toolName === "ask") {
      seen();
      resume();
    } else if (e.toolName === "todo" && !e.isError) {
      const todo = todoFrom(e.result?.details?.phases);
      if (todo) {
        s.todo = todo;
        changed(true);
      }
    }
  });

  on("tool_approval_requested", (e) => stopFor("approval", cut(e.toolName, 40)));
  on("tool_approval_resolved", () => {
    seen();
    resume();
  });
  on("plan_review_requested", (e) => stopFor("approval", cut(e.title, 120) ?? "Plan review"));
  on("plan_review_resolved", (_e, ctx) => {
    seen();
    s.q = s.opts = undefined;
    setState(ctx?.isIdle?.() === false ? "working" : "idle");
    changed();
  });

  on("auto_compaction_start", () => {
    s.doing = "Compacting";
    changed(true);
  });
  on("auto_retry_start", () => {
    s.doing = "Retrying";
    changed(true);
  });
  on("turn_end", () => changed(true));

  pi.on("session_shutdown", async (_e, ctx) => {
    if (!main(ctx)) return;
    try {
      s.closing = true;
      s.again = false;
      cancel(s.timer);
      cancel(s.settle);
      cancel(s.heartbeat);
      s.timer = s.settle = s.heartbeat = undefined;
      s.ctx = undefined;
      await s.writing;
      await run(["set-option", "-p", "-u", "-t", pane, "@agent"], 1_000);
    } catch {}
  });
}
