# Worktree teardown helper Implementation Plan

**Status:** Implemented — do not re-execute. Kept as the design record for this change.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `.worktreehook teardown` something to call, so `wt-rm` stops project processes instead of refusing because one is still running.

**Architecture:** A machine-level zsh script `~/.local/bin/wt-teardown` owns all mechanics and refusals — scanning `lsof` by cwd, proving a pid belongs to the worktree, TERM→KILL escalation. A project's `.worktreehook` owns only declaration, passing `--pidfile` and `--sweep` flags. Neither holds the other's knowledge.

**Tech Stack:** zsh (subject, matching `_wt_live_processes`' idioms and guaranteed present on macOS), bash 5 (test suite, via `#!/usr/bin/env bash` → `/opt/homebrew/bin/bash`), `lsof`, POSIX `sh` (the curato hook).

**Spec:** `docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md`


> **The appendix is normative.** Both files in Appendix A were built and run during plan
> review: the suite reported `53 passed, 53 total, 0 failed`, and an 11-mutant battery
> against the subject was caught in full. A later fix wave (Appendix B, item 9) replaced
> `_ancestors`, reworked pidfile-clearing, and re-proved ownership before escalation,
> bringing the suite to `64 passed, 64 total, 0 failed`. A third fix wave (Appendix B,
> item 10) re-proved ownership before TERM as well as before KILL, distinguished a
> confirmed-gone pidfile target from one `kill -0` merely couldn't reach, and made a
> `_stop` that could not confirm its outcome refuse rather than report success; the
> appendix above now reflects that shipped content, and the suite reported
> `68 passed, 68 total, 0 failed`. A fourth fix wave (Appendix B, item 11) took occupancy
> and ancestry off one `lsof` listing instead of two, making true a premise `_ancestors`'s
> own comment had asserted as fact while it was false; the appendix above reflects that
> shipped content, and the suite reports `69 passed, 69 total, 0 failed`. A fifth fix wave
> (Appendix B, item 12) made the ancestry walk's hop budget fail closed instead of
> reporting a truncated chain as success, and replaced section S's single case — which had
> been silently reduced by an earlier fix to testing only the pre-TERM re-check, leaving
> the pre-KILL safeguard uncovered — with two cases that each isolate one re-check; the
> appendix above reflects that shipped content, and the suite reports
> `71 passed, 71 total, 0 failed`. Where a task's
> inline snippet and the appendix disagree, the appendix wins — the tasks define the
> increments and the order, the appendix defines the finished content. Defects found only
> by running it, across every wave, are recorded in Appendix B; do not re-introduce them.

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

Take the file header through section **C. environment** of **Appendix A.2** verbatim. Concretely, this task contributes the shebang, `set -u`, ROOT/SUBJECT, the pass/fail helpers, the missing-subject guard, the HARNESS_TERMED trap, the `T=`/`pwd -P` resolution, `WT=`, `run()`, `spawn()`, and sections A, B and C, plus the closing `RESULT:` line and `[ "$fail" -eq 0 ]`.

Do not retype it from memory or paraphrase it: the appendix is the version that was executed during plan review, and Appendix B lists six defects that a reasonable-looking rewrite reintroduces.

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

Take sections **D** through **G** of **Appendix A.2** verbatim, with one documented exception. This task contributes the `lsof`/`ps` stubs, `mk_raw`, `mk_live`, `srun`, and sections D, E, F and G, inserted before the closing `RESULT:` line.

**Exception (ruling R1):** stop section G after its `has "and it is reported" "$out" "sleep"` assertion. The `near`/`sleepy` block that follows it in the appendix asserts `exit 1` for an occupant no declaration covers, and that refusal comes from the survivor re-scan added in Task 3 — it is unsatisfiable here. Task 3 adds it.

Do not retype it from memory or paraphrase it: the appendix is the version that was executed during plan review, and Appendix B lists six defects that a reasonable-looking rewrite reintroduces.

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
Expected: `RESULT: 26 passed, 26 total, 0 failed`, exit 0.

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

Take the tail of section **G**, then sections **H** and **I**, of **Appendix A.2** verbatim. This task contributes: (a) the `near`/`sleepy` block that closes section G — deferred here by ruling R1 because it asserts the survivor-re-scan refusal this task introduces; (b) the deaf fixture with its readiness marker; and (c) sections H and I. All inserted before the closing `RESULT:` line.

Do not retype it from memory or paraphrase it: the appendix is the version that was executed during plan review, and Appendix B lists six defects that a reasonable-looking rewrite reintroduces.

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
Expected: `RESULT: 33 passed, 33 total, 0 failed`, exit 0.

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

Take sections **J** through **M** of **Appendix A.2** verbatim. Concretely, this task contributes sections J, K, L and M, inserted before the closing `RESULT:` line.

Do not retype it from memory or paraphrase it: the appendix is the version that was executed during plan review, and Appendix B lists six defects that a reasonable-looking rewrite reintroduces.

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
Expected: `RESULT: 48 passed, 48 total, 0 failed`, exit 0.

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

Take sections **N** and **O** of **Appendix A.2** verbatim. Concretely, this task contributes sections N and O, inserted before the closing `RESULT:` line.

Do not retype it from memory or paraphrase it: the appendix is the version that was executed during plan review, and Appendix B lists six defects that a reasonable-looking rewrite reintroduces.

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

Expected: `wt-teardown` reports exactly `RESULT: 53 passed, 53 total, 0 failed`; `run.sh` reports no `INCONSISTENT` suite and no new failures. Report totals as passed/total, never "N green".

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

### Task 7: Pre-merge — self-review, local merge, apply

**Files:**
- Modify: `docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md`
- Modify: `docs/superpowers/plans/2026-09-11-worktree-teardown-helper.md`

**Interfaces:**
- Consumes: Tasks 1-6 complete, suites green.
- Produces: both repos merged locally on their default branches, the helper deployed.

**Scope change (ruling R2, from the operator):** no cross-review, no push, no merge requests.
Credits are short, so Codex is not dispatched at this checkpoint. Self-review replaces it, and
integration is a LOCAL merge in both repos followed by `chezmoi apply`. Nothing is published.

- [ ] **Step 1: Self-review the whole branch**

Read the full branch diff against its merge-base and check it yourself — no subagent, no peer:

```bash
git -C /Users/michael/.local/share/chezmoi diff "$(git -C /Users/michael/.local/share/chezmoi merge-base main HEAD)"..HEAD
```

Check specifically: no secret or machine-local credential in either repo's diff; no agent
attribution in any commit message; the curato hook contains no absolute machine paths beyond
the `PATH` lookup; and the deferred-minor list in the ledger is triaged — each one either fixed
or consciously carried.

- [ ] **Step 2: Run every suite one last time**

```bash
./tests/run.sh
```

Expected: no `INCONSISTENT` suite, no failures. Report `passed/total` per suite, never "N green",
and confirm the listing actually reaches `wt-teardown` — a truncated run reads as a pass.

- [ ] **Step 3: Mark the records**

In the spec, change `**Status:** Approved` to `**Status:** Implemented`, citing the local merge
commit rather than an MR. Add a `**Status:** Implemented` line to this plan so it is not
re-executed.

- [ ] **Step 4: Commit the record update**

```bash
git add docs/superpowers/
git commit -m "Mark the worktree teardown helper implemented"
```

- [ ] **Step 5: Merge locally, dotfiles first**

Dotfiles before curato: curato's hook is inert without `wt-teardown` on `PATH`, and the
`command -v` guard makes that inertness silent.

```bash
git -C /Users/michael/.local/share/chezmoi checkout main
git -C /Users/michael/.local/share/chezmoi merge --no-ff feat/worktree-teardown-helper
git -C /Users/michael/Code/Netronix/curato checkout main
git -C /Users/michael/Code/Netronix/curato merge --no-ff chore/worktree-teardown-hook
```

Do NOT push either repo. Leave both merges local for the operator to push when they choose.

- [ ] **Step 6: Deploy**

```bash
chezmoi apply
zsh -c 'command -v wt-teardown && wt-teardown setup; echo "rc=$?"'
```

Expected: a path under `~/.local/bin`, and `rc=0`. `chezmoi apply` renders `op`-backed
templates, so 1Password must be signed in and the desktop app approved.

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


---

## Appendix A: verified reference implementation

Both files below were executed during plan review. Reproduce them exactly.

### A.1 `dot_local/bin/executable_wt-teardown`

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
# pid -> ppid, populated by the most recent _scan call. _ancestors reads it rather than
# calling lsof itself — see _scan and _ancestors below for why one listing must feed both.
typeset -gA _WT_PARENT
# Seconds to wait after TERM, then after KILL. Overridable so the test suite does not
# spend fifteen seconds per case; there is no reason to change them in use.
typeset -i TERM_WAIT=${WT_TEARDOWN_TERM_WAIT:-10}
typeset -i KILL_WAIT=${WT_TEARDOWN_KILL_WAIT:-5}

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

# Stand outside the worktree for the rest of the run. Every path this script uses is absolute,
# so the cwd buys nothing — and keeping it makes the script an occupant of the very directory it
# is about to scan. wt-rm invokes the hook with cwd inside the worktree, so without this the
# subshell that `$(_scan ...)` forks shows up in lsof as a process holding the checkout open, and
# the post-teardown re-scan vetoes its own success.
builtin cd -q / || die "cannot leave $WT to scan it"

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

# _ancestors — this pid and every ancestor, one per line. Must be called only after a
# _scan, which is what populates _WT_PARENT; called any other time it fails closed on an
# empty map.
#
# Unconditional, not merely covered by the allowlist: wt-rm runs the hook with cwd inside the
# worktree, so this process and the chain that started it appear in every scan. A repository
# declaring `--sweep zsh` must not kill the shell interpreting its own hook.
#
# Ancestry comes from _WT_PARENT, the parent map _scan built from lsof's own R field, rather
# than from `ps`. ps is unavailable under the sandbox agents run wt-rm in, and a walk that
# stops early there returns a TRUNCATED chain while reporting success — which leaves a
# grandparent eligible to be signalled whenever a hook omits `exec`.
#
# The walk climbs while parents are known, and treats an unknown parent as the top of the
# reachable tree, not an error (RULING R9): MINE only needs to cover every ancestor that could
# also be a sweep target, sweep targets come from OCCUPANT, and OCCUPANT and _WT_PARENT are
# built from the very same lsof listing — one call, in _scan, feeding both — so an ancestor
# lsof cannot report can never be a target either, and stopping the climb there loses nothing.
# This is what makes the argument hold: it was FALSE when _scan and this function issued
# separate lsof calls, because a process present in one snapshot and gone from the other left a
# visible ancestor unprotected. Splitting the calls again — even to add a field, even for a
# single caller — reopens exactly that hole; keep them one call.
#
# On macOS the first unreadable link is the root-owned `login` every session descends from;
# above it lie only root processes whose cwd is never inside a user worktree. What must never
# happen is a chain truncated BELOW a visible ancestor — exactly what the old `ps` walk did
# whenever ps was unavailable. Fails closed only where nothing at all is known: _scan was never
# run, or it ran against a listing empty enough to leave the parent map empty.
#
# The 64-hop cap is a fail-closed guard, not a silent truncation: exhausting it means the walk
# reached neither an unknown parent nor pid 0, so the chain is INCOMPLETE and an ancestor beyond
# hop 64 is still unaccounted for and still eligible to be signalled. That is exactly the failure
# mode this function exists to rule out, so running out of hops returns 1 the same as an empty
# map, rather than reporting a partial chain as though it were the whole one.
_ancestors() {
  emulate -L zsh
  local p
  local -a chain
  (( ${#_WT_PARENT} )) || return 1
  p=$$
  chain=( $p )
  local -i hops=0
  local -i complete=0
  while (( ++hops <= 64 )); do
    (( ${+_WT_PARENT[$p]} )) || { complete=1; break }   # unknown parent: top of what we can see
    p="${_WT_PARENT[$p]}"
    (( p == 0 )) && { complete=1; break }               # reached the top of the tree
    chain+=( "$p" )
  done
  # Budget exhausted rather than chain ended: the ancestry is incomplete, and an ancestor we
  # never reached is still eligible to be signalled. Refuse instead of sweeping on a partial
  # chain — the same rule as an empty map, for the same reason.
  (( complete )) || return 1
  print -rl -- $chain
  return 0
}

# _scan <abs-dir> — print "<pid> <command>" for every process whose cwd is at or below
# <abs-dir>. Return 1 when the answer cannot be trusted. Also (re)populates _WT_PARENT,
# the pid -> ppid map _ancestors reads, from the same listing — see _ancestors for why
# one call has to feed both.
#
# The parse discipline is deliberate and mirrors _wt_live_processes:
#   -F0 gives NUL-terminated fields, so framing does not rest on lsof's escaping of a
#   newline inside a pathname. A single invocation keeps the status attached to the
#   listing actually parsed — split across two, a scan that died partway would read as an
#   idle checkout, since the records it never reached are exactly where the occupant is.
_scan() {
  emulate -L zsh
  local dir="$1" edir rc i pid ppid cmd cwd
  local -a lines hits
  (( $+commands[lsof] )) || {
    print -ru2 -- "$PROG: lsof is unavailable, so processes using $dir cannot be detected — refusing."
    return 1
  }
  edir="$(_render "$dir")" || {
    print -ru2 -- "$PROG: $dir contains a control character, which lsof renders rather than reports — refusing."
    return 1
  }
  _WT_PARENT=()
  lines=( ${(0)"$(LC_ALL=C command lsof -w -d cwd -F0pcnR 2>/dev/null)"} ); rc=$?
  if (( rc )); then
    print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
    return 1
  fi
  # Each record set ends with a newline after its final NUL, which lands at the front of
  # the next field. Strip exactly one.
  lines=( ${lines#$'\n'} )
  # Real lsof cannot come back empty: this shell has a cwd of its own and is in every
  # answer. Nothing at all therefore means the scan failed.
  if (( ${#lines} == 0 )) || (( ${#lines} % 5 )); then
    print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
    return 1
  fi
  for (( i = 1; i <= ${#lines}; i += 5 )); do
    if [[ "${lines[i]}" != p<1-> || "${lines[i+1]}" != R<0-> || "${lines[i+2]}" != c* || \
          "${lines[i+3]}" != fcwd || "${lines[i+4]}" != n/* ]]; then
      print -ru2 -- "$PROG: could not read the process list from lsof — refusing."
      return 1
    fi
    pid="${lines[i]#p}" ppid="${lines[i+1]#R}" cmd="${lines[i+2]#c}" cwd="${lines[i+4]#n}"
    _WT_PARENT[$pid]="$ppid"
    # Anchored on purpose: repo-a and repo-a-extra are neighbours by construction.
    [[ "$cwd" == "$edir" || "$cwd" == "$edir"/* ]] && hits+=( "$pid $cmd" )
  done
  (( ${#hits} )) && print -rl -- $hits
  return 0
}

# _still_here <pid>... — filter a pid list down to those lsof still reports inside $WT.
# Returns 1 if the scan itself failed, so callers fail closed rather than signalling blind.
_still_here() {
  emulate -L zsh
  local -a keep
  local out line p
  out="$(_scan "$WT")" || return 1
  typeset -A here
  for line in ${(f)out}; do
    [[ -n "$line" ]] && here[${line%% *}]=1
  done
  for p in "$@"; do
    if (( ${+here[$p]} )); then
      keep+=( "$p" )
    else
      # stderr, not stdout: this function's stdout is captured by callers as the
      # filtered pid list, and a message sharing that stream would be word-split
      # straight into it.
      print -ru2 -- "$PROG: $p is no longer in $WT — not signalling it"
    fi
  done
  print -rl -- $keep
}

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
  # Ownership was proved by the scan that built OCCUPANT, but ancestry discovery and the
  # whole pidfile loop run between that snapshot and here — including another lsof call —
  # so the evidence can be stale by the time the first signal goes out. Re-prove it now,
  # the same way the pre-KILL escalation below does.
  pids=( $(_still_here $pids) ) || return 1
  (( ${#pids} )) || return 0
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  left=( $pids )
  for (( i = 0; i < TERM_WAIT * 10; i++ )); do
    pids=( $left ); left=()
    for p in $pids; do kill -0 "$p" 2>/dev/null && left+=( "$p" ); done
    (( ${#left} )) || return 0
    command sleep 0.1
  done
  # Ownership is proved at scan time, and KILL lands up to TERM_WAIT seconds later. A process
  # that trapped TERM and left the worktree, or a pid recycled inside that window, is no longer
  # the process we identified — so re-prove occupancy before the escalation, and drop whatever
  # can no longer be shown to be here. A fresh scan narrows the window to sub-second; nothing a
  # shell can do makes pid identity atomic.
  left=( $(_still_here $left) ) || return 1
  (( ${#left} )) || return 0
  for p in $left; do kill -KILL "$p" 2>/dev/null; done
  for (( i = 0; i < KILL_WAIT * 10; i++ )); do
    pids=( $left ); left=()
    for p in $pids; do kill -0 "$p" 2>/dev/null && left+=( "$p" ); done
    (( ${#left} )) || return 0
    command sleep 0.1
  done
  return 1
}

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

typeset scan_out
typeset _wt_scan_tmp
typeset -i _wt_scan_rc
_wt_scan_tmp="$(mktemp "${TMPDIR:-/tmp}/wt-teardown-scan.XXXXXX")" || die "cannot create a scratch file to run the initial scan"
# Run directly, not via $(...): command substitution forks a subshell, and _WT_PARENT — the
# parent map _ancestors reads below — is a global _scan mutates, which a fork would confine
# to the child and lose. Redirecting to a real file instead keeps this call in the running
# shell, so the map _scan just built is still there when _ancestors reads it.
_scan "$WT" > "$_wt_scan_tmp"; _wt_scan_rc=$?
scan_out="$(<$_wt_scan_tmp)"
rm -f "$_wt_scan_tmp"
(( _wt_scan_rc )) && exit 1

typeset -A OCCUPANT          # pid -> command, for every process inside the worktree
typeset line
for line in ${(f)scan_out}; do
  [[ -n "$line" ]] && OCCUPANT[${line%% *}]="${line#* }"
done

typeset -A MINE              # pids of this process and its ancestors
typeset anc
anc="$(_ancestors)" || die "cannot establish this process's ancestry — refusing to signal anything."
for line in ${(f)anc}; do
  [[ -n "$line" ]] && MINE[$line]=1
done

typeset -a TARGETS
typeset -A CLEAR_PIDS        # pidfile path -> the pid it named
typeset rel pfpid rc
for rel in $PIDFILES; do
  pfpid="$(_pidfile_pid "$rel" "$WT")"; rc=$?
  (( rc == 2 )) && continue
  (( rc == 1 )) && exit 1
  CLEAR_PIDS[$WT/$rel]="$pfpid"
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

typeset pid cmd want
for pid cmd in ${(kv)OCCUPANT}; do
  (( ${+MINE[$pid]} )) && continue
  # Already taken by a declared pidfile: appending it again would stop nothing extra and would
  # print a second "stopping" line for one process.
  (( ${TARGETS[(Ie)$pid]} )) && continue
  for want in $SWEEPS; do
    # Exact equality, never substring: `ruby` must not select `rubyfmt`.
    [[ "$cmd" == "$want" ]] && { TARGETS+=( "$pid" ); print -r -- "$PROG: stopping $pid $cmd"; break }
  done
done

typeset -i stop_rc=0
_stop $TARGETS || stop_rc=1
if (( stop_rc == 0 )); then
  typeset f fpid kerr
  for f in ${(k)CLEAR_PIDS}; do
    fpid="${CLEAR_PIDS[$f]}"
    # Confirmed gone, not merely "we tried", and not merely "we could not look". kill -0 fails
    # both for a process that does not exist and for one owned by another user, and deleting the
    # file on the second reading throws away the only handle anything has on a live process.
    kerr="$(LC_ALL=C kill -0 "$fpid" 2>&1)" && continue          # alive: keep the file
    [[ "$kerr" == *"no such process"* || "$kerr" == *"No such process"* ]] || {
      print -ru2 -- "$PROG: cannot confirm pid $fpid is gone ($kerr) — keeping $f"
      continue
    }
    [[ -e "$f" ]] || continue
    rm -f -- "$f" || die "could not remove $f"
  done
fi

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

# A failed stop is a failed teardown even when the final scan comes back clear: the scan that
# failed is the one that would have told us what we were signalling. wt-rm keeps the worktree
# and the retry re-runs from a known state.
(( stop_rc )) && {
  print -ru2 -- "$PROG: could not confirm every target was stopped — refusing."
  exit 1
}

exit 0
```

### A.2 `tests/wt-teardown.test.sh`

```bash
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
```

---

## Appendix B: defects found by running the plan, not reading it

Each of these made the suite pass while testing nothing, or fail for a reason that was
an artefact. They are recorded because every one of them is re-introducible by an
executor who "simplifies" the harness.

1. **The temp dir must be resolved with `pwd -P`.** The subject does `${WT_WORKTREE:A}`
   and real `lsof` reports resolved paths, but `mktemp -d` under `$TMPDIR` hands back the
   `/var` symlink. A fixture holding the unresolved path never matches, and every
   behavioural case passes vacuously.

2. **`mk_raw` must `printf` straight to the file.** Bash command substitution strips NUL
   bytes, so `mk_raw "$(printf 'p1\0c...')"` fed the parser a single field — every
   refusal in section D passed for the wrong reason.

3. **Test victims must be spawned detached** (`spawn`, via a subshell that exits). A
   killed child of the runner stays a zombie until bash reaps it, and a zombie still
   answers `kill -0`, so the stub reported a phantom survivor after every successful stop.

4. **The `lsof` stub must always emit a baseline record.** A real `lsof -d cwd` is never
   empty, and the subject refuses an empty listing by design. A stub that emptied out once
   its fixture pids died tripped that refusal on every re-scan.

5. **The deaf fixture must signal readiness after installing its trap.** Spawning it and
   running the subject immediately is a race: TERM arrives before `trap '' TERM` executes,
   the process dies on TERM, and KILL escalation is never exercised at all. Removing the
   KILL loop then passed the suite.

6. **Sections E and F must use disposable processes, not `$$`.** In E the harness is an
   ancestor, so the sweep skipped it for the wrong reason and the anchoring was never
   under test. In F the subject escalates to SIGKILL, which no trap survives, so a
   regression killed the runner instead of reporting a failure.

7. **The whole run must `cd` out of the worktree once at the top, not just the `lsof`
   call inside `_scan`.** The worktree hook protocol invokes the hook with cwd *inside*
   the worktree being retired. A first attempt (R5) cd'd only inside `_scan`'s own
   nested `$(builtin cd -q / && lsof ...)`, on the theory that the substitution forking
   *that* subshell was the occupant. It was not: `scan_out="$(_scan "$WT")"` is *itself*
   a command substitution, forking a zsh subshell that runs at the caller's cwd — inside
   the worktree — for as long as `_scan` takes to return. R5's inner `cd` moved `lsof`
   itself out of the directory, so the survivor list shrank from `zsh` + `lsof` down to
   just `zsh`, but that outer `_scan` subshell was still standing in the worktree when
   the re-scan's `lsof` ran, was never an ancestor of the running process, so `MINE`
   never covered it, and the post-teardown re-scan still reported it as a survivor,
   still exiting 1 unconditionally. R6 fixes the actual level: `cd /` once, immediately
   after `WT` is resolved, for the rest of the run — every path the script touches is
   already absolute, so the cwd was never doing anything useful, and now neither `_scan`
   nor any subshell it forks is ever standing inside the directory being scanned. No
   suite section caught either version of this because the suite stubs `lsof`: a stub
   reports only its fixture, never the process that invoked it, so every stubbed case
   passed while the real binary failed deterministically end to end. Section P exists
   precisely because this class of bug is structurally invisible to a stub and needs the
   real `lsof` against an empty directory nothing else occupies.

8. **The pidfile removal must be gated on `_stop` succeeding, and that gate must have a
   test.** Spec §5.2 states it, the code's own comment above the removal block stated it,
   and neither was true: `_stop $TARGETS` discarded its return value and the removal ran
   unconditionally. A failed stop still deleted the pidfile, so the retry `wt-rm`
   recommends found no pidfile, `_pidfile_pid` returned 2, and a project declaring only
   `--pidfile` (no `--sweep`) lost the one route left to target that supervisor again —
   a permanent refusal loop. This shipped at 55/55 green because no case in the suite ever
   drove `_stop` to failure; sections Q and R (added in the fix wave, both appendices
   above) close that gap — Q with both wait budgets forced to 0 so `_stop` returns 1
   without waiting, R for the related but distinct defect that a process satisfying both
   a declared pidfile and a sweep was appended to `TARGETS` twice and reported stopped
   twice in the transcript that spec §5.5 makes the deliverable.

9. **Fix wave 2 — re-proving ownership before KILL, and taking ancestry from `lsof` instead
   of `ps`.** An independent review of the shipped (55/55-green) helper found four real
   defects, all confirmed by running the plan rather than reading it:

   - **`_stop` never re-checked ownership before escalating.** It sent TERM to the batch
     from the scan's snapshot, waited, then sent KILL to whatever still answered
     `kill -0` — with no re-proof that a still-alive pid was still the process, still
     inside the worktree, that was identified at scan time. A supervisor that traps TERM
     and `chdir`s out, or a pid recycled during the wait, got KILLed on stale evidence.
     Fixed by re-scanning with `_scan "$WT"` immediately before the KILL loop and
     dropping from `left` anything no longer shown to be an occupant.
   - **`_ancestors` walked with `ps`, which is denied under the sandbox agents run
     `wt-rm` in (exit 127).** A walk that stops early on `ps` failure returns a
     TRUNCATED chain while reporting success, leaving a grandparent eligible to be
     signalled whenever a `.worktreehook` omits `exec` — exactly the gap the subsection
     below (now superseded) accepted as an untested risk. Fixed by taking ancestry from
     `lsof`'s own `R` (parent pid) field instead, via a dedicated `-F0pR` call.
   - **Pidfile clearing was gated on the whole `_stop $TARGETS` batch succeeding, not on
     the named pid actually being gone.** `CLEAR_FILES` queued every syntactically valid
     pidfile for removal before checking whether its process, specifically, had stopped.
     A live process outside the worktree, or a protected ancestor, had its pidfile
     deleted anyway as a side effect of unrelated targets succeeding. Fixed by tracking
     each pidfile's pid (`CLEAR_PIDS`) and clearing a file only when `kill -0` on its pid
     fails at the end. This flips section J's expectation: a stale pidfile naming a
     live bystander is now asserted **preserved**, not cleared — it is the only handle
     anything has on that process, and nothing can tell "pid recycled" from "supervisor
     chdir'd away."
   - **A failed removal was silent.** `rm -f -- "$f"` had no failure path; now
     `|| die "could not remove $f"` propagates it.

   Two further defects surfaced only by executing the fix, not by reading it:

   - **The exact `_ancestors` parser given in the first draft assumed `lsof -F0pR`
     emits exactly two fields per process (`p<pid>`, `R<ppid>`).** On this machine, and
     presumably any Mac, `-d cwd` also emits an unrequested `fcwd` descriptor-identity
     line per process, so the fixed-width `(( ${#lines} % 2 ))` shape check failed on
     every real invocation — 22 of 61 cases failed, all downstream of `_ancestors`
     refusing on good data. Fixed by scanning fields tolerantly (a `case` over each
     token, keyed on its own `p`/`R` prefix) instead of assuming a fixed record shape,
     so an extra or reordered field cannot break the parser again.
   - **Even the tolerant parser could not complete a walk to pid 0/1.** An unprivileged
     `lsof` never reports pid 1 at all (the lowest pid it can see belongs to whatever it
     is allowed to read), and on macOS every terminal session's ancestry passes through
     a root-owned `login` process that `lsof`, running as the user, can never enumerate
     — confirmed independently (`kill -0` on it returns `EPERM`, not `ESRCH`; a raw
     `sysctl kern.proc.pid` call returns a valid, live `kinfo_proc` naming it `login`).
     "Fail unless the chain reaches pid 0/1" was therefore impossible by construction,
     not merely strict. **RULING R9** replaces that criterion: the walk climbs while
     parents are known and treats an unknown parent as the top of the *reachable* tree,
     not an error, because `MINE` only needs to cover pids that could also be sweep
     targets, sweep targets come from `OCCUPANT`, and `OCCUPANT` and the ancestry parent
     map are built from the same `lsof` listing — an ancestor `lsof` cannot report can
     never be a sweep target either, so stopping the climb there loses nothing. What
     must never happen, and still does not, is a chain cut short *below* a pid `lsof`
     can actually see — the failure mode the old `ps` walk had whenever `ps` was
     unavailable. Fails closed only where nothing at all is known: a nonzero `lsof` exit,
     or an empty parent map.

   Section S was added to cover the `_stop` re-proof and the `_ancestors` refusal. Its
   first case needed two more fixes to actually exercise anything, both found by running
   it: a fixture with `--sweep nothing-matches` can never enter `TARGETS` regardless of
   `_stop`'s behavior, so the case was vacuous as first written — reverting the re-proof
   code left the suite at 61/61 either way. The fix reuses the section H "deaf" fixture
   (survives TERM) plus a one-shot fixture transition in the `lsof` stub (`live.next`,
   swapped in on the call *after* the one that reports it): the escapee is present for
   the scan that builds `OCCUPANT`/`TARGETS`, then reported gone from the next scan
   onward, modeling "left the worktree between TERM and the KILL re-check" without the
   test needing to actually move a live process. With that fixture, reverting the
   re-proof correctly fails two assertions (the escapee dies, and the transcript loses
   its explanation); reverting the pidfile-clearing fix correctly fails section J's
   "preserved" assertion. Section Q's fixture needed a matching adjustment for an
   unrelated reason: the re-proof now legitimately detects that an ordinary `sleep`
   (no TERM trap) has already died from the plain `kill -TERM` sent first, and returns
   success early — correct behavior, but it defeated Q's old trick of forcing `KILL_WAIT`
   to 0 so `_stop` always returned failure regardless of outcome. Q's fixture now uses
   `mk_raw` (already established in section I) to report its stubborn process
   unconditionally present, independent of whether it actually died, so the deterministic
   zero-wait failure path is still reachable.

10. **Fix wave 3 — re-proving ownership before TERM as well as before KILL, distinguishing
    "confirmed gone" from "kill -0 could not tell," and refusing when a stop could not be
    confirmed.** An independent review of the 64/64-green helper found three more defects,
    all confirmed by running the plan:

    - **`_stop` re-validated occupancy before KILL but sent the initial TERM straight from
      the snapshot the main body took.** Ancestry discovery and the whole pidfile loop —
      including another `lsof` call — run between that snapshot and the TERM loop, so the
      evidence backing the first signal could already be stale. Fixed by factoring the
      re-validation into `_still_here <pid>...` (filters a pid list down to what `_scan`
      still reports inside `$WT`, returning 1 if the scan itself fails) and calling it
      immediately before both the TERM loop and the KILL loop.
    - **The `CLEAR_PIDS` removal loop treated any `kill -0` failure as "gone."** `kill -0`
      also fails with `EPERM` for a live process owned by someone else, which is not
      "gone" — deleting the pidfile on that reading throws away the only handle anything
      has on that process. Fixed by inspecting the error text under `LC_ALL=C` and keeping
      the file unless it says the process does not exist.
    - **A failed `_stop` was discarded at the call site.** `if _stop $TARGETS; then ...`
      only gated the pidfile-clearing block; a failed pre-KILL scan that happened to be
      followed by the target exiting on its own still let the script reach `exit 0`. Fixed
      by capturing `_stop`'s exit status in `stop_rc`, gating the `CLEAR_PIDS` loop on it,
      and refusing (`exit 1`) after the final survivor scan when it is nonzero — even when
      that final scan is clear.

    One further defect surfaced only by executing the fix, not by reading it: **the
    reviewer's own suggested `_still_here` printed its "not signalling it" message on
    stdout**, but every call site captures the whole function via
    `pids=( $(_still_here $pids) )` to get the filtered pid list back — so that message's
    words, including a real pid it happened to contain, were word-split straight into the
    array. Instrumented and confirmed directly: section S's `deaf.sh` escapee, which the
    section exists to prove survives, was actually killed by a garbage token that happened
    to equal its own pid. Fixed by routing that one message through `print -ru2` (stderr),
    invisible to the `$(...)` capture but still visible in transcripts, which capture
    `2>&1`. No other line changed, and section S is green again.

    Section T was added to cover Y3 and Y4, and both of its cases needed rework, found only
    by running the mandated bite-check reversions rather than by inspection:

    - **T's first case originally named pid 1** as a live, unsignallable stand-in for "kill
      -0 fails but the process is not gone." Reverting the fix did not fail it: `1` is
      rejected by `_pidfile_pid`'s own pre-existing `<2->` validation (deliberately
      excluding init) before `CLEAR_PIDS` ever runs, so the file was "kept" only because the
      whole run refused for an unrelated reason. Fixed by discovering a live, unsignallable
      pid dynamically (scan real `lsof -w -d cwd -F0p` output for the first pid whose
      `kill -0` fails with a permission error) instead of hardcoding one — and the pattern
      matching that error had to cover both shells' wording (`Operation not permitted` from
      the suite's own bash shebang, `operation not permitted` from zsh), confirmed by
      running the exact loop under each.
    - **T's second case originally swept an ordinary `sleep`.** With both wait budgets at
      0, the real TERM sent right after the pre-TERM `_still_here` check kills a plain
      `sleep` for real before the pre-KILL check runs, so the stub's own `kill -0` filter
      (independent of any fixture bookkeeping) excludes it there — the same reason section
      Q uses `mk_raw` rather than `mk_live` for its "stubborn" case. `_stop` then returns 0
      (correctly: it never touched a process that had already left), not 1, so the case
      could not reach the state it claims regardless of Y4. Fixed by reusing the section H
      `deaf.sh` fixture, which survives the real TERM, so it is still genuinely alive (and
      correctly kept) at the pre-KILL check; the real KILL that follows does end it, but
      `WT_TEARDOWN_KILL_WAIT=0` never polls to notice, so `_stop` still returns 1. A
      `drop_after` call counter was added to the `lsof` stub (fixture-only; the `-F0pR`
      ancestry passthrough is not counted) so the final survivor scan is deterministically
      clear on the fourth call, rather than racing the real `SIGKILL`'s delivery.

    Bite checks on scratch copies, never the shipped files: reverting the Y3 fix fails
    exactly T's "kept" assertion; reverting the Y4 fix fails exactly T's "exits nonzero"
    assertion; reverting the Y2 pre-TERM re-validation trips no assertion, old or new —
    section S's fixture is already resolved by the pre-existing pre-KILL check, and no
    case in the suite isolates the narrower TERM-side window. That gap is accepted rather
    than chased with a more elaborate fixture.

11. **Fix wave 4 — a false premise in `_ancestors`'s own comment, from taking occupancy and
    ancestry off two separate `lsof` listings.** Fix wave 2 (item 9) gave `_ancestors` its
    own `lsof -F0pR` call, independent of `_scan`'s `lsof -F0pcn` call, and justified the
    walk's early-stop-on-unknown-parent behaviour with an argument that only holds if
    "OCCUPANT and this function's parent map are built from the very same lsof listing." That
    sentence was asserted as fact in the comment while being false in the code: two
    invocations are two snapshots, and a process present in one and gone from the other could
    leave a visible ancestor unprotected. No test caught it because nothing on this machine
    ever actually raced the two calls into disagreement — the hole was real but latent.

    Fixed by making the premise true by construction: `_scan` now issues one
    `lsof -w -d cwd -F0pcnR` call (verified against real output — the field order is
    `p<pid>`, `R<ppid>`, `c<command>`, `fcwd`, `n<path>`, five fields per record, confirmed
    with `od -c` before coding to it) and populates, alongside the hit lines it already
    printed, a `typeset -gA _WT_PARENT` pid-to-ppid map cleared at the start of every call.
    `_ancestors` no longer calls `lsof` at all; it only reads `_WT_PARENT`, and is only ever
    meaningful when called right after a `_scan`. The record-shape validation's cycle length
    moved from 4 to 5 and gained the `R<0->` field check.

    One subtlety `_WT_PARENT` alone did not solve: every existing call to `_scan` is through
    `$(_scan ...)` command substitution, which forks a subshell — and a subshell's mutation
    of a global array is invisible to the parent shell once it exits (confirmed directly: a
    function that sets a `typeset -gA` entry and is invoked as `x="$(f)"` leaves the array
    empty in the caller). `_ancestors` only needs `_WT_PARENT` to be live for the one call
    immediately following the *first* `_scan` (the one that builds `OCCUPANT`); no later
    `_scan` call (inside `_still_here`'s re-proofs, or the final rescan) is ever followed by
    `_ancestors` again, so their being forked is harmless. Fixed by having only that first
    call redirect to a real scratch file (`_scan "$WT" > "$tmp"; rc=$?`) instead of going
    through command substitution — a plain redirection of a function's output runs in the
    current shell, not a fork, confirmed the same way — then reading the file back into
    `scan_out`. `_still_here` and the closing rescan are untouched.

    The test stub changed shape to match: it now serves controlled fixture occupancy and
    truthful ancestry from the same call. In live mode it runs real `lsof -w -d cwd -F0pcnR`,
    drops any record whose pid the fixture also names (so no pid is reported twice with two
    different cwds), and appends the fixture's own records — synthesised to the new 5-field
    shape with `R1`, since fixture processes are detached and their ancestry is irrelevant to
    what those sections test. The now-redundant `-F0pR` passthrough branch and the synthetic
    `p1 launchd /` baseline record were both removed; real `lsof` is never empty, so nothing
    stands in for it. Section D gained a case proving the new property directly — a
    5-field-shaped listing missing `R` (`p1\0cruby\0fcwd\0n/\0`) must refuse — and its two
    cases that depend on reaching the per-record positional check (the bare-`n` and
    non-`fcwd`-descriptor cases) needed an `R1` field added, or the new cycle-length-5 check
    would refuse them before ever reaching the check they exist to exercise. Sections I and Q's
    `mk_raw` single-record fixtures needed the same `R1` addition. Bite checks on scratch
    copies confirmed the stub change did not weaken what sections E and F test: reverting the
    sweep loop's self-exclusion still fails section F (`--sweep zsh` sends the parent a real
    TERM), and reverting the anchored cwd match still fails section E (the sibling gets swept).
    Suite: `69 passed, 69 total, 0 failed`.

12. **Fix wave 5 — the hop budget must fail closed, and the pre-KILL safeguard had no test
    exercising it.** An independent review of the 69/69-green helper found two more defects,
    both confirmed by running the plan:

    - **`_ancestors`'s 64-hop walk exhausted its budget and reported success anyway.** The
      loop was followed unconditionally by `print -rl -- $chain; return 0`, so an unknown
      parent or pid 0 (the top of the reachable tree — fine) and running out of hops (the
      chain is INCOMPLETE, and an ancestor beyond hop 64 stays eligible for TERM and KILL)
      reached the exact same `return 0`. Fixed by tracking whether the walk actually
      terminated at a known boundary (`local -i complete=0`, set at the unknown-parent break
      and the pid-0 break) and refusing (`return 1`) when the loop instead ran out the clock —
      the same fail-closed rule the empty-map case already applied, extended to the other way
      a chain can be incomplete. The function's comment was extended to say so.
    - **Section S no longer exercised the pre-KILL re-proof, and nothing exercised the
      pre-TERM one.** Section S's one case used the one-shot `live.next` fixture, which
      removed the escapee immediately after the *initial* scan — so the pre-TERM check (not
      the pre-KILL check the section's own comment claimed to be testing) is what dropped it,
      and no signal was ever sent. Deleting the pre-KILL safeguard would have left the suite
      green. Fixed by replacing that one case with two, built on the `drop_after` scan
      counter (already used by section T) rather than `live.next`: **S-a** (`drop_after=1`)
      spawns an ordinary `sleep`, present for the initial scan and gone from the pre-TERM
      check onward, asserting it is never signalled at all; **S-b** (`drop_after=2`) reuses
      the section H `deaf.sh` fixture (it must ignore TERM to reach the KILL escalation at
      all), present through the pre-TERM check and gone from the pre-KILL check onward,
      asserting only the pre-KILL safeguard keeps it alive. Both assert the transcript names
      the departure and clean up their `drop_after` marker afterwards.

    Bite checks on scratch copies, never the shipped files: removing the pre-KILL
    `_still_here` call fails S-b's `the escapee was NOT killed on stale evidence` assertion
    (the deaf victim is actually killed); removing the pre-TERM `_still_here` call fails S-a's
    `the pre-TERM departure was NOT signalled` assertion (the victim is actually signalled).
    Reverting the hop-budget fix trips no assertion, old or new: a 65-deep ancestor chain is
    not constructible in this harness (it would need genuinely spawning that many nested
    processes), so no case isolates it, and none was invented to force the point — accepted
    as a gap rather than chased with an unrealistic fixture. Suite: `71 passed, 71 total, 0
    failed`.

### Why `_ancestors` walks with `ps` rather than stopping at `$PPID` — superseded, see item 9

This subsection described the original design and is kept for history; it no longer
matches the shipped code. `_ancestors` no longer uses `ps` at all — fix wave 2 (item 9
above) replaced the walk with one driven by `lsof`'s own `R` field, specifically because
`ps` is denied under the sandbox this paragraph accepted as an untested risk. The
original reasoning:

Curato's hook uses `exec`, giving a two-deep chain (`wt-teardown`, the subshell that cd'd
into the worktree) that `$$` and `$PPID` already cover. A hook that omits `exec` — the
easy mistake, and the shape most projects will write — puts three processes in the
worktree, and only the walk reaches the third. Losing it means killing the shell running
the hook, mid-teardown. There is deliberately no dedicated test case: `ps` is denied
outright under the sandbox (exit 127), and a stub faithful enough to model real parentage
costs more than the twelve lines it would protect. Do not strip the walk as dead code.
