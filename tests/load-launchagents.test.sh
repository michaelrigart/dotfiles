#!/usr/bin/env bash
# Mocked test for .scripts/load-launchagents.sh. launchctl is a stub backed by a file of
# loaded labels, so bootstrap and bootout really change what print answers; the script
# never reaches the host's launchd. Run: ./tests/load-launchagents.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$SRC/.scripts/load-launchagents.sh"
[ -f "$SUT" ] || { echo "MISSING SUBJECT: $SUT"; exit 2; }
pass=0; fail=0; OUT=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) _pass "$2";; *) _fail "$2";; esac; }
hasnt(){ case "$OUT" in *"$1"*) _fail "$2";; *) _pass "$2";; esac; }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }
called(){ grep -qF -- "$1" "$CALLS" && _pass "$2" || _fail "$2"; }
not_called(){ grep -qF -- "$1" "$CALLS" && _fail "$2" || _pass "$2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/loadla.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
[ -n "$T" ] && [ -d "$T" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
case "$T" in "$HOME"|"$HOME"/*) echo "REFUSING: temp root is inside the real HOME"; exit 2;; esac
mkdir -p "$T/bin" "$T/home/Library/LaunchAgents"
CALLS="$T/calls"; LOADED="$T/loaded"; : > "$CALLS"; : > "$LOADED"
LA="$T/home/Library/LaunchAgents"
REC="$T/home/.local/state/launchagents"
UID_NOW=$(id -u)

# File-backed launchctl: print exits 0 iff the label is listed, bootstrap adds it (unless
# FAIL_BOOTSTRAP names it), bootout removes it. Like launchd, bootstrap of a loaded label
# fails with 5. Race knobs: LINGER names a label that still answers print once after its
# bootout (and refuses bootstrap until then); FAIL_FIRST names one whose first bootstrap
# fails. Every call is logged.
cat > "$T/bin/launchctl" <<'L'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
[ -n "${LOADED:-}" ] || { echo "launchctl stub: LOADED unset" >&2; exit 99; }
verb=$1; target=$2
case "$verb" in
  print)     label=${target##*/}
             if grep -qx "$label" "$LOADED"; then exit 0; fi
             if [ -f "$LOADED.linger" ]; then rm -f "$LOADED.linger"; exit 0; fi
             exit 1 ;;
  bootstrap) label=$(basename "$3" .plist)
             grep -qx "$label" "$LOADED" && exit 5
             [ -f "$LOADED.linger" ] && exit 5
             [ "${FAIL_BOOTSTRAP:-}" = "$label" ] && exit 5
             if [ "${FAIL_FIRST:-}" = "$label" ] && [ ! -f "$LOADED.failed1" ]; then : > "$LOADED.failed1"; exit 5; fi
             echo "$label" >> "$LOADED" ;;
  bootout)   label=${target##*/}
             grep -vx "$label" "$LOADED" > "$LOADED.n"; mv "$LOADED.n" "$LOADED"
             [ "${LINGER:-}" = "$label" ] && echo "$label" > "$LOADED.linger" ;;
esac
exit 0
L
chmod +x "$T/bin/launchctl"

plist(){ printf '<plist>%s</plist>\n' "$2" > "$LA/$1.plist"; }
load(){ OUT=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" CALLS="$CALLS" LOADED="$LOADED" \
    FAIL_BOOTSTRAP="${FAIL_BOOTSTRAP:-}" FAIL_FIRST="${FAIL_FIRST:-}" LINGER="${LINGER:-}" \
    /bin/bash "$SUT" 2>&1); RC=$?; }
reset(){ : > "$CALLS"; : > "$LOADED"; rm -f "$LOADED.linger" "$LOADED.failed1" "$LA"/*.plist
  [ -d "$REC" ] && chmod -R u+w "$REC"; rm -rf "$T/home/.local"; }

echo "A. no plists"
reset; load
rc_is 0 "no plists: exit 0"
not_called "launchctl bootstrap" "and nothing is bootstrapped"

echo "B. a job that is not loaded is bootstrapped and recorded"
reset; plist be.netronix.one v1; load
rc_is 0 "exit 0"
has "  loaded be.netronix.one" "reported loaded"
called "launchctl bootstrap gui/$UID_NOW $LA/be.netronix.one.plist" "bootstrapped into the user's gui domain"
not_called "launchctl bootout" "nothing booted out first"
cmp -s "$LA/be.netronix.one.plist" "$REC/be.netronix.one.plist" \
  && _pass "the plist is recorded" || _fail "the plist is recorded"

echo "C. loaded with an identical record: untouched"
: > "$CALLS"; load
rc_is 0 "exit 0"
has "  unchanged be.netronix.one" "reported unchanged"
not_called "launchctl bootout" "no bootout on a second run"
not_called "launchctl bootstrap" "no bootstrap on a second run"

echo "D. a changed plist reloads only that job"
plist be.netronix.two v1; load
plist be.netronix.one v2; : > "$CALLS"; load
has "  reloaded be.netronix.one" "the edited job is reloaded"
has "  unchanged be.netronix.two" "the other job is not"
called "launchctl bootout gui/$UID_NOW/be.netronix.one" "the edited job was booted out"
not_called "launchctl bootout gui/$UID_NOW/be.netronix.two" "the other job was not"
cmp -s "$LA/be.netronix.one.plist" "$REC/be.netronix.one.plist" \
  && _pass "the record follows the reload" || _fail "the record follows the reload"
: > "$CALLS"; load
not_called "launchctl bootout" "the run after a reload changes nothing"

echo "E. loaded with no record: reloaded once, then recorded"
rm -f "$REC/be.netronix.two.plist"; : > "$CALLS"; load
has "  reloaded be.netronix.two" "a missing record counts as changed"
cmp -s "$LA/be.netronix.two.plist" "$REC/be.netronix.two.plist" \
  && _pass "and is recorded" || _fail "and is recorded"

echo "F. codex-app-server is never reloaded"
reset; plist be.netronix.codex-app-server v1; load
has "  loaded be.netronix.codex-app-server" "absent: it is bootstrapped"
plist be.netronix.codex-app-server v2; : > "$CALLS"; load
has "  unchanged be.netronix.codex-app-server (never reloaded here: a reload disconnects every Codex session)" \
  "loaded and edited: left alone, with the reason"
not_called "launchctl bootout" "no bootout"
not_called "launchctl bootstrap" "no bootstrap"
rm -f "$REC/be.netronix.codex-app-server.plist"; : > "$CALLS"; load
not_called "launchctl bootout" "a missing record does not reload it either"
[ -e "$REC/be.netronix.codex-app-server.plist" ] \
  && _fail "and no record is written for a loaded one" || _pass "and no record is written for a loaded one"

echo "G. a bootstrap failure is reported, unrecorded, and fails the run at the end"
reset; plist be.netronix.bad v1; plist be.netronix.good v1
FAIL_BOOTSTRAP=be.netronix.bad load; FAIL_BOOTSTRAP=
rc_is 1 "exit 1"
has "  could not load be.netronix.bad — run: launchctl bootstrap gui/$UID_NOW $LA/be.netronix.bad.plist" "the remedy is named"
has "  loaded be.netronix.good" "the other job still loads"
[ -e "$REC/be.netronix.bad.plist" ] \
  && _fail "the failed job is not recorded" || _pass "the failed job is not recorded"

echo "H. a reload waits for the bootout to finish, and a lost bootstrap is retried once"
reset; plist be.netronix.one v1; load; plist be.netronix.one v2; : > "$CALLS"
LINGER=be.netronix.one load; LINGER=
rc_is 0 "a label that lingers after bootout: exit 0"
has "  reloaded be.netronix.one" "it is reloaded once the label is gone"
n=$(grep -c "^launchctl bootstrap" "$CALLS" || true)
[ "$n" = 1 ] && _pass "with a single bootstrap (it waited, it did not retry)" || _fail "with a single bootstrap (bootstraps=$n)"
reset; plist be.netronix.one v1; : > "$CALLS"
FAIL_FIRST=be.netronix.one load; FAIL_FIRST=
rc_is 0 "a first bootstrap that fails: exit 0 after the retry"
has "  loaded be.netronix.one" "the retry loads it"
n=$(grep -c "^launchctl bootstrap" "$CALLS" || true)
[ "$n" = 2 ] && _pass "with exactly one retry" || _fail "with exactly one retry (bootstraps=$n)"
cmp -s "$LA/be.netronix.one.plist" "$REC/be.netronix.one.plist" \
  && _pass "and records it" || _fail "and records it"

echo "I. a failed record write is reported, and the job still counts as loaded"
reset; plist be.netronix.one v1; mkdir -p "$REC"; chmod 555 "$REC"
load
rc_is 1 "exit 1"
has "  loaded be.netronix.one" "the job is loaded"
has "  could not record be.netronix.one in $REC" "the failed record is named"
grep -qx be.netronix.one "$LOADED" && _pass "and launchd has it" || _fail "and launchd has it"
chmod 755 "$REC"

echo "J. other plists are ignored"
reset; plist com.example.other v1; load
rc_is 0 "exit 0"
not_called "launchctl bootstrap" "only be.netronix.* is loaded"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
