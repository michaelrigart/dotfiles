#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="$ROOT/dot_local/bin/executable_wt-teardown"

pass=0; fail=0
_pass() { echo "  ok  $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1 (got '$2', want '$3')"; fi; }
has() {
  if printf '%s' "$2" | grep -q -- "$3"; then _pass "$1"
  else _fail "$1 (output did not contain '$3': $2)"; fi
}

if [ ! -r "$SUBJECT" ]; then
  echo "FATAL: $SUBJECT not found — every assertion below would pass vacuously." >&2
  echo "RESULT: 0 passed, 1 total, 1 failed"
  exit 2
fi

# A regression in self-exclusion sends TERM to this very process. Trapping it turns
# "the runner dies mid-suite" into an ordinary assertion, so the failure is legible
# instead of arriving as a truncated run.
HARNESS_TERMED=0
trap 'HARNESS_TERMED=1' TERM

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-teardown-test.XXXXXX")"
# Fully resolved: the subject does ${WT_WORKTREE:A} and lsof reports real paths, so a
# fixture holding the /var symlink would never match and every behavioural case would
# pass vacuously.
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
WT="$T/repo-feature"
mkdir -p "$WT/tmp/pids" "$T/bin"

run() { WT_WORKTREE="$WT" zsh "$SUBJECT" "$@" 2>&1; }

# spawn <cmd...> — start a process DETACHED and print its pid.
#
# Not `cmd & pid=$!`: a killed child of this shell stays a zombie until bash reaps it,
# and a zombie still answers kill -0. The stub would then report a process the subject
# had already stopped, and every behavioural case would fail on a phantom survivor.
# Real lsof never reports a zombie — it has no cwd. Reparenting to launchd, which reaps
# immediately, is what makes the stub agree with the thing it stands in for.
spawn() { ( "$@" >/dev/null 2>&1 & echo $! ); }

echo "A. verbs"
out="$(run setup)"; is "setup is an accepted no-op" "$?" "0"
is "setup prints nothing" "$out" ""
out="$(run bogus)"; is "an unknown verb exits 64" "$?" "64"
has "and names the usage" "$out" "setup|teardown"
out="$(run)"; is "no verb exits 64" "$?" "64"

echo
echo "B. flags"
out="$(run --pidfile 2>&1)"; is "--pidfile without a value exits 64" "$?" "64"
out="$(run --sweep 2>&1)"; is "--sweep without a value exits 64" "$?" "64"
out="$(run --nonsense teardown 2>&1)"; is "an unknown flag exits 64" "$?" "64"

echo
echo "C. environment"
out="$(WT_WORKTREE= zsh "$SUBJECT" teardown 2>&1)"
is "an unset WT_WORKTREE is an error" "$?" "1"
has "and says so" "$out" "WT_WORKTREE"
out="$(WT_WORKTREE=relative/path zsh "$SUBJECT" teardown 2>&1)"
is "a relative WT_WORKTREE is an error" "$?" "1"
out="$(WT_WORKTREE="$T/does-not-exist" zsh "$SUBJECT" teardown 2>&1)"
is "a nonexistent WT_WORKTREE is an error" "$?" "1"

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
