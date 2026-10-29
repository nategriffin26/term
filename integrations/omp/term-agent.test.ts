import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// Execute the shipped extension; only the clock, managed timers and tmux subprocess are fake.
const source = readFileSync(new URL("./term-agent.ts", import.meta.url), "utf8")
  .replace(/^import .*;\n/gm, "")
  .replace("export default function termAgent", "function termAgent");

interface EventHarness {
  emit(name: string, event?: object, ctx?: object): unknown;
  tick(ms?: number): Promise<void>;
}
/** `options`: pane options tmux already holds ("@diagrams", "@messages", "@read"), kept as the extension sets them;
 *  `branch`: the session entries `getBranch()` returns. */
function harness({ options = {} as Record<string, string>, branch = [] as object[] } = {}) {
  let clock = 1_792_987_200_100;
  let held = false;
  let seen = 0;
  let agent: { state: string; stop: { at: number; why: string }; n?: number } | undefined;
  const pending: Array<() => void> = [];
  const commands: string[][] = [];
  const timers = new Map<object, () => void>();
  const handlers = new Map<string, Function>();
  const ctx = {
    mode: "tui", agent: { kind: "main" }, isIdle: () => true,
    sessionManager: { getBranch: () => branch },
    setTimeout(fn: () => void) { const id = {}; timers.set(id, fn); return id; },
    setInterval() { return {}; }, clearTimer(id: object) { timers.delete(id); },
  };
  const pi = { on: (name: string, fn: Function) => handlers.set(name, fn) };
  vm.runInNewContext(source + "\ntermAgent(pi);", {
    pi, process: { env: { TMUX: "private", TMUX_PANE: "%0" }, pid: 1 },
    Date: { now: () => clock }, existsSync: () => true, createHash,
    execFile(_file: string, args: string[], _options: object, callback: Function) {
      commands.push(args);
      const finish = () => {
        if (args.includes("@agent")) agent = args.includes("-u") ? undefined : JSON.parse(args.at(-1)!);
        if (args.includes("@seen")) {
          const value = args.at(-1)!;
          const stamp = Number(value.match(/,([\d.]+)}$/)?.[1] ?? value);
          seen = args.includes("-F") ? Math.max(seen, stamp) : stamp;
        } else if (args[0] === "set-option" && args.includes("-p") && !args.includes("-u")) {
          const [name, value] = args.slice(-2);
          options[name] = args.includes("-F") ? value.replaceAll(`#{${name}}`, options[name] ?? "") : value;
        }
        callback(null, args[0] === "show-options" ? (options[args.at(-1)!] ?? "") + "\n" : "");
      };
      if (held && !args.includes("-u")) pending.push(finish);
      else finish();
    },
  });
  return {
    commands,
    emit: (name: string, event = {}, context: object = ctx) => handlers.get(name)?.(event, context),
    get agent() { return agent!; },
    /** The last `@diagrams` value written. */
    get diagrams() {
      return commands.filter(args => args[0] === "set-option" && args.includes("@diagrams")).at(-1)?.at(-1);
    },
    get diagramWrites() { return commands.filter(args => args[0] === "set-option" && args.includes("@diagrams")).length; },
    get seen() { return seen; },
    /** The pane's options as tmux would hold them now. */
    options,
    hold() { held = true; },
    release() { held = false; for (const finish of pending.splice(0)) finish(); },
    async tick(ms = 0) {
      clock += ms;
      for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
      // Flush the bounded writes and their coalesced successors.
      for (let i = 0; i < 32; i++) await Promise.resolve();
    },
  };
}

const assistant = (stopReason: string) => ({ role: "assistant", stopReason, content: [] });

async function finish(h: EventHarness, messages: object[]) {
  await h.emit("agent_end", { messages });
  await h.tick();
  await h.tick();
}

describe("Term omp stop state", () => {
  test("cancelled tool and pre-model abort never become done without a terminal assistant", async () => {
    for (const toolName of ["ask", "bash", undefined]) {
      const h = harness();
      await h.emit("session_start");
      await h.emit("agent_start");
      if (toolName) {
        await h.emit("tool_execution_start", { toolName });
        await h.emit("tool_execution_end", { toolName, isError: true, result: { details: {} } });
      }
      await finish(h, toolName ? [assistant("toolUse")] : []);
      expect(h.agent.state).toBe("aborted");
      expect(h.agent.stop.why).toBe("aborted");
    }
  });

  test("prompt and instant stop, and answer and instant stop, stay ordered even in one clock tick", async () => {
    const h = harness();
    await h.emit("session_start");
    await h.emit("input", { source: "interactive" });
    await h.emit("agent_start");
    await finish(h, [assistant("stop")]);
    expect(h.agent.stop.at).toBeGreaterThan(h.seen);
    await h.emit("agent_start");
    await h.emit("tool_execution_start", { toolName: "ask" });
    await h.tick();
    const ask = h.agent.stop.at;
    await h.emit("tool_execution_end", { toolName: "ask", isError: false });
    expect(h.seen).toBeGreaterThanOrEqual(ask);
    await finish(h, [assistant("stop")]);
    expect(h.agent.stop.at).toBeGreaterThan(h.seen);
  });

  test("shutdown drains an in-flight set before unsetting, and queued work cannot republish", async () => {
    const h = harness();
    await h.emit("session_start");
    h.hold();
    await h.emit("agent_start");
    await h.tick();
    await h.emit("turn_end");
    const shutdown = h.emit("session_shutdown");
    await Promise.resolve();
    h.release();
    await shutdown;
    await h.tick();
    await h.emit("turn_end");
    await h.tick();
    expect(h.agent).toBeUndefined();
  });

  test("completed and failed model outcomes survive, and a later run clears an earlier abort", async () => {
    const h = harness();
    await h.emit("session_start");
    for (const [reason, state] of [["aborted", "aborted"], ["stop", "done"], ["error", "error"], ["length", "error"]]) {
      await h.emit("agent_start");
      await finish(h, [assistant(reason)]);
      expect(h.agent.state).toBe(state);
    }
  });

  test("real tmux advances fractional acknowledgements but never moves them backwards", async () => {
    const h = harness();
    await h.emit("session_start");
    await h.tick(25);
    await h.emit("input", { source: "interactive" });
    const command = h.commands.find(args => args.includes("@seen"))!;
    // Python owns the private server: Bun's child-process pipes can stall tmux clients on macOS.
    const child = Bun.spawn(["python3", "-c", `
import json, subprocess, sys
server = sys.argv[1]
def tmux(*args):
    return subprocess.check_output(["tmux", "-L", server, *args], text=True, timeout=5).strip()
tmux("-f", "/dev/null", "new-session", "-d", "-s", "proof", "sleep 60")
try:
    command = json.loads(sys.argv[2])
    tmux("set-option", "-t", "%0", "@seen", "1792987200.001")
    tmux(*command)
    assert tmux("show-option", "-t", "%0", "-v", "@seen") == "1792987200.125"
    tmux("set-option", "-t", "%0", "@seen", "1792987200.999")
    tmux(*command)
    assert tmux("show-option", "-t", "%0", "-v", "@seen") == "1792987200.999"
finally:
    tmux("kill-server")
`, `term-extension-test-${process.pid}`, JSON.stringify(command)], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    expect(await child.exited).toBe(0);
  });
});

const fence = (src: string) => "```mermaid\n" + src + "\n```";
const said = (text: string) => ({ message: { role: "assistant", content: [{ type: "text", text }] } });
const published = (h: { diagrams?: string }) => JSON.parse(h.diagrams!) as { v: number; d: Array<{ h: string; t: number; src: string }> };
const flow = "flowchart TD\n  A[Phone] --> B[tmux]";
const seq = "sequenceDiagram\n  P->>T: attach";

describe("Term omp diagrams", () => {
  test("a fence is published once, as soon as it closes, and an open fence never is", async () => {
    const h = harness();
    await h.emit("session_start");
    await h.emit("message_start", { message: { role: "assistant" } });
    await h.emit("message_update", said("Here:\n```mermaid\nflowchart TD\n  A[Phone] -->"));
    expect(h.diagramWrites).toBe(0);
    await h.emit("message_update", said("Here:\n" + fence(flow)));
    await h.emit("message_update", said("Here:\n" + fence(flow) + "\nMore prose."));
    await h.emit("message_end", said("Here:\n" + fence(flow) + "\nMore prose."));
    expect(h.diagramWrites).toBe(1);
    const value = published(h);
    expect(value.v).toBe(1);
    expect(value.d).toEqual([{ h: createHash("sha256").update(flow).digest("hex").slice(0, 12), t: 1_792_987_200, src: flow }]);
  });

  test("newest last, and a source drawn again in a later message moves to the end", async () => {
    const h = harness();
    await h.emit("session_start");
    for (const src of [flow, seq, flow]) {
      await h.emit("message_start", { message: { role: "assistant" } });
      await h.emit("message_end", said(fence(src)));
    }
    expect(published(h).d.map(e => e.src)).toEqual([seq, flow]);
  });

  test("a restarted omp keeps the sources an earlier one left in the pane, ahead of its own", async () => {
    const earlier = { h: "0123456789ab", t: 1_792_980_000, src: seq };
    const h = harness({ options: { "@diagrams": JSON.stringify({ v: 1, d: [earlier] }) } });
    await h.emit("session_start");
    await h.emit("message_end", said(fence(flow)));
    expect(published(h).d.map(e => e.src)).toEqual([seq, flow]);
    expect(published(h).d[0]).toEqual(earlier);
  });

  test("a pane value that is not a source list, or entries missing fields, are dropped", async () => {
    for (const pane of ["", "not json", JSON.stringify({ v: 1, d: "x" }), JSON.stringify({ v: 1, d: [{ h: "a", src: seq }, { h: 1, t: 1, src: seq }] })]) {
      const h = harness({ options: { "@diagrams": pane } });
      await h.emit("session_start");
      await h.emit("message_end", said(fence(flow)));
      expect(published(h).d.map(e => e.src)).toEqual([flow]);
    }
  });

  test("the value stays within 12 KB by dropping the oldest, and one source over the cap is skipped", async () => {
    const h = harness();
    await h.emit("session_start");
    const sources = Array.from({ length: 12 }, (_, i) => `flowchart TD\n  A${i}[${"x".repeat(1500)}] --> B`);
    for (const src of sources) await h.emit("message_end", said(fence(src)));
    expect(h.diagrams!.length).toBeLessThanOrEqual(12_000);
    const kept = published(h).d.map(e => e.src);
    expect(kept.at(-1)).toBe(sources.at(-1));
    expect(kept).not.toContain(sources[0]);
    expect(kept.length).toBeGreaterThanOrEqual(7);
    await h.emit("message_end", said(fence(`flowchart TD\n  A[${"y".repeat(13_000)}] --> B`)));
    expect(published(h).d.map(e => e.src)).toEqual(kept);
  });

  test("non-ASCII is escaped, so a tmux without a UTF-8 locale keeps it", async () => {
    const h = harness();
    await h.emit("session_start");
    const src = "flowchart TD\n  A[Café → 東京] --> B[✓]";
    await h.emit("message_end", said(fence(src)));
    expect(/^[\x20-\x7e]*$/.test(h.diagrams!)).toBe(true);
    expect(published(h).d[0].src).toBe(src);
  });

  test("subagents and user messages publish nothing", async () => {
    const h = harness();
    await h.emit("session_start");
    await h.emit("message_end", said(fence(flow)), { mode: "tui", agent: { kind: "sub" } });
    await h.emit("message_end", { message: { role: "user", content: [{ type: "text", text: fence(flow) }] } });
    expect(h.diagramWrites).toBe(0);
  });

  test("the system prompt gains the Diagrams section once, in the main session only", async () => {
    const h = harness();
    const first = (await h.emit("before_agent_start", { systemPrompt: ["base"] })) as { systemPrompt: string[] };
    expect(first.systemPrompt[0]).toBe("base");
    expect(first.systemPrompt[1]).toStartWith("# Diagrams\n");
    expect(first.systemPrompt).toHaveLength(2);
    expect(await h.emit("before_agent_start", first)).toBeUndefined();
    expect(await h.emit("before_agent_start", { systemPrompt: ["base"] }, { mode: "tui", agent: { kind: "sub" } })).toBeUndefined();
  });

  test("real tmux takes a full 12 KB value, and Term's fetch reads it back whole", async () => {
    const h = harness();
    await h.emit("session_start");
    for (let i = 0; i < 12; i++) await h.emit("message_end", said(fence(`flowchart TD\n  A${i}[${"é".repeat(250)}] --> B`)));
    const command = h.commands.filter(args => args.includes("@diagrams")).at(-1)!;
    expect(command.at(-1)!.length).toBeGreaterThan(11_000);
    const child = Bun.spawn(["python3", "-c", `
import json, subprocess, sys
server = sys.argv[1]
def tmux(*args):
    return subprocess.check_output(["tmux", "-L", server, *args], text=True, timeout=5).strip()
tmux("-f", "/dev/null", "new-session", "-d", "-s", "proof", "sleep 60")
try:
    command = json.loads(sys.argv[2])
    tmux(*command)
    # Term's fetch (app/Sources/Diagrams/DiagramSource.swift fetchCommand)
    assert tmux("list-panes", "-s", "-t", "=proof", "-f", "#{@diagrams}", "-F", "#{@diagrams}") == command[-1]
finally:
    tmux("kill-server")
`, `term-extension-test-${process.pid}`, JSON.stringify(command)], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    expect(await child.exited).toBe(0);
  });
});

type Listed = { v: number; m: Array<{ i: string; t: number; h: string }> };
const listed = (h: { options: Record<string, string> }) => JSON.parse(h.options["@messages"]) as Listed;
const heads = (h: { options: Record<string, string> }) => listed(h).m.map(e => e.h);
const read = (h: { options: Record<string, string> }) => (h.options["@read"] ?? "").split(" ").filter(Boolean).sort();
/** An assistant message as omp stores it: text blocks, then tool calls. */
const reply = (timestamp: number, text: string, extra: object[] = []) =>
  ({ role: "assistant", timestamp, stopReason: "stop", content: [{ type: "text", text }, ...extra] });
const entry = (message: object) => ({ type: "message", message });
// Ids: each message's timestamp in ms, base 36 (worked out by hand from the contract, not by the extension's code).
const T1 = 1_792_987_200_100, T2 = 1_792_987_260_000, T3 = 1_792_987_320_000, T4 = 1_792_987_380_000;
const [I1, I2, I3, I4] = ["mvoqa9us", "mvoqbk2o", "mvoqcudc", "mvoqe4o0"];

describe("Term omp messages", () => {
  // Bug: Term greps the pane's history for the head; any markdown left in it, or a URL omp prints after a link's
  // text, or a cut inside a word that wraps differently, finds nothing (heads below are as omp 18.13 printed them).
  test("a head is the first prose line as omp prints it, cut back to a word", async () => {
    const cases: Array<[string, string]> = [
      ["**No: don't rewire Computer around Pomerado.** Its core idea", "No: don't rewire Computer around"],
      ["Yes. [`heavy`](https://github.com/mokevnin/heavy) fixes one of the causes", "Yes. heavy"],
      ["1. Yes, `ios-dev` is in my skill list.", "Yes, ios-dev is in my skill"],
      ["Your **Headroom** app is at:", "Your Headroom app is at:"],
      ["\n\n```sh\nls -la\n```\n## Summary of *the* run\nbody", "Summary of the run"],
      ["| a | b |\n|---|---|\n| 1 | 2 |\n---\n- After the table, a list item", "After the table, a list item"],
      ["snake_case_name stays, so does 2*3*4", "snake_case_name stays, so does"],
      ["Antidisestablishmentarianismically", "Antidisestablishmentarianismical"],
      // 32 code points, the last an emoji (two UTF-16 units): whole, not cut back.
      ["Done. Shipped the rail to main 🎉 and more", "Done. Shipped the rail to main 🎉"],
      ["Café → 東京: déjà vu", "Café → 東京: déjà vu"],
    ];
    const h = harness();
    await h.emit("session_start");
    for (const [n, [text]] of cases.entries()) await h.emit("message_end", { message: reply(T1 + n, text) });
    await h.tick();
    expect(heads(h)).toEqual(cases.map(([, head]) => head));
    expect(/^[\x20-\x7e]*$/.test(h.options["@messages"])).toBe(true);
  });

  // Bug: a reply with no prose (a tool-only step, thinking, a code block alone) would mark nothing findable.
  test("only text with prose is listed; thinking, tools, users and subagents never are", async () => {
    const h = harness();
    await h.emit("session_start");
    await h.emit("message_end", { message: { role: "assistant", timestamp: T1, content: [{ type: "thinking", thinking: "hmm" }] } });
    await h.emit("message_end", { message: { role: "assistant", timestamp: T2, content: [{ type: "toolCall", name: "bash", arguments: {} }] } });
    await h.emit("message_end", { message: reply(T3, "```\nonly code\n```\n   ") });
    await h.emit("message_end", { message: { role: "user", timestamp: T4, content: [{ type: "text", text: "my prompt" }] } });
    await h.emit("message_end", { message: reply(T4, "from a subagent") }, { mode: "tui", agent: { kind: "sub" } });
    await h.tick();
    expect(listed(h).m).toEqual([]);
  });

  // Bug: a question omp asks is what the user must not miss; without its own entry it has no mark.
  test("an ask lists each question after the message's text, ids ending q, q2", async () => {
    const h = harness();
    await h.emit("session_start");
    const ask = { type: "toolCall", name: "ask", arguments: { questions: [
      { id: "a", question: "Which **build** should I install on the Duo tonight?" },
      { id: "b", question: "Keep the old one?\nIt still works." },
    ] } };
    await h.emit("message_end", { message: reply(T1, "Two builds are ready.", [ask]) });
    await h.tick();
    expect(listed(h)).toEqual({ v: 1, m: [
      { i: I1, t: 1_792_987_200, h: "Two builds are ready." },
      { i: I1 + "q", t: 1_792_987_200, h: "Which build should I install on" },
      { i: I1 + "q2", t: 1_792_987_200, h: "Keep the old one?" },
    ] });
  });

  // Bug: tmux refuses an option near 17 KB, so an unbounded list stops updating in a long session.
  test("the list stays within 12 KB by dropping the oldest, newest last", async () => {
    const h = harness();
    await h.emit("session_start");
    for (let n = 0; n < 400; n++) await h.emit("message_end", { message: reply(T1 + n * 1000, `Message ${n} é ${"x".repeat(20)}`) });
    await h.tick();
    expect(h.options["@messages"].length).toBeLessThanOrEqual(12_000);
    const kept = listed(h).m;
    expect(kept.at(-1)!.h).toStartWith("Message 399 ");
    expect(kept[0].h).not.toStartWith("Message 0 ");
    expect(kept.length).toBeGreaterThan(100);
    expect(h.agent.n).toBe(400);
  });

  // Bug: rolling the extension out would show every old message as unread on every pane.
  test("the first start in a pane lists the branch, every message read", async () => {
    const branch = [entry(reply(T1, "First answer.")), entry({ role: "user", content: "next" }), entry(reply(T2, "Second answer."))];
    const h = harness({ branch });
    await h.emit("session_start");
    await h.tick();
    expect(listed(h).m.map(e => e.i)).toEqual([I1, I2]);
    expect(read(h)).toEqual([I1, I2]);
    expect(h.agent.n).toBe(2);
  });

  // Bug: restarting omp (or resuming) would mark unread messages read, or keep ids of messages long gone.
  test("a restart keeps what was unread, reads what is new to the pane, and drops ids no longer listed", async () => {
    const before = { v: 1, m: [{ i: "gone1", t: 1, h: "Old." }, { i: I1, t: 1, h: "First answer." }, { i: I2, t: 1, h: "Second answer." }] };
    const branch = [entry(reply(T1, "First answer.")), entry(reply(T2, "Second answer.")), entry(reply(T3, "Third answer."))];
    const h = harness({ options: { "@messages": JSON.stringify(before), "@read": "gone1 " + I1 + " " + I1 }, branch });
    await h.emit("session_start");
    await h.tick();
    expect(read(h)).toEqual([I1, I3]);
  });

  // Bug: answering from the Mac would leave the message answered still marked unread on the phone.
  test("a prompt or an answer reads the newest message, after the start's reading", async () => {
    const h = harness({ branch: [entry(reply(T1, "First answer."))] });
    await h.emit("session_start");
    await h.emit("message_end", { message: reply(T2, "Mid-turn note.") });
    await h.emit("message_end", { message: reply(T3, "The answer.") });
    await h.emit("input", { source: "interactive" });
    await h.tick();
    expect(read(h)).toEqual([I1, I3]);
    const ask = { type: "toolCall", name: "ask", arguments: { questions: [{ question: "Ship it?" }] } };
    await h.emit("message_end", { message: reply(T4, "Ready.", [ask]) });
    await h.emit("tool_execution_end", { toolName: "ask", isError: false });
    await h.tick();
    expect(read(h)).toEqual([I1, I3, I4 + "q"]);
    await h.emit("input", { source: "extension" });
    await h.emit("message_end", { message: reply(T4 + 1, "Later.") });
    await h.emit("input", { source: "extension" });
    await h.tick();
    expect(read(h)).not.toContain((T4 + 1).toString(36));
  });

  // Bug: a set-option that replaces instead of appending loses Term's own reads when both write at once.
  test("real tmux: the start's list, then appends, give the read set", async () => {
    const h = harness({ branch: [entry(reply(T1, "First answer."))] });
    await h.emit("session_start");
    await h.emit("message_end", { message: reply(T2, "The answer.") });
    await h.emit("input", { source: "interactive" });
    await h.tick();
    const writes = h.commands.filter(args => args[0] === "set-option" && (args.includes("@read") || args.includes("@messages")));
    const child = Bun.spawn(["python3", "-c", `
import json, subprocess, sys
server = sys.argv[1]
def tmux(*args):
    return subprocess.check_output(["tmux", "-L", server, *args], text=True, timeout=5).strip()
tmux("-f", "/dev/null", "new-session", "-d", "-s", "proof", "sleep 60")
try:
    for command in json.loads(sys.argv[2]):
        tmux(*command)
    # Term's own append when a message has been on screen.
    tmux("set-option", "-p", "-F", "-t", "%0", "@read", "#{@read} viewed")
    assert tmux("show-options", "-pqv", "-t", "%0", "@read").split() == sys.argv[3].split(), tmux("show-options", "-pqv", "-t", "%0", "@read")
    assert json.loads(tmux("show-options", "-pqv", "-t", "%0", "@messages"))["m"][-1]["h"] == "The answer."
finally:
    tmux("kill-server")
`, `term-extension-test-${process.pid}`, JSON.stringify(writes), `${I1} ${I2} viewed`], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    expect(await child.exited).toBe(0);
  });
});
