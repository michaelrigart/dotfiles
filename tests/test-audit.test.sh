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
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC: ${ERR: -900})"; }
has(){ case "$3" in *"$1"*) _pass "$2";; *) _fail "$2 (got: $3)";; esac; }
lacks(){ case "$3" in *"$1"*) _fail "$2 (found: $1)";; *) _pass "$2";; esac; }
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
eq "$(jget via_detail)" '[]' "B1: an exact-label kill is not attributed through failure detail"
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
run try tests/s.test.sh "$FLAGCHK" 'bad "flag is set (want 1, got 2)"' s
eq "$(jget verdict)" killed "B4: a FAIL label with a (want, got) detail is a kill"
eq "$(jget killers)" '["flag is set"]' "B4: the killer is the baseline label it extends"
eq "$(jget via_detail)" '["flag is set"]' "B4: and it is listed in via_detail"
eq "$(jget unmatched)" '[]' "B4: nothing is unmatched"
run try tests/s.test.sh "$FLAGCHK" "bad \"y (z)\"; $FLAGCHK" s
eq "$(jget killers)" '[]' "B4: a detail on a label the baseline lacks is no killer"
eq "$(jget unmatched)" '["y (z)"]' "B4: it is unmatched"
sum=$(cksum <"$T/repo/bin/s.sh")
run try "$T/repo/bin/s.sh" "$ADD" "$SUB" s
rc_is 2 "B5: an absolute FILE is refused"
has "outside the copy" "B5: the refusal says why" "$ERR"
run try ../../repo/bin/s.sh "$ADD" "$SUB" s
rc_is 2 "B5: a ../ FILE is refused"
eq "$(cksum <"$T/repo/bin/s.sh")" "$sum" "B5: the checkout's file is byte-identical"
run try bin/s.sh "$ADD" "$SUB" ../../repo/tests/s
rc_is 2 "B5: a ../ suite is refused"
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
for sig in TERM HUP; do
  mk "F-$sig"
  # Not through aud(): a backgrounded function is a subshell, and the signal must reach the harness itself.
  "$AUDIT" --repo "$T/repo" --state "$T/state" --copy-root "$T/copies" --lock "$T/lock" --probe-dir "$T/ro" \
    --timeout-floor 60 try bin/s.sh 'FLAG=on' "$HANG" s >"$T/out" 2>"$T/err" &
  pid=$!
  for i in $(seq 1 100); do started && break; sleep 0.1; done
  kill -"$sig" "$pid"
  wait "$pid"; RC=$?
  [ "$RC" -ne 0 ] && _pass "F: the harness exits on SIG$sig (rc=$RC)" || _fail "F: the harness exits on SIG$sig (rc=0)"
  gone && _pass "F: the hanging suite is killed on SIG$sig" || _fail "F: the hanging suite survived SIG$sig"
  eq "$(ls "$T/copies" 2>/dev/null | wc -l | tr -d ' ')" 0 "F: its copy directory is gone after SIG$sig"
  lockf -t 0 "$T/lock" true; RC=$?
  rc_is 0 "F: the lock is free after SIG$sig"
  clean "F-$sig"
  run try bin/s.sh "$ADD" "$SUB" s
  eq "$(jget verdict)" killed "F: the next run after SIG$sig starts from a clean baseline"
done

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
lockf -k "$T/lock" sleep 4 &
for i in $(seq 1 50); do lockf -k -t 0 "$T/lock" true 2>/dev/null; [ $? -eq 75 ] && break; sleep 0.1; done
run try bin/s.sh "$ADD" "$SUB" red
eq "$(jget verdict)" baseline-red "G2: a lock wait before a red baseline still reports it"
awk -v s="$(jget seconds)" 'BEGIN{exit !(s < 2)}' && _pass "G2: the 4 s lock wait is not in the run's seconds" || _fail "G2: the run's seconds include the lock wait ($(jget seconds))"
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
eq "$(wc -l <"$rows" | tr -d ' ')" 6 "H: one row per fixture suite"
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

echo "J. hardening"
mk J
run --probe-dir "$T/nope" inventory s
rc_is 2 "J: a probe directory that cannot be probed is refused"
has "refusing: cannot probe $T/nope" "J: the refusal names the error" "$ERR"
eq "$(runs s)" 0 "J: nothing ran after it"
run try tests/s.test.sh "$FLAGCHK" "mkdir -p \"\$here/../rodir/sub\"; touch \"\$here/../rodir/sub/f\"; chmod 555 \"\$here/../rodir/sub\"; $FLAGCHK" s
eq "$(jget verdict)" survived "J: a suite that leaves a read-only tree still finishes"
eq "$(ls "$T/copies" 2>/dev/null | wc -l | tr -d ' ')" 0 "J: its copy is removed anyway"
case "$ERR" in *"copy left behind"*) _fail "J: no leftover warning when the retry works";; *) _pass "J: no leftover warning when the retry works";; esac
run try tests/s.test.sh "$FLAGCHK" "trap 'bad \"term reaches the suite\"' TERM; kill -TERM \$\$; sleep 0.3; $FLAGCHK" s
eq "$(jget unmatched)" '["term reaches the suite"]' "J: a suite starts with SIGTERM unblocked"
clean J
echo "K. ambiguous and failure-detail attributions (R8)"
mk K
AMBX='echo "  PASS: w"'
run try tests/amb.test.sh "$AMBX" 'echo "  FAIL: x (a) (b)"; echo "  PASS: w"' amb
eq "$(jget verdict)" inconclusive "K: a run whose only failure is ambiguous is inconclusive"
eq "$(jget ambiguous)" '["x (a) (b)"]' "K: the label is listed as ambiguous"
eq "$(jget killers)$(jget unmatched)" '[][]' "K: it is neither a killer nor unmatched"
run try tests/amb.test.sh "$AMBX" 'echo "  FAIL: x (a) (b)"; echo "  FAIL: w"' amb
eq "$(jget verdict)" killed "K: a real killer next to an ambiguous label keeps the kill"
eq "$(jget killers)" '["w"]' "K: the exact label is the killer"
eq "$(jget ambiguous)" '["x (a) (b)"]' "K: the ambiguous label is still listed"
eq "$(jget via_detail)" '[]' "K: an exact kill is not via_detail"
run try tests/amb.test.sh "$AMBX" 'echo "  FAIL: x (a) (b)"; echo "  FAIL: brand new"' amb
eq "$(jget verdict)" killed "K: an unmatched label next to an ambiguous one keeps the kill"
run try tests/amb.test.sh "$AMBX" 'echo "  FAIL: w (why)"' amb
eq "$(jget killers)" '["w"]' "K: a single prefix match is the killer"
eq "$(jget via_detail)" '["w"]' "K: and is listed in via_detail"
run try tests/amb.test.sh "$AMBX" 'echo "  FAIL: w"; echo "  FAIL: w (why)"' amb
eq "$(jget killers)" '["w"]' "K: two failed lines that map to one killer list it once"
eq "$(jget via_detail)" '[]' "K: an exact match beats the prefix rule for via_detail"
clean K

echo "M. code mutants, sample, targeted, reports"
mk M
ops_of(){ python3 -c 'import json,sys
print(",".join(sorted({json.loads(l)["op"] for l in sys.stdin if l.strip()})))'; }
run mutants bin/s.sh; rc_is 0 "M1: mutants bin/s.sh succeeds"; printf '%s\n' "$OUT" > "$T/m-s.jsonl"
run mutants bin/p.py; rc_is 0 "M1: mutants bin/p.py succeeds"; printf '%s\n' "$OUT" > "$T/m-p.jsonl"
eq "$(ops_of <"$T/m-s.jsonl")" andor,compare,delete,exit,negate "M1: bin/s.sh has every operator"
eq "$(ops_of <"$T/m-p.jsonl")" andor,compare,delete,exit,negate "M1: bin/p.py has every operator"
M1=$(python3 - "$SRC/.scripts/test-audit" "$T" <<'PY'
import json, subprocess, sys
sys.path.insert(0, sys.argv[1])
import mutators
t, res = sys.argv[2], {}
for name, lang, path in (("s", "bash", "bin/s.sh"), ("p", "py", "bin/p.py")):
    text = open(f"{t}/repo/{path}").read()
    ms = [json.loads(l) for l in open(f"{t}/m-{name}.jsonl") if l.strip()]
    ok = len(ms) > 0
    for m in ms:
        new = mutators.apply(text, m)
        if new is None:
            ok = False
        elif lang == "py":
            try:
                compile(new, path, "exec")
            except SyntaxError:
                ok = False
        else:
            ok = ok and subprocess.run(["bash", "-n"], input=new.encode(), capture_output=True).returncode == 0
    res[name + "_valid"] = ok
    res[name + "_inert"] = [m["context"] for m in ms if m["context"].lstrip().startswith("#") or m["context"] == "exit 0"]
print(json.dumps(res))
PY
)
mget(){ python3 -c 'import json,sys
v=json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v,str) else json.dumps(v))' "$M1" "$1"; }
eq "$(mget s_valid)" true "M1: every bin/s.sh mutant, applied, passes bash -n"
eq "$(mget p_valid)" true "M1: every bin/p.py mutant, applied, compiles"
eq "$(mget s_inert)" '[]' "M1: none sits on the comment line or inside the heredoc"
run mutants bin/loop.sh
eq "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys
print(json.dumps([json.loads(l)["context"] for l in sys.stdin if l.strip() and json.loads(l)["op"]=="negate"]))')" '["while [ \"$count\" -lt 3 ]; do"]' "M1: while and until over read get no negate mutant, another while still does"

run plan
rc_is 2 "M2: plan without an inventory exits 2"
has "run inventory first" "M2: and says so" "$ERR"
run inventory s s2
rc_is 0 "M2: inventory s s2 succeeds"
mkdir -p "$T/state2"; cp "$T/state/meta.json" "$T/state/inventory.jsonl" "$T/state2/"
run plan
rc_is 0 "M2: plan succeeds"
has "| bin/s.sh | s | 13 | 13 |" "M2: bin/s.sh has 13 valid mutants, all sampled" "$OUT"
has "| bin/p.py | s2 | 9 | 9 |" "M2: bin/p.py has 9 valid mutants, all sampled" "$OUT"
has "total: 22 mutants, ~" "M2: the output has a total line" "$OUT"
before=$(cksum <"$T/state/sample.jsonl")
run plan
eq "$(cksum <"$T/state/sample.jsonl")" "$before" "M2: a second plan keeps the frozen sample"
run --state "$T/state2" plan
cmp -s "$T/state/sample.jsonl" "$T/state2/sample.jsonl" && _pass "M2: the same seed in a fresh state writes an identical sample" || _fail "M2: the same seed in a fresh state writes an identical sample"
eq "$(python3 -c 'import json,sys
print(",".join(sorted({json.loads(l)["op"] for l in open(sys.argv[1]) if json.loads(l)["file"]=="bin/s.sh"})))' "$T/state/sample.jsonl")" andor,compare,delete,exit,negate "M2: every operator of bin/s.sh is in its sample"
head -1 "$T/state2/sample.jsonl" > "$T/one.jsonl" && cp "$T/one.jsonl" "$T/state2/sample.jsonl"
run --state "$T/state2" plan
eq "$(wc -l <"$T/state2/sample.jsonl" | tr -d ' ')" 1 "M2: plan never rewrites a frozen sample"

run sample
rc_is 0 "M4: sample succeeds"
has "[sample] bin/s.sh: 13/13 (killed 6, survived 7, inconclusive 0, baseline-red 0)" "M4: bin/s.sh progress line" "$OUT"
has "[sample] bin/p.py: 9/9 (killed 6, survived 3, inconclusive 0, baseline-red 0)" "M4: bin/p.py progress line" "$OUT"
has "remaining: 0" "M4: nothing remains" "$OUT"
M4=$(python3 - "$T/state" <<'PY'
import json, sys
st = sys.argv[1]
rows = [json.loads(l) for l in open(st + "/sample.jsonl")]
recs = [json.loads(l) for l in open(st + "/runs-sample.jsonl")]
print(json.dumps({"n": len(recs), "covered": sorted(r["id"] for r in recs) == sorted(r["id"] for r in rows),
                  "survivor_attempts": sorted({r["attempts"] for r in recs if r["verdict"] == "survived"}),
                  "killed_attempts": sorted({r["attempts"] for r in recs if r["verdict"] == "killed"})}))
PY
)
m4get(){ python3 -c 'import json,sys
v=json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v,str) else json.dumps(v))' "$M4" "$1"; }
eq "$(m4get n)" 22 "M4: one record per sampled mutant"
eq "$(m4get covered)" true "M4: every sampled mutant has a final record"
eq "$(m4get survivor_attempts)" '[2]' "M4: every survivor ran a second time"
eq "$(m4get killed_attempts)" '[1]' "M4: a first-run kill does not rerun"
lines=$(wc -l <"$T/state/runs-sample.jsonl" | tr -d ' ')
run sample
has "remaining: 0" "M4: a second sample has nothing remaining" "$OUT"
eq "$(wc -l <"$T/state/runs-sample.jsonl" | tr -d ' ')" "$lines" "M4: and adds no record"
lockf -k "$T/state/sample.lock" sleep 4 &
for i in $(seq 1 50); do lockf -k -t 0 "$T/state/sample.lock" true 2>/dev/null; [ $? -eq 75 ] && break; sleep 0.1; done
run sample
rc_is 2 "M4: a second sample on the same state is refused"
has "another sample run holds $T/state" "M4: the refusal names the state" "$ERR"
wait
run --state "$T/state0" sample --sample-from "$T/state" --max-minutes 0
has "remaining: 22" "M4: --max-minutes 0 reports everything as remaining" "$OUT"
[ ! -e "$T/state0/runs-sample.jsonl" ] && _pass "M4: and runs nothing" || _fail "M4: and runs nothing"

run report --section kills
has "| bin/s.sh | 13 | 6 | 0 | 7 | 0 | 0 | 0 | 0 | 46.2% |" "M5: the bin/s.sh row has the exact counts and rate" "$OUT"
has "| bin/p.py | 9 | 6 | 0 | 3 | 0 | 0 | 0 | 0 | 66.7% |" "M5: the bin/p.py row has the exact counts and rate" "$OUT"
has "| s | greet says hello | 3 |" "M5: greet's assertion killed three mutants" "$OUT"
has "| s | scratch dir exists at <tmp> | 0 | - |" "M5: an assertion that killed nothing is listed" "$OUT"
has "| s2 | p.py doubles #2 | 6 |" "M5: the repeated label kills as its own row" "$OUT"
run report --section gaps
uncov=$(grep -n 'echo never-called' "$T/repo/bin/s.sh" | cut -d: -f1)
has "| bin/s.sh:$uncov | delete | echo never-called → : |" "M5: the uncovered line's mutant is a gap" "$OUT"
has "| compare | -n → -z |" "M5: the uncovered comparison is a gap" "$OUT"
lacks "echo hello" "M5: a killed mutant is not a gap" "$OUT"

python3 - "$T/targeted.jsonl" "$T/bad.jsonl" <<'PY'
import json, sys
ADD = '$(( $1 + $2 ))'
def c(name, suite, labels, claim, dup, muts):
    return {"candidate": name, "suite": suite, "labels": labels, "claim": claim, "duplicate_of": dup,
            "safety": False, "mutants": muts}
def m(file, find, replace):
    return {"file": file, "find": find, "replace": replace}
rows = [
    c("s:11-11", "s", ["add returns the sum"], "duplicate", ["s2::add handles a one"], [m("bin/s.sh", ADD, '$(( $1 - $2 ))')]),
    c("s2:11-11", "s2", ["add handles a one"], "duplicate", ["s::add returns the sum"], [m("bin/s.sh", ADD, '$(( $1 + $2 + ($1 < 2) ))')]),
    c("s2:13-13", "s2", ["p.py doubles #2"], "duplicate", ["s2::p.py doubles"], [m("bin/p.py", "x * 2", "x * 3")]),
    c("s:15-15", "s", ["greet says hello"], "other", [], [m("bin/s.sh", "echo hello", "echo goodbye")]),
    c("s:14-14", "s", ["flag is set"], "other", [], [m("bin/s.sh", "echo hello", "echo hallo")]),
    c("solo", "s", ["add returns the sum"], "other", [], [m("bin/s.sh", ADD, '$(( $1 - $2 ))')]),
]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
open(sys.argv[2], "w").write(json.dumps(c("bad:ambig", "s", [], "other", [], [m("bin/s.sh", "echo", "echo x")])) + "\n")
PY
run targeted "$T/bad.jsonl"
rc_is 2 "M6: a find that occurs several times exits 2"
has "candidate bad:ambig" "M6: naming its candidate" "$ERR"
run targeted "$T/targeted.jsonl"
rc_is 0 "M6: targeted succeeds"
has "remaining: 0" "M6: nothing remains" "$OUT"
tl=$(wc -l <"$T/state/runs-targeted.jsonl" | tr -d ' ')
run targeted "$T/targeted.jsonl"
eq "$(wc -l <"$T/state/runs-targeted.jsonl" | tr -d ' ')" "$tl" "M6: a second targeted run repeats nothing"
run report --section targeted
row(){ printf '%s\n' "$OUT" | grep -F "$1"; }
has "| evidenced |" "M6: a candidate with another killer in its suite is evidenced" "$(row '| s2:13-13 |')"
has "| unique |" "M6: a candidate that alone kills its mutant is unique" "$(row '| s:15-15 |')"
has "| mis-targeted |" "M6: a candidate that does not kill its mutant is mis-targeted" "$(row '| s:14-14 |')"
has "| evidenced |" "M6: a cross-suite duplicate is evidenced by the other suite" "$(row '| s:11-11 |')"
has "s2::add handles a one" "M6: and the second killer is s2's" "$(row '| s:11-11 |')"
has "| unique |" "M6: the same mutant without the duplicate claim is unique" "$(row '| solo |')"
lacks "s2::" "M6: s2 runs only because of the duplicate claim" "$(row '| solo |')"
has "* attributed through failure detail (R8)" "M6: the report carries the R8 footnote" "$OUT"

first=$("${GIT[@]}" -C "$T/repo" rev-parse HEAD)
# The second commit does three things: inserts a line under the shebang of s.sh, deletes the
# covered `return 0` line of flag(), and drops the greet check from s.test.sh (so the mutants
# only that check killed are lost).
python3 - "$T/repo" <<'PY'
import sys
r = sys.argv[1]
p = r + "/bin/s.sh"
lines = open(p).read().split("\n")
lines.insert(1, "# touched")
open(p, "w").write("\n".join(l for l in lines if l != "  return 0"))
p = r + "/tests/s.test.sh"
kept = [l for l in open(p).read().split("\n") if not l.startswith('check "greet says hello"')]
open(p, "w").write("\n".join(kept))
PY
"${GIT[@]}" -C "$T/repo" commit -q -am "second"
second=$("${GIT[@]}" -C "$T/repo" rev-parse HEAD)
run --ref "$second" mutants bin/s.sh
printf '%s\n' "$OUT" > "$T/m2-s.jsonl"
M3=$(python3 - "$T/m-s.jsonl" "$T/m2-s.jsonl" <<'PY'
import json, sys
a = {m["id"]: m for m in map(json.loads, filter(str.strip, open(sys.argv[1])))}
b = {m["id"]: m for m in map(json.loads, filter(str.strip, open(sys.argv[2])))}
print(json.dumps({"gone": sorted(a[i]["op"] + ":" + a[i]["before"] for i in set(a) - set(b)),
                  "new": sorted(set(b) - set(a)), "kept": len(set(a) & set(b))}))
PY
)
m3get(){ python3 -c 'import json,sys
v=json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v,str) else json.dumps(v))' "$M3" "$1"; }
eq "$(m3get gone)" '["delete:return 0", "exit:return 0"]' "M3: only the mutants on the deleted line are gone"
eq "$(m3get new)" '[]' "M3: the line inserted at the top adds no mutant and renames none"
eq "$(m3get kept)" 11 "M3: every mutant on an unchanged line keeps its id"
run --state "$T/state3" --ref "$second" sample --sample-from "$T/state" --only bin/s.sh
rc_is 0 "M3: sample from the first state on the second commit succeeds"
has "[sample] bin/s.sh: 13/13 (killed 3, survived 8, inconclusive 0, baseline-red 0)" "M3: the progress line" "$OUT"
eq "$(python3 -c 'import json,sys
print(sorted(r["before"] for r in map(json.loads, open(sys.argv[1])) if r["verdict"]=="stale"))' "$T/state3/runs-sample.jsonl")" "['return 0', 'return 0']" "M3: the deleted line's mutants are stale, not survived"

run --state "$T/state3" report --section kills --compare "$T/state" --kind code
lostids=$(python3 - "$T/state" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1] + "/runs-sample.jsonl")]
print(" ".join(r["id"] for r in recs if r["verdict"] == "killed" and r["file"] == "bin/s.sh" and r["killers"] == ["s::greet says hello"]))
PY
)
has "lost: 3" "M7: the three mutants only the removed check killed are lost" "$OUT"
for id in $lostids; do has "- $id bin/s.sh" "M7: $id is listed as lost" "$OUT"; done
has "not run: 0" "M7: nothing the first state killed is unrun on the selected files" "$OUT"
lacks "bin/p.py" "M7: bin/p.py, never rerun here, is not listed" "$OUT"
tids=$(python3 -c 'import json,sys
print(" ".join(json.loads(l)["id"] for l in open(sys.argv[1])))' "$T/state/runs-targeted.jsonl")
for id in $tids; do lacks "$id" "M7: targeted mutant $id is not in a code comparison" "$OUT"; done
run --state "$T/state3" report --section kills --compare "$T/state" --kind code --only bin/s.sh bin/p.py
has "not run: 6" "M7: --only adds bin/p.py, whose six kills were not run" "$OUT"
eq "$(printf '%s\n' "$OUT" | grep -c 'bin/p.py')" 6 "M7: all six are listed"
run --state "$T/state3" report --section kills --compare "$T/state" --kind targeted
has "lost: 0" "M7: a targeted comparison selects no files here" "$OUT"
run --state "$T/state3" report --section kills --compare "$T/state"
rc_is 2 "M7: --compare without --kind exits 2"

# M8: the targeted records of the M6 run, with a hand-written inventory that fixes the ranking.
mkdir -p "$T/state8"; cp "$T/state/meta.json" "$T/state/runs-targeted.jsonl" "$T/state8/"
python3 - "$T/state8/inventory.jsonl" <<'PY'
import json, sys
rows = [{"suite": "s", "seconds": 100, "assertions": 4,
         "labels": ["add returns the sum", "flag is set", "greet says hello", "scratch dir exists at <tmp>"]},
        {"suite": "s2", "seconds": 80, "assertions": 4,
         "labels": ["add handles a one", "p.py doubles", "p.py doubles #2", "add handles zero"]}]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
TAB=$(printf '\t')
{
  echo "suite${TAB}test${TAB}labels${TAB}kind${TAB}duplicate_of${TAB}verdict${TAB}merge_with${TAB}evidence${TAB}safety${TAB}note"
  echo "s${TAB}11-11${TAB}add returns the sum${TAB}duplicate${TAB}s2:11-11${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}A"
  echo "s${TAB}14-14${TAB}flag is set${TAB}wording${TAB}-${TAB}delete${TAB}-${TAB}class${TAB}yes${TAB}class evidence on a safety rule"
  echo "s${TAB}15-15${TAB}greet says hello${TAB}duplicate${TAB}-${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}unique, not evidenced"
  echo "s${TAB}16-17${TAB}scratch dir exists at <tmp>${TAB}behaviour${TAB}-${TAB}keep${TAB}-${TAB}class${TAB}no${TAB}kept"
  echo "s2${TAB}11-11${TAB}add handles a one${TAB}duplicate${TAB}s:11-11${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}B"
  echo "s2${TAB}12-12${TAB}p.py doubles${TAB}wording${TAB}-${TAB}delete${TAB}-${TAB}class${TAB}no${TAB}W"
  echo "s2${TAB}13-13${TAB}p.py doubles #2${TAB}duplicate${TAB}s2:12-12${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}D"
  echo "s2${TAB}14-14${TAB}add handles zero${TAB}duplicate${TAB}s:11-11${TAB}delete${TAB}-${TAB}class${TAB}no${TAB}a duplicate with class evidence"
} > "$T/classification.tsv"
mid(){ python3 -c 'import json,sys
print(next(r["id"] for r in map(json.loads, open(sys.argv[1])) if r["candidate"]==sys.argv[2]))' "$T/state8/runs-targeted.jsonl" "$1"; }
run --state "$T/state8" accept "$T/classification.tsv" "$T/targeted.jsonl"
rc_is 0 "M8: accept succeeds"
printf '%s\n' "$OUT" | grep '^| s' | sed 's/ | [0-9.]* | / | /' > "$T/accept.out"
want=$(cat <<EOF
| s:11-11 | accepted |
| s:14-14 | rejected: class evidence in a safety suite |
| s:15-15 | rejected: not evidenced |
| s2:11-11 | rejected: would leave $(mid s:11-11) without a killer |
| s2:12-12 | accepted |
| s2:13-13 | rejected: would leave $(mid s2:13-13) without a killer |
| s2:14-14 | rejected: duplicate needs targeted evidence |
EOF
)
eq "$(cat "$T/accept.out")" "$want" "M8: A is accepted, B rejected over A's mutant, W accepted, D rejected over its own"
clean M

echo "N. survivor rerun, R8 in the reports and in acceptance"
mk N
mkdir -p "$T/crafted"
python3 - "$T/crafted/sample.jsonl" <<'PY'
import json, sys
row = {"id": "flaky0000001", "kind": "code", "file": "bin/s.sh", "op": "delete", "line": 7,
       "context": "  FLAG=on", "occurrence": 0, "col": 2, "before": "FLAG=on",
       "after": 'FLAG=on; [ "$(wc -l < "$AUDIT_MARKERS/s.ran")" -ge 3 ] && FLAG=off',
       "suite": "s", "valid": 1}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
run sample --sample-from "$T/crafted"
rc_is 0 "N: a hand-written sample runs"
has "[sample] bin/s.sh: 1/1 (killed 1, survived 0, inconclusive 0, baseline-red 0)" "N: a mutant only its second run kills is a kill" "$OUT"
eq "$(python3 -c 'import json,sys
r=json.loads(open(sys.argv[1]).read().strip()); print(r["verdict"], r["flaky"], r["attempts"])' "$T/state/runs-sample.jsonl")" "killed True 2" "N: it is recorded killed, flaky, after two attempts"
run report --section kills
has "| bin/s.sh | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 100.0% |" "N: the kills report counts it under flaky as well" "$OUT"
clean N

mk O
mkdir -p "$T/crafted"
python3 - "$T/crafted/sample.jsonl" <<'PY'
import json, sys
row = {"id": "redmut000001", "kind": "code", "file": "bin/s.sh", "op": "delete", "line": 7,
       "context": "  FLAG=on", "occurrence": 0, "col": 2, "before": "FLAG=on", "after": ":",
       "suite": "red", "valid": 1}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
run sample --sample-from "$T/crafted"
has "[sample] bin/s.sh: 0/1 (killed 0, survived 0, inconclusive 0, baseline-red 1)" "O: a mutant of a red suite is neither killed nor survived" "$OUT"
eq "$(runs red)" 1 "O: only the red baseline ran"
run report --section kills
has "| bin/s.sh | 1 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | - |" "O: it is counted as baseline-red, with no kill rate" "$OUT"
clean O

mk P
mkdir -p "$T/crafted"
python3 - "$T/crafted/sample.jsonl" <<'PY'
import json, sys
row = {"id": "retry0000001", "kind": "code", "file": "bin/s.sh", "op": "delete", "line": 7,
       "context": "  FLAG=on", "occurrence": 0, "col": 2, "before": "FLAG=on", "after": ":",
       "suite": "s", "valid": 1}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PY
: > "$T/markers/red-now"
run sample --sample-from "$T/crafted"
has "remaining: 1" "P: a mutant of a red suite stays remaining after the session" "$OUT"
rm "$T/markers/red-now"
run sample --sample-from "$T/crafted"
has "[sample] bin/s.sh: 1/1 (killed 1, survived 0, inconclusive 0, baseline-red 0)" "P: the next session runs it once the suite is green" "$OUT"
has "remaining: 0" "P: and nothing remains" "$OUT"
eq "$(python3 -c 'import json,sys
print([r["verdict"] for r in map(json.loads, open(sys.argv[1]))])' "$T/state/runs-sample.jsonl")" "['baseline-red', 'killed']" "P: the red record is kept and the later record wins"
run report --section kills
has "| bin/s.sh | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 100.0% |" "P: baseline-red counts only while no other record exists" "$OUT"
clean P

mkdir -p "$T/stateR"
python3 - "$T/stateR" "$T/repo" "$SRC/.scripts/test-audit" "$T/r-manifest.jsonl" <<'PY'
import json, sys
st, repo, mod, manifest = sys.argv[1:5]
sys.path.insert(0, mod)
import mutators
text = open(repo + "/bin/s.sh").read()
def rec(kind, cand, labels, killers, via, amb, find, replace):
    m = mutators.targeted_mutant("bin/s.sh", text, find, replace)[0]
    r = {"id": m["id"], "kind": kind, "file": "bin/s.sh", "op": m["op"], "line": m["line"], "before": m["before"],
         "after": m["after"], "suite": "s", "verdict": "killed", "killers": killers, "unmatched": [],
         "ambiguous": amb, "via_detail": via, "suites": {"s": "killed"}, "flaky": False, "attempts": 1, "seconds": 0.1}
    if cand:
        r.update(candidate=cand, claim="other", labels=labels)
    return r
t = [rec("targeted", "s:1-1", ["s::t1"], ["s::t1"], [], ["s::t2"], "echo hello", "echo a"),
     rec("targeted", "s:2-2", ["s::t3"], ["s::t3", "s::t4"], ["s::t4"], [], "echo hello", "echo b")]
open(st + "/runs-targeted.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in t))
c = [rec("code", None, [], ["s::t1"], ["s::t1"], [], "echo hello", "echo c"),
     rec("code", None, [], ["s::t1"], [], [], "echo hello", "echo d")]
open(st + "/runs-sample.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in c))
entries = [{"candidate": "s:1-1", "suite": "s", "labels": ["t1"], "claim": "other", "mutants": [{"file": "bin/s.sh", "find": "echo hello", "replace": "echo a"}]},
           {"candidate": "s:2-2", "suite": "s", "labels": ["t3"], "claim": "other", "mutants": [{"file": "bin/s.sh", "find": "echo hello", "replace": "echo b"}]}]
open(manifest, "w").write("".join(json.dumps(e) + "\n" for e in entries))
open(st + "/inventory.jsonl", "w").write(json.dumps({"suite": "s", "seconds": None, "assertions": None, "labels": ["t1", "t3"]}) + "\n")
PY
run --state "$T/stateR" report --section targeted
has "| s::t3; s::t4* |" "N: a killer attributed through failure detail is starred" "$OUT"
lacks "s::t1*" "N: an exact killer is not starred" "$OUT"
has "* attributed through failure detail (R8)" "N: the footnote is printed" "$OUT"
run --state "$T/stateR" report --section kills
has "| bin/s.sh | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 1 | 100.0% |" "N: the kills report counts kills that have a via_detail killer" "$OUT"
{
  echo "suite${TAB}test${TAB}labels${TAB}kind${TAB}duplicate_of${TAB}verdict${TAB}merge_with${TAB}evidence${TAB}safety${TAB}note"
  echo "s${TAB}1-1${TAB}t1${TAB}duplicate${TAB}-${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}other killer is ambiguous"
  echo "s${TAB}2-2${TAB}t3${TAB}duplicate${TAB}-${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}other killer is via detail"
} > "$T/r-class.tsv"
run --state "$T/stateR" accept "$T/r-class.tsv" "$T/r-manifest.jsonl"
has "| s:1-1 | 0.0 | rejected: not evidenced |" "N: an ambiguous label never counts as another killer" "$OUT"
has "| s:2-2 | 0.0 | accepted |" "N: a killer attributed through failure detail counts" "$OUT"
echo "Q. fix round 1: compare, loaders, accept inputs, plan inventory, targeted pre-flight, dirty copy"
mk Q
TAB=$(printf '\t')
mkrec(){ python3 - "$@" <<'PY'
import json, sys
st, name, rid, file, verdict = sys.argv[1:6]
r = {"id": rid, "kind": "code", "file": file, "op": "delete", "line": 3, "before": "b", "after": ":", "suite": "s",
     "verdict": verdict, "killers": ["s::x"] if verdict == "killed" else [], "unmatched": [], "ambiguous": [],
     "via_detail": [], "suites": {"s": verdict}, "flaky": False, "attempts": 1, "seconds": 0.1}
import os
os.makedirs(st, exist_ok=True)
open(st + "/runs-sample.jsonl", "a").write(json.dumps(r) + "\n")
PY
}
mkrec "$T/cmpA" a xxxxxxxxxxx1 f.sh killed
mkrec "$T/cmpB" b xxxxxxxxxxx1 f.sh baseline-red
mkrec "$T/cmpB" b yyyyyyyyyyy1 g.sh survived
run --state "$T/cmpB" report --section kills --compare "$T/cmpA" --kind code --only f.sh
has "lost: 0" "Q1: a baseline-red record is not a lost kill" "$OUT"
has "not run: 1" "Q1: it counts as not run" "$OUT"
run --state "$T/cmpB" report --section kills --compare "$T/cmpA" --kind code
has "not run: 0" "Q1: a baseline-red record does not add its file to the selection" "$OUT"

# Q2: a duplicate claim whose loader suite (s) is red in the first session
python3 - "$T/dup.jsonl" <<'PY'
import json, sys
e = {"candidate": "s2:11-11", "suite": "s2", "labels": ["add handles a one"], "claim": "duplicate",
     "duplicate_of": ["s::add returns the sum"], "safety": False,
     "mutants": [{"file": "bin/s.sh", "find": "$(( $1 + $2 ))", "replace": "$(( $1 - $2 ))"}]}
open(sys.argv[1], "w").write(json.dumps(e) + "\n")
PY
: > "$T/markers/red-now"
run targeted "$T/dup.jsonl"
has "remaining: 1" "Q2: a record with a red loader suite is not final" "$OUT"
run report --section targeted
has "| s2:11-11 | inconclusive |" "Q2: its own-label kill is not enough while a loader suite had no verdict" "$OUT"
rm "$T/markers/red-now"
run targeted "$T/dup.jsonl"
has "remaining: 0" "Q2: the next run retries it" "$OUT"
run report --section targeted
has "| s2:11-11 | evidenced |" "Q2: and the loader suite's kill then makes it evidenced" "$OUT"
eq "$(wc -l <"$T/state/runs-targeted.jsonl" | tr -d ' ')" 2 "Q2: both records are kept"

# Q3 and Q6: accept refuses bad classification input
mkdir -p "$T/stateA"; cp "$T/state8/inventory.jsonl" "$T/stateA/inventory.jsonl" 2>/dev/null
python3 - "$T/stateA/inventory.jsonl" <<'PY'
import json, sys
rows = [{"suite": "s", "seconds": 100, "assertions": 4, "labels": ["add returns the sum", "t2"]},
        {"suite": "s2", "seconds": 80, "assertions": 4, "labels": ["add handles a one"]}]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
: > "$T/empty.jsonl"
HDR="suite${TAB}test${TAB}labels${TAB}kind${TAB}duplicate_of${TAB}verdict${TAB}merge_with${TAB}evidence${TAB}safety${TAB}note"
{ echo "$HDR"; echo "s${TAB}1-1${TAB}t 2${TAB}wording${TAB}-${TAB}delete${TAB}-${TAB}class${TAB}no${TAB}x"; } > "$T/c1.tsv"
run --state "$T/stateA" accept "$T/c1.tsv" "$T/empty.jsonl"
rc_is 2 "Q3: a label the suite does not have exits 2"
has "row s:1-1" "Q3: naming the row" "$ERR"
has "'t 2'" "Q3: and the label" "$ERR"
{ echo "$HDR"; echo "s${TAB}1-1${TAB}t2${TAB}duplicate${TAB}s2::no such${TAB}delete${TAB}-${TAB}targeted${TAB}no${TAB}x"; } > "$T/c2.tsv"
run --state "$T/stateA" accept "$T/c2.tsv" "$T/empty.jsonl"
rc_is 2 "Q3: a duplicate_of label the suite does not have exits 2"
has "'no such'" "Q3: naming it" "$ERR"
{ echo "$HDR"; echo "s${TAB}1-1${TAB}t2${TAB}wording${TAB}-${TAB}delete${TAB}-${TAB}maybe${TAB}no${TAB}x"; } > "$T/c3.tsv"
run --state "$T/stateA" accept "$T/c3.tsv" "$T/empty.jsonl"
rc_is 2 "Q6: an evidence value other than class or targeted exits 2"
has "row s:1-1" "Q6: naming the row" "$ERR"

# Q4: plan and the inventory
mk QP
run inventory s
run plan
rc_is 2 "Q4: a partial inventory is refused"
has "inventory incomplete: s2" "Q4: naming the missing suite" "$ERR"
[ ! -e "$T/state/sample.jsonl" ] && _pass "Q4: and nothing is frozen" || _fail "Q4: and nothing is frozen"
printf 'bin/s.sh\tbash\ts\ts,s2\nbin/loop.sh\tbash\tgated\tgated\nbin/p.py\tpy\tred\tred\n' > "$T/subj.tsv"
run inventory gated red
run --subjects "$T/subj.tsv" plan
rc_is 0 "Q4: a complete inventory plans"
has "| bin/loop.sh | gated | - | 0 |" "Q4: a gated suite keeps its dash row" "$OUT"
has "copy-red: bin/p.py" "Q4: a red suite's file is listed as copy-red" "$OUT"
has "total: 13 mutants" "Q4: only the green suite's file is sampled" "$OUT"
eq "$(grep -c 'bin/p.py' "$T/state/sample.jsonl")" 0 "Q4: the copy-red file has no sample rows"

# Q7: targeted checks every candidate before the first run
mk QT
python3 - "$T" <<'PY'
import json, sys
t = sys.argv[1]
def c(name, suite):
    return json.dumps({"candidate": name, "suite": suite, "labels": [], "claim": "other",
                       "mutants": [{"file": "bin/s.sh", "find": "echo hello", "replace": "echo hallo"}]}) + "\n"
open(t + "/t-gated.jsonl", "w").write(c("good", "s") + c("bad:gated", "gated"))
open(t + "/t-none.jsonl", "w").write(c("good", "s") + c("bad:none", "nosuch"))
open(t + "/t-red.jsonl", "w").write(c("good", "s") + c("bad:red", "red"))
PY
run targeted "$T/t-gated.jsonl"
rc_is 2 "Q7: a gated own suite exits 2 before the first run"
has "candidate bad:gated" "Q7: naming its candidate" "$ERR"
eq "$(runs s)" 0 "Q7: the earlier good candidate did not run"
run targeted "$T/t-none.jsonl"
rc_is 2 "Q7: a missing own suite exits 2"
has "candidate bad:none" "Q7: naming its candidate" "$ERR"
run inventory red
run targeted "$T/t-red.jsonl"
rc_is 2 "Q7: a copy-red own suite exits 2"
has "candidate bad:red" "Q7: naming its candidate" "$ERR"
eq "$(runs s)" 0 "Q7: nothing ran"

# Q8: a mutant whose run writes into the copy
mk Q8
mkdir -p "$T/crafted"
python3 - "$T/crafted/sample.jsonl" <<'PY'
import json, sys
def row(i, after):
    return {"id": i, "kind": "code", "file": "bin/s.sh", "op": "delete", "line": 7, "context": "  FLAG=on",
            "occurrence": 0, "col": 2, "before": "FLAG=on", "after": after, "suite": "s", "valid": 2}
rows = [row("dirty000001", 'FLAG=on; touch "$here/../stray"'),
        row("dirty000002", 'FLAG=on; [ -e "$here/../stray" ] && FLAG=off')]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
run sample --sample-from "$T/crafted"
has "copy rebuilt after dirty000001" "Q8: a copy a mutant wrote into is rebuilt" "$OUT"
lacks "copy rebuilt after dirty000002" "Q8: a clean copy is kept" "$OUT"
eq "$(python3 -c 'import json,sys
print([r["verdict"] for r in map(json.loads, open(sys.argv[1]))])' "$T/state/runs-sample.jsonl")" "['survived', 'survived']" "Q8: the next mutant runs in a clean copy and its baseline still holds"
clean Q8
U=$(python3 - "$AUDIT" "$ROOT/unit" "$FIX" <<'PY'
import contextlib, importlib.util, io, json, os, subprocess, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("audit", sys.argv[1])
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
root = Path(sys.argv[2]); root.mkdir()
out = {}
R = lambda passed, failed, rc=1: a.Run(rc, 0.1, False, passed, failed, "")
out["longest"] = list(a.attribute(R(["x", "x (a)", "w"], [], 0), R(["w", "q"], ["x (a) (b)"]))[1:])
out["unique_prefix"] = list(a.attribute(R(["x", "w"], [], 0), R(["w"], ["x (a) (b)"]))[1:])
st = a.Store(root / "state"); st.state.mkdir()
(st.state / "runs-k.jsonl").write_text('{"a": 1}\n{"a": 2')
out["torn"] = st.records("k")
(st.state / "runs-m.jsonl").write_text('{"a": \n{"a": 2}\n')
try:
    st.records("m"); out["middle"] = "parsed"
except ValueError:
    out["middle"] = "raised"
src = root / "src"; src.mkdir()
def vcs(*x, cwd=src):
    return subprocess.run(["git", "-c", "user.name=u", "-c", "user.email=u@l", "-c", "commit.gpgsign=false", *x],
                          cwd=cwd, check=True, capture_output=True)
vcs("init", "-q"); (src / "f").write_text("x"); vcs("add", "-A"); vcs("commit", "-q", "-m", "m")
sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=src, capture_output=True, text=True).stdout.strip()
tpl = root / "tpl"; (tpl / "hooks").mkdir(parents=True)
(tpl / "TEMPLATE_MARKER").write_text("t")
hook = tpl / "hooks" / "pre-commit"; hook.write_text("#!/bin/sh\nexit 1\n"); hook.chmod(0o755)
cfg = root / "gitconfig"
cfg.write_text("[init]\n\tdefaultBranch = trunk\n\ttemplateDir = %s\n[core]\n\thooksPath = %s\n" % (tpl, tpl / "hooks"))
os.environ["GIT_CONFIG_GLOBAL"] = str(cfg)
try:
    copy = a.build_copy(src, sha, root / "copies", "unit")
    out["copy"] = "built"
    out["template"] = "leaked" if (copy / ".git" / "TEMPLATE_MARKER").exists() else "clean"
    out["branch"] = subprocess.run(["git", "-C", str(copy), "symbolic-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
except Exception as e:
    out["copy"] = "failed: %s" % e
a.SESSION.cleanup()
d = root / "stuck"; d.mkdir()
a.SESSION.copies.append(d)
a.shutil.rmtree = lambda *x, **k: None
err = io.StringIO()
with contextlib.redirect_stderr(err):
    a.SESSION.cleanup()
out["left"] = err.getvalue().strip()
(st.state / "runs-t.jsonl").write_text('{"a": 1}\n{"a":')
st.append("t", {"b": 2}); out["append_torn"] = st.records("t")
(st.state / "runs-v.jsonl").write_text('{"a": 1}')
st.append("v", {"b": 2}); out["append_whole"] = st.records("v")
out["longest_verdict"] = a.attribute(R(["x", "x (a)", "w"], [], 0), R(["w", "q"], ["x (a) (b)"]))[0]
mu = a.mutators
snip = "\n".join(['x=1', 'if [ "$a" = b ] && echo "a && b"; then # note && here', '  exit 0', 'fi',
                  'echo "exit 0"', 'while (( n < 3 )); do n=$((n + 1)); done'])
ms = mu.code_mutants("f.sh", snip, "bash")
out["snip"] = sorted("%d:%s:%s>%s" % (m["line"], m["op"], m["before"], m["after"]) for m in ms if m["op"] in ("andor", "exit", "compare"))
out["readloop"] = [m["line"] for m in mu.code_mutants("l.sh", "while read a; do :; done </dev/null\nuntil IFS= read -r b; do :; done </dev/null\nwhile [ -z \"$z\" ]; do :; done\n", "bash") if m["op"] == "negate"]
def vrec(suites, killers):
    return {"suites": suites, "killers": killers}
out["verdicts"] = [
    a.candidate_verdict("s", ["s::a"], [vrec({"s": "killed", "s2": "inconclusive"}, ["s::a"])]),
    a.candidate_verdict("s", ["s::a"], [vrec({"s": "killed", "s2": "baseline-red"}, ["s::a"])]),
    a.candidate_verdict("s", ["s::a"], [vrec({"s": "killed", "s2": "inconclusive"}, ["s::a", "s2::b"])]),
    a.candidate_verdict("s", ["s::a"], [vrec({"s": "killed", "s2": "killed"}, ["s::a"])]),
]
out["final"] = [a.is_final({"k": {"verdict": "killed", "suites": {"s": "killed", "s2": "baseline-red"}}}, "k"),
                a.is_final({"k": {"verdict": "killed", "suites": {"s": "killed"}}}, "k")]
out["multiline"] = [m["line"] for m in mu.code_mutants("m.sh", "x='a\nexit 0\nb'\ny=1\n", "bash")]
two = mu.code_mutants("d.sh", "echo a\necho a\n", "bash")
out["occurrence"] = [mu.apply("echo a\necho a\n", m) for m in two]
first = ms[0]
out["stale"] = [mu.apply(snip, first) is None, mu.apply(snip.replace(first["context"], first["context"] + " # edit"), first) is None]
text = open(sys.argv[3] + "/bin/s.sh").read()
sm = mu.code_mutants("bin/s.sh", text, "bash")
p1, p2 = a.pick("bin/s.sh", sm, 6, 20261111), a.pick("bin/s.sh", sm, 6, 20261111)
out["pick"] = [[m["id"] for m in p1] == [m["id"] for m in p2], len(p1), sorted({m["op"] for m in a.pick("bin/s.sh", sm, 5, 1)})]
out["sizes"] = [a.sample_size("xreview", 700, 100), a.sample_size("x", 300, 100), a.sample_size("x", 1, 10),
                a.sample_size("x", 100, 100), a.sample_size("x", 100, 5)]
tx = "a b\nb a\n"
_, n_all = mu.targeted_mutant("f", tx, "a", "x")
one, n_one = mu.targeted_mutant("f", tx, "a", "x", 1)
_, n_none = mu.targeted_mutant("f", tx, "a", "x", 3)
out["targeted"] = [n_all, n_one, mu.apply(tx, one), n_none]
print(json.dumps(out))
PY
)
uget(){ python3 -c 'import json,sys
v=json.loads(sys.argv[1])[sys.argv[2]]
print(v if isinstance(v,str) else json.dumps(v))' "$U" "$1"; }
eq "$(uget longest)" '[[], [], ["x (a) (b)"], []]' "J: a failed label two baseline labels extend is ambiguous, with no killer"
eq "$(uget unique_prefix)" '[["x"], [], [], ["x"]]' "J: a failed label one baseline label extends is that label's kill, via detail"
eq "$(uget torn)" '[{"a": 1}]' "J: a torn last line of a run file is skipped"
eq "$(uget middle)" raised "J: a bad line that is not the last still raises"
eq "$(uget copy)" built "J: the copy builds despite a global hook and template"
eq "$(uget template)" clean "J: the user's init template never reaches the copy"
eq "$(uget branch)" refs/heads/main "J: the copy's branch is main, not the user's default"
eq "$(uget left)" "copy left behind: $ROOT/unit/stuck" "J: an unremovable copy is reported"
eq "$(uget append_torn)" '[{"a": 1}, {"b": 2}]' "J: an append after a torn last line does not fuse with it"
eq "$(uget append_whole)" '[{"a": 1}, {"b": 2}]' "J: an append after a last line missing only its newline keeps both"
eq "$(uget longest_verdict)" inconclusive "J: an ambiguous-only failure gives an inconclusive verdict"
eq "$(uget snip)" '["2:andor:&&>||", "2:compare:=>!=", "3:exit:exit 0>exit 1", "6:compare:<>>="]' "J: operators skip quotes, comments and arithmetic expansions"
eq "$(uget readloop)" '[3]' "J: bare and env-prefixed read loops get no negate mutant"
eq "$(uget verdicts)" '["inconclusive", "inconclusive", "evidenced", "unique"]' "J: an undecided loader suite leaves a candidate inconclusive unless another killer already decided it"
eq "$(uget final)" '[false, true]' "J: a record with a baseline-red suite is not final"
eq "$(uget multiline)" '[4]' "J: a line inside a multi-line string gets no mutant"
eq "$(uget occurrence)" '[":\necho a\n", "echo a\n:\n"]' "J: identical lines are told apart by occurrence"
eq "$(uget stale)" '[false, true]' "J: apply returns None once the context line changed"
eq "$(uget pick)" '[true, 6, ["andor", "compare", "delete", "exit", "negate"]]' "J: a sample is reproducible and covers every operator first"
eq "$(uget sizes)" '[3, 4, 10, 9, 5]' "J: sample sizes follow the clamp, the heavy table and the valid cap"
eq "$(uget targeted)" '[2, 1, "x b\nb a\n", 0]' "J: a find is unique in the file or on the given line"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
