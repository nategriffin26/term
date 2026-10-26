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
/** `pane`: the `@diagrams` value the pane already holds, as tmux prints it. */
function harness(pane = "") {
  let clock = 1_792_987_200_100;
  let held = false;
  let seen = 0;
  let agent: { state: string; stop: { at: number; why: string } } | undefined;
  const pending: Array<() => void> = [];
  const commands: string[][] = [];
  const timers = new Map<object, () => void>();
  const handlers = new Map<string, Function>();
  const ctx = {
    mode: "tui", agent: { kind: "main" }, isIdle: () => true,
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
        }
        callback(null, args[0] === "show-options" && args.includes("@diagrams") ? pane + "\n" : "");
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
    hold() { held = true; },
    release() { held = false; for (const finish of pending.splice(0)) finish(); },
    async tick(ms = 0) {
      clock += ms;
      for (const [id, fn] of [...timers]) { timers.delete(id); fn(); }
      // Flush the bounded write and its coalesced successor.
      for (let i = 0; i < 8; i++) await Promise.resolve();
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
    const h = harness(JSON.stringify({ v: 1, d: [earlier] }));
    await h.emit("session_start");
    await h.emit("message_end", said(fence(flow)));
    expect(published(h).d.map(e => e.src)).toEqual([seq, flow]);
    expect(published(h).d[0]).toEqual(earlier);
  });

  test("a pane value that is not a source list, or entries missing fields, are dropped", async () => {
    for (const pane of ["", "not json", JSON.stringify({ v: 1, d: "x" }), JSON.stringify({ v: 1, d: [{ h: "a", src: seq }, { h: 1, t: 1, src: seq }] })]) {
      const h = harness(pane);
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
