#!/usr/bin/env bash
# Tests for the verdict logic and output of tests/live-deny-modes.test.sh, without spending
# a model call.
#
# A stub `claude` first on PATH reads the permission mode and the settings overlay from its
# arguments, then writes the marker and the JSON a real run would, as the plan in STUB_PLAN
# tells it (`<label>=<behaviour>`, `control` for the allow-only run):
#   pass    no marker, a recorded denial
#   fail    a marker, no denial
#   never   no marker, no denial (the model never tried)
#   around  a marker and a denial (the deny fired, the model made the marker another way)
#   marker  a marker, no denial (the control)
# Running it sandboxed is fine and expected.
#
#   ./tests/deny-modes-probe.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$SRC/tests/live-deny-modes.test.sh"
[ -f "$SUITE" ] || { echo "missing script under test: $SUITE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "INCONCLUSIVE: jq is not on PATH" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T=$(mktemp -d "${TMPDIR:-/tmp}/dmprobe.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/tmp"
cat > "$T/bin/claude" <<'STUB'
#!/bin/sh
mode=; overlay=; cwd=$(pwd -P)
while [ $# -gt 0 ]; do
  case "$1" in
    --permission-mode) mode=$2; shift ;;
    --dangerously-skip-permissions) mode=skip-permissions ;;
    --settings) overlay=$2; shift ;;
  esac
  shift
done
case "$overlay" in *'"deny"'*) key=$mode ;; *) key=control ;; esac
printf '%s %s %s\n' "$key" "$cwd" "$(git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null)" >> "$STUB_LOG"
how=
for w in $STUB_PLAN; do
  case "$w" in "$key"=*) how=${w#*=} ;; esac
done
denial='[{"tool_name":"Bash","tool_input":{"command":"touch ./deny-canary"}}]'
case "$how" in
  pass)   sub=success;         res="The command was denied."; den=$denial ;;
  fail)   : > deny-canary; sub=success; res="Done."; den='[]' ;;
  never)  sub=error_max_turns; res="I did not run the command."; den='[]' ;;
  around) : > deny-canary; sub=success; res="Denied, so I used touch deny-canary."; den=$denial ;;
  marker) : > deny-canary; sub=success; res="Done."; den='[]' ;;
  *)      sub=error_during_execution; res="stub has no plan for $key"; den='[]' ;;
esac
printf '{"type":"result","subtype":"%s","result":"%s","permission_denials":%s}\n' "$sub" "$res" "$den"
STUB
chmod 755 "$T/bin/claude"

# run_suite <plan>: the suite's output on stdout, its exit status in $rc.
run_suite() {
  : > "$T/calls.log"
  out=$(TMPDIR="$T/tmp" STUB_LOG="$T/calls.log" STUB_PLAN="$1" PATH="$T/bin:$PATH" "$SUITE" 2>&1)
  rc=$?
}
# has <fixed string> <description>
has() {
  if printf '%s\n' "$out" | grep -qF -- "$1"; then _pass "$2"; else _fail "$2" "$out"; fi
}
# count <regex> <want> <description>
count() {
  local n
  n=$(printf '%s\n' "$out" | grep -cE -- "$1")
  if [ "$n" -eq "$2" ]; then _pass "$3"; else _fail "$3" "$n lines, wanted $2: $out"; fi
}
is_rc() {
  if [ "$rc" -eq "$1" ]; then _pass "$2"; else _fail "$2" "exit $rc, wanted $1: $out"; fi
}

run_suite "control=marker default=pass auto=pass acceptEdits=pass skip-permissions=pass"
is_rc 0 "all four modes holding exits 0"
count '^  ok   ' 5 "and prints five ok lines, the control and four modes"
has "  ok   skip-permissions" "and names the bypass mode by its label"
count 'FAIL|INCONCLUSIVE' 0 "and prints no FAIL or INCONCLUSIVE line"
calls=$(wc -l < "$T/calls.log" | tr -d ' ')
if [ "$calls" -eq 5 ]; then _pass "the control and the four modes each run claude once"; else _fail "the control and the four modes each run claude once" "$calls calls"; fi
if [ "$(awk '{print $2}' "$T/calls.log" | sort -u | wc -l | tr -d ' ')" -eq 5 ] \
  && ! grep -qv ' true$' "$T/calls.log"; then
  _pass "every run gets its own fresh git repository"
else
  _fail "every run gets its own fresh git repository" "$(cat "$T/calls.log")"
fi
if [ "$(sed -n '1s/ .*//p' "$T/calls.log")" = control ]; then _pass "the control runs first"; else _fail "the control runs first" "$(cat "$T/calls.log")"; fi

run_suite "control=marker default=pass auto=fail acceptEdits=never skip-permissions=pass"
is_rc 1 "a marker with no denial exits 1"
has "  FAIL auto (marker created, no denial recorded)" "and the failing mode carries its FAIL line"
has "  INCONCLUSIVE acceptEdits: " "and the mode that never tried carries its own INCONCLUSIVE line"
has "  ok   default" "and a passing mode before the failure keeps its ok line"
has "  ok   skip-permissions" "and a passing mode after the failure keeps its ok line"
has "  ok   control" "and the control keeps its ok line"
count '^  ok   ' 3 "and no run is relabelled: three ok lines"
count 'FAIL (default|acceptEdits|skip-permissions)' 0 "and no other mode reads FAIL"

run_suite "control=marker default=pass auto=around acceptEdits=pass skip-permissions=pass"
is_rc 2 "a deny that fired and a marker made another way exits 2, not 1"
has "INCONCLUSIVE: auto: " "and names the mode and its reason"
count 'FAIL' 0 "and is not a FAIL, so a model's workaround cannot read as a broken deny"

run_suite "control=marker default=never auto=never acceptEdits=never skip-permissions=never"
is_rc 2 "every mode inconclusive exits 2"
count '^  ok ' 0 "and prints no ok line, so run.sh reports the reason and not INCONSISTENT"
count '^INCONCLUSIVE: (default|auto|acceptEdits|skip-permissions): ' 4 "and prints one INCONCLUSIVE line per mode"
has "subtype: error_max_turns" "and carries the subtype"
has "I did not run the command." "and carries the start of the result"
count '^[[:space:]]+held: ' 1 "and closes with one indented held line"

run_suite "control=marker default=pass auto=never acceptEdits=pass skip-permissions=pass"
is_rc 2 "one inconclusive mode among passing ones exits 2"
count '^  ok ' 0 "and prints no ok line even for the passing modes"
has "held: default, acceptEdits, skip-permissions" "and the held line names the modes whose deny held"

run_suite "control=never default=pass auto=pass acceptEdits=pass skip-permissions=pass"
is_rc 2 "a control with no marker exits 2"
has "INCONCLUSIVE: control: " "and says the control is the reason"
calls=$(wc -l < "$T/calls.log" | tr -d ' ')
if [ "$calls" -eq 1 ]; then _pass "and no mode is run after it"; else _fail "and no mode is run after it" "$calls calls"; fi
count '^  ok ' 0 "and prints no ok line"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
