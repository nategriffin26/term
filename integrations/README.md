# Agent status for Term

Term shows what each coding agent in your tmux panes is doing, and which ones stopped for you. Each agent reports through
the pane option `@agent` (payload v1, documented at the top of [`omp/term-agent.ts`](omp/term-agent.ts)). Outside tmux
nothing runs.

Set up a Mac or Linux machine in one step, from a checkout of this repo:

```sh
scripts/term-host check       # sshd, mosh-server, tmux, Tailscale, which agents are here; prints the install command for each gap
scripts/term-host install     # status for every agent found (or name one: claude-code, codex, omp)
scripts/term-host uninstall   # puts every touched file back byte for byte
```

`install` never overwrites your config. It backs each file up, adds only Term's entries, and records what it did in
`~/.term/host`. Adding hooks to a settings file that already exists needs `jq` or `python3`; without either it changes
nothing and tells you what to install. If you edit a file after installing, `uninstall` removes only Term's entries and
keeps the original backup. Start a new agent session after installing.

| Agent | Reports | Cannot report |
| --- | --- | --- |
| **omp** (`omp/term-agent.ts`, copied to `~/.omp/agent/extensions/`) | everything: state, current step, todo, question and choices, last answer, model, context, cost, subagents, 30 s heartbeat | |
| **Claude Code** (`claude-code/`, hooks in `~/.claude/settings.json`) | working (with the tool in use), approval (with the tool and command), ask (`AskUserQuestion`, MCP elicitation, with choices), done (with the last answer and time taken), error (API failure), idle; model, directory, branch | Esc interrupts: Claude Code fires no hook, so the pane keeps saying working until the next event. No todo, context, cost, subagent count. |
| **Codex** (`codex/`, hooks in `~/.codex/hooks.json`) | working (with the command), approval (with the command), done (with the last answer and time taken), aborted (Ctrl-C), idle; model, directory, branch | Codex asking you a question (no hook), todo, context, cost. It does not use Codex's single `notify` slot, so your own `notify` keeps working. |

Hooks run only when something happens, so `t` is not a heartbeat for Claude Code and Codex; it is the time of the last
event. Term should treat a stale `t` as "no news", not "dead": while the agent's process is the pane's command the state
stands, and once the pane is back at a shell a stale working/ask/approval state means the agent exited, which is how
Term already handles omp.

Codex asks you to trust new hooks: after installing, start `codex`, open `/hooks`, and trust the Term hooks. Until then
they do not run.

Tests: `sh integrations/test/hooks.sh` (also `NOJQ=1 sh integrations/test/hooks.sh`) runs each hook against a scratch
tmux server; `bash integrations/test/term-host.sh` runs install and uninstall against a fake HOME.
