# Worktree teardown helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `.worktreehook teardown` something to call, so `wt-rm` stops project processes instead of refusing because one is still running.

**Architecture:** A machine-level zsh script `~/.local/bin/wt-teardown` owns all mechanics and refusals — scanning `lsof` by cwd, proving a pid belongs to the worktree, TERM→KILL escalation. A project's `.worktreehook` owns only declaration, passing `--pidfile` and `--sweep` flags. Neither holds the other's knowledge.

**Tech Stack:** zsh (subject, matching `_wt_live_processes`' idioms and guaranteed present on macOS), bash 5 (test suite, via `#!/usr/bin/env bash` → `/opt/homebrew/bin/bash`), `lsof`, POSIX `sh` (the curato hook).

**Spec:** `docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md`

## Global Constraints

- Source file is `dot_local/bin/executable_wt-teardown`; chezmoi deploys it to `~/.local/bin/wt-teardown`. Never hand-edit the deployed copy.
- Mode 755. Git stores only the exec bit; `chmod 755` then `git add --chmod=+x` if it lands wrong.
- Test suite is `tests/wt-teardown.test.sh`, mode 755, **executed** (`./tests/wt-teardown.test.sh`), never interpreter-prefixed.
- The suite must carry the missing-subject guard: if the subject is absent it prints `RESULT: 0 passed, 1 total, 1 failed` and exits 2, so a moved subject fails loudly instead of passing vacuously.
- Output idiom is prose: `  ok  <name>` / `  FAIL: <name>`, lettered sections, final `RESULT: N passed, M total, F failed`. `run.sh` counts both and cross-checks against exit status.
- No `# test-requires:` line — the suite stubs `lsof` and `ps` and must run in the default `./tests/run.sh`.
- Every invariant in spec §6 must have at least one assertion.
- No agent attribution in any commit message.
- Commit messages: imperative mood, matching repo history (`Drop the git tab for an alt+g lazygit popup`).

---

### Task 1: CLI surface — verbs, flags, environment

**Files:**
- Create: `dot_local/bin/executable_wt-teardown`
- Create: `tests/wt-teardown.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the executable at `dot_local/bin/executable_wt-teardown` accepting
  `wt-teardown [--pidfile REL]... [--sweep COMMAND]... setup|teardown`, reading
  `WT_WORKTREE` from the environment. Exit 0 on `setup`, 64 on usage error, 1 on
  environment error. Later tasks add behaviour inside the `teardown` branch only.

- [ ] **Step 1: Write the failing test**

Create `tests/wt-teardown.test.sh`:

```bash
#!/usr/bin/env bash
# Tests wt-teardown, the helper a project's .worktreehook calls at teardown.
#
# The helper exists because wt-rm's check 4 can only refuse: it names the process
# holding the checkout and stops. Nothing existed for a hook to call, so no repository
# had a .worktreehook at all and the refusal was the end of the sequence.
#
# What matters here is the refusals, not the kills. A helper that reads a failed lsof
# scan as "nothing is running", or signals a pid it has not proved belongs to this
# worktree, is worse than no helper — it turns a refusal into a wrong kill.
#
# Run: ./tests/wt-teardown.test.sh
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

T="$(mktemp -d "${TMPDIR:-/tmp}/wt-teardown-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
WT="$T/repo-feature"
mkdir -p "$WT/tmp/pids" "$T/bin"

# run <args...> — invoke the subject with WT_WORKTREE set, capturing stdout+stderr.
run() { WT_WORKTREE="$WT" zsh "$SUBJECT" "$@" 2>&1; }

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
```

Then `chmod 755 tests/wt-teardown.test.sh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/wt-teardown.test.sh`
Expected: exit 2, `FATAL: .../executable_wt-teardown not found`.

- [ ] **Step 3: Write minimal implementation**

Create `dot_local/bin/executable_wt-teardown`:

```zsh
#!/usr/bin/env zsh
# wt-teardown — stop processes rooted in the worktree being retired.
#
# Called from a project's .worktreehook at the `teardown` verb. The hook declares WHAT
# to stop; this script owns the mechanics and, more importantly, the refusals. It knows
# nothing about Rails, Postgres or Ruby, so a second project declares different flags
# rather than teaching this script a second stack's conventions.
#
# See docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md

emulate -L zsh

typeset PROG=wt-teardown
typeset -a PIDFILES SWEEPS

die() { print -ru2 -- "$PROG: $*"; exit 1 }
usage() {
  print -ru2 -- "usage: $PROG [--pidfile REL]... [--sweep COMMAND]... setup|teardown"
  exit 64
}

while (( $# )); do
  case "$1" in
    --pidfile) (( $# >= 2 )) || usage; PIDFILES+=( "$2" ); shift 2 ;;
    --sweep)   (( $# >= 2 )) || usage; SWEEPS+=( "$2" );   shift 2 ;;
    --)        shift; break ;;
    -*)        usage ;;
    *)         break ;;
  esac
done

(( $# == 1 )) || usage
typeset VERB="$1"

case "$VERB" in
  setup)    exit 0 ;;
  teardown) ;;
  *)        usage ;;
esac

# Everything below is the teardown verb.
#
# Validated here rather than trusted: the protocol supplies these, but a hook run by
# hand supplies nothing, and a helper that resolved paths from a half-set environment
# would sweep the wrong directory.
[[ -n "${WT_WORKTREE:-}" ]] || die "WT_WORKTREE is not set — this runs from a .worktreehook."
[[ "$WT_WORKTREE" == /* ]] || die "WT_WORKTREE is not absolute: $WT_WORKTREE"
[[ -d "$WT_WORKTREE" ]]    || die "WT_WORKTREE is not a directory: $WT_WORKTREE"
typeset WT="${WT_WORKTREE:A}"

exit 0
```

Then `chmod 755 dot_local/bin/executable_wt-teardown`.

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/wt-teardown.test.sh`
Expected: `RESULT: 12 passed, 12 total, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_wt-teardown tests/wt-teardown.test.sh
git commit -m "Add the wt-teardown CLI surface"
```

---

### Task 2: Scan by cwd, and sweep with TERM

**Files:**
- Modify: `dot_local/bin/executable_wt-teardown`
- Modify: `tests/wt-teardown.test.sh`

**Interfaces:**
- Consumes: Task 1's `$WT`, `$SWEEPS`, `die`, `usage`.
- Produces: shell functions `_render <path>` (string → lsof's rendering, returns 1 on a
  control character), `_ancestors` (prints this pid and every ancestor, one per line),
  `_scan <abs-dir>` (prints `<pid> <command>` per process whose cwd is at or below the
  directory; returns 1 rather than empty on any unreadable scan). Teardown sends TERM to
  swept pids. No KILL escalation yet — Task 3.

- [ ] **Step 1: Write the failing test**

Append to `tests/wt-teardown.test.sh`, before the `RESULT:` line:

```bash
echo
echo "D. the lsof scan refuses rather than reads empty"
# The whole point. An unreadable listing is not an idle checkout, and reading it as one
# would silently disable the guard — which is how husks got left behind in the first place.
# The stub has two modes, and the distinction matters for more than tidiness.
#
#   raw  — emit bytes verbatim, for the malformed listings the parser must refuse.
#   live — emit a record per `pid cmd cwd` line, but ONLY for pids that are still
#          alive. A fixed fixture would keep reporting a process the helper has
#          already stopped, so the final re-scan (Task 3) would see a phantom
#          survivor and every behavioural case would fail for a reason that is
#          entirely an artefact of the stub.
cat > "$T/bin/lsof" <<'STUB'
#!/bin/sh
d="$(dirname "$0")"
if [ "$(cat "$d/mode" 2>/dev/null)" = raw ]; then
  cat "$d/raw"
  exit 0
fi
while read -r pid cmd cwd; do
  [ -n "$pid" ] || continue
  kill -0 "$pid" 2>/dev/null || continue
  printf 'p%s\0c%s\0fcwd\0n%s\0' "$pid" "$cmd" "$cwd"
done < "$d/live"
STUB
# The subject derives $$ and $PPID by itself, but this suite's own pid is the
# GRANDparent of the subject — bash runs `zsh "$SUBJECT"` inside a command-substitution
# subshell, and that subshell is $PPID. Only the ps walk reaches the suite itself, so
# stubbing ps to fail would leave section F asserting nothing and, worse, would let the
# sweep TERM the harness mid-run.
cat > "$T/bin/ps" <<STUB
#!/bin/sh
# Only the \`-o ppid= -p PID\` form is used. Map every pid to this suite, and the suite
# to 1, so the ancestor walk terminates exactly at the harness.
for a in "\$@"; do last="\$a"; done
if [ "\$last" = "$$" ]; then echo 1; else echo $$; fi
STUB
chmod +x "$T/bin/lsof" "$T/bin/ps"
: > "$T/bin/live"; : > "$T/bin/raw"; echo live > "$T/bin/mode"

# mk_raw <bytes>          — malformed-listing mode
# mk_live <<'EOF' ... EOF — "pid cmd cwd" lines, liveness-filtered at call time
mk_raw()  { printf '%s' "$1" > "$T/bin/raw"; echo raw > "$T/bin/mode"; }
mk_live() { cat > "$T/bin/live"; echo live > "$T/bin/mode"; }

srun() { PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" zsh "$SUBJECT" "$@" 2>&1; }

# lsof cannot come back empty — this shell has a cwd of its own and is in every answer.
mk_raw ''
out="$(srun --sweep ruby teardown)"; is "empty lsof output is refused" "$?" "1"
has "and says the list was unreadable" "$out" "lsof"

# A record count not divisible by four means the parse is misaligned with what the
# binary emitted; the occupant would be exactly in the records never reached.
mk_raw "$(printf 'p1\0cruby\0fcwd\0')"
out="$(srun --sweep ruby teardown)"; is "a truncated record is refused" "$?" "1"

# Prefix-shaped but wrong by value: a bare `n` is semantically empty and an empty cwd
# matches nothing, so a process IN the checkout would read as no process at all.
mk_raw "$(printf 'p1\0cruby\0fcwd\0n\0')"
out="$(srun --sweep ruby teardown)"; is "a bare n field is refused" "$?" "1"
mk_raw "$(printf 'p1\0cruby\0ftxt\0n/x\0')"
out="$(srun --sweep ruby teardown)"; is "a non-cwd descriptor is refused" "$?" "1"

echo
echo "E. matching is anchored at a directory boundary"
# Sibling worktrees of one repo differ by a suffix on a shared path by construction, so
# a bare prefix test would let a process in one veto removal of the other forever. The
# pid is this harness, which is alive — a dead pid would make the case vacuous.
mk_live <<EOF
$$ ruby $T/repo-feature-two
EOF
out="$(srun --sweep ruby teardown)"; is "a sibling suffix does not match" "$?" "0"
is "and nothing is reported stopped" "$(printf '%s' "$out" | grep -c stopping)" "0"
is "the harness is still alive" "$(kill -0 $$ 2>/dev/null; echo $?)" "0"

echo
echo "F. the sweep never kills its own chain"
# wt-rm runs the hook with cwd INSIDE the worktree, so this process and the subshell
# that cd'd there are both in every scan result. The allowlist must not be what saves
# them: this declares the very command name the harness runs under.
mk_live <<EOF
$$ zsh $WT
EOF
out="$(srun --sweep zsh teardown)"
is "a --sweep zsh does not kill the test harness" "$?" "0"
is "the harness is still alive" "$(kill -0 $$ 2>/dev/null; echo $?)" "0"

echo
echo "G. TERM is sent to a swept process"
command sleep 300 & victim=$!
mk_live <<EOF
$victim sleep $WT
EOF
out="$(srun --sweep sleep teardown)"
is "the sweep exits clean" "$?" "0"
sleep 1
is "the swept process is gone" "$(kill -0 "$victim" 2>/dev/null; echo $?)" "1"
has "and it is reported" "$out" "sleep"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/wt-teardown.test.sh`
Expected: FAIL on section D — the subject exits 0 and ignores `--sweep` entirely.

- [ ] **Step 3: Write minimal implementation**

Insert these functions after the `WT` assignment in `dot_local/bin/executable_wt-teardown`:

```zsh
# _render <path> — the pathname as lsof itself renders it under LC_ALL=C.
#
# Comparing against the raw path would be wrong for any path lsof escapes. This concerns
# $WT alone: a rendered character INSIDE the checkout still sits after the prefix that
# has to match.
_render() {
  emulate -L zsh
  # Byte-wise, because that is how lsof escapes under LC_ALL=C. NO_MULTIBYTE makes zsh's
  # indexing agree with it.
  setopt local_options no_multibyte
  local s="$1" out="" c i n
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"; n=$(( #c ))
    if (( n == 92 )); then out+='\\'
    elif (( n >= 32 && n <= 126 )); then out+="$c"
    elif (( n >= 128 )); then out+="$(printf '\\x%02x' $n)"
    else return 1
    fi
  done
  print -r -- "$out"
}

# _ancestors — this pid and every ancestor, one per line.
#
# Unconditional, not merely covered by the allowlist: wt-rm runs the hook with cwd inside
# the worktree, so this process AND the subshell that cd'd there appear in every scan.
# A repository declaring `--sweep zsh` must not kill the shell interpreting its own hook.
#
# $$ and $PPID come from zsh and always hold. The ps walk extends the chain beyond them
# and is allowed to fail — under a sandbox that denies ps, two levels still cover the
# wt-rm case exactly.
_ancestors() {
  emulate -L zsh
  local -a chain
  local p pp
  chain=( $$ $PPID )
  p=$PPID
  while [[ "$p" == <2-> ]]; do
    pp="$(command ps -o ppid= -p "$p" 2>/dev/null)" || break
    pp="${pp//[[:space:]]/}"
    [[ "$pp" == <2-> ]] || break
    chain+=( "$pp" )
    p="$pp"
  done
  print -rl -- $chain
}

# _scan <abs-dir> — print "<pid> <command>" for every process whose cwd is at or below
# <abs-dir>. Return 1 when the answer cannot be trusted.
#
# The parse discipline is deliberate and mirrors _wt_live_processes:
#   -F0 gives NUL-terminated fields, so framing does not rest on lsof's escaping of a
#   newline inside a pathname. A single invocation keeps the status attached to the
#   listing actually parsed — split across two, a scan that died partway would read as an
#   idle checkout, since the records it never reached are exactly where the occupant is.
_scan() {
  emulate -L zsh
  local dir="$1" edir rc i pid cmd cwd
  local -a lines hits
  (( $+commands[lsof] )) || {
    print -ru2 -- "$PROG: lsof is unavailable, so processes using $dir cannot be detected — refusing."
    return 1
  }
  edir="$(_render "$dir")" || {
    print -ru2 -- "$PROG: $dir contains a control character, which lsof renders rather than reports — refusing."
    return 1
  }
  lines=( ${(0)"$(LC_ALL=C command lsof -w -d cwd -F0pcn 2>/dev/null)"} ); rc=$?
  if (( rc )); then
    print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
    return 1
  fi
  # Each record set ends with a newline after its final NUL, which lands at the front of
  # the next field. Strip exactly one.
  lines=( ${lines#$'\n'} )
  # Real lsof cannot come back empty: this shell has a cwd of its own and is in every
  # answer. Nothing at all therefore means the scan failed.
  if (( ${#lines} == 0 )) || (( ${#lines} % 4 )); then
    print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
    return 1
  fi
  for (( i = 1; i <= ${#lines}; i += 4 )); do
    if [[ "${lines[i]}" != p<-> || "${lines[i+1]}" != c* || \
          "${lines[i+2]}" != fcwd || "${lines[i+3]}" != n/* ]]; then
      print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
      return 1
    fi
    pid="${lines[i]#p}" cmd="${lines[i+1]#c}" cwd="${lines[i+3]#n}"
    # Anchored on purpose: repo-a and repo-a-extra are neighbours by construction.
    [[ "$cwd" == "$edir" || "$cwd" == "$edir"/* ]] && hits+=( "$pid $cmd" )
  done
  (( ${#hits} )) && print -rl -- $hits
  return 0
}
```

Replace the trailing `exit 0` with:

```zsh
typeset scan_out
scan_out="$(_scan "$WT")" || exit 1

typeset -A OCCUPANT          # pid -> command, for every process inside the worktree
typeset line
for line in ${(f)scan_out}; do
  [[ -n "$line" ]] && OCCUPANT[${line%% *}]="${line#* }"
done

typeset -A MINE              # pids of this process and its ancestors
for line in ${(f)"$(_ancestors)"}; do
  [[ -n "$line" ]] && MINE[$line]=1
done

typeset -a TARGETS
typeset pid cmd want
for pid cmd in ${(kv)OCCUPANT}; do
  (( ${+MINE[$pid]} )) && continue
  for want in $SWEEPS; do
    # Exact equality, never substring: `ruby` must not select `rubyfmt`.
    [[ "$cmd" == "$want" ]] && { TARGETS+=( "$pid" ); print -r -- "$PROG: stopping $pid $cmd"; break }
  done
done

for pid in $TARGETS; do kill -TERM "$pid" 2>/dev/null; done

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/wt-teardown.test.sh`
Expected: all of A–G pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_wt-teardown tests/wt-teardown.test.sh
git commit -m "Scan for worktree occupants and sweep declared commands"
```

---

### Task 3: Signal escalation and final verification

**Files:**
- Modify: `dot_local/bin/executable_wt-teardown`
- Modify: `tests/wt-teardown.test.sh`

**Interfaces:**
- Consumes: Task 2's `_scan`, `$TARGETS`, `$MINE`.
- Produces: `_stop <pid>...` (TERM, poll, KILL, poll; returns 1 if anything survives) and
  a final re-scan. Teardown now exits 1 when a target survives, leaving `wt-rm` holding
  the worktree. Wait budgets are overridable for tests via `WT_TEARDOWN_TERM_WAIT` and
  `WT_TEARDOWN_KILL_WAIT` (seconds, defaults 10 and 5).

- [ ] **Step 1: Write the failing test**

Append before the `RESULT:` line:

```bash
echo
echo "H. a process ignoring TERM is escalated to KILL"
# TERM alone is not a stop. A supervisor that traps it and a process wedged in an
# uninterruptible state both end as husks if the helper reports success on TERM sent.
cat > "$T/deaf.sh" <<'DEAF'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
DEAF
chmod +x "$T/deaf.sh"
"$T/deaf.sh" & deaf=$!
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
# A second refusal is a better outcome than a husk, so wt-rm must keep the worktree.
command sleep 300 & ghost=$!
# raw mode, so the listing keeps reporting the process no matter what is signalled —
# the shape of a process the helper cannot actually stop. The pid is real and alive so
# the signals have somewhere to land.
mk_raw "$(printf 'p%s\0cimmortal\0fcwd\0n%s\0' "$ghost" "$WT")"
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=1 \
  zsh "$SUBJECT" --sweep immortal teardown 2>&1)"
is "a surviving target exits nonzero" "$?" "1"
has "and names what is still there" "$out" "still"
kill -9 "$ghost" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/wt-teardown.test.sh`
Expected: FAIL in H (the deaf process survives, TERM was sent once) and in I (exit 0, no survivor check).

- [ ] **Step 3: Write minimal implementation**

Add near the top of `dot_local/bin/executable_wt-teardown`, beside the other `typeset`s:

```zsh
# Seconds to wait after TERM, then after KILL. Overridable so the test suite does not
# spend fifteen seconds per case; there is no reason to change them in use.
typeset -i TERM_WAIT=${WT_TEARDOWN_TERM_WAIT:-10}
typeset -i KILL_WAIT=${WT_TEARDOWN_KILL_WAIT:-5}
```

Add this function beside `_scan`:

```zsh
# _stop <pid>... — TERM, poll, KILL, poll. Return 1 if anything is still alive.
#
# Polling uses kill -0 because it is cheap; the authority on whether the checkout is
# clear is the re-scan afterwards, not this. A process that ignores TERM is the ordinary
# case here — a supervisor trapping it to shut children down first — so escalation is
# the rule, not an edge.
_stop() {
  emulate -L zsh
  local -a pids left
  pids=( "$@" )
  (( ${#pids} )) || return 0
  local p
  local -i i
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  left=( $pids )
  for (( i = 0; i < TERM_WAIT * 10; i++ )); do
    pids=( $left ); left=()
    for p in $pids; do kill -0 "$p" 2>/dev/null && left+=( "$p" ); done
    (( ${#left} )) || return 0
    command sleep 0.1
  done
  for p in $left; do kill -KILL "$p" 2>/dev/null; done
  for (( i = 0; i < KILL_WAIT * 10; i++ )); do
    pids=( $left ); left=()
    for p in $pids; do kill -0 "$p" 2>/dev/null && left+=( "$p" ); done
    (( ${#left} )) || return 0
    command sleep 0.1
  done
  return 1
}
```

Replace the trailing `for pid in $TARGETS; do kill -TERM …; done` and `exit 0` with:

```zsh
_stop $TARGETS

# The re-scan is the authority, not the signals. A pid that exited leaves no cwd record;
# anything still listed is still holding the checkout open, and reporting success here
# would hand wt-rm a directory that reappears after Git deletes it.
typeset rescan_out
rescan_out="$(_scan "$WT")" || exit 1
typeset -a survivors
for line in ${(f)rescan_out}; do
  [[ -n "$line" ]] || continue
  pid="${line%% *}"
  (( ${+MINE[$pid]} )) && continue
  survivors+=( "$line" )
done

if (( ${#survivors} )); then
  print -ru2 -- "$PROG: processes are still in $WT after teardown:"
  for line in $survivors; do print -ru2 -- "    $line"; done
  exit 1
fi

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/wt-teardown.test.sh`
Expected: A–I pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_wt-teardown tests/wt-teardown.test.sh
git commit -m "Escalate TERM to KILL and verify the worktree is clear"
```

---

### Task 4: Declared pidfiles

**Files:**
- Modify: `dot_local/bin/executable_wt-teardown`
- Modify: `tests/wt-teardown.test.sh`

**Interfaces:**
- Consumes: Task 2's `$OCCUPANT`, `$PIDFILES`, Task 3's `_stop`.
- Produces: `_pidfile_pid <rel> <worktree>` printing the pid a declared pidfile names.
  Returns 0 with a pid, 2 when the file is absent (the idempotent case), 1 on any
  refusal. Declared pidfile pids join `$TARGETS` only after their cwd proves they belong
  to this worktree; the file is removed once its process is gone.

- [ ] **Step 1: Write the failing test**

Append before the `RESULT:` line:

```bash
echo
echo "J. a pidfile is not a licence to signal"
# A pidfile outlives its process and macOS recycles pids, so an unverified pidfile is an
# instruction to signal an arbitrary process. This is the single most important refusal
# in the script.
command sleep 300 & bystander=$!
echo "$bystander" > "$WT/tmp/pids/server.pid"
# The bystander is NOT in the worktree — the scan reports only the harness, elsewhere.
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
command sleep 300 & owned=$!
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
# The worktree's tree comes from the feature branch, so a branch committing `tmp` as a
# symlink redirects this read outside the checkout. A path with no '..' still escapes.
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/wt-teardown.test.sh`
Expected: FAIL in J (pidfile ignored, file still present), K, L, M.

- [ ] **Step 3: Write minimal implementation**

Add beside `_scan`:

```zsh
# _pidfile_pid <rel> <worktree> — the pid a declared pidfile names.
#   0 + pid on stdout   the file names a plausible pid
#   2                   no such file — nothing to stop, the ordinary retry case
#   1                   refusal, message on stderr
#
# Containment is checked lexically AND through the filesystem, the same asymmetric rule
# _wt_manifest applies: the worktree's tree comes from the feature branch, so a branch
# committing `tmp` as a symlink redirects this read outside the checkout, and a path with
# no ".." in it still escapes that way.
_pidfile_pid() {
  emulate -L zsh
  local rel="$1" wt="$2" abs real pid
  [[ "$rel" != /* ]] || {
    print -ru2 -- "$PROG: --pidfile must be repo-root-relative: $rel"; return 1 }
  [[ "$rel" != ../* && "$rel" != */../* && "$rel" != */.. ]] || {
    print -ru2 -- "$PROG: --pidfile escapes the worktree: $rel"; return 1 }
  abs="$wt/$rel"
  [[ -e "$abs" || -L "$abs" ]] || return 2
  real="${abs:A}"
  [[ "$real" == "$wt"/* ]] || {
    print -ru2 -- "$PROG: --pidfile resolves outside the worktree: $rel -> $real"; return 1 }
  [[ ! -L "$abs" && -f "$abs" ]] || {
    print -ru2 -- "$PROG: --pidfile is not a regular file: $rel"; return 1 }
  pid="$(<"$abs")"
  pid="${pid//[[:space:]]/}"
  # <2-> is a numeric range: an integer of at least 2. Excludes the empty string, a
  # non-number, 0 (the whole process group) and 1 (init).
  [[ "$pid" == <2-> ]] || {
    print -ru2 -- "$PROG: --pidfile $rel does not contain a usable pid"; return 1 }
  print -r -- "$pid"
  return 0
}
```

Insert before the sweep loop, after `MINE` is built:

```zsh
typeset -a CLEAR_FILES       # pidfiles to remove once their process is gone
typeset rel pfpid rc
for rel in $PIDFILES; do
  pfpid="$(_pidfile_pid "$rel" "$WT")"; rc=$?
  (( rc == 2 )) && continue
  (( rc == 1 )) && exit 1
  CLEAR_FILES+=( "$WT/$rel" )
  if (( ${+MINE[$pfpid]} )); then
    print -r -- "$PROG: $rel names this process — not signalling it"
    continue
  fi
  # The check this step exists for. No ownership proof, no signal: the pid may have been
  # recycled since the file was written, and the new owner is a stranger.
  if (( ${+OCCUPANT[$pfpid]} )); then
    TARGETS+=( "$pfpid" )
    print -r -- "$PROG: stopping $pfpid ${OCCUPANT[$pfpid]} (from $rel)"
  else
    print -r -- "$PROG: $rel is stale — pid $pfpid is not in this worktree"
  fi
done
```

`TARGETS` must be declared before this block; move `typeset -a TARGETS` above it.

Insert after `_stop $TARGETS`, before the re-scan:

```zsh
# Removed only now: a pidfile whose process could not be stopped keeps its evidence in
# place for the retry.
typeset f
for f in $CLEAR_FILES; do
  [[ -e "$f" ]] && rm -f -- "$f"
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/wt-teardown.test.sh`
Expected: A–M pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add dot_local/bin/executable_wt-teardown tests/wt-teardown.test.sh
git commit -m "Stop declared pidfiles only after proving ownership"
```

---

### Task 5: Idempotency and the full-sequence check

**Files:**
- Modify: `tests/wt-teardown.test.sh`
- Modify: `dot_local/bin/executable_wt-teardown` (only if a defect surfaces)

**Interfaces:**
- Consumes: everything above.
- Produces: no new interface. This task proves spec §6 invariant 5 — every step run
  twice leaves the state one run leaves — which is what makes `wt-rm`'s retry path work.

- [ ] **Step 1: Write the failing test**

Append before the `RESULT:` line:

```bash
echo
echo "N. teardown is idempotent"
# wt-rm preserves the worktree on a teardown failure and reruns teardown on retry, so a
# second run from the post-run state must be a clean no-op — not an error about a pidfile
# that is already gone or a process already stopped.
command sleep 300 & twice=$!
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/wt-teardown.test.sh`
Expected: PASS is the likely outcome. If any case fails, that is a real defect in Tasks 2–4 — fix it in the subject, not in the test.

- [ ] **Step 3: Write minimal implementation**

Only if step 2 surfaced a failure. Otherwise no change to the subject.

- [ ] **Step 4: Run the full suite and the whole repo's suites**

```bash
./tests/wt-teardown.test.sh
./tests/run.sh
```

Expected: `wt-teardown` reports `passed/total` with 0 failed; `run.sh` reports no `INCONSISTENT` suite and no new failures. Report totals as passed/total, never "N green".

- [ ] **Step 5: Commit**

```bash
git add tests/wt-teardown.test.sh dot_local/bin/executable_wt-teardown
git commit -m "Prove wt-teardown is idempotent across retries"
```

---

### Task 6: Curato's `.worktreehook`

**Files:**
- Create: `/Users/michael/Code/Netronix/curato/.worktreehook` (separate repository —
  `git@gitlab.com:netronix/curato.git`)

**Interfaces:**
- Consumes: `wt-teardown` on `PATH`, deployed by `chezmoi apply` from Task 1's source file.
- Produces: curato's opt-in to the hook protocol. No dotfiles change.

- [ ] **Step 1: Deploy the helper and verify it is reachable**

```bash
chezmoi apply --dry-run --verbose
chezmoi apply
zsh -c 'command -v wt-teardown && wt-teardown setup; echo "setup rc=$?"'
```

Expected: a path under `~/.local/bin`, and `setup rc=0`.

- [ ] **Step 2: Write the hook**

Create `/Users/michael/Code/Netronix/curato/.worktreehook`:

```sh
#!/bin/sh
# Worktree lifecycle hook. Invoked by `wt` (setup) and `wt-rm` (teardown) with
# WT_MAIN / WT_WORKTREE / WT_BRANCH / WT_SLUG set and cwd in the target worktree.
#
# Only the machine that uses the `wt` worktree workflow has wt-teardown; everyone else —
# and CI — gets a clean no-op rather than a broken executable in their clone.
set -eu
command -v wt-teardown >/dev/null 2>&1 || exit 0

# tmp/pids/server.pid is what `bin/rails server` writes; --sweep ruby is the backstop for
# anything started ad hoc (bin/dev's foreman, bin/jobs, a stray rake), which is the shape
# that actually leaks — an agent starting a server in the background outlives the Herdr
# pane that would otherwise have taken it down.
#
# No database flags: every worktree carries the same mise.local.toml and resolves to the
# one shared localhost:5433/curato_development. There is nothing here to reclaim.
exec wt-teardown --pidfile tmp/pids/server.pid --sweep ruby "$@"
```

- [ ] **Step 3: Make it executable in the index and verify the protocol accepts it**

```bash
chmod 755 /Users/michael/Code/Netronix/curato/.worktreehook
git -C /Users/michael/Code/Netronix/curato add --chmod=+x .worktreehook
git -C /Users/michael/Code/Netronix/curato ls-files --stage -- .worktreehook
```

Expected: mode `100755` at stage 0. Anything else — notably `100644` — makes
`_wt_hook_check` refuse every `wt` and `wt-rm` for this repository.

- [ ] **Step 4: Exercise it end to end against a real worktree**

```bash
zsh -ic 'wt issue-teardown-probe'
# In the new worktree, start a server the way an agent would — detached, so the Herdr
# pane never owns it:
( cd /Users/michael/Code/Netronix/curato-issue-teardown-probe && \
  nohup mise exec -- bin/rails server -p 3011 >/tmp/probe.log 2>&1 & )
sleep 15
zsh -c 'cd /Users/michael/Code/Netronix/curato && command wt-rm issue-teardown-probe'
```

Expected: `wt-rm` prints `wt-teardown: stopping <pid> ruby (from tmp/pids/server.pid)`
and then `✓ removed worktree …` — where before this plan it printed the check-4 refusal.
Then confirm no husk: `ls -d /Users/michael/Code/Netronix/curato-issue-teardown-probe`
must report no such file, and `git -C .../curato worktree list` must not name it.

- [ ] **Step 5: Commit in the curato repository**

```bash
git -C /Users/michael/Code/Netronix/curato checkout -b chore/worktree-teardown-hook
git -C /Users/michael/Code/Netronix/curato add .worktreehook
git -C /Users/michael/Code/Netronix/curato diff --cached
git -C /Users/michael/Code/Netronix/curato commit -m "Add a worktree teardown hook"
```

Check the diff before committing: this repo is shared, and the hook must contain no
machine paths beyond the `PATH` lookup.

---

### Task 7: Pre-merge — status, cross-review, both MRs

**Files:**
- Modify: `docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md`
- Modify: `docs/superpowers/plans/2026-09-11-worktree-teardown-helper.md`

**Interfaces:**
- Consumes: Tasks 1–6 complete, suites green.
- Produces: both MRs open, the canonical document merged first.

- [ ] **Step 1: Cross-review before merging**

Invoke the `cross-review` skill at the pre-merge checkpoint with the branch diff and the
spec. Reconcile findings; bring back a disagreement, not a round count.

- [ ] **Step 2: Run every suite one last time**

```bash
./tests/run.sh
```

Expected: no `INCONSISTENT` suite, no failures. Report `passed/total`.

- [ ] **Step 3: Mark the records**

In the spec, change `**Status:** Approved` to `**Status:** Implemented` and cite the MR.
Add a `**Status:** Implemented` line to this plan so it is not re-executed.

- [ ] **Step 4: Commit and open both MRs**

```bash
git add docs/superpowers/
git commit -m "Mark the worktree teardown helper implemented"
git push -u origin feat/worktree-teardown-helper
```

Then open the curato MR from `chore/worktree-teardown-hook`, describing the dependency by
repo and path plus a GitLab link to the canonical spec — never a bare path, which looks
local to curato and does not resolve there. Follow whatever template
`.gitlab/merge_request_templates/` holds in each repo; `glab mr create --description "$(cat <file>)"`,
since glab does not expand a template from a flag.

- [ ] **Step 5: Merge in order**

Dotfiles first, curato second. Curato's hook is inert without `wt-teardown` on `PATH`,
and the `command -v` guard makes that inertness silent — the reverse order lands a hook
that does nothing and says nothing.

---

## Notes for the executor

**Do not run the live suites unsandboxed.** They measure the sandbox; disabling it
inverts the result. Not relevant to `wt-teardown.test.sh`, which stubs what it needs.

**Control for sandbox mode before calling anything a regression.** Comparing a sandboxed
run against an unsandboxed one has produced a believable 18-test phantom regression here
before. `ps` and `kill` are both denied under the sandbox — which is why the suite stubs
`ps`, and why Task 6's live probe must run unsandboxed.

**Never prefix an interpreter on a suite.** `./tests/wt-teardown.test.sh`, never
`bash tests/wt-teardown.test.sh`.

**`chezmoi apply` renders `op`-backed templates**, so it needs 1Password signed in and
the desktop app approved. Task 6 step 1 is the only step that applies.
