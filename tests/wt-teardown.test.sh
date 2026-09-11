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
echo "D. the lsof scan refuses rather than reads empty"
cat > "$T/bin/lsof" <<'STUB'
#!/bin/sh
d="$(dirname "$0")"
if [ "$(cat "$d/mode" 2>/dev/null)" = raw ]; then
  cat "$d/raw"
  exit 0
fi
# A real `lsof -d cwd` is never empty — the caller has a cwd and so does launchd — and
# the subject refuses an empty listing rather than reading it as an idle checkout. A stub
# that emptied out once its fixture pids died would trip that refusal on every re-scan,
# so it carries the same baseline record a real listing always has.
printf 'p1\0claunchd\0fcwd\0n/\0'
while read -r pid cmd cwd; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  printf 'p%s\0c%s\0fcwd\0n%s\0' "$pid" "$cmd" "$cwd"
done < "$d/live"
STUB
cat > "$T/bin/ps" <<STUB
#!/bin/sh
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$$" ]; then echo 1; else echo $$; fi
STUB
chmod +x "$T/bin/lsof" "$T/bin/ps"
: > "$T/bin/live"; : > "$T/bin/raw"; echo live > "$T/bin/mode"
mk_raw()  { printf "$@" > "$T/bin/raw"; echo raw > "$T/bin/mode"; }
mk_live() { cat > "$T/bin/live"; echo live > "$T/bin/mode"; }
srun() { PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" zsh "$SUBJECT" "$@" 2>&1; }

mk_raw ''
out="$(srun --sweep ruby teardown)"; is "empty lsof output is refused" "$?" "1"
has "and says the list was unreadable" "$out" "lsof"
mk_raw 'p1\0cruby\0fcwd\0'
out="$(srun --sweep ruby teardown)"; is "a truncated record is refused" "$?" "1"
mk_raw 'p1\0cruby\0fcwd\0n\0'
out="$(srun --sweep ruby teardown)"; is "a bare n field is refused" "$?" "1"
mk_raw 'p1\0cruby\0ftxt\0n/x\0'
out="$(srun --sweep ruby teardown)"; is "a non-cwd descriptor is refused" "$?" "1"

echo
echo "E. matching is anchored at a directory boundary"
# A disposable process, NOT $$: the harness is an ancestor and would be skipped by the
# self-exclusion rule, so the anchoring this section exists to test would never run.
sibling="$(spawn command sleep 300)"
mk_live <<EOF
$sibling ruby $T/repo-feature-two
EOF
out="$(srun --sweep ruby teardown)"; is "a sibling suffix does not match" "$?" "0"
is "and nothing is reported stopped" "$(printf '%s' "$out" | grep -c stopping)" "0"
sleep 0.5
is "the sibling's process is untouched" "$(kill -0 "$sibling" 2>/dev/null; echo $?)" "0"
kill -9 "$sibling" 2>/dev/null

echo
echo "F. the sweep never kills its own chain"
# A DISPOSABLE ancestor, not $$. Using the harness itself cannot fail cleanly: the
# subject escalates to SIGKILL, which no trap survives, so a regression would take the
# runner down mid-suite instead of reporting. This stand-in registers itself in the
# listing and then runs the subject, so it is the subject's real parent — exactly the
# shape wt-rm produces, where the subshell that cd'd into the worktree is $PPID.
cat > "$T/parent.zsh" <<'PZ'
#!/usr/bin/env zsh
print -r -- "$$ zsh $WT_WORKTREE" > "$LIVE"
"$@"
rc=$?
print -r -- "PARENT_ALIVE"
exit $rc
PZ
chmod +x "$T/parent.zsh"
echo live > "$T/bin/mode"
out="$(PATH="$T/bin:/usr/bin:/bin" LIVE="$T/bin/live" WT_WORKTREE="$WT" \
  zsh "$T/parent.zsh" zsh "$SUBJECT" --sweep zsh teardown 2>&1)"
is "a --sweep zsh does not kill the subject's own parent" "$?" "0"
has "and the parent lived to say so" "$out" "PARENT_ALIVE"
is "the harness was never signalled" "$HARNESS_TERMED" "0"

echo
echo "G. TERM is sent to a swept process"
victim="$(spawn command sleep 300)"
mk_live <<EOF
$victim sleep $WT
EOF
out="$(srun --sweep sleep teardown)"
is "the sweep exits clean" "$?" "0"
sleep 1
is "the swept process is gone" "$(kill -0 "$victim" 2>/dev/null; echo $?)" "1"
has "and it is reported" "$out" "sleep"

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
