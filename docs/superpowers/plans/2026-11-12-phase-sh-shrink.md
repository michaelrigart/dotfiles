# Shrink Herdr's `phase.sh` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented on `refactor/phase-sh` (dotfiles: no MR). Completed 2026-11-13: do not run this plan again; its
execution notes bind that run only. Task 4, Step 4 (the rebase onto the merged `chore/test-audit`) was
deferred by a ruling of 2026-11-13 and done the same day, once that line was on `main` (`832dc90`): a clean
rebase, a fresh suite run and a confirming pre-merge review.

**Goal:** Replace `phase.sh`'s hand-rolled process supervision with `/usr/bin/timeout` and one run
lock, and its Python with `/usr/bin/jq`, keeping every badge and every hardening property.

**Architecture:** `phase.sh refresh` checks its arguments and execs
`/usr/bin/timeout -s KILL <deadline> /bin/bash "$0" _refresh …`. The `_refresh` worker takes one
kernel lock on fd 9, sweeps stale temporary files, then runs one plain background subshell per
repository and waits. The process group `timeout` creates is the only supervisor.

**Tech Stack:** `/bin/bash` 3.2, `/usr/bin/timeout` (Apple's), `/usr/bin/lockf`, `/usr/bin/jq`
1.7.1-apple, git, `glab`, `gh`; the suite is `tests/herdr-phase.test.sh` (bash, stubs on `PATH`).

**Spec:** `docs/superpowers/specs/2026-11-12-phase-sh-shrink-design.md`. Read it first; section
numbers below refer to it. The earlier design is
`docs/superpowers/specs/2026-11-11-draft-status-design.md`.

## Global Constraints

- Script: `dot_config/herdr/executable_phase.sh`. Suite: `tests/herdr-phase.test.sh`. Run the
  suite as `./tests/herdr-phase.test.sh` (never `bash tests/…`); it must run sandboxed.
- `/bin/bash` 3.2 only. No here-documents in the script. No `set -m`, no `trap`, no `python`.
- Nothing calls `herdr` without `$HERDR_ARGS` (`--session`); never `command herdr`.
- Every path absolute; `git` with `-C`; the script still does `cd /` and pins `PATH`.
- Defaults: `RUN_DEADLINE` 40, `LOCK_WAIT` 10, `TTL` 120, `FRESH_GAP` 10, `STALE_PIPELINE` 1800.
- Badge behaviour does not change: no edit to `derive`, `report`, `repo_slug`, `repo_status`,
  `cache_key`, `age_of`, `read_table`, the forge commands' arguments, or the cache file names and
  formats (`<key>.tsv`, `<key>.lookup`, `<key>.mr<iid>.pipeline`).
- A test is never weakened to pass. A pin that no longer applies (it names a removed mechanism)
  is deleted and named in the task report; a pin of visible behaviour or hardening stays.
- Each new or rewritten case states in a comment the behaviour it pins and the bug it catches.
  For each new case: break the script the way the case describes, watch it fail, restore.
- No explanatory comments beyond what the code cannot say; match the surrounding style.
- Commits: small, imperative mood, no agent attribution. Check `git branch --show-current` is
  `refactor/phase-sh` before each commit.
- The machine-wide test lock is saturated: implementers run only `./tests/herdr-phase.test.sh`
  (it does not take the lock when executed directly). The controller runs `./tests/run.sh`.

## Review Focus

1. **`$0` is not executable in every caller.** The suite runs `/bin/bash "$PHASE"`. The exec is
   therefore `timeout … /bin/bash "$0" _refresh …`, never `timeout … "$0"`. Pinned by every
   suite run (Task 2).
2. **A workspace id or run mode with a space or glob** must reach the worker as one word. Task 2
   pins `--workspace 'w 4*'` reporting nothing and running no forge call.
3. **`lockf` failing for a reason other than "held"** (exit 75) must not read as a skip: any
   other non-zero status exits 2 with `lockf`'s own message. Task 2 pins
   `HERDR_PHASE_LOCK_WAIT=abc`.
4. **First run with no cache directory:** the worker creates it before opening the lock. Task 2
   pins a run against an empty `XDG_CACHE_HOME`.
5. **`jq` reading `~/.jq`:** a `.jq` file in `HOME` must not be loaded. Task 3 pins it with a
   `.jq` that would make every program fail.

---

### Task 1: Drop `HERDR_PHASE_CACHE_DIR` and `HERDR_PHASE_TTL`

**Depends on:** nothing.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (the `CACHE_DIR=` and `TTL=` lines, the header's
  mention of `HERDR_PHASE_CACHE_DIR`)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Produces: `CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase"`; `TTL=120` (a constant).
  The suite's cache directory is `$T/cache/herdr-phase` with `XDG_CACHE_HOME="$T/cache"`
  (and likewise for the `cache-hostile*` directories).

- [ ] **Step 1:** In the suite, change every invocation to pass `XDG_CACHE_HOME` instead of
  `HERDR_PHASE_CACHE_DIR`, drop `HERDR_PHASE_TTL`, and point every cache path at the new
  directory. Replace each case that sets `TTL=` with ageing the cache file by `touch -t` (older
  than 120 s to expire it; the default mtime to keep it fresh). In section N's loop over the
  numeric overrides, delete the `TTL` cases (an invalid `HERDR_PHASE_TTL` exiting 2): the
  override they validate is gone. The `LOCK_WAIT` and `RUN_DEADLINE` cases stay until Task 2.
  Add a pin:
  `grep -c 'HERDR_PHASE_CACHE_DIR\|HERDR_PHASE_TTL' "$PHASE"` is 0.
- [ ] **Step 2:** Run `./tests/herdr-phase.test.sh`. Expected: the new pin and the moved cache
  paths FAIL.
- [ ] **Step 3:** Change the two lines in the script; remove `whole_seconds TTL`.
- [ ] **Step 4:** Run the suite. Expected: `0 failed`.
- [ ] **Step 5:** Commit: `Drop the Herdr phase cache-directory and TTL overrides`.

---

### Task 2: `timeout` and one run lock in place of the supervisor

**Depends on:** Task 1.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh`
- Modify: `Library/LaunchAgents/be.netronix.herdr-phase-refresh.plist.tmpl` (comments only)
- Modify: `dot_config/herdr/plugin-phase/herdr-plugin.toml` (comments only, where they describe
  per-repository locks)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Produces:
  - `phase.sh refresh [--force | --fresh] [--workspace ID]`: parses as today (`die` on unknown
    options, exit 2), checks `RUN_DEADLINE`, checks `/usr/bin/timeout` and `/usr/bin/lockf` are
    executable (else `die`), then
    `exec /usr/bin/timeout -s KILL "$RUN_DEADLINE" /bin/bash "$0" _refresh "$run" "$only"`.
  - `phase.sh _refresh <run: ttl|force|fresh> <workspace id or "">`: the worker. Not in `usage`.
  - `RUN_DEADLINE="${HERDR_PHASE_RUN_DEADLINE-40}"` (the default applies only when the variable
    is unset, so an empty value is refused; the suite's `run()` likewise passes
    `"${DEADLINE-40}"` and `"${LOCK_WAIT-10}"`): must match a positive whole number with no
    leading zero; the check is one `case` with the ten digits listed (as `slug_chars_ok` lists
    its characters). Otherwise:
    `phase.sh: HERDR_PHASE_RUN_DEADLINE is not a positive whole number of seconds`, exit 2.
  - `LOCK_WAIT="${HERDR_PHASE_LOCK_WAIT-10}"`, passed to `lockf` unvalidated.
  - Lock: `$CACHE_DIR/run.lock`, created mode 0200 (a subshell with `umask 577`, append-open),
    then `exec 9>>` and `/usr/bin/lockf -s -t "$LOCK_WAIT" 9`. Status 75: print
    `phase.sh: skipped: another refresh holds the lock` on stderr, exit 0. Any other non-zero
    status: exit 2.
  - `write_cache <file> <content>` (the key argument goes): `mktemp "$CACHE_DIR/.tmp.XXXXXX"`,
    write, `mv -f` onto `<file>`; on failure remove the temporary file and return 1.
  - Sweep, in the worker under the lock, before `spaces`:
    `find "$CACHE_DIR" -maxdepth 1 -name '.tmp.*' -mmin +1 -delete` (errors ignored).
  - `refresh_repo <root> <run> <spaces>`: as today minus its lock, its `rm -rf` and its
    `mkdir`. The worker starts it as `( refresh_repo … ) </dev/null &` per repository, then one
    bare `wait`, then returns 0.
- Removed: `spawn_job`, `live_jobs`, `live_groups`, `end_jobs`, `abort_run`, `job_key`, `clock`,
  `wait_jobs`, the three traps, fd 8, `KILL_GRACE`, `whole_seconds`, `JOB_PIDS`, `JOB_ROOTS`.

**The script's header** is rewritten to at most about 30 lines: what the tokens are, the three
drivers and why the timer is not redundant (keep the no-throttling note), the three freshness
modes, the structure above in four lines, and the accepted failure modes of spec section 7, one
line each. The inline hardening comments (`repo_status`, `repo_slug`, the forge calls) stay.

- [ ] **Step 1: Rewrite section N of the suite** ("each repository is its own job", through the
  line before `echo "O. …"`) and adapt the pins elsewhere that name removed mechanisms (the
  `.lock` names in the cache listing of section K, the `.tmp/<key>` paths in sections N and O,
  the `LOCK_WAIT`/`RUN_DEADLINE` default greps, the `whole_seconds` cases, the `clock` cases,
  the `KILLJOB_*` hooks in the `herdr` stub if nothing uses them any more). `run()` passes
  `HERDR_PHASE_LOCK_WAIT="${LOCK_WAIT-10}"` and `HERDR_PHASE_RUN_DEADLINE="${DEADLINE-40}"`. Keep the helpers that still serve (`waitfor`, the
  logging `mv`, the slow/hanging forge stubs); replace `now_s`'s Python with
  `/usr/bin/perl -MTime::HiRes=time` as the `herdr` stub already does. The new section N, one
  case each:

  | Case | Asserts |
  |---|---|
  | side by side | two repositories whose forge stubs each sleep 2 s finish in under 3.5 s; every space is reported exactly once |
  | isolation | repository A's lookup fails with nothing cached; B's spaces get their MR badges, A's get git-only badges; exit 0 |
  | one space | `--workspace w4` gives exactly one report |
  | odd workspace id | `--workspace 'w 4*'` gives no report and no forge call; exit 0 |
  | lock held, skip | with the lock held by the suite and `LOCK_WAIT=1`: exit 0, the stderr line above, no `herdr` and no forge call |
  | lock held, wait | with `LOCK_WAIT=10` and the holder releasing after 1 s: the run reports as usual |
  | bad lock wait | `LOCK_WAIT=abc`: exit 2, no `herdr` call |
  | first run | an empty `XDG_CACHE_HOME`: exit 0, reports made, `run.lock` exists |
  | lock mode | `stat -f %Lp run.lock` is `200` |
  | deadline | `DEADLINE=2`, repository A's forge stub ignores TERM and sleeps 30 s and records its PID: the run ends in under 4 s with exit 137; that PID is dead; a probe takes the lock at once; B's spaces were reported; A's `.tsv` is byte for byte what it was before the run |
  | deadline covers the lock wait | `DEADLINE=2 LOCK_WAIT=10`, lock held throughout: the run is over in under 4 s |
  | TERM | TERM to the run's PID while a forge stub (an ordinary `sleep 30`) hangs: the run exits 143 within 2 s, the stub's PID is dead, the lock is free |
  | bad deadline | `DEADLINE` of `0`, empty, `08`, `1.5`, `x[$(touch $T/pwned)]`: exit 2, the message above, no `herdr` call, and `$T/pwned` does not exist |
  | atomic write | the `mv` log shows each of `.tsv`, `.lookup` and `.mr10.pipeline` written as `mv -f <cache dir>/.tmp.<6 chars> <target>` |
  | killed mid-write | a run KILLed (by a 1 s deadline) while the logging `mv` hangs on the `.tsv` leaves the previous `.tsv` byte for byte and one `.tmp.*` file |
  | sweep | a `.tmp.old` aged 5 minutes by `touch -t` is gone after a run; a `.tmp.new` made just before it is still there; a file named `x.tmp.y` is untouched |
  | no tool | a copy of the script with `/usr/bin/timeout` replaced by `/nonexistent/timeout` exits 2 with a message and makes no `herdr` call |
  | structure | the script has no `set -m`, no `trap `, no `command herdr`, no `kill ` |

  Keep section O's concurrency case (two `--fresh` runs of one space at once make one lookup's
  worth of forge calls) and the plist pins (`AbandonProcessGroup` absent, `StartInterval` 50).
- [ ] **Step 2:** Run `./tests/herdr-phase.test.sh`. Expected: the new section N cases FAIL
  against the old script (at least: lock mode, lock name, deadline exit status, bad deadline
  message, atomic-write paths, sweep, structure). Record which failed.
- [ ] **Step 3:** Implement the Interfaces block in the script, and rewrite its header.
- [ ] **Step 4:** Update the plist's and the plugin's comments where they describe the old
  mechanism ("one refresh of a repository at a time" becomes one refresh at a time). No key or
  command changes.
- [ ] **Step 5:** Run the suite. Expected: `0 failed`. Note the suite's wall time
  (`time ./tests/herdr-phase.test.sh`) in the task report.
- [ ] **Step 6:** For the deadline, lock-skip and atomic-write cases, break the script as each
  comment says (drop `-s KILL`; drop the `lockf`; write the target directly), watch each fail,
  restore. Report the three observations.
- [ ] **Step 7:** Commit: `Run Herdr phase refreshes under timeout and one run lock`.

---

### Task 3: `jq` in place of Python

**Depends on:** Task 2.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`gitlab_rows`, `github_rows`,
  `pipeline_class`, `spaces`, the `PY=` lines and their comment)
- Modify: `AGENTS.md` (the `herdr-phase` paragraph in Testing: the stubbed tools are unchanged;
  add that the script needs `/usr/bin/jq` and `/usr/bin/timeout`)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Produces: `jqi() { HOME=/var/empty /usr/bin/jq "$@"; }`, the only way the script runs `jq`;
  `refresh` also `die`s when `/usr/bin/jq` is not executable.
- The four programs print exactly what the Python printed for every fixture in the suite, with
  `-r` and `join("\t")` (never `@tsv`, which escapes), and keep the exit statuses: `gitlab_rows`
  and `github_rows` return 0 (full), 3 (open rows only: the merged answer is missing or not a
  list) or 1 (the open answer is missing or not a list); the pipeline program fails unless the
  answer is an object whose `iid` equals the one asked for, and prints the status if it matches
  `^[a-z_]{1,40}$`, else `none`; `spaces` prints nothing on unparseable input.
- Each forge answer reaches `jq` as its own `--arg` string, parsed with `try fromjson catch null`
  (never concatenated on stdin; `--argjson` would abort on a bad answer before the program can
  tell which half failed). `halt_error(<n>)` sets an exit status.
- GitHub rows: `isCrossRepository` must be exactly `false`; `state` `OPEN` or `MERGED`;
  `headRefName` a non-empty string with no tab or newline; `number` a number of 1 or more equal
  to its floor, printed without a fraction; `isDraft` exactly `true` gives `1`; the first PR per
  branch and state wins; a merged row is dropped when the branch has an open one. CI from
  `statusCheckRollup`, per item: `.state` if the key exists, else `.conclusion` when `.status`
  is `COMPLETED`, else `.status`; a non-string counts as an unknown state. FAIL
  (`FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE`) gives `fail`; else PEND
  (`QUEUED IN_PROGRESS PENDING EXPECTED REQUESTED WAITING`) gives `run`; else all in
  `SUCCESS SKIPPED NEUTRAL` gives `ok`; else, or an empty or non-list rollup, nothing.
- GitLab rows: per `source_branch` (skip a row without one), an `opened` MR wins, otherwise the
  first seen; columns `branch`, `state`, `iid` (empty when missing), `1` when `draft` is true
  else `0`.

- [ ] **Step 1:** In the suite: replace the hostile-directory Python case (the `json.py` in the
  current directory, near the end) with the `~/.jq` case: run a GitLab and a GitHub refresh with
  `HOME` holding a `.jq` whose content is `def fromjson: error("hijacked");` and assert the MR
  and PR badges are still reported. Change the hostile-`PATH` tool list to drop `python3`. Add
  the pins: no `python` in the script; a copy with `/usr/bin/jq` replaced by `/nonexistent/jq`
  exits 2 with no `herdr` call; a GitHub PR whose `number` is `1.5` or `"7"` is dropped and one
  written `12.0` badges `#12` (spec section 6, item 12).
- [ ] **Step 2:** Run the suite. Expected: the new pins FAIL (the `.jq` case passes vacuously
  until `jq` is used; note that in the report).
- [ ] **Step 3:** Replace the four Python blocks and remove `PY`.
- [ ] **Step 4:** Run the suite. Expected: `0 failed`. Sections K and M are the regression net:
  if one of their cases fails, the program is wrong, not the case.
- [ ] **Step 5:** Break `jqi` (drop `HOME=/var/empty`), watch the `.jq` case fail, restore.
- [ ] **Step 6:** Report every input for which the `jq` programs knowingly differ from the
  Python (beyond the number forms of spec item 12), or "none found".
- [ ] **Step 7:** Commit: `Parse Herdr phase forge answers with jq instead of Python`.

---

### Task 4: Live check, measurements and finish (the controller)

**Depends on:** Task 3.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-12-phase-sh-shrink-design.md` and this plan (Status)

- [ ] **Step 1:** Record `wc -l` of the script and the suite, and the suite's time from
  `./tests/run.sh herdr-phase`, against the baseline taken on `main`.
- [ ] **Step 2: Live comparison** (unsandboxed, needs the live Herdr session). Save
  `herdr workspace list` output; run the deployed `~/.config/herdr/phase.sh refresh --force`,
  save the list again; run the checkout's script the same way, save again. The phase and CI
  tokens of every workspace must be equal between the last two (allowing a real forge change in
  between, checked by hand). Record the checkout script's run time.
- [ ] **Step 3:** Check that a Herdr hook whose command exits 137 shows nothing in the UI or
  its log (spec section 6, item 2); record what was observed. If it shows an error, stop and
  bring it to Michael.
- [ ] **Step 4:** After `chore/test-audit` has merged: `git fetch origin`, rebase onto
  `origin/main`, resolve the suite's conflicts by keeping that line's deletions, re-take the
  baseline time on the new `main`, and run `./tests/herdr-phase.test.sh`.
- [ ] **Step 5:** A cold whole-branch review (`sp-architect`) of `main...refactor/phase-sh`
  against the spec; fix its findings.
- [ ] **Step 6:** Set `**Status:** Implemented` in the spec and this plan (and mark the plan
  completed), and commit. This is the last planned commit.
- [ ] **Step 7:** `./tests/run.sh`, then `./tests/run.sh xreview git-forge-guard wt-functions`,
  on that commit. Report passed/total per suite.
- [ ] **Step 8:** Codex pre-merge review (`xreview dispatch --checkpoint pre-merge`) of that
  commit. Every fix round commits, repeats step 7 and is reviewed again; the head that is pushed
  is one the suites passed on and the review approved. Then push `refactor/phase-sh`.
- [ ] **Step 9:** Final report to the driver session: lines and suite time before and after,
  the dropped behaviour (spec section 6), passed/total, the Codex receipts, and for Michael the
  after-apply commands: reload the LaunchAgent, remove the old cache debris
  (`~/.cache/herdr-phase/*.lock` except `run.lock`, and `~/.cache/herdr-phase/.tmp/`), the
  sandboxed lock probe of spec section 3, `ls /usr/bin/timeout /usr/bin/jq` on hercules, and
  `wt-rm refactor/phase-sh`.
