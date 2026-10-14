#!/usr/bin/env bash
# Tests for dot_config/herdr/executable_clear-pane.sh: Alt-k (Ghostty's Cmd-k) inside Herdr.
#
# The script passes Alt-k to the focused pane only while zsh is idle at its prompt, so the
# zsh widget redraws the whole two-line prompt; anything else in the foreground gets
# nothing, because LazyVim binds <A-k> to "move line up". `herdr` is stubbed on PATH: it
# logs each call and answers process-info from $STUB_INFO (exit status $STUB_RC). Also
# checks that config.toml binds alt+k to this script and nothing else.
#
#   ./tests/herdr-clear-pane.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/dot_config/herdr/executable_clear-pane.sh"
CONFIG="$SRC/dot_config/herdr/config.toml"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "missing config under test: $CONFIG" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
# The first jq on PATH that works under the suite's own conditions (an empty environment).
# A mise shim re-enters mise there and fails, so it is passed over.
JQ=""
while IFS= read -r c; do
  if env -i "$c" -n 1 >/dev/null 2>&1; then JQ="$c"; break; fi
done < <(type -ap jq)
[ -n "$JQ" ] || { echo "no jq that runs under env -i" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/clearpane.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"
ln -s "$JQ" "$T/bin/jq"
cat > "$T/bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *process-info*) printf '%s\n' "$STUB_INFO"; exit "${STUB_RC:-0}" ;;
esac
exit 0
SH
chmod 755 "$T/bin/herdr"

# run <process-info json> [VAR=value ...] -> the herdr calls, one per line, joined by " | "
run() {
  local info="$1"; shift
  : > "$T/log"
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$T/log" STUB_INFO="$info" \
    HERDR_ACTIVE_PANE_ID=w1:p2 "$@" /bin/zsh "$SCRIPT" >/dev/null 2>&1
  echo "rc=$? $(paste -sd'|' "$T/log" | sed 's/|/ | /g')"
}

info() { # info <fg pgid> <shell pid> <name of the shell pid's process>
  printf '{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":%s,"foreground_processes":[{"name":"%s","pid":%s}],"pane_id":"w1:p2","shell_pid":%s},"type":"pane_process_info"}}' "$1" "$3" "$2" "$2"
}
AGENT='{"id":"x","result":{"process_info":{"foreground_process_group_id":2292,"foreground_processes":[{"name":"claude","pid":2292}],"pane_id":"w1:p2","shell_pid":98623},"type":"pane_process_info"}}'
ENVELOPE='{"id":"cli:pane:process_info","error":{"code":"pane_not_found","message":"no pane"}}'

is "an idle zsh prompt gets Alt-k" \
   "$(run "$(info 97087 97087 zsh)")" \
   "rc=0 pane process-info --pane w1:p2 | pane send-keys w1:p2 alt+k"
is "an agent in the foreground gets nothing" \
   "$(run "$AGENT")" "rc=0 pane process-info --pane w1:p2"
is "a pane whose own process is not zsh gets nothing (a popup's exec lazygit)" \
   "$(run "$(info 4100 4100 lazygit)")" "rc=0 pane process-info --pane w1:p2"
is "an error envelope at exit 0 sends nothing" \
   "$(run "$ENVELOPE")" "rc=0 pane process-info --pane w1:p2"
is "a failed process-info sends nothing and still exits 0" \
   "$(run "$(info 97087 97087 zsh)" STUB_RC=1)" "rc=0 pane process-info --pane w1:p2"
is "garbage from process-info sends nothing" \
   "$(run 'not json')" "rc=0 pane process-info --pane w1:p2"
is "no focused pane: herdr is not called" \
   "$(run "$(info 97087 97087 zsh)" HERDR_ACTIVE_PANE_ID=)" "rc=0 "
is "HERDR_SESSION is threaded into every call" \
   "$(run "$(info 97087 97087 zsh)" HERDR_SESSION=dev)" \
   "rc=0 --session dev pane process-info --pane w1:p2 | --session dev pane send-keys w1:p2 alt+k"

# config.toml: alt+k runs this script, and no other binding claims alt+k.
PY="$(command -v python3)" || { echo "no python3" >&2; exit 2; }
bound="$("$PY" -I - "$CONFIG" <<'PY' 2>/dev/null
import sys, tomllib
keys = tomllib.load(open(sys.argv[1], "rb")).get("keys", {})
hits = []
for name, val in keys.items():
    vals = val if isinstance(val, list) else [val]
    if name != "command" and "alt+k" in vals:
        hits.append("action:" + name)
for c in keys.get("command", []):
    if c.get("key") == "alt+k":
        hits.append("%s:%s" % (c.get("type"), c.get("command")))
print(" ".join(hits))
PY
)"
is "config.toml binds alt+k only to clear-pane.sh" "$bound" "shell:~/.config/herdr/clear-pane.sh"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
