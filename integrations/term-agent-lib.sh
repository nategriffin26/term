# Shared by the Claude Code and Codex hook scripts (sourced, never run). POSIX sh.
#
# Keeps one agent's state in its tmux pane as the user option `@agent`, payload v1, the same value
# integrations/omp/term-agent.ts writes (documented at the top of that file), so Term shows it the
# same way. Outside tmux every function does nothing. A hook must never break the agent it watches:
# every failure here is silent and the script exits 0.
#
# A hook is a new process per event, so the state lives in the pane itself: the previous `@agent`
# supplies since, title, model, pid, branch and the last stop; `@agent_turn` holds when the turn began
# (for `took`). Strings are carried as JSON string contents, already escaped and ASCII.

ta_init() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
  TA_TMUX=$(command -v tmux) || exit 0
  TA_INPUT=$(cat)
  TA_JQ=$(command -v jq 2>/dev/null || true)
  TA_CUR=$("$TA_TMUX" show-options -pqv -t "$TMUX_PANE" @agent 2>/dev/null || true)
}

ta_tmux() { "$TA_TMUX" "$@" >/dev/null 2>&1 || true; }

# Fractional unix seconds: perl everywhere Term's hosts are, else whole seconds.
ta_now() {
  perl -MTime::HiRes=time -e 'printf "%.3f\n", time' 2>/dev/null || date +%s
}

# ta_field JQ_PATH KEY: a string (or scalar) from the hook's JSON input as escaped JSON content, ASCII only.
# With jq the path is exact. Without it, the first `"KEY": "..."` anywhere in the input; non-ASCII is \u-escaped (or ? without perl).
ta_field() {
  if [ -n "$TA_JQ" ]; then
    printf '%s' "$TA_INPUT" | "$TA_JQ" -r "($1 // empty) | if type == \"string\" then . else tostring end | tojson" 2>/dev/null |
      sed -n '1{s/^"//;s/"$//;p;}' | ta_ascii
  else
    printf '%s' "$TA_INPUT" | tr '\n\r\t' '   ' | LC_ALL=C grep -o -E "\"$2\" *: *\"([^\"\\\\]|\\\\.)*\"" 2>/dev/null |
      sed -n '1{s/^"[^"]*" *: *"//;s/"$//;p;}' | ta_ascii
  fi
}

# ta_cut MAX: stdin is escaped JSON content; one line, whitespace collapsed, at most MAX characters,
# never inside an escape or a surrogate pair.
ta_cut() {
  LC_ALL=C awk -v max="$1" '{
    s = $0; out = ""; n = 0; i = 1; L = length(s)
    while (i <= L && n < max) {
      c = substr(s, i, 1)
      if (c == "\\") {
        d = substr(s, i + 1, 1)
        if (d == "u") {
          if (tolower(substr(s, i + 2, 2)) ~ /^d[89ab]/) { tok = substr(s, i, 12); i += 12 }
          else { tok = substr(s, i, 6); i += 6 }
        } else if (d == "n" || d == "r" || d == "t") { tok = " "; i += 2 }
        else { tok = substr(s, i, 2); i += 2 }
      } else { tok = c; i++ }
      out = out tok; n++
    }
    print out
  }' | sed 's/  */ /g;s/^ //;s/ $//'
}

# Values from the payload the pane already holds (our own compact JSON, so a pattern is enough).
ta_cur_str() { printf '%s' "$TA_CUR" | grep -o -E "\"$1\":\"([^\"\\\\]|\\\\.)*\"" | sed -n '1{s/^"[^"]*":"//;s/"$//;p;}'; }
ta_cur_num() { printf '%s' "$TA_CUR" | grep -o -E "\"$1\":[0-9.]+" | sed -n '1s/^[^:]*://p'; }

ta_has() { [ -n "$1" ]; }

# The agent's own process: the pane's child on the way up from this hook, else the hook's parent.
ta_agent_pid() {
  pane_pid=$("$TA_TMUX" display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null || true)
  p=$PPID
  i=0
  while [ "$i" -lt 8 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    [ "$p" = "$pane_pid" ] && break
    up=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ "$up" = "$pane_pid" ] && { echo "$p"; return; }
    p=$up
    i=$((i + 1))
  done
  echo "$PPID"
}

# ta_write STATE: assembles and writes `@agent`. The caller sets these first (escaped content; empty = omit):
#   TA_DOING TA_Q TA_OPTS (a JSON array body: "a","b") TA_LAST TA_TITLE TA_MODEL TA_CWD
# and TA_STOP=1 when this state is a stop for the user (records stop {at, why}).
# Carried from the previous payload unless the caller sets them: title, model, cwd, branch, pid.
ta_write() {
  state=$1
  now=$(ta_now)
  prev=$(ta_cur_str state)
  since=$(ta_cur_num since)
  [ "$prev" = "$state" ] && ta_has "$since" || since=$now
  pid=$(ta_cur_num pid)
  ta_has "$pid" || pid=$(ta_agent_pid)
  title=${TA_TITLE:-$(ta_cur_str title)}
  model=${TA_MODEL:-$(ta_cur_str model)}
  cwd=${TA_CWD:-$(ta_cur_str cwd)}
  branch=${TA_BRANCH-$(ta_cur_str branch)}
  if [ -n "${TA_STOP:-}" ]; then
    stop="{\"at\":$now,\"why\":\"$state\"}"
  else
    at=$(printf '%s' "$TA_CUR" | grep -o -E '"stop":\{"at":[0-9.]+,"why":"[a-z]+"\}')
    stop=${at#\"stop\":}
  fi
  took=
  if [ -n "${TA_TOOK:-}" ]; then
    t0=$("$TA_TMUX" show-options -pqv -t "$TMUX_PANE" @agent_turn 2>/dev/null || true)
    ta_has "$t0" && took=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$now" "$t0" 2>/dev/null || true)
  fi

  json="{\"v\":1,\"state\":\"$state\",\"since\":$since,\"t\":$now,\"pid\":$pid"
  ta_has "$title" && json="$json,\"title\":\"$title\""
  [ "$state" = working ] && ta_has "${TA_DOING:-}" && json="$json,\"doing\":\"$TA_DOING\""
  ta_has "${TA_Q:-}" && json="$json,\"q\":\"$TA_Q\""
  ta_has "${TA_OPTS:-}" && json="$json,\"opts\":[$TA_OPTS]"
  ta_has "${TA_LAST:-}" && json="$json,\"last\":\"$TA_LAST\""
  ta_has "$took" && json="$json,\"took\":$took"
  ta_has "$stop" && json="$json,\"stop\":$stop"
  ta_has "$model" && json="$json,\"model\":\"$model\""
  ta_has "$cwd" && json="$json,\"cwd\":\"$cwd\""
  ta_has "$branch" && json="$json,\"branch\":\"$branch\""
  json="$json}"
  ta_tmux set-option -p -t "$TMUX_PANE" @agent "$json"
}

# A turn begins: remember when, for `took`.
ta_turn_start() { ta_tmux set-option -p -t "$TMUX_PANE" @agent_turn "$(ta_now)"; }

# He prompted: whatever stopped for him is seen, on every device. Never moves the watermark backwards.
ta_seen() {
  at=$(ta_now)
  ta_tmux set-option -F -t "$TMUX_PANE" @seen "#{?#{e|>|f|0:#{?@seen,#{@seen},0},$at},#{@seen},$at}"
}

# The agent ended: remove its state, as omp does when it exits.
ta_clear() {
  ta_tmux set-option -p -u -t "$TMUX_PANE" @agent
  ta_tmux set-option -p -u -t "$TMUX_PANE" @agent_turn
}

# ta_git_branch DIR: the current branch, as escaped content.
ta_git_branch() {
  [ -n "$1" ] || return 0
  git -C "$1" branch --show-current 2>/dev/null | head -1 | ta_escape | ta_cut 60
}

# Escape plain text (stdin) as JSON string content, ASCII only.
ta_escape() {
  tr '\n\r\t' '   ' | tr -d '\000-\010\013\014\016-\037' | sed 's/\\/\\\\/g;s/"/\\"/g' | ta_ascii
}

# \u-escape non-ASCII (stdin UTF-8), so the value survives a tmux without a UTF-8 locale.
ta_ascii() {
  if command -v perl >/dev/null 2>&1; then
    perl -CS -pe 's/([^\x00-\x7f])/my $c = ord($1); $c > 0xFFFF ? sprintf("\\u%04x\\u%04x", 0xD800 + (($c - 0x10000) >> 10), 0xDC00 + (($c - 0x10000) & 0x3FF)) : sprintf("\\u%04x", $c)/ge'
  else
    LC_ALL=C sed 's/[^ -~]/?/g'
  fi
}

# "Tool: argument", for the `doing` line and an approval's `q`. NAME and ARG are escaped content.
ta_step() {
  arg=$(printf '%s' "$2" | ta_cut 70)
  if ta_has "$arg"; then printf '%s: %s' "$1" "$arg"; else printf '%s' "$1"; fi
}

# The first question's option labels (at most 6) from the hook input, as a JSON array body: "a","b".
ta_options() {
  if [ -n "$TA_JQ" ]; then
    printf '%s' "$TA_INPUT" | "$TA_JQ" -r '(.tool_input.questions[0].options // []) | .[0:6] | map(.label | tojson) | join(",")' 2>/dev/null | ta_ascii
  else
    printf '%s' "$TA_INPUT" | tr '\n\r\t' '   ' | grep -o -E '"label" *: *"([^"\\]|\\.)*"' 2>/dev/null | sed -n '1,6s/^"label" *: *//p' | ta_ascii | paste -sd, -
  fi
}
