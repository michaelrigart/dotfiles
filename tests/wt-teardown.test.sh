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
# The stub serves two masters: controlled occupancy from the fixtures below, AND truthful
# ancestry for the subject's own real process chain, so sections asserting "the parent is
# not killed" (section F) still mean something. It runs real lsof for every live-mode call,
# drops any record whose pid the fixture also names — a pid must never be reported twice
# with two different cwds — and appends the fixture's own records after it, each synthesised
# to the subject's new 5-field shape with a ppid of 1: fixture processes are detached, so
# their ancestry is irrelevant to what these sections test. Raw mode is untouched — it hands
# back exactly the bytes staged in $T/bin/raw, which is how section D drives malformed and
# empty listings regardless of what real lsof would say.
cat > "$T/bin/lsof" <<'STUB'
#!/usr/bin/env zsh
emulate -L zsh
local d="${0:h}"
if [[ "$(cat "$d/mode" 2>/dev/null)" == raw ]]; then
  cat "$d/raw"
  exit 0
fi
# Count fixture calls so a test can say "present for the first N scans, gone afterwards".
# The subject scans four times per run: build OCCUPANT, re-check before TERM, re-check before
# KILL, then the final survivor scan.
local -i n
n=$(cat "$d/calls" 2>/dev/null || echo 0); n=$(( n + 1 )); echo "$n" > "$d/calls"

# Suppress the real record for any pid the fixture also names, so it is reported once, from
# the fixture, with the fixture's cwd — never twice with two different cwds.
local -A drop
local fpid frest
if [[ -f "$d/live" ]]; then
  while read -r fpid frest; do
    [[ -n "$fpid" ]] && drop[$fpid]=1
  done < "$d/live"
fi

# Real lsof is never empty — this shell has a cwd and so does launchd — so it alone already
# satisfies the subject's refusal-on-empty check; no synthesised baseline record is needed.
local -a lines
lines=( ${(0)"$(LC_ALL=C command /usr/sbin/lsof -w -d cwd -F0pcnR 2>/dev/null)"} )
lines=( ${lines#$'\n'} )
local -i i
local rpid
for (( i = 1; i <= ${#lines}; i += 5 )); do
  rpid="${lines[i]#p}"
  (( ${+drop[$rpid]} )) && continue
  printf 'p%s\0R%s\0c%s\0fcwd\0n%s\0' \
    "$rpid" "${lines[i+1]#R}" "${lines[i+2]#c}" "${lines[i+4]#n}"
done

if [[ -f "$d/drop_after" ]] && (( n > $(cat "$d/drop_after") )); then
  : # the fixture's pids have "exited" as of this call — report none of them
else
  local pid cmd cwd
  while read -r pid cmd cwd; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    printf 'p%s\0R1\0c%s\0fcwd\0n%s\0' "$pid" "$cmd" "$cwd"
  done < "$d/live"
fi
# A one-shot transition: if a successor fixture is staged, it takes effect from the NEXT call.
# This is how a test can say "the process left the worktree between the scan and the escalation",
# which is the only difference X1's re-check can detect.
if [[ -f "$d/live.next" ]]; then
  mv "$d/live.next" "$d/live"
fi
STUB
chmod +x "$T/bin/lsof"
: > "$T/bin/live"; : > "$T/bin/raw"; echo live > "$T/bin/mode"
mk_raw()  { printf "$@" > "$T/bin/raw"; echo raw > "$T/bin/mode"; : > "$T/bin/calls"; rm -f "$T/bin/drop_after"; }
mk_live() { cat > "$T/bin/live"; echo live > "$T/bin/mode"; : > "$T/bin/calls"; rm -f "$T/bin/drop_after"; }
srun() { PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" zsh "$SUBJECT" "$@" 2>&1; }

mk_raw ''
out="$(srun --sweep ruby teardown)"; is "empty lsof output is refused" "$?" "1"
has "and says the list was unreadable" "$out" "lsof"
mk_raw 'p1\0cruby\0fcwd\0'
out="$(srun --sweep ruby teardown)"; is "a truncated record is refused" "$?" "1"
mk_raw 'p1\0R1\0cruby\0fcwd\0n\0'
out="$(srun --sweep ruby teardown)"; is "a bare n field is refused" "$?" "1"
mk_raw 'p1\0R1\0cruby\0ftxt\0n/x\0'
out="$(srun --sweep ruby teardown)"; is "a non-cwd descriptor is refused" "$?" "1"
# The exact shape the review used to defeat the old split-call design: a complete-looking
# record that simply omits R. Under the two-call design this could slip through _scan's own
# check (it validated only p/c/f/n) and still leave _ancestors's separate call to reconcile;
# now the two are the same call and the same record shape, so a record missing R fails the
# cycle-length check before anything is inspected field-by-field.
mk_raw 'p1\0cruby\0fcwd\0n/\0'
out="$(srun --sweep ruby teardown)"; is "a record with p but no R is refused" "$?" "1"

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
mk_raw 'p%s\0R1\0cimmortal\0fcwd\0n%s\0' "$ghost" "$WT"
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
# The pidfile names a process that is still alive, just not inside this worktree — X3 clears a
# pidfile only once its named pid is confirmed gone, so a live bystander's file must survive:
# it is the only handle anything has on that process, and nothing here can tell "pid recycled"
# from "supervisor chdir'd away".
is "and the stale pidfile was preserved" "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "present"
kill -9 "$bystander" 2>/dev/null
rm -f "$WT/tmp/pids/server.pid"

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
#
# mk_raw, not mk_live: X1's ownership re-proof re-scans before escalating, and mk_live reports
# a pid only while it answers kill -0. An ordinary `sleep` genuinely dies on the plain kill
# -TERM sent first, so with mk_live the re-scan would correctly find it already gone and let
# _stop return 0 early — a real improvement from X1, but it defeats the zero-wait failure
# trick this section relies on. mk_raw reports the fixture regardless of real liveness, the
# same technique section I uses for its "immortal" survivor, so the re-scan still finds it an
# occupant and escalation proceeds to the deterministic KILL_WAIT=0 return-1 path.
stubborn="$(spawn command sleep 400)"
echo "$stubborn" > "$WT/tmp/pids/server.pid"
mk_raw 'p%s\0R1\0csleep\0fcwd\0n%s\0' "$stubborn" "$WT"
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
echo "S. ownership is re-proved before escalation, and ancestry is complete"
# X1a: a process gone by the PRE-TERM check must never be signalled at all. Present for the
# initial scan (call 1), gone from the pre-TERM re-check (call 2) onward. An ordinary spawned
# sleep is enough — it need not survive anything, since nothing should ever be sent to it.
depart_before_term="$(spawn command sleep 300)"
mk_live <<EOF
$depart_before_term sleep $WT
EOF
echo 1 > "$T/bin/drop_after"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=1 \
  zsh "$SUBJECT" --sweep sleep teardown 2>&1)"
sleep 0.5
is "the pre-TERM departure was NOT signalled" \
  "$(kill -0 "$depart_before_term" 2>/dev/null; echo $?)" "0"
has "and the transcript says why" "$out" "is no longer in"
kill -9 "$depart_before_term" 2>/dev/null
rm -f "$T/bin/drop_after"

# X1b: a process that leaves the worktree between TERM and KILL is no longer the process we
# identified. It must not be killed on the old evidence. The victim ignores TERM, so it survives
# to the escalation; present for the initial scan (call 1) AND the pre-TERM check (call 2), gone
# from the pre-KILL check (call 3) onward — only the pre-KILL safeguard can save it. Without that
# re-check, KILL lands on it and it dies.
rm -f "$T/escapee.ready"
escapee="$(spawn "$T/deaf.sh" "$T/escapee.ready")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/escapee.ready" ] && break; sleep 0.2; done
is "the escapee fixture installed its TERM trap" \
  "$([ -e "$T/escapee.ready" ] && echo yes || echo no)" "yes"
mk_live <<EOF
$escapee deaf.sh $WT
EOF
echo 2 > "$T/bin/drop_after"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=1 \
  zsh "$SUBJECT" --sweep deaf.sh teardown 2>&1)"
is "teardown exits clean once the escapee is gone from the worktree" "$?" "0"
sleep 1
is "the escapee was NOT killed on stale evidence" \
  "$(kill -0 "$escapee" 2>/dev/null; echo $?)" "0"
has "and the transcript says why" "$out" "is no longer in"
kill -9 "$escapee" 2>/dev/null
rm -f "$T/bin/drop_after" "$T/escapee.ready"

# X2: ancestry must fail closed rather than return a truncated chain.
cat > "$T/bin/lsof.broken" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$T/bin/lsof.broken"
mkdir -p "$T/brokenbin"
cp "$T/bin/lsof.broken" "$T/brokenbin/lsof"
out="$(PATH="$T/brokenbin:/usr/bin:/bin" WT_WORKTREE="$WT" zsh "$SUBJECT" --sweep ruby teardown 2>&1)"
is "an unreadable process list refuses rather than sweeping" "$?" "1"

echo
echo "T. indeterminate is not the same as gone"
# Y3. kill -0 fails both for a process that does not exist and for one owned by another user.
# Only the first is proof of death. Find a real live process we cannot signal — on macOS there
# are always root-owned ones — rather than hardcoding a pid.
unreadable=""
for cand in $(LC_ALL=C lsof -w -d cwd -F0p 2>/dev/null | tr '\0' '\n' \
              | grep '^p[0-9]' | sed 's/^p//' | sort -u | head -60); do
  LC_ALL=C kill -0 "$cand" 2>/dev/null && continue
  case "$(LC_ALL=C kill -0 "$cand" 2>&1)" in
    # Wording differs by shell: bash's builtin says "Operation not permitted", zsh's says
    # "operation not permitted". This suite's shebang is bash, but match both rather than
    # hardcode one shell's phrasing.
    *"Operation not permitted"*|*"operation not permitted"*) unreadable="$cand"; break ;;
  esac
done
is "found a live process we may not signal" "$([ -n "$unreadable" ] && echo yes || echo no)" "yes"
echo "$unreadable" > "$WT/tmp/pids/server.pid"
mk_live <<EOF
$$ zsh $T/elsewhere
EOF
out="$(srun --pidfile tmp/pids/server.pid teardown)"
is "a pidfile naming an unreadable live process is kept" \
  "$([ -e "$WT/tmp/pids/server.pid" ] && echo present || echo gone)" "present"
rm -f "$WT/tmp/pids/server.pid"

# Y4. With both budgets at 0, _stop sends TERM, then KILL, and returns 1 without ever confirming
# either — the "signalled but unconfirmed" state. drop_after=3 keeps the target visible for the
# three scans _stop depends on and removes it for the fourth, so the final scan is clear. The
# helper must still refuse: the scan that failed is the one that would have told us what we
# signalled.
#
# Not a plain `sleep`: an ordinary process genuinely dies on the real TERM sent right after the
# first scan, so the stub's own kill -0 filter would drop it from the pre-KILL scan on its own —
# the same reason section Q uses mk_raw rather than mk_live for its "stubborn" case. deaf.sh
# ignores TERM, so it is still genuinely alive (and correctly kept) at the pre-KILL check; the
# KILL that follows is real and does end it, but WT_TEARDOWN_KILL_WAIT=0 never polls to notice,
# so _stop still returns 1. drop_after then makes the final scan clear deterministically, rather
# than racing the real SIGKILL's delivery.
rm -f "$T/unconfirmed.ready"
unconfirmed="$(spawn "$T/deaf.sh" "$T/unconfirmed.ready")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/unconfirmed.ready" ] && break; sleep 0.2; done
is "the unconfirmed fixture installed its TERM trap" \
  "$([ -e "$T/unconfirmed.ready" ] && echo yes || echo no)" "yes"
mk_live <<EOF
$unconfirmed deaf.sh $WT
EOF
echo 3 > "$T/bin/drop_after"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=0 WT_TEARDOWN_KILL_WAIT=0 \
  zsh "$SUBJECT" --sweep deaf.sh teardown 2>&1)"
is "an unconfirmed stop exits nonzero even with a clear final scan" "$?" "1"
kill -9 "$unconfirmed" 2>/dev/null
rm -f "$T/bin/drop_after" "$T/unconfirmed.ready"

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
