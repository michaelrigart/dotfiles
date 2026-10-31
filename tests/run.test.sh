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
out="$("$T/run.sh" gated 2>&1)"
ran "a prefix of the name keeps the gate"        no  'ok +gated-alpha' "$out"
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

# Locking. hold <tenths> takes the lock in the background, waits until it is held, and
# releases it after that long or when $T/release appears.
hold() {
  rm -f "$T/release" "$T/holder.done"
  lockf -k "$L" sh -c 'i=0; while [ ! -e "$1/release" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done; touch "$1/holder.done"' sh "$T" "$1" &
  holder=$!
  local i=0
  while lockf -k -t 0 "$L" true 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
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
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
