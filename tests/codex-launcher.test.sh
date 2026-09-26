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
done

echo "E. --remote is refused for an interactive start"
out="$(run --remote ws://h:1)"; rc=$?
is "--remote <addr> is refused" "$rc" 2
is "and says herdr cannot map it" "$(grep -c 'herdr' "$T/err")" 1
out="$(run --remote=ws://h:1)"; rc=$?
is "--remote=<addr> is refused" "$rc" 2

echo "F. explicit --no-daemon and non-interactive commands pass straight through"
is "--no-daemon passes through"          "$(run --no-daemon)" "REAL --no-daemon"
is "without touching the daemon"         "$(ensured)" 0
is "--no-daemon keeps its overrides"     "$(run --no-daemon -c k=v)" "REAL --no-daemon -c k=v"
is "exec passes through"                 "$(run exec 'do x')" "REAL exec do x"
is "exec keeps its -c overrides"         "$(run -c k=v exec foo)" "REAL -c k=v exec foo"
is "app-server passes through"           "$(run app-server daemon version)" "REAL app-server daemon version"
is "and none of them ensured the daemon" "$(ensured)" 0
is "--help passes through"               "$(run --help)" "REAL --help"
is "--version passes through"            "$(run --version)" "REAL --version"

echo "G. no real binary is an error, never a loop"
printf '#!/bin/sh\nexit 1\n' > "$T/localbin/codex-daemon"; chmod +x "$T/localbin/codex-daemon"
run >/dev/null; is "the launcher exits 127" "$?" 127

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
