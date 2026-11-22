#!/usr/bin/env bash
# Test for .scripts/machine-check.sh: the marks and summary, machine scoping, --todo, the
# environment a verify command sees, the timeout, the default machine, and a malformed list.
# The script is copied into a temporary tree with a fixture checklist and machines.toml, so no
# verify command of the real checklist runs. Run: ./tests/machine-check.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0; OUT=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) _pass "$2";; *) _fail "$2";; esac; }
hasnt(){ case "$OUT" in *"$1"*) _fail "$2";; *) _pass "$2";; esac; }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }
line_is(){ if printf '%s\n' "$OUT" | grep -qxF -- "$1"; then _pass "$2"; else _fail "$2"; fi; }

[ -f "$SRC/.scripts/machine-check.sh" ] || { echo "MISSING SUBJECT: .scripts/machine-check.sh"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/mchecktest.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
[ -n "$T" ] && [ -d "$T" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
case "$T" in "$HOME"|"$HOME"/*) echo "REFUSING: temp root is inside the real HOME"; exit 2;; esac
mkdir -p "$T"/{bin,home,src/.chezmoidata,src/.scripts}
cp "$SRC/.scripts/machine-check.sh" "$T/src/.scripts/machine-check.sh"
chmod 755 "$T/src/.scripts/machine-check.sh"
SCRIPT="$T/src/.scripts/machine-check.sh"
LIST="$T/src/.scripts/machine-checklist.tsv"
printf 'known_hostnames = ["alpha", "beta"]\nresearch_host = "alpha"\n' > "$T/src/.chezmoidata/machines.toml"

cat > "$T/bin/scutil" <<'S'
#!/usr/bin/env bash
[ "$1" = --get ] && [ "$2" = ComputerName ] && cat "$SCUTIL_NAME_FILE" 2>/dev/null
exit 0
S
chmod 755 "$T/bin/scutil"
export SCUTIL_NAME_FILE="$T/computername"
echo alpha > "$SCUTIL_NAME_FILE"

# row id machines by step verify: one tab-separated line.
row(){ printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
# run [args]: the script with a stray exported variable, stdin from /dev/null.
run(){ OUT=$(env PATH="$T/bin:$PATH" HOME="$T/home" LEAKME=leaked "$SCRIPT" "$@" </dev/null 2>&1); RC=$?; }

echo "== marks and summary"
{
  row ok-one all script "Step one" true
  row bad-one all script "Step two" false
  row you-one all you "Step three" -
  row ok-two all you "Step four" true
} > "$LIST"
run --machine alpha
rc_is 1 "a failing row exits 1"
line_is "✓ ok-one" "a true row prints a tick and its id"
line_is "✗ bad-one: Step two" "a false row prints a cross, its id and its step"
line_is "· you-one: Step three" "a '-' row prints a dot, its id and its step"
line_is "2 done, 1 to do, 1 without a check" "the summary counts done, to do and no check"
{ row ok-one all script "Step one" true; row you-one all you "Step three" -; } > "$LIST"
run --machine alpha
rc_is 0 "no failing row exits 0, a no-check row included"
line_is "1 done, 0 to do, 1 without a check" "the summary of a list with no cross"

echo "== scoping"
{
  row r-all all script "All" true
  row r-alpha alpha script "Alpha" true
  row r-beta beta script "Beta" true
  row r-research research_host script "Research" true
} > "$LIST"
run --machine alpha
has "r-all" "alpha: an 'all' row runs"
has "r-alpha" "alpha: its own row runs"
has "r-research" "alpha is the research host: that row runs"
hasnt "r-beta" "alpha: a beta row does not appear"
line_is "3 done, 0 to do, 0 without a check" "alpha: the summary counts only its rows"
run --machine beta
has "r-all" "beta: an 'all' row runs"
has "r-beta" "beta: its own row runs"
hasnt "r-research" "beta is not the research host: that row does not appear"
hasnt "r-alpha" "beta: an alpha row does not appear"

echo "== --todo"
{
  row ok-one all script "Done thing" true
  row bad-one all script "Broken thing" false
  row you-one all you "Manual thing" -
  row bad-beta beta script "Not here" false
  row bad-two alpha you "Second broken" false
} > "$LIST"
run --machine alpha --todo
rc_is 1 "--todo with a cross exits 1"
line_is "Still to do on alpha:" "--todo prints its header"
line_is "  1. Broken thing [bad-one]" "--todo numbers a cross row and ends it with its id"
line_is "  2. Manual thing [you-one] (no check)" "--todo marks a no-check row"
line_is "  3. Second broken [bad-two]" "--todo numbers in file order"
hasnt "Done thing" "--todo hides a passing row"
hasnt "Not here" "--todo hides another machine's row"
hasnt "done," "--todo prints no summary"
{ row ok-one all script "Done thing" true; row other beta script "Not here" false; } > "$LIST"
run --machine alpha --todo
rc_is 0 "--todo with nothing open exits 0"
line_is "Nothing left to do on alpha." "--todo with nothing open says so"
hasnt "Still to do" "--todo with nothing open prints no header"

echo "== the environment of a verify"
ENVOUT="$T/src/env.out"
{
  row env-check all script "Env" 'env > "$DOTFILES/env.out"'
  row stdin-check all script "Stdin" '! read x'
} > "$LIST"
rm -f "$ENVOUT"
# stdin carries data here: a verify that inherited it would read it and fail.
OUT=$(printf 'data\n' | env PATH="$T/bin:$PATH" HOME="$T/home" LEAKME=leaked "$SCRIPT" --machine alpha 2>&1); RC=$?
rc_is 0 "the env row and the stdin row pass"
line_is "✓ stdin-check" "stdin is /dev/null: read fails at once"
if [ -f "$ENVOUT" ]; then
  seen(){ grep -qxF -- "$1" "$ENVOUT" && _pass "verify sees $1" || _fail "verify sees $1"; }
  seen "MACHINE=alpha"
  seen "DOTFILES=$T/src"
  seen "KNOWN_HOSTNAMES=alpha beta"
  seen "USER=$(id -un)"
  seen "LOGNAME=$(id -un)"
  seen "HOME=$T/home"
  seen "XDG_CONFIG_HOME=$T/home/.config"
  seen "XDG_DATA_HOME=$T/home/.local/share"
  seen "XDG_CACHE_HOME=$T/home/.cache"
  seen "XDG_STATE_HOME=$T/home/.local/state"
  seen "PATH=$T/home/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  grep -q LEAKME "$ENVOUT" && _fail "a caller's exported variable does not reach the verify" \
    || _pass "a caller's exported variable does not reach the verify"
else
  _fail "the env row wrote its environment"
fi

echo "== timeout"
{ row hangs all script "Hangs" 'sleep 10'; row fine all script "Fine" true; } > "$LIST"
SECONDS=0
OUT=$(env PATH="$T/bin:$PATH" HOME="$T/home" MACHINE_CHECK_TIMEOUT=2 "$SCRIPT" --machine alpha </dev/null 2>&1); RC=$?
took=$SECONDS
line_is "✗ hangs: Hangs" "a hanging verify is a cross"
line_is "✓ fine" "the next row still runs"
[ "$took" -lt 5 ] && _pass "the hang was cut within 5 s (took ${took} s)" || _fail "the hang was cut within 5 s (took ${took} s)"
rc_is 1 "a timeout exits 1"

echo "== the machine"
row ok-one all script "One" true > "$LIST"
echo beta > "$SCUTIL_NAME_FILE"
run --todo
line_is "Nothing left to do on beta." "the machine defaults to ComputerName"
echo gamma > "$SCUTIL_NAME_FILE"
run
rc_is 2 "an unknown ComputerName exits 2"
has "alpha" "and names the known machines (alpha)"
has "beta" "and names the known machines (beta)"
run --machine delta
rc_is 2 "an unknown --machine exits 2"
run --machine
rc_is 2 "--machine without a value exits 2"
run --nonsense
rc_is 2 "an unknown option exits 2"
echo alpha > "$SCUTIL_NAME_FILE"

echo "== a malformed list"
MARK="$T/ran"
bad(){ # bad <description> <expected line number> <expected problem> <the bad row>
  { row first all script "First" "touch '$MARK'"; printf '%s\n' "$4"; } > "$LIST"
  rm -f "$MARK"
  run --machine alpha
  rc_is 2 "$1: exit 2"
  has "machine-check: $LIST:$2: $3" "$1: names the file, line and problem"
  [ -e "$MARK" ] && _fail "$1: nothing ran before the list was valid" || _pass "$1: nothing ran before the list was valid"
}
bad "four fields" 2 "expected 5 tab-separated fields" "$(printf 'x1\tall\tscript\tStep')"
bad "six fields" 2 "expected 5 tab-separated fields" "$(printf 'x1\tall\tscript\tStep\ttrue\textra')"
bad "by not script or you" 2 "by must be script or you" "$(row x1 all robot Step true)"
bad "machines not known" 2 "machines must be all, research_host or a known machine" "$(row x1 gamma script Step true)"
bad "a duplicate id" 2 "duplicate id first" "$(row first all script Step true)"
bad "an id with a capital" 2 "id must match [a-z0-9-]+" "$(row Bad_Id all script Step true)"
bad "an empty verify" 2 "empty verify" "$(printf 'x1\tall\tscript\tStep\t')"
bad "'-' on a script row" 2 "a script row needs a verify command" "$(row x1 all script Step -)"
{ printf '# a comment\n\n'; row ok-one all you "Fine" -; printf '\n'; } > "$LIST"
run --machine alpha
rc_is 0 "comments and blank lines are skipped"
rm -f "$LIST"
run --machine alpha
rc_is 2 "a missing checklist exits 2"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
