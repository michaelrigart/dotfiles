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

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
