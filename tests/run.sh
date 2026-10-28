#!/bin/bash
# Tests for bin/agents that don't depend on what's running on this Mac.
#
#   tests/run.sh
#
# Detection reads canned `ps` and `pmset` output from tests/cases/<case>/ (see tests/README.md)
# through AGENTS_TEST_FIXTURE. Everything runs with an empty environment and a temporary HOME,
# so nothing touches your real settings, markers or the pmset flag.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
AGENTS="$ROOT/bin/agents"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     /'; }

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3"))"; fi
}

# run_agents <home> <fixture dir or ""> <args...>: bin/agents with nothing from this shell
# (TEST_PATH and TEST_ENV add to the empty environment)
run_agents() {
  local home="$1" fixture="$2"; shift 2
  # shellcheck disable=SC2086  # TEST_ENV is a list of VAR=value words
  env -i HOME="$home" PATH="${TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" ${TEST_ENV:-} \
    ${fixture:+AGENTS_TEST_FIXTURE="$fixture"} /bin/bash "$AGENTS" "$@"
}

# `agents busy`, reduced to "pid name why why" (fixture pids have no folder), sorted
busy_lines() {
  run_agents "$1" "$2" busy | awk '$1 ~ /^[0-9]+$/ { print $1, $2, $3, $4 } $1 == "No" { print "No busy agents" }' | sort
}

# A needs-input marker as `agents mark waiting` writes it: "<epoch> <kind>", then the agent's
# descendants at that moment
put_marker() {   # put_marker <home> <pid> [descendants]
  mkdir -p "$1/.cache/lid-agents/waiting"
  printf '%s permission\n%s\n' "$(date +%s)" "${3:-}" > "$1/.cache/lid-agents/waiting/$2"
}

# --- Detection: one case per directory ---------------------------------------------------
for dir in "$ROOT"/tests/cases/*/; do
  dir="${dir%/}"
  name="${dir##*/}"
  home="$TMP/$name"
  mkdir -p "$home"
  if [ -f "$dir/waiting" ]; then
    while read -r pid snap; do put_marker "$home" "$pid" "${snap:-}"; done < "$dir/waiting"
  fi
  check "busy: $name" "$(sort "$dir/expected")" "$(busy_lines "$home" "$dir")"
  # markers whose agent isn't running are removed
  if [ -f "$dir/waiting" ]; then
    while read -r pid _; do
      if ! grep -q "^$pid " "$dir/procs" && [ -e "$home/.cache/lid-agents/waiting/$pid" ]; then
        not_ok "busy: $name removes the marker of exited pid $pid"
      fi
    done < "$dir/waiting"
  fi
done

# --- agents mark: finds the agent at or above the pid ------------------------------------
home="$TMP/mark"; mkdir -p "$home"; W="$home/.cache/lid-agents/waiting"
fx="$ROOT/tests/cases/claude-caffeinate"
run_agents "$home" "$fx" mark waiting --pid 900002 --kind question      # caffeinate under claude
check "mark: a child's pid marks its agent" "question" "$(awk 'NR == 1 { print $2 }' "$W/900001" 2>/dev/null)"
check "mark: the agent then needs input" "900001 claude needs input" "$(busy_lines "$home" "$fx")"
run_agents "$home" "$fx" mark working --pid 900001
check "mark: working clears it and leaves a stamp" "-.clear-900001" "$(ls -A "$W" | tr '\n' ' ' | sed 's/ $//; s/^/-/')"
rm -f "$W"/.clear-*
run_agents "$home" "$fx" mark waiting --pid 900010                      # the Claude desktop app
check "mark: a non-agent marks nothing" "" "$(ls "$W" 2>/dev/null)"
run_agents "$home" "$fx" mark waiting --pid 900001 --kind bogus
check "mark: an unknown kind is stored as input" "input" "$(awk 'NR == 1 { print $2 }' "$W/900001" 2>/dev/null)"
rm -f "$W/900001"
# a clear that lands after `mark waiting` started (the stamp is newer) wins the race
touch -t "$(date -v+1M +%Y%m%d%H%M.%S)" "$W/.clear-900001"
run_agents "$home" "$fx" mark waiting --pid 900001
check "mark: a later clear wins the race" "no" "$([ -f "$W/900001" ] && echo yes || echo no)"
rm -f "$W"/.clear-*
run_agents "$home" "$ROOT/tests/cases/interpreters" mark waiting --pid 900303
check "mark: an interpreter agent (node titled claude)" "yes" "$([ -f "$W/900302" ] && echo yes)"
run_agents "$home" "$ROOT/tests/cases/answered-long-tool" mark waiting --pid 900601
check "mark: records the agent's children at that moment" "900602,900603" "$(sed -n 2p "$W/900601")"
run_agents "$home" "$fx" mark sideways --pid 900001; status=$?
check "mark: always exits 0" "0" "$status"

# --- agents integrate: hooks merge into Claude Code's and Codex's JSON --------------------
home="$TMP/hooks"; mkdir -p "$home/.claude" "$home/.codex" "$TMP/bin"
cat > "$TMP/bin/codex" <<'EOF'
#!/bin/sh
# a stand-in for `codex features enable|list`
[ "$1" = features ] || exit 1
[ "$2" = list ] && echo "prevent_idle_sleep  experimental  true"
exit 0
EOF
chmod +x "$TMP/bin/codex"
export TEST_PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# The fixtures are written the way edit_hooks_json writes (2-space JSON), so a remove that
# restores them must give back the same bytes.
canonical() { osascript -l JavaScript -e 'function run(a) { return JSON.stringify(JSON.parse(a[0]), null, 2) }' "$1"; }
canonical '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}' > "$home/.claude/settings.json"
canonical '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"superset-notify"}]}]}}' > "$home/.codex/hooks.json"
chmod 600 "$home/.claude/settings.json"
cp "$home/.claude/settings.json" "$TMP/claude.orig"; cp "$home/.codex/hooks.json" "$TMP/codex.orig"

run_agents "$home" "" integrate >/dev/null 2>&1
first="$(stat -f %m "$home/.claude/settings.json")"
sleep 1
run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: 9 Claude hooks, once each after two runs" "9" "$(grep -c 'lid-agents-hook' "$home/.claude/settings.json")"
check "integrate: 7 Codex hooks, once each after two runs" "7" "$(grep -c 'lid-agents-hook' "$home/.codex/hooks.json")"
check "integrate: an unchanged file isn't rewritten" "$first" "$(stat -f %m "$home/.claude/settings.json")"
check "integrate: the file's permissions are kept" "600" "$(stat -f %Lp "$home/.claude/settings.json")"
check "integrate: Claude's other hooks and settings kept" "guard.sh opus say done" \
  "$(grep -o '"say done"\|"guard.sh"\|"opus"' "$home/.claude/settings.json" | tr -d '"' | sort | tr '\n' ' ' | sed 's/ $//')"
check "integrate: Codex's other hooks kept" "1" "$(grep -c 'superset-notify' "$home/.codex/hooks.json")"
check "integrate: Claude permission prompts mark it" "1" \
  "$(plutil -extract hooks.Notification json -o - "$home/.claude/settings.json" | grep -c 'permission_prompt')"
check "integrate: Codex PermissionRequest marks it" "yes" \
  "$(plutil -extract hooks.PermissionRequest json -o - "$home/.codex/hooks.json" >/dev/null 2>&1 && echo yes)"
check "integrate: backups of the originals" "same same" \
  "$(cmp -s "$TMP/claude.orig" "$home/.claude/settings.json.lid-agents.bak" && echo same) $(cmp -s "$TMP/codex.orig" "$home/.codex/hooks.json.lid-agents.bak" && echo same)"

# a custom CLAUDE_CONFIG_DIR is recorded, so refresh and uninstall find it without the variable
mkdir -p "$home/custom-claude"
TEST_ENV="CLAUDE_CONFIG_DIR=$home/custom-claude" run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: a custom CLAUDE_CONFIG_DIR is recorded" "yes" \
  "$(grep -qxF "$home/custom-claude/settings.json" "$home/.cache/lid-agents/hook-files" && echo yes)"

# removal (what uninstall does) gives back the original files byte for byte
(
  export HOME="$home" AGENTS_SOURCED=1
  # shellcheck source=../bin/agents
  source "$AGENTS"
  edit_hooks_json "$home/.claude/settings.json" remove && edit_hooks_json "$home/.codex/hooks.json" remove
)
# Remote Control is a Claude Code setting you may want either way, so uninstall leaves it
without_remote() {
  osascript -l JavaScript -e 'function run(a) { const o = JSON.parse(a[0]); delete o.remoteControlAtStartup
    delete o.inputNeededNotifEnabled; return JSON.stringify(o, null, 2) }' "$(cat "$1")"
}
check "remove: Claude settings back to the original, apart from Remote Control" "$(cat "$TMP/claude.orig")" \
  "$(without_remote "$home/.claude/settings.json")"
check "remove: Codex hooks back to the original" "same" "$(cmp -s "$TMP/codex.orig" "$home/.codex/hooks.json" && echo same)"

# files that aren't a JSON object are left alone
printf '{ not json' > "$home/.claude/settings.json"
run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: invalid JSON is left untouched" "{ not json" "$(cat "$home/.claude/settings.json")"
printf '[]\n' > "$home/.claude/settings.json"
run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: a JSON array is left untouched" "[]" "$(cat "$home/.claude/settings.json")"

# --- Remote Control: Claude Code's own settings, and which busy sessions are connected ------
home="$TMP/remote"; mkdir -p "$home/.claude"
S="$home/.claude/settings.json"
setting() { plutil -extract "$1" raw -o - "$S" 2>/dev/null || echo unset; }
remote_line() { run_agents "$home" "$1" state --menu | awk '$1 == "remote"'; }
agent_line() { run_agents "$home" "$1" state --menu | awk '$1 == "agent" { print $2, $3, $4, $5 }'; }
fx="$ROOT/tests/cases/claude-caffeinate"
canonical '{"model":"opus"}' > "$S"
check "remote: unset until chosen" "remote unset" "$(remote_line "")"
run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: Remote Control and its push on when never chosen" "true true" \
  "$(setting remoteControlAtStartup) $(setting inputNeededNotifEnabled)"
run_agents "$home" "" remote off >/dev/null
run_agents "$home" "" integrate >/dev/null 2>&1
check "integrate: keeps Remote Control off once you've chosen it" "false" "$(setting remoteControlAtStartup)"
check "remote: off" "remote off" "$(remote_line "")"
canonical '{"inputNeededNotifEnabled":false}' > "$S"
run_agents "$home" "" remote on >/dev/null
check "remote on: keeps a push choice you made" "true false" \
  "$(setting remoteControlAtStartup) $(setting inputNeededNotifEnabled)"
check "remote: on" "remote on" "$(remote_line "")"
# a busy Claude session's sessions/<pid>.json says whether it's connected
mkdir -p "$home/.claude/sessions"
canonical '{"pid":900001,"kind":"interactive"}' > "$home/.claude/sessions/900001.json"
check "state --menu: a busy Claude session not on Remote Control" "900001 claude working no" "$(agent_line "$fx")"
canonical '{"pid":900001,"kind":"interactive","bridgeSessionId":"session_x"}' > "$home/.claude/sessions/900001.json"
check "state --menu: a busy Claude session on Remote Control" "900001 claude working yes" "$(agent_line "$fx")"
rm "$home/.claude/sessions/900001.json"
check "state --menu: a session without a file isn't flagged" "900001 claude working -" "$(agent_line "$fx")"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
