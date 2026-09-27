#!/usr/bin/env bash
# Tests dot_local/bin/executable_codex, the launcher that makes every interactive Codex
# start attach to the shared daemon (spec section 5). codex-daemon is stubbed, so each
# case asserts only the launcher's own classification: which starts need the daemon,
# which are refused, and which pass straight through.
#
# Run: ./tests/run.sh codex-launcher   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/dot_local/bin/executable_codex"
[ -f "$L" ] || { echo "missing file under test: $L" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/codex-launcher.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/localbin" "$T/brew"
export CALLS="$T/calls" REALBIN="$T/brew/codex"
cp "$L" "$T/localbin/codex"
printf '#!/bin/sh\necho "REAL $*"\n' > "$T/brew/codex"
cat > "$T/localbin/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  real-bin) echo "$REALBIN" ;;
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: the daemon carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
chmod +x "$T/localbin/codex" "$T/brew/codex" "$T/localbin/codex-daemon"

run() { : > "$CALLS"; PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" "$@" 2>"$T/err"; }
# run_acc: like run, but never truncates $CALLS - for asserting across several invocations
# that none of them ever touched the daemon.
run_acc() { PATH="$T/localbin:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" "$@" 2>"$T/err"; }
ensured() { grep -c 'codex-daemon ensure' "$CALLS"; }

echo "A. interactive starts attach to the daemon"
is "a bare start execs the real binary"          "$(run)" "REAL "
is "after ensuring the daemon"                   "$(ensured)" 1
is "resume is interactive"                       "$(run resume abc)" "REAL resume abc"
is "and ensures the daemon"                      "$(ensured)" 1
is "fork is interactive"                         "$(run fork)" "REAL fork"
is "a prompt argument is interactive"            "$(run 'fix the tests')" "REAL fix the tests"
is "option values are not mistaken for commands" "$(run -m exec resume x)" "REAL -m exec resume x"
is "and that start ensures the daemon"           "$(ensured)" 1
is "the pane command's own flags are allowed"    "$(run --sandbox read-only --ask-for-approval never)" "REAL --sandbox read-only --ask-for-approval never"

echo "B. a daemon that cannot start refuses the session"
out="$(ENSURE_RC=1 run)"; rc=$?
is "the start is refused"        "$rc" 1
is "and the real binary never runs" "$out" ""

echo "C. a contaminated daemon warns but does not block"
out="$(CHECK_RC=1 run)"; rc=$?
is "the session still starts"    "$out" "REAL "
is "with a warning"              "$(grep -c 'starting anyway' "$T/err")" 1

echo "D. overrides that would leave the daemon are refused"
for args in "-c model=x" "--config=model=x" "--enable foo" "--disable=foo" "resume -c k=v id"; do
  # shellcheck disable=SC2086
  out="$(run $args)"; rc=$?
  is "'$args' is refused"        "$rc" 2
  is "'$args' names --no-daemon" "$(grep -c -- '--no-daemon' "$T/err")" 1
  is "'$args' never starts"      "$out" ""
  is "'$args' never touches the daemon" "$(ensured)" 0
done

echo "E. --remote is refused for an interactive start"
out="$(run --remote ws://h:1)"; rc=$?
is "--remote <addr> is refused" "$rc" 2
is "and says herdr cannot map it" "$(grep -c 'herdr' "$T/err")" 1
is "and never touches the daemon" "$(ensured)" 0
out="$(run --remote=ws://h:1)"; rc=$?
is "--remote=<addr> is refused" "$rc" 2
is "and never touches the daemon either" "$(ensured)" 0

echo "F. explicit --no-daemon and non-interactive commands pass straight through"
: > "$CALLS"
is "--no-daemon passes through"          "$(run_acc --no-daemon)" "REAL --no-daemon"
is "--no-daemon keeps its overrides"     "$(run_acc --no-daemon -c k=v)" "REAL --no-daemon -c k=v"
is "exec passes through"                 "$(run_acc exec 'do x')" "REAL exec do x"
is "exec keeps its -c overrides"         "$(run_acc -c k=v exec foo)" "REAL -c k=v exec foo"
is "app-server passes through"           "$(run_acc app-server daemon version)" "REAL app-server daemon version"
is "--help passes through"               "$(run_acc --help)" "REAL --help"
is "--version passes through"            "$(run_acc --version)" "REAL --version"
is "e passes through"                    "$(run_acc e 'do x')" "REAL e do x"
is "review passes through"               "$(run_acc review)" "REAL review"
is "mcp passes through"                  "$(run_acc mcp)" "REAL mcp"
is "and NONE of section F ever ensured the daemon" "$(ensured)" 0

echo "G. no real binary is an error, never a loop"
printf '#!/bin/sh\nexit 1\n' > "$T/localbin/codex-daemon"; chmod +x "$T/localbin/codex-daemon"
run >/dev/null; is "the launcher exits 127" "$?" 127
is "and prints the real-codex message, not the helper's own"    "$(grep -c 'no real codex on PATH outside' "$T/err")" 1
is "the helper's own stderr is not echoed"                       "$(grep -c 'codex-daemon:' "$T/err")" 0
rm -f "$T/localbin/codex-daemon"
run >/dev/null; is "a missing helper (not just a failing one) is also 127" "$?" 127
is "and says the helper itself is missing" "$(grep -c 'codex-daemon helper is not' "$T/err")" 1
cat > "$T/localbin/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  real-bin) echo "$REALBIN" ;;
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: the daemon carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
chmod +x "$T/localbin/codex-daemon"

echo "H. -- ends option/subcommand parsing; everything after it is a prompt"
is "'-- exec' is interactive, not the exec subcommand" "$(run -- exec)" "REAL -- exec"
is "and it ensures the daemon"                         "$(ensured)" 1
out="$(run -- '-c is wrong')"; rc=$?
is "'-- -c is wrong' is interactive, not refused"      "$rc" 0
is "and it is not treated as an override"              "$(ensured)" 1

echo "I. a help/version flag anywhere before -- passes through untouched"
is "'resume --help' passes through"        "$(run resume --help)" "REAL resume --help"
is "and never touches the daemon"          "$(ensured)" 0
out="$(run --remote ws://h:1 --help)"; rc=$?
is "'--remote ws://h:1 --help' passes through, not refused" "$out" "REAL --remote ws://h:1 --help"
is "and is not refused"                    "$rc" 0

echo "J. the helper resolves beside the launcher first, then on PATH"
mkdir -p "$T/other"
mv "$T/localbin/codex-daemon" "$T/other/codex-daemon"
out="$(PATH="$T/localbin:$T/other:/usr/bin:/bin" XDG_BIN_HOME="$T/localbin" sh "$T/localbin/codex" 2>"$T/err")"
is "PATH is the fallback when no helper sits beside the launcher" "$out" "REAL "
mv "$T/other/codex-daemon" "$T/localbin/codex-daemon"

echo "K. agents needs the daemon like an interactive start"
: > "$CALLS"
is "agents attaches to the daemon"  "$(run agents)" "REAL agents"
is "and ensures it first"           "$(ensured)" 1

echo "L. -i/--image takes several values, mirroring clap"
: > "$CALLS"
is "-i consumes every value up to the next flag" \
   "$(run -i a.png b.png --sandbox read-only foo)" "REAL -i a.png b.png --sandbox read-only foo"
# Mirroring clap's own footgun: -i swallows every bare token after it, even one that looks
# like a subcommand, up to the next flag or end of args. It is still passed through
# untouched, and the bare start still ensures the daemon regardless.
is "a bare word after -i is swallowed as an image value, not misread as a flag" \
   "$(run -i a.png resume xyz)" "REAL -i a.png resume xyz"
is "and it still ensures the daemon (an unrecognised bare start is still interactive)" \
   "$(ensured)" 1

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
