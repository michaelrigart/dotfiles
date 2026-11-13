#!/usr/bin/env bash
# Tests for tests/run.sh: the requirement gate (a suite tagged `# test-requires:` runs only
# when named exactly or with --all; a substring filter must still skip it), the parallel
# run, the serial tag and the per-machine lock.
#
# Runs a COPY of run.sh in a temp directory holding two fake suites, so nothing here
# executes a real suite (and nothing recurses into this one).
#
#   ./tests/run.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$SRC/tests/run.sh"
[ -f "$RUN" ] || { echo "missing script under test: $RUN" >&2; exit 2; }
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
unset HOLDER_DONE
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
