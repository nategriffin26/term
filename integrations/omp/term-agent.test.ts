import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// Execute the shipped extension; only the clock, managed timers and tmux subprocess are fake.
const source = readFileSync(new URL("./term-agent.ts", import.meta.url), "utf8")
  .replace(/^import .*;\n/gm, "")
  .replace("export default function termAgent", "function termAgent");

interface EventHarness {
  emit(name: string, event?: object): unknown;
  tick(ms?: number): Promise<void>;
}
function harness() {
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
    Date: { now: () => clock }, existsSync: () => true,
    execFile(_file: string, args: string[], _options: object, callback: Function) {
      commands.push(args);
      const finish = () => {
        if (args.includes("@agent")) agent = args.includes("-u") ? undefined : JSON.parse(args.at(-1)!);
        if (args.includes("@seen")) {
          const value = args.at(-1)!;
          const stamp = Number(value.match(/,([\d.]+)}$/)?.[1] ?? value);
          seen = args.includes("-F") ? Math.max(seen, stamp) : stamp;
        }
        callback(null);
      };
      if (held && !args.includes("-u")) pending.push(finish);
      else finish();
    },
  });
  return {
    commands,
    emit: (name: string, event = {}) => handlers.get(name)?.(event, ctx),
    get agent() { return agent!; },
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
