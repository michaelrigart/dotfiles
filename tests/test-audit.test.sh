#!/usr/bin/env bash
# Suite for .scripts/test-audit/audit.py, the mutation-audit harness. Every case runs the
# harness against a throwaway git repository built from tests/fixtures/test-audit, with its
# own state, copy root, run lock and a read-only probe directory standing in for $HOME.
# Run: ./tests/test-audit.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$SRC/.scripts/test-audit/audit.py"
FIX="$SRC/tests/fixtures/test-audit"
[ -f "$AUDIT" ] || { echo "missing script under test: $AUDIT"; exit 2; }
[ -d "$FIX" ] || { echo "missing fixture repository: $FIX"; exit 2; }
pass=0; fail=0; OUT=""; ERR=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }
has(){ case "$3" in *"$1"*) _pass "$2";; *) _fail "$2 (got: $3)";; esac; }
eq(){ [ "$1" = "$2" ] && _pass "$3" || _fail "$3 (got: $1, want: $2)"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-audit-suite.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
ROOT=$(cd "$ROOT" && pwd -P)
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
case "$ROOT" in "$HOME"|"$HOME"/*) echo "REFUSING: temp root is inside the real HOME"; exit 2;; esac
cleanup(){
  jobs -p | xargs kill 2>/dev/null
  chmod -R u+w "$ROOT" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

GIT=(git -c user.name=fixture -c user.email=fixture@localhost -c commit.gpgsign=false)
# mk <case>: a fresh fixture repository with run.sh beside the fixture suites, plus its own
# state, copies, lock and run markers. $T/ro is the unwritable probe directory.
mk(){
  T="$ROOT/$1"; mkdir -p "$T/markers" "$T/ro"; chmod 555 "$T/ro"
  cp -R "$FIX" "$T/repo"; cp "$SRC/tests/run.sh" "$T/repo/tests/run.sh"
  "${GIT[@]}" -C "$T/repo" init -q -b main
  "${GIT[@]}" -C "$T/repo" add -A
  "${GIT[@]}" -C "$T/repo" commit -q -m fixture
  export AUDIT_MARKERS="$T/markers"
}
aud(){
  "$AUDIT" --repo "$T/repo" --state "$T/state" --copy-root "$T/copies" --lock "$T/lock" \
    --probe-dir "$T/ro" --subjects "$T/repo/subjects.tsv" "$@"
}
run(){ OUT=$(aud "$@" 2>"$T/err"); RC=$?; ERR=$(<"$T/err"); }
jget(){ python3 -c 'import json,sys
v=json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v,str) else json.dumps(v))' "$OUT" "$1"; }
runs(){ [ -f "$T/markers/$1.ran" ] && wc -l <"$T/markers/$1.ran" | tr -d ' ' || echo 0; }
# E: no case may leave the checkout dirty.
clean(){
  local s; s=$("${GIT[@]}" -C "$T/repo" status --porcelain)
  [ -z "$s" ] && _pass "$1: the checkout is untouched" || _fail "$1: the checkout is dirty ($s)"
}
# The hang mutants record the pids of their shell and sleep in $T/markers/hang.pids. Sandboxed,
# pgrep and ps cannot list processes, so a pgrep-only check would pass vacuously; kill -0 works.
hung(){ # hung: a recorded pid is still running
  local p
  for p in $(cat "$T/markers/hang.pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && return 0; done
  pgrep -f audit-hang-marker >/dev/null 2>&1
}
started(){ [ -s "$T/markers/hang.pids" ]; }
gone(){ # gone: nothing of the hang runs, allowing the reaper a moment; it must have started
  local i
  started || return 1
  for i in $(seq 1 20); do
    hung || return 0
    sleep 0.1
  done
  return 1
}

ADD='$(( $1 + $2 ))'; SUB='$(( $1 - $2 ))'
FLAGCHK='check "flag is set" "$FLAG" on'
HANGCMD=$(cat <<'X'
sh -c 'sleep 30 & echo "$$ $!" >> "$AUDIT_MARKERS/hang.pids"; wait # audit-hang-marker'
X
)
HANG="while :; do $HANGCMD; done; FLAG=on"

echo "A. refusals"
mk A
run --probe-dir "$T" inventory s
rc_is 2 "a writable probe directory is refused"
has "refusing: $T is writable, so this shell is not sandboxed" "the refusal says why" "$ERR"
eq "$(runs s)" 0 "the suite never ran after the refusal"
run --copy-root "$T/repo/x" inventory s
rc_is 2 "a copy root inside the repository is refused"
has "refusing: copy root $T/repo/x is inside the repository" "the refusal names the copy root" "$ERR"
[ ! -e "$T/repo/x" ] && _pass "nothing was created inside the repository" || _fail "nothing was created inside the repository"
clean A

echo "B. attribution"
mk B
run try bin/s.sh "$ADD" "$SUB" s
eq "$(jget verdict)" killed "B1: breaking add is killed"
eq "$(jget killers)" '["add returns the sum"]' "B1: exactly the add assertion is the killer"
run try bin/s.sh '&& echo "$d"' '&& rmdir "$d" && echo "$d"' s
eq "$(jget verdict)" killed "B2: a kill whose label holds a temp path is still a kill"
eq "$(jget killers)" '["scratch dir exists at <tmp>"]' "B2: the killer label carries <tmp>, not the path"
run try tests/s.test.sh "$FLAGCHK" "bad \"brand new label\"; $FLAGCHK" s
eq "$(jget verdict)" killed "B2: a FAIL label absent from the baseline is a kill"
eq "$(jget killers)" '[]' "B2: it is no killer"
eq "$(jget unmatched)" '["brand new label"]' "B2: it is listed as unmatched"
run try bin/s.sh 'echo never-called' 'echo changed' s
eq "$(jget verdict)" survived "B3: a mutant on an uncovered line survives"
run try bin/s.sh 'not in the file' x s
rc_is 2 "a FIND that is absent exits 2"
run try tests/s.test.sh 'check "' 'check  "' s
rc_is 2 "a FIND that occurs several times exits 2"
clean B

echo "C. hangs and crashes"
mk C
t0=$SECONDS
run --timeout-floor 2 try bin/s.sh 'FLAG=on' "$HANG" s
t1=$((SECONDS - t0))
eq "$(jget verdict)" inconclusive "C1: a hanging mutant is inconclusive"
eq "$(jget timed_out)" true "C1: it reports the timeout"
[ "$t1" -lt 10 ] && _pass "C1: it took ${t1}s" || _fail "C1: it took ${t1}s, want under 10"
gone && _pass "C1: nothing of the hang is left running" || _fail "C1: the hang left a process behind"
run try tests/s.test.sh "$FLAGCHK" 'exit 3' s
eq "$(jget verdict)" inconclusive "C2: exit 3 with no FAIL line is inconclusive"
run try tests/s.test.sh "$FLAGCHK" 'exit 0' s
eq "$(jget verdict)" inconclusive "C2: exit 0 after fewer PASS lines is inconclusive"
run try tests/s.test.sh '[ "$fail" -eq 0 ]' 'exit 3' s
eq "$(jget verdict)" inconclusive "C2: exit 3 after every assertion, with no FAIL line, is inconclusive"
: > "$T/markers/hang.pids"
run --timeout-floor 2 try tests/s.test.sh "$FLAGCHK" "bad \"flag is set\"; $HANGCMD" s
eq "$(jget verdict)" inconclusive "C2: a FAIL and then a hang is inconclusive"
eq "$(jget timed_out)" true "C2: the hang is reported as a timeout"
gone && _pass "C2: that hang left nothing running" || _fail "C2: that hang left a process behind"
run try tests/s.test.sh "$FLAGCHK" 'bad "flag is set"; exit 1' s
eq "$(jget verdict)" inconclusive "C2: a FAIL and then an exit before the remaining cases is inconclusive"
clean C

echo "D. red baseline"
mk D
run try bin/s.sh "$ADD" "$SUB" red
eq "$(jget verdict)" baseline-red "D: a failing suite is baseline-red"
eq "$(runs red)" 1 "D: only the baseline ran, not the mutant"
clean D

echo "F. interrupted"
mk F
# Not through aud(): a backgrounded function is a subshell, and SIGTERM must reach the harness itself.
"$AUDIT" --repo "$T/repo" --state "$T/state" --copy-root "$T/copies" --lock "$T/lock" --probe-dir "$T/ro" \
  --timeout-floor 60 try bin/s.sh 'FLAG=on' "$HANG" s >"$T/out" 2>"$T/err" &
pid=$!
for i in $(seq 1 100); do started && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"; RC=$?
[ "$RC" -ne 0 ] && _pass "F: the harness exits on SIGTERM (rc=$RC)" || _fail "F: the harness exits on SIGTERM (rc=0)"
gone && _pass "F: the hanging suite is killed" || _fail "F: the hanging suite survived SIGTERM"
eq "$(ls "$T/copies" 2>/dev/null | wc -l | tr -d ' ')" 0 "F: its copy directory is gone"
lockf -t 0 "$T/lock" true; RC=$?
rc_is 0 "F: the lock is free"
clean F
run try bin/s.sh "$ADD" "$SUB" s
eq "$(jget verdict)" killed "F: the next run starts from a clean baseline"

echo "G. the run lock"
mk G
run try bin/s.sh "$ADD" "$SUB" lock
eq "$(jget verdict)" survived "G1: the lock suite sees the lock held, baseline and mutant"
eq "$(runs lock)" 2 "G1: it ran twice"
lockf -t 0 "$T/lock" true; RC=$?
rc_is 0 "G1: the lock is released after the harness exits"
lockf -k "$T/lock" sleep 4 &
for i in $(seq 1 50); do lockf -k -t 0 "$T/lock" true 2>/dev/null; [ $? -eq 75 ] && break; sleep 0.1; done
run --timeout-floor 2 try bin/s.sh "$ADD" "$SUB" s
eq "$(jget verdict)" killed "G2: waiting for the lock does not trip the timeout"
has "waiting for the test-run lock $T/lock" "G2: it says it is waiting" "$ERR"
wait
clean G

echo "H. inventory"
mk H
run inventory
rc_is 0 "inventory succeeds"
rows="$T/state/inventory.jsonl"
q(){ python3 -c 'import json,sys
rows={}
for l in open(sys.argv[1]):
    r=json.loads(l); rows[r["suite"]]=r
r=rows.get(sys.argv[2])
v=r[sys.argv[3]] if r else "NO-ROW"
print(v if isinstance(v,str) else json.dumps(v))' "$rows" "$1" "$2"; }
eq "$(wc -l <"$rows" | tr -d ' ')" 5 "H: one row per fixture suite"
want=$(RUN_SH_LOCK="$T/lock" AUDIT_MARKERS= "$T/repo/tests/run.sh" s 2>&1 | awk '$2=="s"{split($3,a,"/"); print a[2]}')
eq "$(q s assertions)" "$want" "H: s has the assertion count run.sh reports"
eq "$(q s passed)" 4 "H: s passed count"
eq "$(q s failed)" 0 "H: s failed count"
eq "$(q red failed)" 1 "H: a red suite keeps its failure"
eq "$(q red rc)" 1 "H: and its exit status"
eq "$(q gated seconds)" null "H: a gated suite has no seconds"
eq "$(q gated requires)" unsandboxed "H: and records its requirement"
eq "$(runs gated)" 0 "H: a gated suite is not run"
eq "$(q lock passed)" 1 "H: the lock suite passes under the inventory"
case "$(q s labels)" in *'"add returns the sum"'*) _pass "H: labels list the passed assertions";; *) _fail "H: labels list the passed assertions";; esac
case "$(q s2 labels)" in *'"p.py doubles #2"'*) _pass "H: a repeated label gets #2";; *) _fail "H: a repeated label gets #2 (got: $(q s2 labels))";; esac
run report --section inventory
has "| s |" "H: the report has a row for s" "$OUT"
has "bin/s.sh" "H: and lists the files s loads" "$OUT"
clean H

echo "I. state binding"
"${GIT[@]}" -C "$T/repo" commit -q --allow-empty -m second
second=$("${GIT[@]}" -C "$T/repo" rev-parse HEAD)
run --ref "$second" inventory s
rc_is 2 "a second commit into the same state is refused"
has "state is bound to" "I: the refusal names the binding" "$ERR"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
