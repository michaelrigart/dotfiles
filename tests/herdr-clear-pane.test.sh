#!/usr/bin/env bash
# Tests for dot_config/herdr/executable_clear-pane.sh: Alt-k (Ghostty's Cmd-k) inside Herdr.
#
# The script signals the pane's shell with SIGURG, and only while that shell is an idle zsh;
# dot_zshrc's trap then clears. It never types into the pane. `herdr` is stubbed on PATH: it
# logs each call and answers process-info from $STUB_INFO (exit status $STUB_RC). The shell
# is a real helper process that records each SIGURG it receives. Also checks that
# config.toml binds alt+k to this script and nothing else.
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
HPID=""
trap '[ -n "$HPID" ] && kill "$HPID" 2>/dev/null; rm -rf "$T"' EXIT
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

# The pane's shell: records every SIGURG in $T/sig, and END on SIGUSR1. bash runs pending
# traps in signal-number order and SIGURG (16) is below SIGUSR1 (30), so once END is
# written, any SIGURG the script sent before it is written too.
bash -c 'trap "echo URG >> \"$1\"" URG; trap "echo END >> \"$1\"" USR1
  echo ready > "$2"; while :; do sleep 0.05; done' helper "$T/sig" "$T/ready" &
HPID=$!
for _ in $(seq 100); do [ -s "$T/ready" ] && break; sleep 0.05; done
[ -s "$T/ready" ] || { echo "the helper shell never started" >&2; exit 2; }

# run <process-info json> [VAR=value ...] -> "rc=<status> sig=<URGs the shell got> <herdr calls>"
run() {
  local info="$1" i got; shift
  : > "$T/log"; : > "$T/sig"
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$T/log" STUB_INFO="$info" \
    HERDR_ACTIVE_PANE_ID=w1:p2 "$@" /bin/zsh "$SCRIPT" >/dev/null 2>&1
  local rc=$?
  kill -USR1 "$HPID"
  for i in $(seq 100); do grep -q END "$T/sig" && break; sleep 0.05; done
  grep -q END "$T/sig" || { echo "rc=$rc the helper never answered"; return; }
  got=$(grep -c URG "$T/sig")
  echo "rc=$rc sig=$got $(paste -sd'|' "$T/log" | sed 's/|/ | /g')"
}

info() { # info <fg pgid> <shell pid> <name of the shell pid's process>
  printf '{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":%s,"foreground_processes":[{"name":"%s","pid":%s}],"pane_id":"w1:p2","shell_pid":%s},"type":"pane_process_info"}}' "$1" "$3" "$2" "$2"
}
AGENT="{\"id\":\"x\",\"result\":{\"process_info\":{\"foreground_process_group_id\":2292,\"foreground_processes\":[{\"name\":\"claude\",\"pid\":2292}],\"pane_id\":\"w1:p2\",\"shell_pid\":$HPID},\"type\":\"pane_process_info\"}}"
ENVELOPE='{"id":"cli:pane:process_info","error":{"code":"pane_not_found","message":"no pane"}}'
CALL="pane process-info --pane w1:p2"

is "an idle zsh gets one SIGURG, and nothing is typed into the pane" \
   "$(run "$(info "$HPID" "$HPID" zsh)")" "rc=0 sig=1 $CALL"
is "an agent in the foreground: no signal" "$(run "$AGENT")" "rc=0 sig=0 $CALL"
is "a pane whose own process is not zsh: no signal (a popup's exec lazygit)" \
   "$(run "$(info "$HPID" "$HPID" lazygit)")" "rc=0 sig=0 $CALL"
is "an error envelope at exit 0: no signal" "$(run "$ENVELOPE")" "rc=0 sig=0 $CALL"
is "a failed process-info: no signal, and still exit 0" \
   "$(run "$(info "$HPID" "$HPID" zsh)" STUB_RC=1)" "rc=0 sig=0 $CALL"
is "garbage from process-info: no signal" "$(run 'not json')" "rc=0 sig=0 $CALL"
is "shell pid 0 is never signalled (kill 0 means the whole process group)" \
   "$(run "$(info 0 0 zsh)")" "rc=0 sig=0 $CALL"
is "no focused pane: herdr is not called" \
   "$(run "$(info "$HPID" "$HPID" zsh)" HERDR_ACTIVE_PANE_ID=)" "rc=0 sig=0 "
is "HERDR_SESSION is threaded into the call" \
   "$(run "$(info "$HPID" "$HPID" zsh)" HERDR_SESSION=dev)" "rc=0 sig=1 --session dev $CALL"

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
