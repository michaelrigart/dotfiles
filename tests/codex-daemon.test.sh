#!/usr/bin/env bash
# Tests dot_local/bin/executable_codex-daemon and the LaunchAgent that starts the daemon.
#
# The daemon must be started by launchd, never by a TUI: a TUI-spawned daemon keeps that
# pane's HERDR_* environment, and herdr's hook then reports every thread against that one
# pane (spec section 1). `check` is what detects that state, and `restart` is its fix.
# Every external command is stubbed: the real codex, launchctl and ps.
#
# Run: ./tests/run.sh codex-daemon   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CD="$ROOT/dot_local/bin/executable_codex-daemon"
PLIST="$ROOT/Library/LaunchAgents/be.netronix.codex-app-server.plist.tmpl"
for f in "$CD" "$PLIST"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-daemon.XXXXXX")"
trap 'kill $A_PID $B_PID $C_PID 2>/dev/null; rm -rf "$T"' EXIT
A_PID=""; B_PID=""; C_PID=""
mkdir -p "$T/localbin" "$T/brew" "$T/cask/bin" "$T/stub" "$T/codexhome/app-server-daemon"
export CALLS="$T/calls" STATE="$T/state" CODEX_HOME="$T/codexhome" CODEX_DAEMON_WAIT=2

# The launcher's directory: real-bin must never answer with anything in here.
printf '#!/bin/sh\necho LAUNCHER\n' > "$T/localbin/codex"
# The real binary lives in a versioned cask directory and is linked from brew/, as Homebrew does.
cat > "$T/cask/bin/codex" <<'C'
#!/bin/sh
case "$*" in
  "app-server daemon version")
    st="$(cat "$STATE" 2>/dev/null || echo notRunning)"
    if [ -n "${PRETTY:-}" ]; then printf '{\n  "status": "%s"\n}\n' "$st"
    else printf '{"status":"%s"}\n' "$st"; fi ;;
  "app-server daemon stop") echo "codex stop" >> "$CALLS"; echo notRunning > "$STATE" ;;
  *) echo "REAL $*" ;;
esac
C
ln -s "$T/cask/bin/codex" "$T/brew/codex"
cat > "$T/stub/launchctl" <<'L'
#!/bin/sh
echo "launchctl $*" >> "$CALLS"
[ "${KICK_STARTS:-1}" = 1 ] && echo running > "$STATE"
# A restarted daemon writes a fresh pid file.
[ -n "${NEW_SERVER_PID:-}" ] && printf '{"pid":%s}' "$NEW_SERVER_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
exit 0
L
cat > "$T/stub/ps" <<'P'
#!/bin/sh
# `ps eww -o command= -p PID` shows the environment; `ps -o command= -p PID` does not.
[ -n "${PS_FAIL:-}" ] && exit 1
pid=""; for a in "$@"; do pid="$a"; done
cmd="/x/codex app-server --listen unix://"
[ "$pid" = "${FOREIGN_PID:-none}" ] && cmd="/usr/bin/some-other-program"
if [ "$1" = eww ]; then
  case " ${DIRTY_PIDS:-} " in
    *" $pid "*) cmd="$cmd HOME=/h HERDR_PANE_ID=wE:p2" ;;
    *) cmd="$cmd HOME=/h" ;;
  esac
fi
echo "$cmd"
P
chmod +x "$T/localbin/codex" "$T/cask/bin/codex" "$T/stub/launchctl" "$T/stub/ps"

run() { PATH="$T/stub:$T/localbin:$T/brew:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" "$@"; }
real_path="$(cd "$T/cask/bin" && pwd -P)/codex"

echo "A. real-bin"
is "it skips ~/.local/bin and follows the Homebrew symlink" "$(run real-bin)" "$real_path"
ln -s "$T/localbin" "$T/lb-link"
is "a symlinked alias of ~/.local/bin is skipped too" \
   "$(PATH="$T/lb-link:$T/brew:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" real-bin)" "$real_path"
out="$(PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$CD" real-bin 2>&1)"; rc=$?
is "no real codex is an error" "$rc" 1
is "and it says so" "$(printf '%s' "$out" | grep -c 'no codex on PATH outside')" 1

echo "B. ensure"
echo running > "$STATE"; : > "$CALLS"
run ensure; is "a running daemon needs nothing" "$?" 0
is "and launchd is not touched" "$(grep -c launchctl "$CALLS")" 0
echo notRunning > "$STATE"; : > "$CALLS"
run ensure; is "a stopped daemon is started through launchd" "$?" 0
is "by kickstarting the agent" \
   "$(grep -c "launchctl kickstart gui/$(id -u)/be.netronix.codex-app-server" "$CALLS")" 1
echo notRunning > "$STATE"
out="$(KICK_STARTS=0 run ensure 2>&1)"; rc=$?
is "a daemon that will not start is an error" "$rc" 1
is "and names the deliberate escape" "$(printf '%s' "$out" | grep -c -- '--no-daemon')" 1
is "and how to load the agent" "$(printf '%s' "$out" | grep -c 'launchctl bootstrap')" 1
echo running > "$STATE"; : > "$CALLS"
PRETTY=1 run ensure; is "pretty-printed JSON with whitespace around the colon still answers" "$?" 0
is "and launchd is not touched for it either" "$(grep -c launchctl "$CALLS")" 0

echo "C. check"
# Live processes stand in for the daemon: check only trusts a pid it can see running.
sleep 60 & A_PID=$!
sleep 60 & B_PID=$!
echo running > "$STATE"
printf '{"pid":%s,"processStartTime":"x"}' "$A_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
printf '{"pid":%s,"processStartTime":"x"}' "$B_PID" > "$CODEX_HOME/app-server-daemon/daemon-updater.pid"
run check; is "a clean running daemon passes" "$?" 0
out="$(DIRTY_PIDS=$B_PID run check 2>&1)"; rc=$?
is "a daemon process carrying HERDR_* fails" "$rc" 1
is "the fix is named" "$(printf '%s' "$out" | grep -c 'codex-daemon restart')" 1
is "and its cost" "$(printf '%s' "$out" | grep -c 'disconnects every open Codex TUI')" 1
# A recycled pid is not scanned for HERDR_ at all unless it is actually still a Codex
# process (same guard as restart): a pid file outliving its process can be recycled by
# something else entirely, and that something else's environment says nothing about the
# daemon's.
out="$(DIRTY_PIDS=$B_PID FOREIGN_PID=$B_PID run check 2>&1)"; rc=$?
is "a recycled updater pid now held by a non-Codex process carrying HERDR_ does not fail" "$rc" 0
out="$(DIRTY_PIDS=$A_PID FOREIGN_PID=$A_PID run check 2>&1)"; rc=$?
is "but a recycled SERVER pid held by a non-Codex process is a hard failure" "$rc" 1
is "and says it is not a Codex process" "$(printf '%s' "$out" | grep -c 'not a Codex process')" 1
# An environment that cannot be read is not known to be clean, and `ps` is exactly what a
# sandbox denies. Inspection failure must fail the check, never pass it.
out="$(PS_FAIL=1 run check 2>&1)"; rc=$?
is "an environment that cannot be read fails" "$rc" 1
is "and says it could not inspect" "$(printf '%s' "$out" | grep -c 'cannot inspect')" 1
mv "$CODEX_HOME/app-server-daemon/daemon.pid" "$T/daemon.pid.bak"
out="$(run check 2>&1)"; rc=$?
is "a missing server pid file fails" "$rc" 1
is "and names the file" "$(printf '%s' "$out" | grep -c 'daemon.pid')" 1
mv "$T/daemon.pid.bak" "$CODEX_HOME/app-server-daemon/daemon.pid"
kill "$B_PID" 2>/dev/null; sleep 0.5
run check; is "a supervisor pid whose process is gone is skipped, not a failure" "$?" 0
echo notRunning > "$STATE"
out="$(run check 2>&1)"; rc=$?
is "a daemon that does not answer fails" "$rc" 1
is "and says so" "$(printf '%s' "$out" | grep -c 'not answering')" 1

echo "D. restart"
kill "$A_PID" 2>/dev/null
sleep 60 & A_PID=$!
sleep 60 & B_PID=$!
sleep 60 & C_PID=$!   # the server the restarted daemon reports
printf '{"pid":%s}' "$A_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
printf '{"pid":%s}' "$B_PID" > "$CODEX_HOME/app-server-daemon/daemon-updater.pid"
echo running > "$STATE"; : > "$CALLS"
FOREIGN_PID="$B_PID" NEW_SERVER_PID="$C_PID" run restart; rc=$?
is "restart ends with a clean running daemon" "$rc" 0
is "it stops the daemon first" "$(grep -c 'codex stop' "$CALLS")" 1
sleep 0.5   # let bash reap the signalled child, or kill -0 still sees a zombie
is "a surviving Codex daemon process is signalled" "$(kill -0 "$A_PID" 2>/dev/null && echo alive || echo gone)" gone
is "a recycled pid belonging to something else is not" "$(kill -0 "$B_PID" 2>/dev/null && echo alive || echo gone)" alive
is "and the daemon is started again through launchd" "$(grep -c 'launchctl kickstart' "$CALLS")" 1
is "stop happens before the kickstart, not after" \
   "$([ "$(grep -n 'codex stop' "$CALLS" | head -1 | cut -d: -f1)" \
       -lt "$(grep -n 'launchctl kickstart' "$CALLS" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" yes

sleep 60 & A_PID=$!
sleep 60 & B_PID=$!
printf '{"pid":%s}' "$A_PID" > "$CODEX_HOME/app-server-daemon/daemon.pid"
printf '{"pid":%s}' "$B_PID" > "$CODEX_HOME/app-server-daemon/daemon-updater.pid"
echo notRunning > "$STATE"; : > "$CALLS"
out="$(KICK_STARTS=0 FOREIGN_PID="$B_PID" run restart 2>&1)"; rc=$?
is "restart fails when ensure cannot bring the daemon back" "$rc" 1
is "and says so" "$(printf '%s' "$out" | grep -c 'did not start within')" 1
kill "$A_PID" "$B_PID" 2>/dev/null; sleep 0.5

echo "E. the LaunchAgent"
rendered="$T/agent.plist"
chezmoi execute-template --file "$PLIST" > "$rendered" 2>"$T/tpl.err" \
  || { _fail "the plist template renders" "$(head -c 200 "$T/tpl.err")"; }
if plutil -lint "$rendered" >/dev/null 2>&1; then _pass "the rendered plist is valid"; else _fail "the rendered plist is valid" "$(plutil -lint "$rendered" 2>&1)"; fi
rendered_intel="$T/agent-intel.plist"
if chezmoi execute-template --override-data '{"is_arm":false}' --file "$PLIST" \
     > "$rendered_intel" 2>"$T/tpl-intel.err"; then
  _pass "the plist template also renders for is_arm=false"
else
  _fail "the plist template also renders for is_arm=false" "$(head -c 200 "$T/tpl-intel.err")"
fi
if plutil -lint "$rendered_intel" >/dev/null 2>&1; then _pass "the intel-rendered plist is valid"; else _fail "the intel-rendered plist is valid" "$(plutil -lint "$rendered_intel" 2>&1)"; fi
x() { plutil -extract "$1" raw -o - "$rendered" 2>/dev/null; }
is "the label is the one codex-daemon kickstarts" "$(x Label)" "be.netronix.codex-app-server"
is "it runs codex app-server daemon start" "$(x ProgramArguments.1) $(x ProgramArguments.2) $(x ProgramArguments.3)" "app-server daemon start"
is "the program is the real Homebrew binary, not the launcher" \
   "$(x ProgramArguments.0 | grep -c '/\.local/bin/')" 0
is "it runs at load" "$(x RunAtLoad)" true
is "launchd does not reap the daemon when start returns" "$(x AbandonProcessGroup)" true
is "it is not kept alive by launchd (the daemon supervises itself)" "$(x KeepAlive >/dev/null 2>&1 && echo set || echo unset)" unset
is "no HERDR_ variable is handed to the daemon" \
   "$(plutil -extract EnvironmentVariables json -o - "$rendered" 2>/dev/null | grep -c 'HERDR_')" 0
is "the PATH covers the mise shims" "$(x EnvironmentVariables.PATH | grep -c '/.local/share/mise/shims')" 1

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
