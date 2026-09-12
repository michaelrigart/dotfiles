# Worktree teardown helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `.worktreehook teardown` something to call, so `wt-rm` stops project processes instead of refusing because one is still running.

**Architecture:** A machine-level zsh script `~/.local/bin/wt-teardown` owns all mechanics and refusals — scanning `lsof` by cwd, proving a pid belongs to the worktree, TERM→KILL escalation. A project's `.worktreehook` owns only declaration, passing `--pidfile` and `--sweep` flags. Neither holds the other's knowledge.

**Tech Stack:** zsh (subject, matching `_wt_live_processes`' idioms and guaranteed present on macOS), bash 5 (test suite, via `#!/usr/bin/env bash` → `/opt/homebrew/bin/bash`), `lsof`, POSIX `sh` (the curato hook).

**Spec:** `docs/superpowers/specs/2026-09-11-worktree-teardown-helper-design.md`


> **The appendix is normative.** Both files in Appendix A were built and run during plan
> review: the suite reported `53 passed, 53 total, 0 failed`, and an 11-mutant battery
> against the subject was caught in full. A later fix wave (Appendix B, item 9) replaced
> `_ancestors`, reworked pidfile-clearing, and re-proved ownership before escalation; the
> appendix above now reflects that shipped content, and the suite reports
> `64 passed, 64 total, 0 failed`. Where a task's inline snippet and the appendix
> disagree, the appendix wins — the tasks define the increments and the order, the
> appendix defines the finished content. Defects found only by running it, across every
> wave, are recorded in Appendix B; do not re-introduce them.

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

# _ancestors — this pid and every ancestor, one per line.
#
# Unconditional, not merely covered by the allowlist: wt-rm runs the hook with cwd inside the
# worktree, so this process and the chain that started it appear in every scan. A repository
# declaring `--sweep zsh` must not kill the shell interpreting its own hook.
#
# Ancestry comes from lsof's own R field rather than from `ps`. ps is unavailable under the
# sandbox agents run wt-rm in, and a walk that stops early there returns a TRUNCATED chain while
# reporting success — which leaves a grandparent eligible to be signalled whenever a hook omits
# `exec`.
#
# The walk climbs while parents are known, and treats an unknown parent as the top of the
# reachable tree, not an error (RULING R9): MINE only needs to cover every ancestor that could
# also be a sweep target, sweep targets come from OCCUPANT, and OCCUPANT and this function's
# parent map are built from the very same lsof listing — so an ancestor lsof cannot report can
# never be a target either, and stopping the climb there loses nothing. On macOS the first
# unreadable link is the root-owned `login` every session descends from; above it lie only root
# processes whose cwd is never inside a user worktree. What must never happen is a chain
# truncated BELOW a visible ancestor — exactly what the old `ps` walk did whenever ps was
# unavailable. Fails closed only where nothing at all is known: an unreadable lsof call, or an
# empty parent map.
_ancestors() {
  emulate -L zsh
  local -a lines
  local -A parent
  local rc i pid ppid p
  local -a chain
  lines=( ${(0)"$(LC_ALL=C command lsof -w -d cwd -F0pR 2>/dev/null)"} ); rc=$?
  (( rc )) && return 1
  lines=( ${lines#$'\n'} )
  local cur=""
  for (( i = 1; i <= ${#lines}; i++ )); do
    case "${lines[i]}" in
      p<1->) cur="${lines[i]#p}" ;;
      R<0->) [[ -n "$cur" ]] && parent[$cur]="${lines[i]#R}" ;;
    esac
  done
  (( ${#parent} )) || return 1
  # Climb while the parents are known. An unknown parent is the top of the tree we can SEE, not
  # an error: the parent map and OCCUPANT are built from the same lsof listing, so an ancestor
  # lsof cannot report can never be a sweep target either. On macOS the climb stops at the
  # root-owned `login` every session descends from — above it are only root processes whose cwd
  # is never inside a user worktree. What must not happen is a chain cut below a VISIBLE
  # ancestor, which is precisely what the old `ps` walk did whenever ps was unavailable.
  p=$$
  chain=( $p )
  local -i hops=0
  while (( ++hops <= 64 )); do
    (( ${+parent[$p]} )) || break
    p="${parent[$p]}"
    (( p == 0 )) && break
    chain+=( "$p" )
  done
  print -rl -- $chain
  return 0
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
    if [[ "${lines[i]}" != p<1-> || "${lines[i+1]}" != c* || \
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
  # Ownership is proved at scan time, and KILL lands up to TERM_WAIT seconds later. A process
  # that trapped TERM and left the worktree, or a pid recycled inside that window, is no longer
  # the process we identified — so re-prove occupancy before the escalation, and drop whatever
  # can no longer be shown to be here. A fresh scan narrows the window to sub-second; nothing a
  # shell can do makes pid identity atomic.
  local -a still
  local rescan
  rescan="$(_scan "$WT")" || return 1
  typeset -A here
  for rescan in ${(f)rescan}; do
    [[ -n "$rescan" ]] && here[${rescan%% *}]=1
  done
  still=()
  for p in $left; do
    if (( ${+here[$p]} )); then
      still+=( "$p" )
    else
      print -r -- "$PROG: $p left $WT before escalation — not killing it"
    fi
  done
  left=( $still )
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
scan_out="$(_scan "$WT")" || exit 1

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

if _stop $TARGETS; then
  typeset f fpid
  for f in ${(k)CLEAR_PIDS}; do
    fpid="${CLEAR_PIDS[$f]}"
    # Confirmed gone, not merely "we tried": a file naming a process that is still alive is the
    # only handle anything has on that process, and the retry needs it.
    kill -0 "$fpid" 2>/dev/null && continue
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
cat > "$T/bin/lsof" <<'STUB'
#!/bin/sh
d="$(dirname "$0")"
# The ancestry call (-F0pR) is about this machine's real process tree, not about the
# worktree-occupancy fixtures below — so hand it off to the real lsof rather than fake it.
for a in "$@"; do
  if [ "$a" = "-F0pR" ]; then
    exec /usr/sbin/lsof "$@"
  fi
done
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
# A one-shot transition: if a successor fixture is staged, it takes effect from the NEXT call.
# This is how a test can say "the process left the worktree between the scan and the escalation",
# which is the only difference X1's re-check can detect.
if [ -f "$d/live.next" ]; then
  mv "$d/live.next" "$d/live"
fi
STUB
chmod +x "$T/bin/lsof"
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
mk_raw 'p%s\0csleep\0fcwd\0n%s\0' "$stubborn" "$WT"
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
# X1: a process that leaves the worktree between TERM and KILL is no longer the process we
# identified. It must not be killed on the old evidence. The victim ignores TERM, so it survives
# to the escalation; the staged successor fixture drops it from the listing, which is how it
# "leaves". Without the re-check, KILL lands on it and it dies.
rm -f "$T/escapee.ready"
escapee="$(spawn "$T/deaf.sh" "$T/escapee.ready")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$T/escapee.ready" ] && break; sleep 0.2; done
is "the escapee fixture installed its TERM trap" \
  "$([ -e "$T/escapee.ready" ] && echo yes || echo no)" "yes"
mk_live <<EOF
$escapee deaf.sh $WT
EOF
: > "$T/bin/live.next"     # from the next scan onward it is no longer in the worktree
out="$(PATH="$T/bin:/usr/bin:/bin" WT_WORKTREE="$WT" \
  WT_TEARDOWN_TERM_WAIT=1 WT_TEARDOWN_KILL_WAIT=1 \
  zsh "$SUBJECT" --sweep deaf.sh teardown 2>&1)"
is "teardown exits clean once the escapee is gone from the worktree" "$?" "0"
sleep 1
is "the escapee was NOT killed on stale evidence" \
  "$(kill -0 "$escapee" 2>/dev/null; echo $?)" "0"
has "and the transcript says why" "$out" "before escalation"
kill -9 "$escapee" 2>/dev/null
rm -f "$T/bin/live.next"

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
