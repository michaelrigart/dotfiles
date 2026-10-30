#!/usr/bin/env bash
# Tests for tests/run.sh's requirement gate: a suite tagged `# test-requires:` runs only
# when named exactly or with --all. A substring filter must still skip it.
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
printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
