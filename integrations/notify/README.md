# term-notify

Pushes "An agent needs you" to your phone when an agent running in tmux stops for you. Tapping the push opens Term on that session and pane.

`term-notify` is one Python 3 file (3.8 or newer, standard library only) that runs in the background on the machine where your agents run, macOS or Linux. It needs tmux 3.0 or newer.

## What it sends

Per push, one HTTPS POST to the relay named in your pairing file, with exactly three fields:

```json
{"secret": "…", "session_ref": "…", "kind": "ask"}
```

- `secret`: the random key the phone gave this host. The relay knows which phone it belongs to.
- `session_ref`: an HMAC-SHA256 of the session name, pane id and tmux server identity, keyed with a `routing_key` that stays on this machine and your phone. Only the phone can map it back to a pane.
- `kind`: `ask`, `approval`, `done` or `error`.

Session names, pane ids, titles, questions, answers, agent-provided file paths and host names are never sent or logged. The relay URL must be `https` (plain `http` only for `localhost`); redirects are not followed, so the secret goes only where `relay_url` says. The threat model of the relay itself is in [`relay/README.md`](../../relay/README.md).

## Install

```sh
integrations/notify/term-notify install
```

This copies the program to `~/.local/share/term/notify/`, writes a LaunchAgent (macOS, `~/Library/LaunchAgents/dev.nategriffin.term.notify.plist`) or a systemd user unit (Linux, `~/.config/systemd/user/term-notify.service`), and starts it. It is safe to run again; run it again after updating Term to update the program. `--no-start` writes the files only.

Then pair the host from Term on your phone. The phone writes a pairing file over SSH; the running notifier picks it up within a few seconds, with no restart.

On Linux, a user service stops when you log out. For a server you only reach by SSH, keep it running with `sudo loginctl enable-linger $USER`; `term-notify status` tells you when that is off.

```sh
~/.local/share/term/notify/term-notify status       # service, tmux, pairings; exit 1 when something needs fixing
~/.local/share/term/notify/term-notify uninstall    # stop and remove; pairing files stay
~/.local/share/term/notify/term-notify uninstall --purge   # also delete pairing files
```

Uninstall never touches tmux or any agent's configuration. `term-notify run` starts the watcher in the foreground (`--debounce SECONDS`, `--interval SECONDS`, `--tmux-socket NAME` for `tmux -L NAME`); `term-notify once` makes one pass and exits.

## Pairing files

`~/.config/term/notify/<pairing_id>.json`, directory mode 0700, files 0600 (a wider mode is tightened, and files that are symlinks or owned by someone else are ignored):

```json
{"version": 1, "relay_url": "https://relay.example.com", "secret": "<64 lowercase hex>", "routing_key": "<64 lowercase hex>"}
```

Every `*.json` there is a pairing; each stop is pushed to all of them, so two phones both get it. Delete a file to stop pushes to that phone. A file that is not valid is skipped with one log line naming the field at fault.

## When it pushes

It lists panes with `tmux list-panes -a -f '#{@agent}'` every 2 seconds. Whatever writes the pane option `@agent` is covered: the omp extension, the Claude Code hooks and the Codex notify hook all write the same payload, and none of them talks to the relay. A pane is a stop when its `state` is `ask`, `approval`, `done` or `error`. Its time is `stop.at` (or `since`).

- Not yet seen: the stop is newer than the session option `@seen`. Prompting or answering the agent, or opening that session in Term, sets `@seen`.
- Debounced: the stop is at least 6 seconds old. Answer inside that window and nothing is sent. The check is made again right before sending.
- Once per stop: heartbeat rewrites of `@agent` do not repeat it. Delivered stops are remembered in `~/.local/share/term/notify/state.json` (mode 0600), so restarting the service or the machine does not repeat them.
- Not stale: a stop older than 5 minutes is never pushed, so a fresh install or a long outage does not announce old news.
- New panes and sessions are handled like any other.
- A failing relay is retried with a growing wait (5 s up to 60 s; the relay's `Retry-After` when it rate limits). A refusal (HTTP 400, 401, 403, 404) is final for that stop and the log says what to do.

State `aborted` (you interrupted) and `exited` never push.

## Logs and problems

macOS: `~/Library/Logs/term-notify.log`. Linux: `journalctl --user -u term-notify`.

| Log line or symptom | What to do |
| --- | --- |
| `no pairings in …` | Pair this host from Term. |
| `ignoring pairing file …: "relay_url" must be an https URL…` | The file was edited or written by a different Term version; pair again. |
| `relay answered HTTP 401/403/404 …` | The phone revoked this pairing or it never registered; pair again. |
| `relay answered HTTP 400 …` | The relay speaks a newer protocol; update term-notify. |
| `tmux not found` | Install tmux; the service looks in `/opt/homebrew/bin`, `/usr/local/bin` and `/usr/bin`. For another location, run `term-notify run` under your own supervisor with `TERM_NOTIFY_TMUX=/path/to/tmux`. |
| `tmux list-panes failed … is tmux 3.0 or newer?` | Upgrade tmux. |
| `could not resolve the relay's name`, `could not reach the relay` | No network; it retries by itself. |
| `TLS check of the relay failed` | Check the system clock and any proxy that rewrites HTTPS. |
| `term-notify is already running` | A second copy was started by hand while the service runs. |
| macOS: install says `launchctl could not load it now` | There is no login session (SSH only). Log in once at the Mac; it then starts at every login. |
| Pushes arrive but the tap says the pane is gone | The tmux server restarted after the push; the route belongs to the old server. |

tmux is always run with `-u`, because without a UTF-8 locale (a LaunchAgent has none) it prints non-ASCII session names as `_`, which would change the route the phone computes.

## Tests

```sh
python3 -m unittest discover -s integrations/notify/tests -v
```

Unit tests need nothing. `RealTmuxTests` run the real program against a private tmux server (`tmux -L termnotify-test-<pid>`) and a local relay, and are skipped without tmux; they take about 15 seconds and touch only a temporary `HOME`.
