#!/bin/sh
# Runs the Claude Code and Codex hook scripts against a scratch tmux server (`tmux -L termtest`) and checks the
# `@agent` payload each event leaves: parses as v1, and the states move as expected. Run with and without jq:
#   sh integrations/test/hooks.sh            (uses jq if installed)
#   NOJQ=1 sh integrations/test/hooks.sh     (hides jq, to test the fallback parser)
root=$(cd "$(dirname "$0")/../.." && pwd)
S=termtest
unset TMUX TMUX_PANE
fail=0
T() { tmux -L $S "$@"; }
trap 'T kill-server 2>/dev/null' EXIT
T kill-server 2>/dev/null
T new-session -d -s t -x 100 -y 30 || { echo "cannot start tmux"; exit 1; }
export TMUX="$(T display-message -p '#{socket_path},#{pid},0')"
export TMUX_PANE="$(T display-message -p '#{pane_id}')"

if [ -n "$NOJQ" ]; then
  bin=$(mktemp -d)
  for c in tmux perl awk sed grep tr cat head paste date git ps dirname sleep env python3 sh; do ln -s "$(command -v $c)" "$bin/$c"; done
  PATH="$bin"
  echo "mode: no jq"
else
  echo "mode: $(command -v jq >/dev/null && echo jq || echo no jq)"
fi

agent() { T show-options -pqv -t "$TMUX_PANE" @agent; }
# check NAME CONDITION-ON-$a (a is the @agent value)
check() {
  a=$(agent)
  if printf '%s' "$a" | grep -q -E "$2"; then echo "ok   $1"; else echo "FAIL $1: $a"; fail=1; fi
}
checknot() {
  a=$(agent)
  if printf '%s' "$a" | grep -q -E "$2"; then echo "FAIL $1: $a"; fail=1; else echo "ok   $1"; fi
}
# valid JSON v1 per python's parser (the one thing grep cannot show)
valid() {
  agent | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
assert all(ord(c) < 128 for c in raw)
p = json.loads(raw)
assert p["v"] == 1 and p["state"] in "working ask approval done error aborted idle".split()
assert isinstance(p["since"], (int, float)) and isinstance(p["t"], (int, float))' 2>/dev/null &&
    echo "ok   $1 parses as v1, ASCII" || { echo "FAIL $1 not valid v1: $(agent)"; fail=1; }
}
fire() { printf '%s' "$2" | "$1" >/dev/null; }

C=$root/integrations/claude-code/term-agent-hook
X=$root/integrations/codex/term-agent-hook
J='"session_id":"s","cwd":"/tmp"'

echo "-- Claude Code"
fire $C '{'"$J"',"hook_event_name":"SessionStart","model":"claude-opus"}'
check "SessionStart is idle" '"state":"idle"'
fire $C '{'"$J"',"hook_event_name":"UserPromptSubmit","prompt":"fix the \"login\" bug\nplease é 😀"}'
check "prompt is working" '"state":"working"'
check "title from prompt, \\u-escaped" '"title":"fix the \\"login\\" bug please \\u00e9 \\ud83d\\ude00"'
valid "working"
[ -n "$(T show-options -qv -t $TMUX_PANE @seen)" ] && echo "ok   @seen set" || { echo "FAIL @seen"; fail=1; }
fire $C '{'"$J"',"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}'
check "tool step shown" '"doing":"Bash: npm test"'
fire $C '{'"$J"',"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
check "permission is approval with q" '"state":"approval".*"q":"Bash: rm -rf build".*"stop":\{"at":[0-9.]+,"why":"approval"\}'
checknot "approval has no doing" '"doing"'
fire $C '{'"$J"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"x"}}'
check "answered goes back to working, q cleared" '"state":"working"'
checknot "q cleared" '"q"'
check "stop kept" '"stop":\{"at"'
fire $C '{'"$J"',"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which db?","options":[{"label":"sqlite"},{"label":"postgres"}]}]}}'
check "AskUserQuestion is ask with options" '"state":"ask".*"q":"Which db\?","opts":\["sqlite","postgres"\]'
fire $C '{'"$J"',"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
check "permission notification is approval" '"state":"approval".*"q":"Claude needs your permission to use Bash"'
fire $C '{'"$J"',"hook_event_name":"PostToolUse","tool_name":"Bash"}'
sleep 0.2
fire $C '{'"$J"',"hook_event_name":"Stop","last_assistant_message":"All done.\nTests pass."}'
check "Stop is done with last, took, stop" '"state":"done".*"last":"All done. Tests pass\.".*"took":[0-9.]+.*"stop":\{"at":[0-9.]+,"why":"done"\}'
valid "done"
fire $C '{'"$J"',"hook_event_name":"Notification","notification_type":"idle_prompt","message":"waiting"}'
check "idle_prompt leaves done alone" '"state":"done"'
fire $C '{'"$J"',"hook_event_name":"UserPromptSubmit","prompt":"next"}'
check "next prompt works again, title kept" '"state":"working".*"title":"fix the'
fire $C '{'"$J"',"hook_event_name":"StopFailure","last_assistant_message":"API Error: Rate limit"}'
check "StopFailure is error" '"state":"error".*"last":"API Error: Rate limit"'
fire $C '{'"$J"',"hook_event_name":"SessionEnd","reason":"other"}'
[ -z "$(agent)" ] && echo "ok   SessionEnd removes @agent" || { echo "FAIL SessionEnd: $(agent)"; fail=1; }

echo "-- Codex"
out=$(printf '%s' '{'"$J"',"hook_event_name":"SessionStart","model":"gpt-6"}' | $X)
check "SessionStart is idle, model" '"state":"idle".*"model":"gpt-6"'
[ "$out" = "{}" ] && echo "ok   prints {}" || { echo "FAIL stdout: $out"; fail=1; }
fire $X '{'"$J"',"hook_event_name":"UserPromptSubmit","prompt":"add tests","model":"gpt-6"}'
check "prompt is working" '"state":"working".*"title":"add tests"'
fire $X '{'"$J"',"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push","description":"push"}}'
check "permission is approval" '"state":"approval".*"q":"Bash: git push"'
fire $X '{'"$J"',"hook_event_name":"PostToolUse","tool_name":"Bash"}'
check "post tool working" '"state":"working"'
out=$(printf '%s' '{'"$J"',"hook_event_name":"Stop","last_assistant_message":"Done."}' | $X)
check "Stop is done" '"state":"done".*"last":"Done\."'
[ "$out" = "{}" ] && echo "ok   Stop prints {}" || { echo "FAIL Stop stdout: $out"; fail=1; }
fire $X '{'"$J"',"hook_event_name":"UserPromptSubmit","prompt":"again"}'
fire $X '{'"$J"',"hook_event_name":"Interrupt"}'
check "Interrupt is aborted" '"state":"aborted".*"why":"aborted"'
valid "aborted"

echo "-- Outside tmux"
out=$(env -u TMUX -u TMUX_PANE sh -c "printf '%s' '{\"hook_event_name\":\"Stop\"}' | $X")
[ "$out" = "{}" ] && echo "ok   codex Stop outside tmux prints {}" || { echo "FAIL: $out"; fail=1; }

[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
