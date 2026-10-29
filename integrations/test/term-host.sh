#!/bin/sh
# term-host install/uninstall against a fake HOME: install adds Term's entries and keeps yours; uninstall leaves every
# file and directory byte-identical to before. Runs once per JSON tool (jq, python3) and once with neither.
#   sh integrations/test/term-host.sh
root=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' 0
trap 'exit 1' 1 2 15
mkdir "$test_root/bin"
export TERM_HOST_SERVICE_CALLS="$test_root/service-calls"
for service in launchctl systemctl loginctl; do
  cat >"$test_root/bin/$service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$TERM_HOST_SERVICE_CALLS"
case "${0##*/}" in
  loginctl) printf 'Linger=yes\n' ;;
esac
exit 0
EOF
  chmod +x "$test_root/bin/$service"
done
PATH="$test_root/bin:$PATH"
export PATH
unset XDG_CONFIG_HOME
say_ok() { echo "ok   $*"; }
say_fail() { echo "FAIL $*"; fail=1; }

# The whole tree as paths, modes and checksums.
tree() { (cd "$1" && find . | sort | while read -r p; do if [ -f "$p" ]; then echo "$p $(cksum <"$p") $(ls -ld "$p" | cut -c1-10)"; else echo "$p"; fi; done); }

run() { # JSON_TOOL
  tool=$1
  case $tool in jq) command -v jq >/dev/null || { echo "skip $tool"; return; } ;; python3) command -v python3 >/dev/null || { echo "skip $tool"; return; } ;; esac
  H=$(mktemp -d "$test_root/home.XXXXXX")
  export HOME=$H TERM_HOST_JSON_TOOL=$tool
  unset CLAUDE_CONFIG_DIR CODEX_HOME
  mkdir -p "$H/.claude" "$H/.codex" "$H/.omp/agent"
  cat >"$H/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-stop-hook"}]}]}
}
EOF
  printf 'model = "gpt"\nnotify = ["/bin/true"]\n' >"$H/.codex/config.toml"
  before=$(tree "$H")
  claude_before=$(cat "$H/.claude/settings.json")

  out=$(sh "$root/scripts/term-host" install 2>&1); rc=$?
  if [ "$tool" = none ]; then [ $rc = 1 ] && say_ok "[none] install exits 1 and says why" || { say_fail "[none] rc=$rc"; return; }
  else [ $rc = 0 ] && say_ok "[$tool] install exits 0" || { say_fail "[$tool] install rc=$rc: $out"; return; }; fi

  if [ "$tool" = none ]; then
    [ "$(cat "$H/.claude/settings.json")" = "$claude_before" ] && say_ok "[none] existing settings untouched without a JSON tool" || say_fail "[none] settings changed"
    echo "$out" | grep -q "needs jq or python3" && say_ok "[none] says what to install" || say_fail "[none] no hint: $out"
  else
    grep -q my-own-stop-hook "$H/.claude/settings.json" && grep -q term-agent-hook "$H/.claude/settings.json" && say_ok "[$tool] settings keep your hook and add Term's" || say_fail "[$tool] merge: $(cat "$H/.claude/settings.json")"
    grep -q '"model"' "$H/.claude/settings.json" && say_ok "[$tool] other settings kept" || say_fail "[$tool] model lost"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$H/.claude/settings.json" 2>/dev/null || [ "$tool" = jq ] && jq -e . "$H/.claude/settings.json" >/dev/null 2>&1 || python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$H/.claude/settings.json" && say_ok "[$tool] settings still valid JSON" || say_fail "[$tool] invalid JSON"
    # Re-installing must not duplicate entries.
    sh "$root/scripts/term-host" install >/dev/null 2>&1
    n=$(grep -c term-agent-hook "$H/.claude/settings.json")
    [ "$n" = 10 ] && say_ok "[$tool] second install adds no duplicates" || say_fail "[$tool] $n Term entries after reinstall"
    [ -f "$H/.codex/hooks.json" ] && grep -q term-agent-hook "$H/.codex/hooks.json" && say_ok "[$tool] codex hooks.json created" || say_fail "[$tool] no codex hooks"
    [ -x "$H/.term/hooks/claude-code/term-agent-hook" ] && [ -f "$H/.term/hooks/term-agent-lib.sh" ] && say_ok "[$tool] hook scripts in place" || say_fail "[$tool] scripts missing"
    [ -f "$H/.omp/agent/extensions/term-agent.ts" ] && say_ok "[$tool] omp extension copied" || say_fail "[$tool] no omp extension"
    cmp -s "$H/.codex/config.toml" - <<'EOF' && say_ok "[$tool] codex notify config untouched" || say_fail "[$tool] config.toml changed"
model = "gpt"
notify = ["/bin/true"]
EOF
  fi

  sh "$root/scripts/term-host" uninstall >/dev/null 2>&1
  after=$(tree "$H")
  [ "$before" = "$after" ] && say_ok "[$tool] uninstall leaves the tree byte-identical" || { say_fail "[$tool] tree differs:"; diff - - <<EOF
$before
EOF
    printf '%s\n' "$after" | diff <(printf '%s\n' "$before") - 2>/dev/null | head; }

  # You edited the file after install: uninstall removes only Term's entries.
  if [ "$tool" != none ]; then
    sh "$root/scripts/term-host" install >/dev/null 2>&1
    printf '\n' >>"$H/.claude/settings.json"
    sh "$root/scripts/term-host" uninstall >/dev/null 2>&1
    if grep -q term-agent-hook "$H/.claude/settings.json"; then say_fail "[$tool] edited file still has Term entries"; else grep -q my-own-stop-hook "$H/.claude/settings.json" && say_ok "[$tool] edited file: only Term's entries removed" || say_fail "[$tool] edited file lost your hook"; fi
  fi
  rm -rf "$H"
}

run jq
run python3
run none

# check runs and names what is missing without failing on a missing optional tool
out=$(HOME=$(mktemp -d "$test_root/check.XXXXXX") sh "$root/scripts/term-host" check 2>&1); echo "$out" | grep -q "Connection" && say_ok "check prints a report" || say_fail "check: $out"
if [ -x "$root/integrations/notify/term-notify" ]; then
  [ -s "$TERM_HOST_SERVICE_CALLS" ] && say_ok "service operations used test stubs" || say_fail "service stubs were not exercised"
fi

[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
