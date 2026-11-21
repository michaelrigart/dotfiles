#!/usr/bin/env bash
# Tests dot_local/bin/executable_ssh-agent-run, the loader the be.netronix.ssh-agent LaunchAgent
# runs: it starts ssh-agent on the fixed socket and loads a fixed key list.
#
# Bugs caught: a stale socket at the fixed path failing every start; a planted file at that path
# being deleted; a loader that hangs when the agent never comes up; a failed key add leaking
# ssh-add's output into the log or stopping the keys after it; a SIGTERM leaving a dead socket
# for a shell to prefer; michael_rsa, a borg key or huginn being loaded.
#
# The sandbox forbids bind(), so ssh-agent and ssh-add are stubs on PINNED_PATH; the "socket" is a
# symlink to a system socket under /var/run. HOME is a temp directory holding empty key files.
#
#   ./tests/ssh-agent-run.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/dot_local/bin/executable_ssh-agent-run"
PLIST="$SRC/Library/LaunchAgents/be.netronix.ssh-agent.plist.tmpl"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
[ -f "$PLIST" ] || { echo "missing plist under test: $PLIST" >&2; exit 2; }
target=$(find /var/run -maxdepth 1 -type s 2>/dev/null | head -1)
[ -n "$target" ] || { echo "INCONCLUSIVE: no system unix socket under /var/run to symlink" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2 (want $3)"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/ssh-agent-run.XXXXXX")" || exit 2
# A stub agent a regressed loader leaves running (the SIGTERM case runs timeout --foreground)
# is killed here by the pid it recorded.
trap 'while read -r p; do kill "$p" 2>/dev/null; done <"$T/stub.pids" 2>/dev/null; rm -rf "$T"' EXIT

STUBS="$T/stubs"
mkdir "$STUBS"
cat >"$STUBS/ssh-agent" <<STUB
#!/bin/bash
echo "agent \$*" >>"\$STUB_LOG"
echo \$\$ >>"$T/stub.pids"
sock=\${@: -1}
if [ -e "\$sock" ] || [ -L "\$sock" ]; then echo agent-exists >>"\$STUB_LOG"; exit 1; fi
if [ "\${STUB_NO_SOCKET:-}" != 1 ]; then ln -s "$target" "\$sock" || exit 1; fi
trap 'echo agent-term >>"\$STUB_LOG"; exit 143' TERM
if [ -n "\${STUB_AGENT_LIFE:-}" ]; then
  /bin/sleep "\$STUB_AGENT_LIFE"; exit "\${STUB_AGENT_RC:-0}"
fi
while :; do /bin/sleep 0.2; done
STUB
cat >"$STUBS/ssh-add" <<'STUB'
#!/bin/bash
echo "add $SSH_AUTH_SOCK $*" >>"$STUB_LOG"
last=${@: -1}
if [ -n "${STUB_ADD_FAIL:-}" ] && [ "${last%/"$STUB_ADD_FAIL"}" != "$last" ]; then
  echo STUBSECRET >&2; exit 1
fi
STUB
chmod 755 "$STUBS/ssh-agent" "$STUBS/ssh-add"

n=0
# fresh_home: a new temp HOME with the key files; sets H, SOCK, STUB_LOG, LOGF.
fresh_home() {
  n=$((n + 1))
  H="$T/home$n"
  mkdir -p "$H/.ssh"
  for k in michael viumore_rsa michael_rsa borg huginn; do : >"$H/.ssh/$k"; done
  SOCK="$H/.local/state/ssh-agent/agent.sock"
  LOGF="$H/.local/state/ssh-agent/error.log"
  export STUB_LOG="$T/stub$n.log"
  : >"$STUB_LOG"
}
runit() { # runit [VAR=value...]: runs the script to the end; sets RC
  /usr/bin/timeout 20 env HOME="$H" XDG_STATE_HOME="$T/xdg" PINNED_PATH="$STUBS:/usr/bin:/bin" STUB_LOG="$STUB_LOG" "$@" /bin/bash "$SCRIPT" >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 124 ] || _fail "script finished within 20 s" "timed out (rc 124)"
}
adds() { grep '^add ' "$STUB_LOG" | sed "s|^add $SOCK -q $H/.ssh/||"; }

echo "ssh-agent-run"

fresh_home
runit STUB_AGENT_LIFE=1 STUB_AGENT_RC=0
check "agent runs on the fixed socket in the foreground" \
  "$(grep '^agent ' "$STUB_LOG")" "agent -D -a $H/.local/state/ssh-agent/agent.sock"
check "loads exactly the listed keys, in order: never michael_rsa, a borg key or huginn" "$(adds | tr '\n' ' ')" "michael viumore_rsa "
check "state directory is mode 700" "$(stat -f %Lp "$H/.local/state/ssh-agent")" "700"

fresh_home
rm "$H/.ssh/viumore_rsa"
runit STUB_AGENT_LIFE=1 STUB_AGENT_RC=7
check "exits with the agent's status" "$RC" "7"
check "a listed key with no file is skipped" "$(adds | tr '\n' ' ')" "michael "
if [ -e "$SOCK" ] || [ -L "$SOCK" ]; then _fail "socket is removed after the agent exits" "still there"; else _pass "socket is removed after the agent exits"; fi
if [ -e "$T/xdg" ]; then _fail "XDG_STATE_HOME is ignored" "$(ls -A "$T/xdg")"; else _pass "XDG_STATE_HOME is ignored"; fi

fresh_home
mkdir -p "$H/.local/state/ssh-agent"
chmod 755 "$H/.local/state/ssh-agent"
ln -s "$target" "$SOCK"
runit STUB_AGENT_LIFE=1 STUB_AGENT_RC=7
check "stale socket is removed: rc" "$RC" "7"
check "existing state directory is tightened to mode 700" "$(stat -f %Lp "$H/.local/state/ssh-agent")" "700"
check "stale socket is removed: agent started" "$(grep -c '^agent-exists' "$STUB_LOG")" "0"

fresh_home
mkdir -p "$H/.local/state/ssh-agent"
echo planted >"$SOCK"
runit STUB_AGENT_LIFE=1 STUB_AGENT_RC=7
check "regular file at the socket path is refused: rc" "$RC" "1"
check "regular file at the socket path is refused: no agent" "$(grep -c '^agent ' "$STUB_LOG")" "0"
check "regular file at the socket path is kept" "$(cat "$SOCK" 2>/dev/null)" "planted"
check "regular file at the socket path is logged once" "$(wc -l <"$LOGF" | tr -d ' ')" "1"

fresh_home
SECONDS=0
runit STUB_NO_SOCKET=1
elapsed=$SECONDS
check "gives up when no socket appears: rc" "$RC" "1"
if [ "$elapsed" -le 8 ]; then _pass "gives up when no socket appears: within 8 s"; else _fail "gives up when no socket appears: within 8 s" "${elapsed}s"; fi
check "gives up when no socket appears: agent stopped" "$(grep -c '^agent-term' "$STUB_LOG")" "1"

fresh_home
runit STUB_AGENT_LIFE=1 STUB_AGENT_RC=0 STUB_ADD_FAIL=michael
if grep -q 'michael' "$LOGF" 2>/dev/null; then _pass "failed add is logged by name"; else _fail "failed add is logged by name" "$(cat "$LOGF" 2>/dev/null)"; fi
if grep -q 'STUBSECRET' "$LOGF" 2>/dev/null; then _fail "failed add does not leak ssh-add output" "$(cat "$LOGF")"; else _pass "failed add does not leak ssh-add output"; fi
check "failed add: the rest still load" "$(adds | tr '\n' ' ')" "michael viumore_rsa "

fresh_home
/usr/bin/timeout --foreground 20 env HOME="$H" XDG_STATE_HOME="$T/xdg" PINNED_PATH="$STUBS:/usr/bin:/bin" STUB_LOG="$STUB_LOG" /bin/bash "$SCRIPT" >/dev/null 2>&1 &
pid=$!
i=0
while [ "$i" -lt 100 ] && [ "$(grep -c '^add ' "$STUB_LOG")" -lt 2 ]; do /bin/sleep 0.1; i=$((i + 1)); done
kill -TERM "$pid" 2>/dev/null
wait "$pid"; RC=$?
[ "$RC" -ne 124 ] || _fail "SIGTERM: finished within 20 s" "timed out (rc 124)"
check "SIGTERM: rc 143" "$RC" "143"
check "SIGTERM stops the agent" "$(grep -c '^agent-term' "$STUB_LOG")" "1"
if [ -e "$SOCK" ] || [ -L "$SOCK" ]; then _fail "SIGTERM removes the socket" "still there"; else _pass "SIGTERM removes the socket"; fi

if [ -e "$T/xdg" ]; then _fail "XDG_STATE_HOME is ignored (SIGTERM run too)" "$(ls -A "$T/xdg")"; else _pass "XDG_STATE_HOME is ignored (SIGTERM run too)"; fi

H="$T/plisthome"; mkdir "$H"
P="$T/ssh-agent.plist"
sed "s|{{ .chezmoi.homeDir }}|$H|g" "$PLIST" >"$P"
if plutil -lint "$P" >/dev/null 2>&1; then _pass "plist is valid"; else _fail "plist is valid" "$(plutil -lint "$P" 2>&1)"; fi
check "plist label" "$(plutil -extract Label raw -o - "$P" 2>&1)" "be.netronix.ssh-agent"
check "plist runs the script" "$(plutil -extract ProgramArguments.0 raw -o - "$P" 2>&1)" "$H/.local/bin/ssh-agent-run"
check "plist RunAtLoad" "$(plutil -extract RunAtLoad raw -o - "$P" 2>&1)" "true"
check "plist KeepAlive" "$(plutil -extract KeepAlive raw -o - "$P" 2>&1)" "true"

echo "ssh-agent-run: $pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ]
