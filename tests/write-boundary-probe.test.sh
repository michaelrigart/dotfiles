#!/usr/bin/env bash
# Tests for the chezmoi_top_git_module_hooks probe and the failed_keys line of
# tests/live-write-boundary.test.sh, without measuring a sandbox.
#
# The suite runs against a throwaway HOME in TMPDIR, with a mkdir stub in front of PATH that
# refuses to create the checkout's .git/modules with a chosen message. Every other key in that
# run is meaningless (nothing is denied in a throwaway HOME), so only the one key and the
# failed_keys line are judged. Running it sandboxed is fine and expected; the sandbox is
# never turned off.
#
#   ./tests/write-boundary-probe.test.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$SRC/tests/live-write-boundary.test.sh"
[ -f "$SUITE" ] || { echo "missing script under test: $SUITE" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wbprobe.XXXXXX")" && pwd -P)"
trap 'rm -rf "$T"' EXIT
H="$T/home"
cz="$H/.local/share/chezmoi"
mkdir -p "$T/bin" "$T/tmp" "$T/start" "$cz"
# The checkout, a real repository so the harness-worktree case has a common directory to compare.
git init -q -b main "$cz" \
  && git -C "$cz" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
  && git -C "$cz" worktree add -q "$T/wt" -b wt \
  || { echo "INCONCLUSIVE: could not build the checkout fixture" >&2; exit 2; }
cat > "$T/bin/mkdir" <<'STUB'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    */chezmoi/.git/modules|*/chezmoi/.git/modules/*) printf 'mkdir: %s: %s\n' "$a" "$STUB_MSG" >&2; exit 1 ;;
  esac
done
exec /bin/mkdir "$@"
STUB
chmod 755 "$T/bin/mkdir"

# run_suite <stub message> <session start dir>: the suite's output, with the stub refusing as told.
run_suite() {
  HOME="$H" TMPDIR="$T/tmp" RUN_SH_START_DIR="$2" STUB_MSG="$1" PATH="$T/bin:$PATH" "$SUITE" 2>&1
}
key=chezmoi_top_git_module_hooks
# verdict <output> <expected value>
verdict() {
  local want=$2 got
  got=$(printf '%s\n' "$1" | sed -n "s/^$key=//p")
  if [ "$got" = "$want" ]; then _pass "$3"; else _fail "$3" "$key=${got:-<none>}, wanted $want"; fi
}
# listed <output> <yes|no>: whether the closing failed_keys line names the key.
listed() {
  local got=no
  printf '%s\n' "$1" | grep -E '^failed_keys=' | tail -n 1 | tr ',=' '\n\n' | grep -qx "$key" && got=yes
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$(printf '%s\n' "$1" | grep -E '^failed_keys=' | tail -n 1)"; fi
}

out=$(run_suite "Operation not permitted" "$T/start")
verdict "$out" DENIED "a sandbox refusal to create .git/modules reads DENIED"
listed  "$out" no     "and a DENIED probe is not listed in failed_keys"
out=$(run_suite "No such file or directory" "$T/start")
verdict "$out" ABSENT "a missing parent reads ABSENT"
listed  "$out" yes    "and an ABSENT probe is listed in failed_keys"
out=$(run_suite "Read-only file system" "$T/start")
verdict "$out" ABSENT "any other mkdir error reads ABSENT"
listed  "$out" yes    "and is listed in failed_keys"
out=$(run_suite "Operation not permitted" "$cz")
verdict "$out" SKIPPED "a session in the checkout itself still reads SKIPPED"
listed  "$out" no      "and a SKIPPED probe is not listed in failed_keys"
out=$(run_suite "Operation not permitted" "$T/wt")
verdict "$out" SKIPPED "a harness worktree of the checkout still reads SKIPPED"

# The closing line is the last thing printed, and the exit status is the failure count.
out=$(run_suite "No such file or directory" "$T/start"); rc=$?
last=$(printf '%s\n' "$out" | tail -n 1)
case "$last" in failed_keys=*) _pass "failed_keys is the last line of a failing run" ;; *) _fail "failed_keys is the last line of a failing run" "$last" ;; esac
n=$(printf '%s\n' "$last" | sed 's/^failed_keys=//' | tr ',' '\n' | grep -c .)
if [ "$rc" -eq "$n" ]; then _pass "the exit status equals the number of failed keys"; else _fail "the exit status equals the number of failed keys" "exit $rc, keys $n"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
