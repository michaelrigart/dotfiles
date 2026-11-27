#!/usr/bin/env bash
# Tests dot_local/bin/executable_herdr-core-desktop and the be.netronix.herdr-core-desktop plist:
# the job that moves Herdr's core into the desktop login when its programs cannot use the login
# keychain (spec 2026-11-27-hercules-herdr-desktop-session).
#
# Bugs caught: a usable core being restarted; a failed move restarting again or never unloading
# the job; the job unloading itself before the failure is logged (launchd would kill the script
# first); a check run before the wait for herdr's own stop and start; a changed environment
# reaching `server restart --fresh`; a herdr-core call outside timeout; a herdr-core `server stop`,
# `kill` or `rm`; a path
# with a space splitting; a fresh machine without ~/.local/state; a plist that restarts the job
# in a loop or runs it outside the desktop login.
#
# herdr-core, timeout, sleep and launchctl are stubs; every scratch HOME has a space in its name.
#
#   ./tests/herdr-core-desktop.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/dot_local/bin/executable_herdr-core-desktop"
PLIST="$SRC/Library/LaunchAgents/be.netronix.herdr-core-desktop.plist.tmpl"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
[ -f "$PLIST" ] || { echo "missing plist under test: $PLIST" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2 (want $3)"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/herdr-core-desktop.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
ALL="$T/all.calls"
: >"$ALL"
UID_NOW=$(/usr/bin/id -u)
LABEL=be.netronix.herdr-core-desktop

n=0
# fresh <move>: a new scratch HOME with a space in its name and no .local/state, the herdr-core
# stub in it and stub tools beside it; sets H, TOOLS, CALLS, CTX, LOGF, RESTARTENV.
fresh() {
  n=$((n + 1))
  H="$T/home $n"
  TOOLS="$T/tools $n"
  CALLS="$T/calls $n"
  CTX="$T/ctx $n"
  LOGF="$H/.local/state/herdr-core-desktop.log"
  RESTARTENV="$T/restart $n.env"
  local move="$T/move $n" armed="$T/armed $n"
  mkdir -p "$H/.local/bin" "$TOOLS"
  : >"$CALLS"
  echo bad >"$CTX"
  echo "$1" >"$move"
  cat >"$H/.local/bin/herdr-core" <<STUB
#!/bin/bash
if [ -n "\${STUB_VIA_TIMEOUT:-}" ]; then name=hc; else name=hc-direct; fi
{ printf '%s' "\$name"; printf ' [%s]' "\$@"; printf '\n'; } >>"$CALLS"
case "\$1" in
  exec)
    if [ "\$(cat "$CTX")" = ok ]; then exit 0; fi
    if [ -e "$armed" ]; then rm -f "$armed"; echo ok >"$CTX"; fi
    echo "security: SecKeychainCopySettings: User interaction is not allowed." >&2
    exit 36 ;;
  server)
    if [ "\$2" = restart ] && [ "\$3" = --fresh ]; then
      env | /usr/bin/grep -v '^STUB_VIA_TIMEOUT=' >"$RESTARTENV"
      case "\$(cat "$move")" in
        now) echo ok >"$CTX" ;;
        late) : >"$armed" ;;
      esac
    fi ;;
esac
exit 0
STUB
  cat >"$TOOLS/timeout" <<STUB
#!/bin/bash
{ printf 'timeout'; printf ' [%s]' "\$@"; printf '\n'; } >>"$CALLS"
export STUB_VIA_TIMEOUT=1
if [ "\$1" = -f ]; then shift; fi; shift
exec "\$@"
STUB
  cat >"$TOOLS/sleep" <<STUB
#!/bin/bash
{ printf 'sleep'; printf ' [%s]' "\$@"; printf '\n'; } >>"$CALLS"
STUB
  cat >"$TOOLS/launchctl" <<STUB
#!/bin/bash
{ printf 'launchctl'; printf ' [%s]' "\$@"; printf '\n'; } >>"$CALLS"
if /usr/bin/grep -q 'could not move' "$LOGF" 2>/dev/null; then echo log-had-failure=yes >>"$CALLS"; else echo log-had-failure=no >>"$CALLS"; fi
STUB
  chmod 755 "$H/.local/bin/herdr-core" "$TOOLS/timeout" "$TOOLS/sleep" "$TOOLS/launchctl"
}
runit() { # runs the script in the environment the job gives it; sets RC
  /usr/bin/timeout 30 env -i HOME="$H" PATH=/opt/x:/usr/bin:/bin HCD_TOOLS="$TOOLS" MARKER=kept /bin/bash "$SCRIPT" >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 124 ] || _fail "script finished within 30 s" "timed out (rc 124)"
  cat "$CALLS" >>"$ALL"
}
count() { grep -cxF -- "$1" "$CALLS"; }
loglines() { if [ -f "$LOGF" ]; then wc -l <"$LOGF" | tr -d ' '; else echo none; fi; }

CHECK_ARGS=" [exec] [/usr/bin/security] [show-keychain-info]"

echo "herdr-core-desktop"

fresh now
echo ok >"$CTX"
runit
HC="$H/.local/bin/herdr-core"
KC="$H/Library/Keychains/login.keychain-db"
check "A usable core: rc" "$RC" "0"
check "A usable core: sleep, then one check through timeout, nothing else" \
  "$(tr '\n' '|' <"$CALLS")" \
  "sleep [5]|timeout [-f] [60] [$HC]$CHECK_ARGS [$KC]|hc$CHECK_ARGS [$KC]|"
check "A usable core: no log file" "$(loglines)" "none"

fresh now
runit
check "B unusable, moves at once: rc" "$RC" "0"
check "B one restart" "$(count 'hc [server] [restart] [--fresh]')" "1"
check "B one log line" "$(loglines)" "1"
if grep -q 'moved' "$LOGF" 2>/dev/null; then _pass "B log line says moved"; else _fail "B log line says moved" "$(cat "$LOGF" 2>/dev/null)"; fi
check "B no launchctl call" "$(grep -c '^launchctl' "$CALLS")" "0"
BENV=$(cat "$RESTARTENV" 2>/dev/null)

fresh late
runit
check "C moves only after the re-check: rc" "$RC" "0"
check "C one restart" "$(count 'hc [server] [restart] [--fresh]')" "1"
check "C three checks" "$(grep -c '^hc \[exec\]' "$CALLS")" "3"
check "C from the restart: check, sleep, check (timeout lines left out)" \
  "$(sed -n '/^hc \[server\] \[restart\] \[--fresh\]$/,$p' "$CALLS" | grep -E '^(hc|sleep)' | sed 's/^hc \[exec\].*/check/; s/^hc \[server\].*/restart/; s/^sleep.*/sleep/' | tr '\n' ' ')" \
  "restart check sleep check "
check "C sleeps before the first check and before the re-check" "$(count 'sleep [5]')" "2"
check "C one log line" "$(loglines)" "1"
if grep -q 'moved' "$LOGF" 2>/dev/null; then _pass "C log line says moved"; else _fail "C log line says moved" "$(cat "$LOGF" 2>/dev/null)"; fi

fresh never
runit
check "D never moves: rc" "$RC" "1"
check "D exactly one restart" "$(count 'hc [server] [restart] [--fresh]')" "1"
check "D one log line" "$(loglines)" "1"
if grep -q 'could not move' "$LOGF" 2>/dev/null; then _pass "D log line says could not move"; else _fail "D log line says could not move" "$(cat "$LOGF" 2>/dev/null)"; fi
check "D boots its own label out once" "$(count "launchctl [bootout] [gui/$UID_NOW/$LABEL]")" "1"
check "D the failure is logged before the bootout" "$(count 'log-had-failure=yes')" "1"

fresh now
rm "$H/.local/bin/herdr-core"
runit
check "E herdr-core missing: rc" "$RC" "0"
check "E herdr-core missing: no calls" "$(wc -c <"$CALLS" | tr -d ' ')" "0"
check "E herdr-core missing: no log file" "$(loglines)" "none"

check "F PATH reaches --fresh unchanged" "$(echo "$BENV" | grep '^PATH=')" "PATH=/opt/x:/usr/bin:/bin"
check "F MARKER reaches --fresh unchanged" "$(echo "$BENV" | grep '^MARKER=')" "MARKER=kept"
check "F no other variable reaches --fresh" \
  "$(echo "$BENV" | cut -d= -f1 | grep -vxE 'HOME|PATH|HCD_TOOLS|MARKER|SHLVL|_|PWD|OLDPWD' | tr '\n' ' ')" ""

check "G every herdr-core call went through timeout" "$(grep -c '^hc-direct' "$ALL")" "0"
check "G every timeout signals only herdr-core, after 60 s" "$(grep '^timeout' "$ALL" | grep -vc '^timeout \[-f\] \[60\] ')" "0"
check "G no server stop, kill or rm" "$(grep -cE '^hc \[(server\] \[stop|kill|rm)\]' "$ALL")" "0"

H="$T/plist home"; mkdir "$H"
P="$T/herdr-core-desktop.plist"
sed "s|{{ .chezmoi.homeDir }}|$H|g" "$PLIST" >"$P"
absent() { plutil -extract "$1" raw -o - "$P" >/dev/null 2>&1; echo $?; }
if plutil -lint "$P" >/dev/null 2>&1; then _pass "H plist is valid"; else _fail "H plist is valid" "$(plutil -lint "$P" 2>&1)"; fi
check "H plist label" "$(plutil -extract Label raw -o - "$P" 2>&1)" "$LABEL"
check "H plist runs the script" "$(plutil -extract ProgramArguments.0 raw -o - "$P" 2>&1)" "$H/.local/bin/herdr-core-desktop"
check "H plist RunAtLoad" "$(plutil -extract RunAtLoad raw -o - "$P" 2>&1)" "true"
check "H plist AbandonProcessGroup" "$(plutil -extract AbandonProcessGroup raw -o - "$P" 2>&1)" "true"
check "H plist LimitLoadToSessionType" "$(plutil -extract LimitLoadToSessionType raw -o - "$P" 2>&1)" "Aqua"
check "H plist WatchPaths" "$(plutil -extract WatchPaths.0 raw -o - "$P" 2>&1)" "$H/.local/state/herdr-core/default/core.lock"
check "H plist has no KeepAlive" "$(absent KeepAlive)" "1"
check "H plist has no EnvironmentVariables" "$(absent EnvironmentVariables)" "1"
check "H plist StandardOutPath" "$(plutil -extract StandardOutPath raw -o - "$P" 2>&1)" "/dev/null"
check "H plist StandardErrorPath" "$(plutil -extract StandardErrorPath raw -o - "$P" 2>&1)" "/dev/null"

echo "herdr-core-desktop: $pass/$((pass + fail)) passed"
[ "$fail" -eq 0 ]
