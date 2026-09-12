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

# Exact equality, never substring: --sweep sleep must not select `sleepy`. A substring
# match would quietly widen every declaration a project makes.
near="$(spawn command sleep 300)"
mk_live <<EOF
$near sleepy $WT
EOF
out="$(srun --sweep sleep teardown)"
# It refuses BECAUSE it did not sweep it: an occupant no declaration covers is left
# alone and reported, which is what surfaces as wt-rm's check-4 refusal one step later.
is "an uncovered occupant makes teardown refuse" "$?" "1"
sleep 0.5
is "and that process is untouched" "$(kill -0 "$near" 2>/dev/null; echo $?)" "0"
kill -9 "$near" 2>/dev/null

echo
echo "H. a process ignoring TERM is escalated to KILL"
cat > "$T/deaf.sh" <<'DEAF'
#!/bin/sh
trap '' TERM
# Written only once the trap is installed: waiting on this is what makes the fixture
# genuinely TERM-proof before the subject runs. A plain sleep here is a race, and losing
# it means the process dies on TERM and escalation is never exercised at all.
: > "$1"
while :; do sleep 1; done
DEAF
chmod +x "$T/deaf.sh"
rm -f "$T/deaf.ready"
deaf="$(spawn "$T/deaf.sh" "$T/deaf.ready")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/deaf.ready" ] && break; sleep 0.2; done
is "the deaf fixture installed its TERM trap" "$([ -e "$T/deaf.ready" ] && echo yes || echo no)" "yes"
mk_live <<EOF
$deaf deaf.sh $WT
EOF
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=3 \
  zsh "$SUBJECT" --sweep deaf.sh teardown 2>&1)"
is "escalation exits clean" "$?" "0"
sleep 1
is "the deaf process was killed" "$(kill -0 "$deaf" 2>/dev/null; echo $?)" "1"

echo
echo "I. a survivor is an error, not a shrug"
ghost="$(spawn command sleep 300)"
mk_raw 'p%s\0cimmortal\0fcwd\0n%s\0' "$ghost" "$WT"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=1 \
  zsh "$SUBJECT" --sweep immortal teardown 2>&1)"
is "a surviving target exits nonzero" "$?" "1"
has "and names what is still there" "$out" "still"
kill -9 "$ghost" 2>/dev/null

echo
echo "J. a pidfile is not a licence to signal"
bystander="$(spawn command sleep 300)"
echo "$bystander" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$$ zsh $T/elsewhere
EOF
out="$(srun --pidfile tmp/pids/server.pid teardown)"
is "a stale pidfile exits clean" "$?" "0"
sleep 1
is "the unrelated process was NOT signalled" "$(kill -0 "$bystander" 2>/dev/null; echo $?)" "0"
is "and the stale pidfile was cleared" "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "gone"
kill -9 "$bystander" 2>/dev/null

echo
echo "K. a verified pidfile is stopped and its file removed"
owned="$(spawn command sleep 300)"
echo "$owned" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$owned sleep $WT
EOF
out="$(srun --pidfile tmp/pids/server.pid teardown)"
is "a verified pidfile exits clean" "$?" "0"
sleep 1
is "its process is gone" "$(kill -0 "$owned" 2>/dev/null; echo $?)" "1"
is "and the pidfile is removed" "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "gone"

echo
echo "L. pidfile paths are contained"
mkdir -p "$T/outside"
echo 99999 > "$T/outside/server.pid"
mk_live <<EOF
$$ zsh $T/elsewhere
EOF
out="$(srun --pidfile ../outside/server.pid teardown)"
is "a relative escape is refused" "$?" "1"
out="$(srun --pidfile /etc/passwd teardown)"
is "an absolute path is refused" "$?" "1"
rm -rf "$WT/tmp/pids/link"; ln -s "$T/outside" "$WT/tmp/pids/link"
out="$(srun --pidfile tmp/pids/link/server.pid teardown)"
is "a symlinked escape is refused" "$?" "1"
rm -f "$WT/tmp/pids/link"

echo
echo "M. pidfile contents are validated"
for bad in "" "not-a-number" "0" "1" "-5"; do
  printf '%s' "$bad" > "$WT/tmp/pids/server.pid"
  out="$(srun --pidfile tmp/pids/server.pid teardown)"
  is "a pidfile containing '$bad' is refused" "$?" "1"
done
rm -f "$WT/tmp/pids/server.pid"
out="$(srun --pidfile tmp/pids/server.pid teardown)"
is "an absent pidfile is not an error" "$?" "0"

echo
echo "N. teardown is idempotent"
twice="$(spawn command sleep 300)"
echo "$twice" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$twice sleep $WT
EOF
out="$(srun --pidfile tmp/pids/server.pid --sweep sleep teardown)"
is "first run exits clean" "$?" "0"
sleep 1
mk_live <<EOF
$$ zsh $T/elsewhere
EOF
out="$(srun --pidfile tmp/pids/server.pid --sweep sleep teardown)"
is "second run exits clean" "$?" "0"
out="$(srun --pidfile tmp/pids/server.pid --sweep sleep teardown)"
is "third run exits clean" "$?" "0"

echo
echo "O. a declaration that matches nothing is not an error"
out="$(srun --sweep nothing-runs-by-this-name teardown)"
is "an unmatched sweep exits clean" "$?" "0"
out="$(srun teardown)"
is "no declarations at all exits clean" "$?" "0"

echo
echo "P. the scan does not report its own helpers"
# Regression. _scan's lsof runs in a command substitution, which forks a subshell that inherits
# cwd and then execs lsof. wt-rm invokes the hook with cwd INSIDE the worktree, so before the fix
# that subshell and lsof were occupants of the very directory being retired, and the
# post-teardown re-scan reported them as survivors — every time, on a real system, while every
# stubbed case passed. A stub reports only its fixture, never the process that ran it, so this
# case deliberately uses the real lsof against an empty directory nothing else is in.
SELFDIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wt-teardown-self.XXXXXX")" && pwd -P)"
out="$(cd "$SELFDIR" && WT_WORKTREE="$SELFDIR" zsh "$SUBJECT" teardown 2>&1)"
is "a scan from inside the target does not flag itself" "$?" "0"
is "and reports no survivors" "$(printf '%s' "$out" | grep -c 'still in')" "0"
rm -rf "$SELFDIR"

echo
echo "Q. a failed stop keeps its evidence"
# Spec 5.2. The retry wt-rm recommends is the only route left to target a declared supervisor
# again, and it finds that supervisor through the pidfile — so deleting the pidfile after a
# stop that did not work strands the process permanently for any project that declares a
# pidfile and no sweep. Both wait budgets are set to 0, which makes _stop return 1 without
# waiting: the deterministic way to exercise the failed-stop branch.
stubborn="$(spawn command sleep 400)"
echo "$stubborn" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$stubborn sleep $WT
EOF
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=0 WT_TEARDOWN_KILL_WAIT=0 \
  zsh "$SUBJECT" --pidfile tmp/pids/server.pid teardown 2>&1)"
is "the pidfile survives a stop that reported failure" \
  "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "present"
kill -9 "$stubborn" 2>/dev/null
rm -f "$WT/tmp/pids/server.pid"

# And the ordinary case still clears it, so the gate did not simply disable removal.
cleanly="$(spawn command sleep 400)"
echo "$cleanly" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$cleanly sleep $WT
EOF
out="$(srun --pidfile tmp/pids/server.pid teardown)"
is "a successful stop still clears it" \
  "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "gone"

echo
echo "R. one process is reported stopped once"
# curato declares both --pidfile and --sweep ruby, and its rails server satisfies both. The
# transcript is the deliverable (spec 5.5), so one process must produce one line.
both="$(spawn command sleep 400)"
echo "$both" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$both sleep $WT
EOF
out="$(srun --pidfile tmp/pids/server.pid --sweep sleep teardown)"
is "a doubly-declared process exits clean" "$?" "0"
is "and is reported exactly once" "$(printf '%s' "$out" | grep -c stopping)" "1"

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
