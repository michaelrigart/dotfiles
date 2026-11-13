#!/usr/bin/env bash
# Tests for tests/run.sh: the requirement gate (a suite tagged `# test-requires:` runs only
# when named exactly or with --all; a substring filter must still skip it), the parallel
# run, the serial tag, the per-machine lock and its holder record, and --changed (which heavy
# suites run for a changed subject, and every way it falls back to running them all).
#
# Runs a COPY of run.sh in a temp directory holding fake suites, and in throwaway git
# repositories for --changed, so nothing here executes a real suite (and nothing recurses into
# this one). The final sections read the real repository: the subject map must cover what the
# heavy suites name (drift_check), every heavy tag must parse as `heavy`, and the runner must
# read the real map as well-formed.
#
#   ./tests/run.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$SRC/tests/run.sh"
[ -f "$RUN" ] || { echo "missing script under test: $RUN" >&2; exit 2; }
SUBJECTS="$SRC/.scripts/test-audit/subjects.tsv"
[ -f "$SUBJECTS" ] || { echo "missing subject map the drift checks read: $SUBJECTS" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/runsh.XXXXXX")"
trap 'rm -rf "$T"' EXIT
# Fixture runners lock on their own file, never the machine's; MARK is where fixtures
# report what they saw of each other.
export RUN_SH_LOCK="$T/lock" MARK="$T/mark"
# A bound or poll interval set for this suite must not reach the fixture runners.
unset RUN_SH_LOCK_WAIT RUN_SH_LOCK_POLL
L="$RUN_SH_LOCK"
mkdir -p "$MARK"
cp "$RUN" "$T/run.sh"
# The tag is assembled at runtime: run.sh greps every suite FILE for a line starting with
# the tag, so a literal one anywhere in this file would make it skip this suite too.
tag="# test-requires"
printf '#!/usr/bin/env bash\n%s: a condition run.sh cannot create\necho "  ok  gated suite ran"\n' "$tag" \
  > "$T/gated-alpha.test.sh"
cat > "$T/plain-alpha.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  ok  plain suite ran"
SUITE
cat > "$T/broken-alpha.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  ok  first"
echo "  FAIL: x"
echo "    | got: detail"
echo "  ok  after"
exit 1
SUITE
cat > "$T/startdir.test.sh" <<'SUITE'
#!/usr/bin/env bash
if [ "${RUN_SH_START_DIR:-unset}" = "$WANT_START" ]; then echo "  ok  start dir"; else echo "  FAIL: start dir ${RUN_SH_START_DIR:-unset}"; exit 1; fi
SUITE
cat > "$T/kvskip.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "second=SKIPPED"
echo "third=WRITABLE"
SUITE
cat > "$T/kvfail.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "second=WRITABLE"
echo "third=ABSENT"
echo "failed_keys=second,third"
exit 2
SUITE
cat > "$T/kvfailodd.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "second=WRITABLE"
echo "failed_keys=sec ond;\$(x)"
exit 1
SUITE
cat > "$T/kvfailbare.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "second=WRITABLE"
exit 1
SUITE
cat > "$T/kvfaildiag.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "FAILURE: synthetic-private-diagnostic"
echo "  indented-private-detail"
echo "failed_keys=first"
exit 1
SUITE
cat > "$T/kvinconc.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "second=WRITABLE"
echo "INCONCLUSIVE: sibling: could not write /x/y; run from a sibling"
echo "  indented continuation"
echo "third=ABSENT"
exit 2
SUITE
cat > "$T/kvfailok.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "first=DENIED"
echo "failed_keys=first"
exit 0
SUITE
cat > "$T/coldcache.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  PASS: first"
printf 'INCONCLUSIVE: chezmoi managed failed: boom\n  warm it: command chezmoi managed\n' >&2
exit 2
SUITE
cat > "$T/coldbare.test.sh" <<'SUITE'
#!/usr/bin/env bash
printf 'INCONCLUSIVE: no cache: bare\n  warm it bare: command chezmoi managed\n' >&2
exit 2
SUITE
cat > "$T/guardbare.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "missing file under test: /x/subject.sh" >&2
echo "probe=SKIPPED"
exit 2
SUITE
# Slow fixtures hold a marker for a second, then record how many markers they saw.
for n in slowa slowb; do
  cat > "$T/$n.test.sh" <<SUITE
#!/usr/bin/env bash
: > "\$MARK/$n.running"
sleep 1
ls "\$MARK" | grep -c '\.running\$' > "\$MARK/$n.saw"
rm -f "\$MARK/$n.running"
echo "  ok  $n"
SUITE
done
# The tag is assembled at runtime for the same reason as test-requires above.
# Two serial fixtures, so serial suites overlapping each other is caught too. Each records
# whether a parallel suite had already finished when it started.
for n in serialy serialz; do
  printf '#!/usr/bin/env bash\n# test-serial\n' > "$T/$n.test.sh"
  cat >> "$T/$n.test.sh" <<SUITE
: > "\$MARK/$n.running"
[ -e "\$MARK/slowa.saw" ] && : > "\$MARK/$n.afterpar"
bad=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.1
  [ "\$(ls "\$MARK" | grep -c '\.running\$')" -gt 1 ] && bad=1
done
rm -f "\$MARK/$n.running"
if [ "\$bad" -eq 0 ]; then echo "  ok  $n ran alone"; else echo "  FAIL: another suite ran at the same time"; exit 1; fi
SUITE
done
# A suite gated on a live condition (anything but `heavy`) drives shared live state, so
# --all must run it alone too. Same body as the serial fixtures, behind a requirement tag.
printf '#!/usr/bin/env bash\n%s: a live herdr\n' "$tag" > "$T/gatedlive.test.sh"
tail -n +3 "$T/serialz.test.sh" | sed 's/serialz/gatedlive/g' >> "$T/gatedlive.test.sh"
cat > "$T/lockheld.test.sh" <<'SUITE'
#!/usr/bin/env bash
if [ -z "${HOLDER_DONE:-}" ] || [ -e "$HOLDER_DONE" ]; then echo "  ok  lock was free"; else echo "  FAIL: ran while the lock was held"; exit 1; fi
SUITE
cat > "$T/lockenv.test.sh" <<'SUITE'
#!/usr/bin/env bash
if [ "${RUN_SH_LOCKED:-}" = 1 ]; then echo "  ok  RUN_SH_LOCKED reaches suites"; else echo "  FAIL: RUN_SH_LOCKED=${RUN_SH_LOCKED:-unset}"; exit 1; fi
SUITE
chmod 755 "$T"/*.sh

# ran <label> <yes|no> <extended regex> <output> - run.sh prints `ok    <suite>` for a
# suite it ran and `skip  <suite>` for one it skipped.
ran() {
  local got=no
  printf '%s\n' "$4" | grep -Eq "$3" && got=yes
  if [ "$got" = "$2" ]; then _pass "$1"; else _fail "$1" "$(printf '%s' "$4" | tr '\n' '|')"; fi
}

out="$("$T/run.sh" 2>&1)"
ran "no filter: the gated suite is skipped"      no  'ok +gated-alpha' "$out"
ran "no filter: the plain suite runs"            yes 'ok +plain-alpha' "$out"
out="$("$T/run.sh" alpha 2>&1)"
ran "a substring filter keeps the gate"          no  'ok +gated-alpha' "$out"
ran "and still lists the skipped suite"          yes 'skip +gated-alpha' "$out"
ran "a substring filter runs the plain suite"    yes 'ok +plain-alpha' "$out"
out="$("$T/run.sh" gated-alpha 2>&1)"
ran "the exact suite name lifts the gate"        yes 'ok +gated-alpha' "$out"
out="$("$T/run.sh" plain gated-alpha 2>&1)"
ran "an exact name among several filters lifts it" yes 'ok +gated-alpha' "$out"
out="$("$T/run.sh" --all alpha 2>&1)"
ran "--all lifts the gate"                       yes 'ok +gated-alpha' "$out"
out="$("$T/run.sh" broken 2>&1)"
ran "a failing suite's detail line is printed"   yes '\| got: detail' "$out"
ran "the following ok line is not folded in"     no  '^ +  ok  after' "$out"
want="$(cd "$T/.." && pwd -P)"
out="$(cd "$T/.." && WANT_START="$want" "$T/run.sh" startdir 2>&1)"
ran "RUN_SH_START_DIR is the physical directory run.sh was started from" yes 'ok +startdir' "$out"
out="$("$T/run.sh" kvskip 2>&1)"
ran "a SKIPPED key=value line is not counted as an assertion" yes 'ok +kvskip +2/2' "$out"

out="$("$T/run.sh" kvfail 2>&1)"; rc=$?
ran "a failing kv suite shows its failed_keys line"          yes '^ +failed_keys=second,third$' "$out"
ran "failed_keys is not counted as an assertion"             yes 'FAIL +kvfail +3/3 \(exit=2\)' "$out"
ran "the other kv statuses are not echoed"                   no  'second=WRITABLE|third=ABSENT|first=DENIED' "$out"
ran "the kv suite is listed under NOT OK with its exit"      yes '  - kvfail \(exit=2\)' "$out"
if [ "$rc" -ne 0 ]; then _pass "a failing kv suite fails the run"; else _fail "a failing kv suite fails the run" "exit $rc"; fi
out="$("$T/run.sh" kvfailodd 2>&1)"
ran "a failed_keys line of other characters is not shown"     no  'failed_keys' "$out"
ran "and the suite still fails"                              yes 'FAIL +kvfailodd +2/2 \(exit=1\)' "$out"
out="$("$T/run.sh" kvfailbare 2>&1)"
ran "a failing kv suite without the line still fails"        yes 'FAIL +kvfailbare +2/2 \(exit=1\)' "$out"
ran "and shows no failed_keys line"                          no  'failed_keys' "$out"
out="$("$T/run.sh" kvfaildiag 2>&1)"
ran "a failing kv suite shows its failed_keys line"          yes '^ +failed_keys=first$' "$out"
ran "other output of a failing kv suite is not echoed"       no  'synthetic-private-diagnostic|indented-private-detail' "$out"
out="$("$T/run.sh" kvinconc 2>&1)"; rc=$?
ran "a failing kv suite shows its INCONCLUSIVE line"         yes '^ +INCONCLUSIVE: sibling: could not write /x/y' "$out"
ran "and its indented continuation line"                     yes '^ +indented continuation$' "$out"
ran "and still fails with its exit"                          yes 'FAIL +kvinconc +3/3 \(exit=2\)' "$out"
ran "the kv statuses are still not echoed"                   no  'first=DENIED|second=WRITABLE|third=ABSENT' "$out"
out="$("$T/run.sh" kvfailok 2>&1)"
ran "a passing kv suite does not count a failed_keys line"   yes 'ok +kvfailok +1/1' "$out"

out="$("$T/run.sh" coldcache 2>&1)"; rc=$?
ran "an INCONCLUSIVE line is printed under its suite" yes '^ +INCONCLUSIVE: chezmoi managed failed: boom' "$out"
ran "its indented continuation line is printed too"   yes '^ +warm it: command chezmoi managed' "$out"
if [ "$rc" -ne 0 ]; then _pass "an inconclusive suite still fails the run"; else _fail "an inconclusive suite still fails the run" "exit $rc"; fi
out="$("$T/run.sh" coldbare 2>&1)"; rc=$?
ran "no-assertions branch: the row is reported"                 yes '\?\?\?\? +coldbare +no assertions' "$out"
ran "no-assertions branch: the INCONCLUSIVE line is printed"    yes '^ +INCONCLUSIVE: no cache: bare' "$out"
ran "no-assertions branch: the continuation line is printed"    yes '^ +warm it bare: command chezmoi managed' "$out"
if [ "$rc" -ne 0 ]; then _pass "no-assertions branch: the run still fails"; else _fail "no-assertions branch: the run still fails" "exit $rc"; fi
# Bug caught: a suite stopped by its missing-subject guard showed as a bare ???? row, and the
# one line saying which file is missing was dropped.
out="$("$T/run.sh" guardbare 2>&1)"
ran "no-assertions branch: a guard's reason is printed under its row" yes '^ +missing file under test: /x/subject.sh$' "$out"
ran "no-assertions branch: and its exit is in the row"                yes '\?\?\?\? +guardbare +no assertions, exit=2' "$out"
ran "no-assertions branch: a KEY=VALUE line is still not echoed"      no  'probe=SKIPPED' "$out"

# Parallel run. Bug caught: parallel output differing from the sequential report.
a="$(RUN_JOBS=1 env -u RUN_SH_LOCKED "$T/run.sh" 2>&1)"
b="$(RUN_JOBS=4 env -u RUN_SH_LOCKED "$T/run.sh" 2>&1)"
if [ "$a" = "$b" ]; then _pass "a parallel run prints exactly what RUN_JOBS=1 prints"; else _fail "a parallel run prints exactly what RUN_JOBS=1 prints" "$(printf '%s\n' "$a" > "$T/a.out"; printf '%s\n' "$b" > "$T/b.out"; diff "$T/a.out" "$T/b.out" | tr '\n' '|')"; fi
ran "the report keeps its totals line"           yes '^[0-9]+ suites run' "$b"
ran "a nested runner (RUN_SH_LOCKED) reaches suites" yes 'ok +lockenv' "$b"

# Bug caught: RUN_JOBS ignored, so suites never overlap (or always do).
saw() { cat "$MARK/slowa.saw" "$MARK/slowb.saw" | sort -n | tail -1; }
rm -f "$MARK"/*.saw
RUN_JOBS=2 "$T/run.sh" slow >/dev/null 2>&1
if [ "$(saw)" = 2 ]; then _pass "RUN_JOBS=2 runs two suites at the same time"; else _fail "RUN_JOBS=2 runs two suites at the same time" "peak $(saw)"; fi
rm -f "$MARK"/*.saw
RUN_JOBS=1 "$T/run.sh" slow >/dev/null 2>&1
if [ "$(saw)" = 1 ]; then _pass "RUN_JOBS=1 runs one suite at a time"; else _fail "RUN_JOBS=1 runs one suite at a time" "peak $(saw)"; fi

# Bug caught: serial suites sharing the machine with parallel ones or with each other, or
# running before the parallel batch.
rm -f "$MARK"/*.saw "$MARK"/*.afterpar
out="$(RUN_JOBS=4 "$T/run.sh" 2>&1)"
ran "a test-serial suite runs alone"             yes 'ok +serialz' "$out"
ran "a second test-serial suite runs alone too"  yes 'ok +serialy' "$out"
if [ -e "$MARK/serialy.afterpar" ] && [ -e "$MARK/serialz.afterpar" ]; then _pass "serial suites start after the parallel ones finish"; else _fail "serial suites start after the parallel ones finish" "$(ls "$MARK" | tr '\n' ' ')"; fi

# Bug caught: --all running a suite gated on a live condition beside other suites.
out="$(RUN_JOBS=4 "$T/run.sh" --all 2>&1)"
ran "--all runs a live-gated suite alone"        yes 'ok +gatedlive' "$out"

# Locking. hold <tenths> [record] takes the lock in the background, waits until it is held
# (and, when given, until its holder-record line is written to $L.holder), and releases it
# after that long or when $T/release appears.
hold() {
  rm -f "$T/release" "$T/holder.done" "$L.holder"
  lockf -k "$L" sh -c '[ -z "$3" ] || printf "%s\n" "$3" > "$4.holder"; i=0; while [ ! -e "$1/release" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done; rm -f "$4.holder"; touch "$1/holder.done"' sh "$T" "$1" "${2:-}" "$L" &
  holder=$!
  local i=0
  while lockf -k -t 0 "$L" true 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  i=0
  while [ -n "${2:-}" ] && [ ! -e "$L.holder" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
# Bug caught: no lock, so two runners share the machine.
export HOLDER_DONE="$T/holder.done"
hold 30
out="$(env -u RUN_SH_LOCKED "$T/run.sh" 2>&1)"
wait "$holder"
ran "unfiltered run: says it is waiting for the lock" yes 'wait.*'"$L" "$out"
ran "unfiltered run: starts only after the holder exits" yes 'ok +lockheld' "$out"
hold 30
out="$(env -u RUN_SH_LOCKED "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "filtered run: says it is waiting for the lock"  yes 'wait.*'"$L" "$out"
ran "filtered run: starts only after the holder exits" yes 'ok +lockheld' "$out"
unset HOLDER_DONE
out="$(env -u RUN_SH_LOCKED "$T/run.sh" plain 2>&1)"
ran "a free lock prints no waiting line"         no  'wait' "$out"
# Bug caught: a lock file that cannot be opened reported as "held by another run".
mkdir "$T/rodir"; chmod 555 "$T/rodir"
out="$(RUN_SH_LOCK="$T/rodir/lock" env -u RUN_SH_LOCKED "$T/run.sh" plain 2>&1)"
chmod 755 "$T/rodir"
ran "an unopenable lock file is not reported as held" no  'wait' "$out"

# Bug caught: a runner nested inside a locked one waits for its parent's lock forever.
hold 600
RUN_SH_LOCKED=1 "$T/run.sh" plain-alpha > "$T/nested.out" 2>&1 &
nested=$!
i=0
while ! grep -q 'suites passed' "$T/nested.out" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if grep -q 'suites passed' "$T/nested.out"; then _pass "RUN_SH_LOCKED=1 runs while the lock is held"; else _fail "RUN_SH_LOCKED=1 runs while the lock is held" "$(cat "$T/nested.out")"; fi
kill "$nested" 2>/dev/null
touch "$T/release"
wait "$holder"

# A runner that must take the lock starts with none of the variables a locked parent exports.
FRESH=(env -u RUN_SH_LOCKED -u RUN_SH_LOCK_OWNER -u RUN_SH_LOCK_SINCE -u RUN_SH_LOCK_WAIT -u RUN_SH_LOCK_POLL)
fresh() { "${FRESH[@]}" "$@"; }
cat > "$T/nestedrun.test.sh" <<'SUITE'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd)
cat "$RUN_SH_LOCK.holder" > "$MARK/nested.before"
"$d/run.sh" plain-alpha > "$MARK/nested.out" 2>&1
cat "$RUN_SH_LOCK.holder" > "$MARK/nested.after"
echo "  ok  nestedrun"
SUITE
cat > "$T/holderseen.test.sh" <<'SUITE'
#!/usr/bin/env bash
cat "$RUN_SH_LOCK.holder" > "$MARK/holderseen.rec"
echo "  ok  holderseen"
SUITE
chmod 755 "$T"/nestedrun.test.sh "$T"/holderseen.test.sh
export HOLDER_DONE="$T/holder.done"
now() { date +%s; }

# Bug caught: a waiter that cannot say who holds the lock, since when, or for what.
hold 15 "$(printf '%s\tCHK/x\txreview wt' "$(( $(now) - 840 ))")"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a waiter names the holder's age, arguments and checkout" yes "held for 14 min by 'run.sh xreview wt' in CHK/x" "$out"
# Bug caught: lockf's own "already locked" line printed before every waiting line.
ran "a waiter prints no line of lockf's own" no '^lockf:' "$out"

# Bug caught: the waiting line printed once, so a long wait looks hung.
hold 25 "$(printf '%s\tCHK/x\txreview' "$(now)")"
out="$(fresh RUN_SH_LOCK_POLL=1 "$T/run.sh" lockheld 2>&1)"
wait "$holder"
n=$(printf '%s\n' "$out" | grep -c 'waiting for the test-run lock')
if [ "$n" -ge 2 ]; then _pass "a waiter repeats the line while it waits"; else _fail "a waiter repeats the line while it waits" "$n waiting lines"; fi

# Bug caught: a missing or unparsable record breaking the wait instead of degrading.
hold 15
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a missing holder record: today's line" yes 'held by another run' "$out"
ran "a missing holder record: the run still happens" yes 'ok +lockheld' "$out"
hold 15 'not a record'
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a garbage holder record: today's line" yes 'held by another run' "$out"
ran "a garbage holder record: the run still happens" yes 'ok +lockheld' "$out"

# Bug caught: a tab or newline in a record field splitting the waiting line or injecting a line.
hold 20 "$(printf '%s\tCHK/a\tone\ttwo\nINJECTED line' "$(now)")"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
n=$(printf '%s\n' "$out" | grep -c 'waiting for the test-run lock')
if [ "$n" = 1 ]; then _pass "a record with a tab and a newline in a field prints one waiting line"; else _fail "a record with a tab and a newline in a field prints one waiting line" "$n waiting lines"; fi
ran "that line carries no tab" no $'\t' "$out"
ran "and no line of the record is printed on its own" no '^INJECTED' "$out"
ran "and the run still happens" yes 'ok +lockheld' "$out"

# Bug caught: RUN_SH_LOCK_WAIT=0 waiting anyway, or running the suites without the lock.
hold 600
out="$(fresh RUN_SH_LOCK_WAIT=0 "$T/run.sh" lockheld 2>&1)"; rc=$?
touch "$T/release"; wait "$holder"
if [ "$rc" = 75 ]; then _pass "RUN_SH_LOCK_WAIT=0 against a held lock exits 75"; else _fail "RUN_SH_LOCK_WAIT=0 against a held lock exits 75" "exit $rc"; fi
ran "RUN_SH_LOCK_WAIT=0 runs no suite" no 'ok +' "$out"
ran "RUN_SH_LOCK_WAIT=0 prints no totals" no 'suites run' "$out"
ran "RUN_SH_LOCK_WAIT=0 says it gave up" yes 'giving up after 0 s: held by another run' "$out"

# Bug caught: a bounded wait that never gives up.
hold 600
out="$(fresh RUN_SH_LOCK_WAIT=2 RUN_SH_LOCK_POLL=1 "$T/run.sh" lockheld 2>&1)"; rc=$?
touch "$T/release"; wait "$holder"
if [ "$rc" = 75 ]; then _pass "a bounded wait the holder outlasts exits 75"; else _fail "a bounded wait the holder outlasts exits 75" "exit $rc"; fi
ran "and runs no suite" no 'suites run|ok +' "$out"
ran "and says how long it waited" yes 'giving up after [2-9] s:' "$out"

# Bug caught: a bounded wait giving up on a holder that releases within the bound.
hold 20
out="$(fresh RUN_SH_LOCK_WAIT=30 RUN_SH_LOCK_POLL=1 "$T/run.sh" lockheld 2>&1)"; rc=$?
wait "$holder"
ran "a bounded wait the holder releases in time runs" yes 'ok +lockheld' "$out"
if [ "$rc" = 0 ]; then _pass "and exits 0"; else _fail "and exits 0" "exit $rc"; fi

# Bug caught: a bad bound read as "no bound" or as a lockf usage error.
for v in soon -1; do
  out="$(fresh RUN_SH_LOCK_WAIT=$v "$T/run.sh" lockheld 2>&1)"; rc=$?
  if [ "$rc" = 2 ]; then _pass "RUN_SH_LOCK_WAIT=$v exits 2"; else _fail "RUN_SH_LOCK_WAIT=$v exits 2" "exit $rc"; fi
  ran "RUN_SH_LOCK_WAIT=$v says why" yes 'RUN_SH_LOCK_WAIT must be a non-negative integer' "$out"
  ran "RUN_SH_LOCK_WAIT=$v runs no suite" no 'suites run|ok +' "$out"
done

# Bug caught: a wait nobody can measure; and a runner that never waited claiming it did.
hold 20
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a runner that waited says how long" yes 'waited [0-9]+ s for the test-run lock' "$out"
out="$(fresh "$T/run.sh" plain 2>&1)"
ran "a runner that did not wait says nothing of waiting" no 'wait' "$out"

# Bug caught: a wait shorter than the poll interval going unreported.
hold 20 "$(printf '%s\tCHK/y\tfoo' "$(now)")"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
seq=$(printf '%s\n' "$out" | grep -oE 'waiting for the test-run lock|held for [0-9]+ min by .run.sh foo. in CHK/y|waited [0-9]+ s|ok +lockheld' | sed -E 's/waited [0-9]+ s/waited/; s/ok +/ok /; s/held for [0-9]+ min/held/' | tr '\n' ,)
want="waiting for the test-run lock,held by 'run.sh foo' in CHK/y,waited,ok lockheld,"
if [ "$seq" = "$want" ]; then _pass "a wait shorter than the poll still prints the holder, then how long, then runs"; else _fail "a wait shorter than the poll still prints the holder, then how long, then runs" "$seq"; fi

# Bug caught: a nested runner clobbering or deleting its parent's record, or reporting a wait
# that was not its own.
hold 20
out="$(fresh "$T/run.sh" nestedrun 2>&1)"
wait "$holder"
ran "the outer runner that waited says so" yes 'waited [0-9]+ s' "$out"
ran "a nested runner reports no wait" no 'waited' "$(cat "$MARK/nested.out")"
if [ -s "$MARK/nested.before" ] && cmp -s "$MARK/nested.before" "$MARK/nested.after"; then _pass "a nested runner leaves the record as it found it"; else _fail "a nested runner leaves the record as it found it" "$(cat "$MARK/nested.before" "$MARK/nested.after" 2>&1 | tr '\n\t' '| ')"; fi
f3=$(awk -F'\t' '{print $3}' "$MARK/nested.before")
if [ "$f3" = nestedrun ]; then _pass "and the record names the outer runner's arguments"; else _fail "and the record names the outer runner's arguments" "$f3"; fi

# Bug caught: a record left behind after the run, which the next waiter would trust.
fresh "$T/run.sh" plain >/dev/null 2>&1
if [ ! -e "$L.holder" ]; then _pass "the holder record is removed after a run"; else _fail "the holder record is removed after a run" "$(cat "$L.holder")"; fi

# Bug caught: a record naming the wrong checkout or arguments.
want="$(cd "$T/.." && pwd -P)"
(cd "$T/.." && fresh "$T/run.sh" holderseen >/dev/null 2>&1)
f2=$(awk -F'\t' '{print $2}' "$MARK/holderseen.rec"); f3=$(awk -F'\t' '{print $3}' "$MARK/holderseen.rec")
if [ "$f2" = "$want" ]; then _pass "a running runner's record names its checkout"; else _fail "a running runner's record names its checkout" "$f2"; fi
if [ "$f3" = holderseen ]; then _pass "and its arguments"; else _fail "and its arguments" "$f3"; fi

# Bug caught: a stale record against a free lock printed as if someone held it.
printf '1\tCHK/old\told\n' > "$L.holder"
out="$(fresh "$T/run.sh" plain-alpha 2>&1)"
ran "a stale record with a free lock prints no waiting line" no 'wait' "$out"
ran "and the run starts" yes 'ok +plain-alpha' "$out"
rm -f "$L.holder"

# Bug caught: a lock directory that does not exist yet reported as a failure to lock.
out="$(fresh RUN_SH_LOCK="$T/newdir/lock" "$T/run.sh" plain-alpha 2>&1)"
ran "a missing lock directory is created and the run starts" yes 'ok +plain-alpha' "$out"
ran "and nothing is said of waiting" no 'wait' "$out"
# Bug caught: lockf started in the background, so Ctrl-C reached neither the suites nor the
# runner's lock: the orphaned runner finished its suites beside the next owner.
cat > "$T/slowint.test.sh" <<'SUITE'
#!/usr/bin/env bash
trap 'echo interrupted > "$MARK/slowint.int"; exit 130' INT
: > "$MARK/slowint.started"
i=0; while [ ! -e "$MARK/slowint.release" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
echo "  ok  slowint"
SUITE
chmod 755 "$T/slowint.test.sh"
rm -f "$MARK"/slowint.*
set -m
"${FRESH[@]}" "$T/run.sh" slowint > "$T/int.out" 2>&1 &
pg=$!
set +m
i=0; while [ ! -e "$MARK/slowint.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -INT -- "-$pg"
wait "$pg"; rc=$?
i=0; while [ ! -e "$MARK/slowint.int" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$rc" = 130 ]; then _pass "an interrupt during a run exits 130"; else _fail "an interrupt during a run exits 130" "exit $rc"; fi
if [ -e "$MARK/slowint.int" ]; then _pass "and the interrupt reaches the running suite"; else _fail "and the interrupt reaches the running suite" "$(cat "$T/int.out")"; fi
# An uninterrupted orphan would leave its loop on release and its runner would report.
touch "$MARK/slowint.release"; sleep 3
ran "and the runner does not go on to report" no 'suites passed|suites run' "$(cat "$T/int.out")"
hold 600
set -m
"${FRESH[@]}" "$T/run.sh" lockheld > "$T/intw.out" 2>&1 &
pg=$!
set +m
i=0; while ! grep -q 'waiting for' "$T/intw.out" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -INT -- "-$pg"
wait "$pg"; rc=$?
touch "$T/release"; wait "$holder"
if [ "$rc" = 130 ]; then _pass "an interrupt while waiting for the lock exits 130"; else _fail "an interrupt while waiting for the lock exits 130" "exit $rc"; fi
ran "and no suite runs" no 'ok +|suites' "$(cat "$T/intw.out")"

# Bug caught: a bound or poll with a leading zero read as octal, which aborted the lock block
# and ran the suites unlocked beside the holder.
hold 20
out="$(fresh RUN_SH_LOCK_WAIT=08 RUN_SH_LOCK_POLL=09 "$T/run.sh" lockheld 2>&1)"; rc=$?
wait "$holder"
ran "RUN_SH_LOCK_WAIT=08 waits for the holder, then runs" yes 'ok +lockheld' "$out"
ran "and prints no shell error" no 'value too great|run\.sh: line' "$out"
if [ "$rc" = 0 ]; then _pass "and exits 0"; else _fail "and exits 0" "exit $rc"; fi
hold 20 "$(printf '08\tCHK/z\tfoo')"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a record timestamp with a leading zero is read in base 10" yes "held for [0-9]+ min by 'run.sh foo' in CHK/z" "$out"
ran "and prints no shell error" no 'value too great|run\.sh: line' "$out"

# Bug caught: a bound or poll value that does not leak into the suites ends up gating the
# fixture runners the suites start.
cat > "$T/envseen.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "${RUN_SH_LOCK_WAIT-unset} ${RUN_SH_LOCK_POLL-unset} ${RUN_SH_LOCK_OWNER-unset} ${RUN_SH_LOCK_SINCE-unset}" > "$MARK/envseen"
echo "  ok  envseen"
SUITE
chmod 755 "$T/envseen.test.sh"
fresh RUN_SH_LOCK_WAIT=30 RUN_SH_LOCK_POLL=5 "$T/run.sh" envseen >/dev/null 2>&1
if [ "$(cat "$MARK/envseen")" = "unset unset unset unset" ]; then _pass "the lock variables do not reach the suites"; else _fail "the lock variables do not reach the suites" "$(cat "$MARK/envseen")"; fi

# Bug caught: arguments with a tab or newline breaking the one-line, three-field record.
rm -f "$MARK/holderseen.rec"
fresh "$T/run.sh" holderseen $'a\tb' $'c\nd' >/dev/null 2>&1
n=$(wc -l < "$MARK/holderseen.rec" | tr -d ' '); nf=$(awk -F'\t' '{print NF}' "$MARK/holderseen.rec" | tr '\n' ' ')
if [ "$n" = 1 ] && [ "$nf" = "3 " ]; then _pass "a record from arguments with a tab and a newline is one line of three fields"; else _fail "a record from arguments with a tab and a newline is one line of three fields" "$n lines, fields: $nf"; fi

# Bug caught: a relative RUN_SH_LOCK putting the record where waiters do not look (the runner
# changes into tests/ before it writes it).
cat > "$T/relseen.test.sh" <<'SUITE'
#!/usr/bin/env bash
if [ -e "$REL_START/rel/lock.holder" ]; then echo start; elif [ -e "$REL_TESTS/rel/lock.holder" ]; then echo tests; else echo none; fi > "$MARK/relseen"
echo "  ok  relseen"
SUITE
chmod 755 "$T/relseen.test.sh"
mkdir -p "$T/sub" "$T/rel"
export REL_START="$T/sub" REL_TESTS="$T"
(cd "$T/sub" && fresh RUN_SH_LOCK=rel/lock "$T/run.sh" relseen >/dev/null 2>&1)
if [ "$(cat "$MARK/relseen")" = start ]; then _pass "a relative RUN_SH_LOCK keeps its record beside the lock"; else _fail "a relative RUN_SH_LOCK keeps its record beside the lock" "$(cat "$MARK/relseen")"; fi

# Bug caught: consecutive tabs collapsing, so an empty checkout field made the arguments the checkout.
hold 15 "$(printf '%s\t\tfoo' "$(now)")"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a record with an empty checkout field degrades" yes 'held by another run' "$out"

# Bug caught: a holder timestamp in the future printing a negative age.
hold 15 "$(printf '%s\tCHK/f\tfoo' "$(( $(now) + 7200 ))")"
out="$(fresh "$T/run.sh" lockheld 2>&1)"
wait "$holder"
ran "a record from the future counts as held for 0 min" yes "held for 0 min by 'run.sh foo' in CHK/f" "$out"
# Bug caught: an expansion error inside the lock block abandoning the whole top-level `if`
# and letting the script run its suites unlocked (exit 0) beside a holder.
sed '/^  local wait_max=/a\
  : $((08))' "$RUN" > "$T/run-inject.sh"
chmod 755 "$T/run-inject.sh"
if ! grep -q '^  : \$((08))$' "$T/run-inject.sh"; then _fail "the injected expansion error is in the copy" "sed did not inject"; fi
out="$(fresh "$T/run-inject.sh" plain-alpha 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then _pass "an expansion error in the lock block exits 2"; else _fail "an expansion error in the lock block exits 2" "exit $rc: $out"; fi
ran "and no suite runs unlocked" no 'ok +|suites' "$out"
rm -f "$T/run-inject.sh"

# Changed-subject selection (--changed). The fixture is a git repository holding a copy of
# run.sh, two heavy suites, a live-gated one and a plain one, a subject map and the files it
# names. Every case starts from the same state: HEAD on `work`, equal to `main`.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
R="$T/repo"; MAP=.scripts/test-audit/subjects.tsv; NAIVE='lib/naïve".sh'
G() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
commit() { G add -A && G commit -q -m "$1"; }
rr() { fresh RUN_SH_LOCK="$T/repolock" "$R/tests/run.sh" "$@" 2>&1; }
row() { printf '%s\t%s\t%s\t%s' "$1" sh '' "$2"; }
# The tab-less comment line is the real map's shape: a comment read as a row is malformed.
write_map() { # write_map [extra row]...: the fixture map, then the rows given
  mkdir -p "$R/.scripts/test-audit"
  { printf '# Subject map\n# file\tlang\town_suite\tloaded_by\n\n'
    row lib/a.sh heavya; echo; row lib/b.sh heavyb; echo; row "lib/has space.sh" heavya; echo; row "$NAIVE" heavyb; echo
    [ $# -eq 0 ] || printf '%s\n' "$@"
  } > "$R/$MAP"
}
drop_rows() { awk -F'\t' -v k="$1" -v v="$2" '$k != v' "$R/$MAP" > "$R/$MAP.new" && mv "$R/$MAP.new" "$R/$MAP"; }
edit() { printf '# edit\n' >> "$R/$1"; }
rm -rf "$R"; mkdir -p "$R/tests" "$R/lib" "$R/.scripts/test-audit"
cp "$RUN" "$R/tests/run.sh"
for n in heavya heavyb; do
  printf '#!/usr/bin/env bash\n%s: heavy  # a fixture\necho "  ok  %s ran"\n' "$tag" "$n" > "$R/tests/$n.test.sh"
done
printf '#!/usr/bin/env bash\n%s: a live herdr\necho "  ok  gatedlive2 ran"\n' "$tag" > "$R/tests/gatedlive2.test.sh"
printf '#!/usr/bin/env bash\necho "  ok  plainc ran"\n' > "$R/tests/plainc.test.sh"
chmod 755 "$R"/tests/*.sh
for f in lib/a.sh lib/b.sh "lib/has space.sh" "$NAIVE"; do echo "# $f" > "$R/$f"; done
write_map
if ! G init -q -b main 2>"$T/ginit.err"; then echo "cannot build the fixture repository: $(cat "$T/ginit.err")" >&2; exit 2; fi
commit base && G switch -q -c work && cp -R "$R" "$T/repo.tpl"
reset_repo() { rm -rf "$R"; cp -R "$T/repo.tpl" "$R"; }
# on_main <message>: commit what is in the tree to main, then start `work` there.
on_main() { G switch -q main && commit "$1" && G switch -q -C work; }

# both <label> <reason regex> <output>: both heavy suites ran, each carrying the reason.
both() {
  local a=no b=no
  printf '%s\n' "$3" | grep -Eq "ok +heavya .*\[needs: heavy; $2\]" && a=yes
  printf '%s\n' "$3" | grep -Eq "ok +heavyb .*\[needs: heavy; $2\]" && b=yes
  if [ "$a$b" = yesyes ]; then _pass "$1"; else _fail "$1" "$(printf '%s' "$3" | tr '\n' '|')"; fi
}
# neither <label> <output>: both heavy suites were left out for want of a changed subject.
neither() {
  local a=no b=no
  printf '%s\n' "$2" | grep -Eq 'skip +heavya +needs: heavy \(no subject changed since [0-9a-f]+\)$' && a=yes
  printf '%s\n' "$2" | grep -Eq 'skip +heavyb +needs: heavy \(no subject changed since [0-9a-f]+\)$' && b=yes
  if [ "$a$b" = yesyes ]; then _pass "$1"; else _fail "$1" "$(printf '%s' "$2" | tr '\n' '|')"; fi
}

# Bug caught: without --changed the report differs from today's (a stray note or reason).
reset_repo
out="$(rr)"
want="$(printf '  skip  %-28s needs: %s\n  skip  %-28s needs: %s\n  skip  %-28s needs: %s\n  ok    %-28s %s\n' gatedlive2 'a live herdr' heavya heavy heavyb heavy plainc 1/1)
$(printf '\n1 suites run, 3 skipped (see the needs: lines)\nall 1 suites passed (1 assertions)')"
if [ "$out" = "$want" ]; then _pass "without --changed the report is exactly today's"; else _fail "without --changed the report is exactly today's" "$out"; fi

# Bug caught: --changed= (an empty base) taken as the default base, or as a filter.
out="$(rr --changed=)"; rc=$?
if [ "$rc" = 2 ]; then _pass "--changed= is refused with exit 2"; else _fail "--changed= is refused with exit 2" "exit $rc"; fi
ran "and names the option" yes 'unknown option: --changed=' "$out"

# Bug caught: a changed subject not selecting its suite, or selecting every heavy suite.
reset_repo; edit lib/a.sh; commit "edit a"
out="$(rr --changed)"
ran "a changed subject selects its heavy suite and names it" yes 'ok +heavya .*\[needs: heavy; changed: lib/a.sh\]' "$out"
ran "the other heavy suite stays skipped" yes 'skip +heavyb +needs: heavy \(no subject changed since [0-9a-f]+\)' "$out"
ran "--changed does not lift another gate" yes 'skip +gatedlive2 +needs: a live herdr$' "$out"
# Bug caught: the repository root taken from the current directory, so a run started inside
# another repository (here a copy where nothing changed) reads that repository's diff.
cp -R "$T/repo.tpl" "$T/other"
out="$(cd "$T/other/lib" && rr --changed)"
ran "started inside another repository the runner reads its own" yes 'ok +heavya .*changed: lib/a.sh\]' "$out"
rm -rf "$T/other"

# Bug caught: any commit selecting every heavy suite; an unrelated file counted as a subject; a
# comment or blank line of the map read as a malformed row.
reset_repo; echo hi > "$R/README"; commit "readme"
out="$(rr --changed)"
neither "an unrelated change selects no heavy suite" "$out"
ran "and the plain suite still runs" yes 'ok +plainc' "$out"
ran "a skipped heavy suite counts as skipped" yes '^1 suites run, 3 skipped' "$out"

# Bug caught: the suite's own file or run.sh missing from its subjects.
reset_repo; edit tests/heavya.test.sh; commit "edit the suite"
out="$(rr --changed)"
ran "a change to the suite's own file selects it" yes 'ok +heavya .*changed: tests/heavya.test.sh' "$out"
ran "and not the other heavy suite" yes 'skip +heavyb' "$out"
reset_repo; edit tests/run.sh; commit "edit run.sh"
out="$(rr --changed)"
ran "a change to run.sh selects one heavy suite" yes 'ok +heavya .*changed: tests/run.sh' "$out"
ran "and the other" yes 'ok +heavyb .*changed: tests/run.sh' "$out"

# Bug caught: only committed changes seen.
reset_repo; edit lib/a.sh
out="$(rr --changed)"
ran "an unstaged change selects" yes 'ok +heavya' "$out"
reset_repo; edit lib/a.sh; G add lib/a.sh
out="$(rr --changed)"
ran "a staged change selects" yes 'ok +heavya' "$out"
reset_repo; write_map "$(row lib/new.sh heavya)"; on_main "row for new"
echo x > "$R/lib/new.sh"
out="$(rr --changed)"
ran "an untracked file selects" yes 'ok +heavya .*changed: lib/new.sh' "$out"
# Bug caught: ignored files selected (build output, caches).
reset_repo; write_map "$(row lib/new.sh heavya)"; echo lib/new.sh > "$R/.gitignore"; on_main "row for new"
echo x > "$R/lib/new.sh"
out="$(rr --changed)"
ran "an ignored untracked file does not select" yes 'skip +heavya' "$out"

# Bug caught: a rename away from a subject path seen only as an addition.
reset_repo; G mv lib/a.sh lib/z.sh; commit "move a"
out="$(rr --changed)"
ran "a rename away from a subject selects" yes 'ok +heavya .*changed: lib/a.sh' "$out"

# Bug caught: names read through git's quoting ("lib/na\303\257ve\".sh") never matching the map.
reset_repo; edit "$NAIVE"; commit "edit naive"
out="$(rr --changed)"
ran "a name git would quote selects" yes 'ok +heavyb .*changed: lib/naïve".sh\]' "$out"
# Bug caught: a name split at its space.
reset_repo; edit "lib/has space.sh"; commit "edit spaced"
out="$(rr --changed)"
ran "a name with a space selects" yes 'ok +heavya .*changed: lib/has space.sh\]' "$out"

# Bug caught: a count of changed subjects that is wrong or missing.
reset_repo; edit lib/a.sh; edit "lib/has space.sh"; commit "edit two"
out="$(rr --changed)"
ran "several changed subjects are counted" yes 'ok +heavya .*changed: lib/a.sh, \+1 more\]' "$out"

# Bug caught: only the working-tree map read, so dropping a row unselects its suite.
reset_repo; drop_rows 1 lib/a.sh; edit lib/a.sh; commit "drop the row and edit"
out="$(rr --changed)"
ran "a row removed on the branch still selects" yes 'ok +heavya .*changed: lib/a.sh\]' "$out"

# Bug caught: a map edit selecting every suite that has subjects.
reset_repo; write_map "$(row lib/c.sh plainc)"; commit "map row for plainc"
out="$(rr --changed)"
neither "a map edit about another suite selects no heavy suite" "$out"

# Bug caught: each fail-safe path skipping a heavy suite it could not decide about.
reset_repo; rm -rf "$R/.git"
out="$(GIT_CEILING_DIRECTORIES="$(cd "$T" && pwd -P)" rr --changed)"
both "not a git work tree selects every heavy suite" 'not a git work tree' "$out"
reset_repo
out="$(rr --changed=nosuchref)"
both "an unresolvable base selects every heavy suite" 'base nosuchref does not resolve' "$out"
reset_repo; G switch -q --orphan orphan && echo o > "$R/o" && commit orphan && G switch -q work
out="$(rr --changed=orphan)"
both "no merge base selects every heavy suite" 'no merge base with orphan' "$out"
reset_repo; G rm -q "$MAP"; commit "no map"
out="$(rr --changed)"
both "a missing map selects every heavy suite" 'subject map missing' "$out"
reset_repo; printf 'lib/x.sh\tsh\theavya\n' >> "$R/$MAP"; commit "bad row"
out="$(rr --changed)"
both "a malformed row selects every heavy suite" 'subject map malformed' "$out"
# Bug caught: whitespace or an empty name in a row taken as part of a name that never matches,
# so the suite the row names is skipped unseen. One shape per row; each case rewrites the whole
# working-tree map, so no shape outlives its case. A space inside a file name stays valid ("a
# name with a space selects" above).
malformed() { # malformed <label> <row>
  write_map "$2"
  out="$(rr --changed)"
  both "$1" 'subject map malformed' "$out"
}
reset_repo
malformed "a file name with a leading space is malformed"      " $(row lib/x.sh heavya)"
malformed "a file name with a trailing space is malformed"     "$(row 'lib/x.sh ' heavya)"
malformed "another field with a trailing space is malformed"   "$(printf 'lib/x.sh\tsh \t\theavya')"
malformed "whitespace inside loaded_by is malformed"           "$(row lib/x.sh 'heavya, heavyb')"
malformed "an empty name inside loaded_by is malformed"        "$(row lib/x.sh heavya,,heavyb)"
malformed "a leading comma in loaded_by is malformed"          "$(row lib/x.sh ,heavya)"
malformed "a trailing comma in loaded_by is malformed"         "$(row lib/x.sh heavya,)"
malformed "a CR inside a row is malformed"                     "$(row "lib/x"$'\r'".sh" heavya)"
reset_repo; printf 'lib/x.sh\tsh\theavya\n' >> "$R/$MAP"; on_main "bad row on main"
write_map; commit "row fixed on the branch"
out="$(rr --changed)"
both "a malformed row at the base selects every heavy suite" 'subject map at [0-9a-f]+ malformed' "$out"
reset_repo; chmod 000 "$R/$MAP"
if [ -r "$R/$MAP" ]; then
  echo "  SKIP: an unreadable map selects every heavy suite (this user reads a mode 000 file)"
else
  out="$(rr --changed)"
  both "an unreadable map selects every heavy suite" 'subject map unreadable' "$out"
fi
chmod 644 "$R/$MAP"
reset_repo; blob="$(G rev-parse "main:$MAP")"; write_map "$(row lib/c.sh plainc)"; commit "map changed"
rm -f "$R/.git/objects/${blob:0:2}/${blob:2}"
out="$(rr --changed)"
both "a base map whose blob cannot be read selects every heavy suite" 'subject map at [0-9a-f]+ unreadable' "$out"
reset_repo; G rm -q "$MAP"; on_main "no map on main"
write_map; echo hi > "$R/README"; commit "map and readme on the branch"
out="$(rr --changed)"
neither "a base without a map reads only the working tree" "$out"
ran "and gives no fail-safe reason" no 'needs: heavy;' "$out"
# Bug caught: a git command's failure read as "nothing changed", or a merge-base failure other
# than its "no merge base" (exit 1) read as that. The stub first on PATH logs every argument to
# STUB_LOG and fails, with STUB_RC, the call carrying the argument STUB_FAIL. The stubbed runs
# only read the repository, so they share one reset.
mkdir -p "$T/gitstub"; REAL_GIT="$(command -v git)"
cat > "$T/gitstub/git" <<'STUB'
#!/bin/sh
[ -z "${STUB_LOG:-}" ] || printf '%s\n' "$@" >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || for a in "$@"; do [ "$a" = "$STUB_FAIL" ] && exit "${STUB_RC:-1}"; done
exec "$REAL_GIT" "$@"
STUB
chmod 755 "$T/gitstub/git"
failing() { # failing <argument> <exit status> <label>
  out="$(PATH="$T/gitstub:$PATH" REAL_GIT="$REAL_GIT" STUB_FAIL=$1 STUB_RC=$2 rr --changed)"
  both "$3" 'git failed' "$out"
}
reset_repo
failing diff 1 "a failing git diff selects every heavy suite"
failing ls-files 1 "a failing git ls-files selects every heavy suite"
failing ls-tree 1 "a failing git ls-tree selects every heavy suite"
failing --short 1 "a failing git rev-parse --short selects every heavy suite"
failing merge-base 128 "a merge-base error other than exit 1 is git failed, not no merge base"
# Bug caught: a base starting with "-" handed to git, which reads it as an option.
out="$(PATH="$T/gitstub:$PATH" REAL_GIT="$REAL_GIT" STUB_LOG="$T/git.log" rr --changed=-x)"
both "a base that starts with - selects every heavy suite" 'base -x does not resolve' "$out"
if grep -q '^-x' "$T/git.log" 2>/dev/null; then _fail "and never reaches git" "$(tr '\n' ' ' < "$T/git.log")"; else _pass "and never reaches git"; fi

# Bug caught: a suite the map does not mention being skipped as "unchanged".
reset_repo; drop_rows 4 heavyb; commit "heavyb has no rows on the branch"
out="$(rr --changed)"
ran "a suite without a row is selected" yes 'ok +heavyb .*\[needs: heavy; no subject-map row\]' "$out"
ran "and the suite with rows is not" yes 'skip +heavya' "$out"

# Bug caught: nothing-changed read as an error.
reset_repo; G switch -q main
out="$(rr --changed)"
neither "HEAD equal to the base with a clean tree selects no heavy suite" "$out"

# Bug caught: --changed overriding the exact-name and --all lifts, or the filters.
reset_repo
out="$(rr --changed heavyb)"
ran "an exact name still runs a heavy suite with no changed subject" yes 'ok +heavyb' "$out"
ran "and the filter still narrows the run" no 'heavya' "$out"
out="$(rr --changed --all)"
ran "--all still runs one heavy suite" yes 'ok +heavya' "$out"
ran "and the other" yes 'ok +heavyb' "$out"
out="$(rr --changed plainc)"
ran "a filter that excludes the heavy suites lists none" no 'heavy' "$out"
# Bug caught: an earlier --changed=<ref> outliving a later bare --changed, which means main.
out="$(rr --changed=nosuchref --changed)"
neither "a later bare --changed resets the base to main" "$out"

# Bug caught: an unexpected shell error in the selection leaving "nothing changed" in force,
# which would skip a heavy suite nobody decided about.
reset_repo; echo hi > "$R/README"; commit "readme"
sed '/^compute_selection() {$/a\
  : $((08))' "$RUN" > "$R/tests/run-inject.sh"
chmod 755 "$R/tests/run-inject.sh"
if ! grep -q '^  : \$((08))$' "$R/tests/run-inject.sh"; then _fail "the injected expansion error is in the copy" "sed did not inject"; fi
out="$(fresh RUN_SH_LOCK="$T/repolock" "$R/tests/run-inject.sh" --changed 2>&1)"
both "an expansion error while selecting runs every heavy suite" 'git failed' "$out"
# Bug caught: the same error in the per-suite decision abandoning both suite loops at the first
# heavy suite, so the suites sorted before it ran and the run ended green with the heavy suites
# dropped. aplain sorts before them.
sed '/^changed_subjects() {$/a\
  : $((08))' "$RUN" > "$R/tests/run-inject.sh"
if ! grep -q '^  : \$((08))$' "$R/tests/run-inject.sh"; then _fail "the injected expansion error is in the copy" "sed did not inject"; fi
printf '#!/usr/bin/env bash\necho "  ok  aplain ran"\n' > "$R/tests/aplain.test.sh"
chmod 755 "$R/tests/aplain.test.sh"
out="$(fresh RUN_SH_LOCK="$T/repolock" "$R/tests/run-inject.sh" --changed 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then _pass "an expansion error in the per-suite decision exits 2"; else _fail "an expansion error in the per-suite decision exits 2" "exit $rc: $out"; fi
ran "and prints no passing verdict" no 'suites passed' "$out"
ran "and says the selection failed" yes '^run.sh: selecting the suites failed; running none$' "$out"
# Bug caught: a selection that stopped partway still running the suites it had picked (a heavy
# one takes minutes) for a run that cannot pass.
ran "and starts none of the suites it picked" no 'ok +aplain' "$out"
# Bug caught: an error in the report loop after the first suite was counted ending in a green
# verdict on the suites before it. Run without --changed: the guard is not tied to it.
sed '/^  suites=\$((suites + 1))$/a\
  [ "$suites" -lt 2 ] || : $((08))' "$RUN" > "$R/tests/run-inject.sh"
if ! grep -qF '|| : $((08))' "$R/tests/run-inject.sh"; then _fail "the injected expansion error is in the copy" "sed did not inject"; fi
out="$(fresh RUN_SH_LOCK="$T/repolock" "$R/tests/run-inject.sh" 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then _pass "an expansion error in the report exits 2"; else _fail "an expansion error in the report exits 2" "exit $rc: $out"; fi
ran "and gives no passing verdict" no 'suites passed' "$out"
ran "and says the report stopped" yes '^run.sh: the report stopped partway; no verdict$' "$out"
rm -f "$R/tests/run-inject.sh" "$R/tests/aplain.test.sh"

# Subject-map drift. drift_check <repo root> prints one line per problem with the map and fails
# when there is any: for each suite tagged heavy, a path it names with no row listing it, a row
# listing it whose file is gone, or no row at all. A named path is a dot_…, .scripts/…, .chezmoi…
# or tests/… token, bare or after a $VAR/, ${VAR}/ or $(…)/ root, with {a,b} expanded: a file
# counts, a directory counts as every file under it that is tracked or untracked and not ignored
# (the files --changed reads), anything else not at all. A floor, not a proof: a file the suite
# reaches through a computed path is the map author's to list.
IFS= read -r -d '' DRIFT_AWK <<'AWK'
function expand(t,    pre, n, parts, i) {
  if (!match(t, /\{[^{}]*,[^{}]*\}/)) { print t; return }
  pre = substr(t, 1, RSTART - 1); n = split(substr(t, RSTART + 1, RLENGTH - 2), parts, ",")
  t = substr(t, RSTART + RLENGTH)
  for (i = 1; i <= n; i++) expand(pre parts[i] t)
}
{ s = " " $0
  while (match(s, /([[:space:]"'=(`:;|&<>]|(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\))\/)(dot_|\.scripts\/|\.chezmoi|tests\/)[]A-Za-z0-9_.\/{},*?[@+-]*/)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^([[:space:]"'=(`:;|&<>]|(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\))\/)/, "", t)
    sub(/[.,:;\/]+$/, "", t)
    expand(t)
  }
}
AWK
# Directories a heavy suite names without loading them whole; the map lists the files it loads.
# wt-functions names dot_local/bin as the root of the two wrappers it runs; git-forge-guard names
# dot_claude only in a command line it hands the guard.
DRIFT_PART_DIRS="git-forge-guard:dot_claude wt-functions:dot_local/bin"
# drift_loaded <root> <suite> <suite file>: the files the suite names, one per line; a directory
# git cannot list is printed itself, so it fails the check rather than counting as empty.
drift_loaded() {
  local p
  awk "$DRIFT_AWK" "$3" | while IFS= read -r p; do
    if [ -f "$1/$p" ]; then
      printf '%s\n' "$p"
    elif [ -d "$1/$p" ]; then
      case " $DRIFT_PART_DIRS " in *" $2:$p "*) continue ;; esac
      git -C "$1" ls-files -z --cached --others --exclude-standard -- "$p" 2>/dev/null | tr '\0' '\n' \
        | while IFS= read -r q; do if [ -f "$1/$q" ]; then printf '%s\n' "$q"; fi; done || printf '%s\n' "$p"
    fi
  done | LC_ALL=C sort -u
}
drift_check() {
  local f suite req rows loaded p out=
  for f in "$1"/tests/*.test.sh; do
    req=$(sed -n 's/^# test-requires: *//p' "$f" | head -1); req=${req%%  #*}
    [ "$req" = heavy ] || continue
    suite=$(basename "$f" .test.sh)
    rows=$(SUITE=$suite awk -F'\t' '/^#/ || $0 == "" { next }
      { n = split($4, l, ","); for (i = 1; i <= n; i++) if (l[i] == ENVIRON["SUITE"]) { print $1; break } }' "$1/$MAP")
    loaded=$(drift_loaded "$1" "$suite" "$f")
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case $'\n'"$rows"$'\n' in *$'\n'"$p"$'\n'*) ;; *) out="$out$suite: $p is loaded but has no subject-map row"$'\n' ;; esac
    done <<<"$loaded"
    while IFS= read -r p; do
      [ -z "$p" ] || [ -f "$1/$p" ] || out="$out$suite: subject-map row for $p names a missing file"$'\n'
    done <<<"$rows"
    [ -n "$rows" ] || out="$out$suite: no subject-map row"$'\n'
  done
  printf '%s' "$out"
  [ -z "$out" ]
}
# drifts <label> <want>: drift_check prints exactly want, and fails unless want is empty.
drifts() {
  local got rc want_rc=1
  got="$(drift_check "$R")"; rc=$?
  [ -n "$2" ] || want_rc=0
  if [ "$got" = "$2" ] && [ "$rc" = "$want_rc" ]; then _pass "$1"; else _fail "$1" "exit $rc: $(printf '%s' "$got" | tr '\n' '|')"; fi
}
names() { printf '%s\n' "$2" >> "$R/tests/$1.test.sh"; } # names <suite> <line>
# Bug caught: a file a heavy suite loads added without a row, so changing it never selects the suite.
reset_repo; mkdir -p "$R/dot_x"; echo b > "$R/dot_x/b.sh"
names heavya 'cat "$SRC/dot_x/b.sh"'
drifts "a file a heavy suite names with no row is reported" "heavya: dot_x/b.sh is loaded but has no subject-map row"
# Bug caught: a brace list read as one literal path, which never exists.
reset_repo; mkdir -p "$R/dot_x"; echo b > "$R/dot_x/b.sh"; echo c > "$R/dot_x/c.sh"; write_map "$(row dot_x/c.sh heavya)"
names heavya 'cat "$SRC/dot_x/{b,c}.sh"'
drifts "a file named through a brace list is reported" "heavya: dot_x/b.sh is loaded but has no subject-map row"
# Bug caught: a new file in a directory a heavy suite loads whole (a fixture tree) selecting nothing,
# committed or not yet; or an ignored file there (bytecode, say) failing the check.
reset_repo; mkdir -p "$R/dot_d/sub"; echo e > "$R/dot_d/sub/e.sh"; echo f > "$R/dot_d/f.sh"; echo 'dot_d/*.pyc' > "$R/.gitignore"
write_map "$(row dot_d/f.sh heavya)"; commit "a directory"
echo u > "$R/dot_d/u.sh"; echo x > "$R/dot_d/x.pyc"
names heavya 'cp -R "$SRC/dot_d" "$T/d"'
drifts "a tracked or untracked file under a directory a heavy suite names is reported, an ignored one not" \
  "$(printf '%s\n' 'heavya: dot_d/sub/e.sh is loaded but has no subject-map row' 'heavya: dot_d/u.sh is loaded but has no subject-map row')"
# Bug caught: a directory the check cannot list read as empty. The ceiling keeps git from finding a
# repository the temporary directory may sit in.
rm -rf "$R/.git"
GIT_CEILING_DIRECTORIES="$(cd "$T" && pwd -P)" drifts "a directory the check cannot list is reported" "heavya: dot_d is loaded but has no subject-map row"
# Bug caught: a tracked file deleted from the working tree still listed under its directory, so a
# row kept for it reads as missing and a row dropped for it as loaded without a row.
reset_repo; mkdir -p "$R/dot_d"; echo f > "$R/dot_d/f.sh"; echo g > "$R/dot_d/g.sh"
write_map "$(row dot_d/f.sh heavya)" "$(row dot_d/g.sh heavya)"; commit "two files"
rm "$R/dot_d/f.sh"
names heavya 'cp -R "$SRC/dot_d" "$T/d"'
drifts "a file deleted under a directory a heavy suite names is a stale row only" "heavya: subject-map row for dot_d/f.sh names a missing file"
drop_rows 1 dot_d/f.sh
drifts "and with its row dropped too nothing is reported" ""
# Bug caught: a row left behind for a file that was moved or deleted.
reset_repo; rm "$R/lib/a.sh"
drifts "a row naming a missing file is reported" "heavya: subject-map row for lib/a.sh names a missing file"
# Bug caught: a heavy suite the map does not mention, which every --changed run then selects; a path
# after a ${VAR}/ or $(…)/ root not read.
reset_repo; drop_rows 4 heavyb; mkdir -p "$R/dot_x"; echo b > "$R/dot_x/b.sh"; echo c > "$R/dot_x/c.sh"
names heavyb 'cat "${SRC}/dot_x/b.sh"'
names heavyb 'cat "$(cd x && pwd)/dot_x/c.sh"'
drifts "a heavy suite with no row is reported, with the files it names after any root" \
  "$(printf '%s\n' 'heavyb: dot_x/b.sh is loaded but has no subject-map row' 'heavyb: dot_x/c.sh is loaded but has no subject-map row' 'heavyb: no subject-map row')"
# Bug caught: a path that does not exist, or a suite that is not heavy, reported as drift.
reset_repo; mkdir -p "$R/dot_x"; echo b > "$R/dot_x/b.sh"; echo c > "$R/dot_x/c.sh"; write_map "$(row dot_x/b.sh heavya)"
names heavya 'cat "$SRC/dot_x/b.sh" "$SRC/dot_x/gone.sh"'
names plainc 'cat "$SRC/dot_x/c.sh"'
drifts "a fixture whose heavy suites' files all have rows passes" ""
got="$(drift_check "$SRC")"; rc=$?
if [ "$rc" = 0 ] && [ -z "$got" ]; then _pass "the subject map covers every file the heavy suites name"; else _fail "the subject map covers every file the heavy suites name" "exit $rc: $(printf '%s' "$got" | tr '\n' '|')"; fi
# Bug caught: a heavy tag the runner's parse does not read as exactly `heavy` (one space before the
# comment, say), which drops the suite from --changed and from the drift check. bad_heavy_tags
# <repo root> prints each such line, parsed as the runner parses it.
bad_heavy_tags() {
  local f line req
  for f in "$1"/tests/*.test.sh; do
    while IFS= read -r line; do
      req=${line#"# test-requires:"}; req=${req#"${req%%[! ]*}"}
      case "$req" in heavy*) ;; *) continue ;; esac
      req=${req%%  #*}
      [ "$req" = heavy ] || printf '%s: %s\n' "${f##*/}" "$line"
    done < <(grep '^# test-requires:' "$f")
  done
}
reset_repo; printf '#!/usr/bin/env bash\n%s: heavy # one space\n' "$tag" > "$R/tests/heavyb.test.sh"
got="$(bad_heavy_tags "$R")"
if [ "$got" = "heavyb.test.sh: $tag: heavy # one space" ]; then _pass "a heavy tag with one space before its comment is reported"; else _fail "a heavy tag with one space before its comment is reported" "$got"; fi
reset_repo
got="$(bad_heavy_tags "$R")"
if [ -z "$got" ]; then _pass "the fixture's heavy tags all parse as heavy"; else _fail "the fixture's heavy tags all parse as heavy" "$got"; fi
got="$(bad_heavy_tags "$SRC")"
if [ -z "$got" ]; then _pass "every heavy tag in the real suites parses as exactly heavy"; else _fail "every heavy tag in the real suites parses as exactly heavy" "$(printf '%s' "$got" | tr '\n' '|')"; fi
# Bug caught: a hand-edited row the runner reads as malformed, so every --changed run runs every
# heavy suite.
reset_repo; cp "$SUBJECTS" "$R/$MAP"
out="$(rr --changed)"
both "the runner reads the real subject map as well-formed" 'no subject-map row' "$out"
unset HOLDER_DONE
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
