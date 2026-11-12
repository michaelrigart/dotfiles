# Shrink Herdr's `phase.sh`

**Status:** Approved
**Date:** 2026-11-12
**Sign-off:** Michael, 2026-11-12 (Codex spec review approved, `xr-1794520796-fe06b267`)
**Branch:** `refactor/phase-sh`, in the `wt` checkout `~/.local/share/chezmoi-refactor-phase-sh`
**Origin:** item 36 of the 2026-11-11 setup review: "`phase.sh` (848 lines, a display badge) to
about 150 with `timeout` and one run lock."

## Why

`dot_config/herdr/executable_phase.sh` paints a badge on each Herdr space. It is 848 lines: 301 of
comment, 52 blank and 495 of code. The 2026-11-11 draft-status line added per-repository jobs, and
with them a hand-rolled bash 3.2 process supervisor: one process group per job, a polled deadline
on a fake-able clock, TERM then KILL with a grace, signal traps, per-job reaping and naming, a
per-repository kernel lock and staging directory, and validation of every number that reaches
shell arithmetic. Its review did not converge in four rounds, and the script's header now lists
fourteen accepted limits, most of them corners of that supervisor. `tests/herdr-phase.test.sh` is
2,041 lines and takes about 111 s, a quarter of it (section N) on supervision.

A display badge does not earn that. The kernel and two system tools already do the job.

## Goals

- The same badges: phases `active`, `draft`, `review`, `merged`; the CI token beside an open MR or
  PR; GitLab and GitHub; the freshness of the draft-status spec, section 5 (`--force`, `--fresh`
  with its 10 s gap, the 120 s TTL, per-repository jobs side by side, the 40 s run deadline).
- The same safety: everything that keeps an unsandboxed script holding forge tokens from being
  steered by repository configuration or the caller's directory (pinned `PATH`, `cd /`, the
  neutralised `git status`, no lazy fetch, slug checks, pinned forge hosts, `gh` under `env -i`).
- Atomic cache writes, and stale data preferred over wiping badges on a failed lookup.
- No supervision code in the script: no process groups, traps, polling, clock, grace or reaping.
- A shorter, faster suite. Its time is measured before and after.

## Non-goals

- Any change to what a badge shows or when (derivation order, tokens, icons, TTLs, interval).
- The GitLab lookup's shape: two `glab mr list` calls and one `glab api` call per open MR stay.
  (One GraphQL call per repository would remove `pipeline_class` and its cache, about 40 more
  lines and about 1,000 calls per hour. It changes a lookup the suite pins call by call and needs
  a live check under launchd, so it is a separate line if Michael wants it.)
- Sandbox settings. The lock no longer needs a read-deny (section 3).

## Anti-goals

- Dropping a behaviour without listing it here.
- A badge wiped, or two phase tokens set, because a run was cut short.
- Reaching the line count by deleting hardening or its tests.

## Size

**About 300 to 350 lines, not 150.** Without supervision, lock plumbing, validation and the long
header the script is about 370 lines of today's code; moving its four Python blocks to `jq`
brings it to about 300, plus a short header. The review's 150 was an estimate made before
counting: what is left after supervision is derivation, two forge lookups with CI, caching and
hardening, each of which is visible behaviour or a safety property. Getting near 150 would mean
dropping GitHub or CI badges, the freshness modes, or hardening. This spec does not.

## Approaches

1. **`timeout` and one run lock (chosen).** The script takes one lock, then replaces itself with
   `timeout` running its own worker. The kernel's process group and `timeout` are the supervisor.
   Measured on fenrir (section 2). Removes about 110 lines of code and every supervision test.
2. **Option B from the draft-status line: a `/usr/bin/python3 -I` supervisor.** Still a
   supervisor to write, review and test, in a second language, and `/usr/bin/python3` is an
   install-prompt stub without the Command Line Tools. Rejected: approach 1 needs no supervisor
   at all, and this spec removes Python from the script entirely (section 4). **This settles
   option B.**
3. **No lock.** Atomic writes make concurrent runs safe, and it removes the lock and the sandbox
   question with it. Rejected: a slow timer job could publish an older lookup after a focus
   refresh published a newer one, which is the staleness Michael asked to be rid of, and the
   lock costs four lines.
4. **Keep per-repository locks under `timeout`.** Rejected: the lock exists to order publishes
   and bound forge traffic, and one lock does both; runs last about 8 s, so waiting is cheap.

## Design

### 1. Structure

```
phase.sh refresh [--force | --fresh] [--workspace ID]
  parse and check the arguments and RUN_DEADLINE
  exec /usr/bin/timeout -s KILL "$RUN_DEADLINE" "$0" _refresh <run> <workspace>

phase.sh _refresh <run> <workspace>        (internal; not in the usage text)
  open the run lock on fd 9; wait up to LOCK_WAIT for it, else say so on stderr and exit 0
  sweep stale temporary files
  spaces  ->  one plain background subshell per repository (`&`)  ->  wait
```

- The lock is taken inside the deadline, so waiting for it counts against the 40 s: a run never
  lasts longer than `RUN_DEADLINE`, whatever it waited for.

- Jobs are plain `&` subshells and one bare `wait`. No `set -m`: every descendant stays in the
  process group `timeout` makes for the worker.
- `timeout` is exec'd, so it is the process launchd or a hook started and signals. It forwards
  TERM, HUP and INT to the group.
- At the deadline `timeout` sends KILL to the group: the jobs, their forge calls and `herdr`
  calls all end at once. Nothing can ignore it, so there is no grace. Atomic writes make a KILL
  at any point safe.
- fd 9 is inherited by every descendant, so the kernel frees the lock when the last one exits,
  as it does today. Nothing reclaims or breaks a lock.
- `_refresh` run directly (not through `refresh`) takes the lock but has no deadline. It is not
  documented and nothing calls it; the suite may, to test the worker alone.
- `RUN_DEADLINE` must be a positive whole number of seconds with no leading zero (one `case`
  with the digits listed, as `slug_chars_ok` lists its characters); anything else exits 2 with a
  message before `timeout` runs. Apple's `timeout` reads 0 as "no limit", and a run must never
  be unbounded.

### 2. What was measured (fenrir, macOS 27.2.1, `/bin/bash` 3.2.57, 2026-11-12)

With a worker that starts one ordinary grandchild and one that ignores TERM:

| Case | Result |
|---|---|
| deadline, `timeout -s KILL 1` | both grandchildren dead, lock free, exit 137 |
| deadline, `timeout -k 1 1` (TERM, then KILL) | the TERM-proof grandchild survives: `-k` only follows up while the command itself is alive. Hence `-s KILL` |
| a second run while the first holds the lock, wait 0 | skipped, exit 0 |
| a second run, wait 10 | gets the lock when the first ends, then runs |
| TERM to the run (which is `timeout`) | forwarded to the group; the ordinary grandchild dies, the TERM-proof one survives |
| KILL of `timeout` itself | both grandchildren live on and hold the lock until they end |
| `timeout` with a duration of 0 | no limit at all (its documented meaning) |
| the command exits while a grandchild lives on | `timeout` exits with it and signals nothing; the grandchild survives |
| lock file mode 0200, fd form (`exec 9>>file; lockf -s -t N 9`) | works |
| the same file opened for reading, or `lockf file cmd` | permission denied |

`/usr/bin/timeout` is Apple's (not coreutils'; it has no `--version`), and `/usr/bin/jq` is
`jq-1.7.1-apple`. Both are SIP-protected.

### 3. The run lock

- One file, `<cache dir>/run.lock`, created with mode 0200 and opened for append on fd 9, locked
  with `/usr/bin/lockf -s -t "$LOCK_WAIT" 9`.
- `LOCK_WAIT` is 10 s. A hook that fires during a timer run (about 8 s) waits and then runs, so
  a `worktree.created` hook is not lost; a `--fresh` focus refresh that waited finds the timer's
  stamp younger than `FRESH_GAP` and answers from the cache. A run that cannot get the lock
  prints `phase.sh: skipped: another refresh holds the lock` on stderr and exits 0.
- **The sandbox item is closed here, without a settings change.** `flock` needs an open
  descriptor. A sandboxed command cannot open the file for writing (the cache directory is
  outside the sandbox's write list) and, at mode 0200, cannot open it for reading; it cannot
  `chmod` it either. The plan verifies this from a sandboxed shell after deployment
  (section 7); if it does not hold, the item goes back to Michael as it stands today.
- With the lock inside the deadline, a run that waited 10 s has 30 s left for its lookups.
- The stamp (`<key>.lookup`), the table and the pipeline files keep their names and formats, so
  a deployed cache keeps working.

### 4. `jq` instead of Python

The four Python blocks (the GitLab table, the GitHub table with its CI rollup, the pipeline
status, the workspace list) become `/usr/bin/jq` programs with the same outputs and exit
statuses (0 full, 3 open rows only, anything else failed). Reasons: the script loses its only
dependency that can be a stub, and about 70 lines.

- `jq` is called by absolute path, with `HOME` pointing at an empty system directory so it
  cannot load `~/.jq`, and with no `-L` or `import`.
- Every edge the suite pins in section M and K carries over: a non-list answer is a failed
  lookup; a cross-repository PR, a branch name with a tab or newline, or a non-integer number
  drops the row (`jq` cannot tell `1e0` or `1.0` from `1`, so "integer" becomes "a number of 1
  or more that equals its floor", printed as an integer; section 6); an open PR beats a merged
  one; the CI buckets and their order (fail, then
  pending, then success, else nothing); a pipeline status outside `[a-z_]{1,40}` reads `none`;
  the answer's `iid` must be the one asked for.
- The two answers of a forge go to `jq` as two arguments (`--arg` or `--slurpfile` from a
  process substitution, the builder's call), never concatenated on one stream.

### 5. What else goes, and what stays

Removed with the supervisor: `spawn_job`, `live_jobs`, `live_groups`, `end_jobs`, `abort_run`,
`job_key`, `clock`, `wait_jobs`, the traps, fd 8, `KILL_GRACE`, `whole_seconds` (no override
reaches shell arithmetic any more: the deadline and the lock wait are arguments to `timeout` and
`lockf`; the deadline keeps the one check of section 1), the per-repository lock and the
`.tmp/<key>` staging directories.

- **Temporary files** are made by `mktemp` in the cache directory itself, beside their target,
  with a fixed prefix (`.tmp.`), then renamed. The worker deletes those older than one minute
  when it starts, under the run lock. No `rm -rf`, so the symlinked-`.tmp` limit goes too.
- **Environment overrides.** `PINNED_PATH` (the suite's stubs), `XDG_CACHE_HOME` (a real
  variable), `HERDR_PHASE_RUN_DEADLINE` and `HERDR_PHASE_LOCK_WAIT` stay. `HERDR_PHASE_CACHE_DIR`
  and `HERDR_PHASE_TTL` go: the suite sets `XDG_CACHE_HOME` and ages files with `touch`. They
  are honoured in production as today, and that is accepted: whoever sets the environment of an
  unsandboxed process already runs unsandboxed (`BASH_ENV` reaches bash before line 1). A bad
  `HERDR_PHASE_LOCK_WAIT` fails in `lockf` with its message and no badge update; 0 skips a held
  lock at once, as today.
- **The header** shrinks to what the code cannot say: what drives the script, the three
  freshness modes, the structure of section 1 and the accepted limits below. The history lives
  in the two specs.
- **Stays, unchanged in behaviour:** `repo_status`, `repo_slug`, `cache_key`, `age_of`,
  `read_table`, `mr_table`, the forge calls and their arguments, `pipeline_class`, `derive`,
  `report`, `spaces`, `refresh_repo`'s loop, `/bin/bash` 3.2, no here-documents.

### 6. Dropped or changed behaviour (for Michael)

1. **One lock for all repositories, not one per repository.** Two refreshes never overlap at
   all. A hook waits up to 10 s for a running refresh, then skips (per-repository: up to 30 s,
   one repository).
2. **Exit status at the deadline is 137, not 0,** and at a forwarded TERM 143. launchd does not
   act on it (no `KeepAlive`). The plan checks that a Herdr hook exiting non-zero shows nothing.
3. **No stderr line naming the repository killed at the deadline,** and none for a job that
   ended abnormally. launchd's stderr is `/dev/null`; a stale badge is the signal, as the plist
   says.
4. **KILL at the deadline, with no TERM first.** A forge call gets no chance to clean up. `gh`
   and `glab` keep no state that needs it.
5. **The whole run is under the deadline,** `herdr workspace list` included. Today that call is
   unbounded (an accepted limit); this is a gain.
6. **A hung forge call ends the run for every repository** still working at 40 s, not only its
   own. Jobs that finished have reported. The next run starts 50 s after this one began, as
   today.
7. **Numeric overrides.** `HERDR_PHASE_RUN_DEADLINE=0` is refused (exit 2); today it ends every
   job at once and exits 0. `HERDR_PHASE_LOCK_WAIT` is no longer validated by the script
   (section 5).
8. **`HERDR_PHASE_CACHE_DIR` and `HERDR_PHASE_TTL` are gone.**
9. **Python is no longer used;** `/usr/bin/jq` and `/usr/bin/timeout` are required. If either is
   missing the script exits 2 with a message, before any work. Both machines
   (`.chezmoidata/machines.toml`: fenrir, hercules) need a macOS that ships them; fenrir does,
   **hercules is unverified** (`ls /usr/bin/timeout /usr/bin/jq` there).
10. **The deadline no longer guards against clock steps** by hand; `timeout` owns the timer.
11. **A job whose shell dies while its forge call lives on is no longer cleaned up.** Today the
    run ends that job's whole process group; now the call runs on and holds the lock until it
    ends (section 7).
12. **A PR number written as `1e0` or `1.0` is accepted** as 1; today only a JSON integer is.
    `gh` prints integers.
13. **Old cache debris** (`<key>.lock` files and `.tmp/` directories) is not cleaned by the
    script. The final report gives Michael the one-off command.

### 7. Accepted failure modes

A badge is redrawn every 50 s; each of these costs at most stale badges until the cause ends.

- **KILL of `timeout` itself** (not sent by launchd in normal operation, which sends TERM
  first): its descendants live on, bounded only by their forge calls, and hold the lock. Later
  runs skip after 10 s each. Same as today's first accepted limit. `lsof -t <cache
  dir>/run.lock` names the processes.
- **TERM, HUP or INT to the run:** forwarded once to the group. A descendant that ignores TERM
  survives and holds the lock until it ends. `gh`, `glab`, `git`, `jq` and `herdr` do not ignore
  TERM, and under launchd its own group kill follows the main process's exit.
- **A descendant that leaves the process group** escapes the deadline. Nothing the script runs
  does.
- **A descendant that outlives the worker.** `timeout` signals the group only at the deadline or
  on a forwarded signal. If a job's shell dies on its own (killed by hand, or a failed fork)
  while its forge call runs, the worker's `wait` returns without it, the worker and `timeout`
  exit, and the call lives on with fd 9: every later run skips until it ends. Bounded by the
  forge call, like the KILL case, and found the same way.
- **A job cut by the deadline between two reports** leaves some of its repository's spaces on
  their previous badge until the next run. Each report is one `herdr` call that sets one token
  per group and clears the rest, so no space is left half-painted.
- **Caller environment** reaches the script (overrides, `BASH_ENV`, exported functions, and
  `glab`'s variables), as today.
- **A partial answer** (the merged half failed) is published but not cached, as today.

### 8. Tests

`tests/herdr-phase.test.sh` keeps every section that pins badges, lookups, caching, freshness,
wiring and hardening (A to M, O, I, J and the pinned-PATH case), moved from
`HERDR_PHASE_CACHE_DIR`/`HERDR_PHASE_TTL` to `XDG_CACHE_HOME` and `touch`. Section N
(supervision, about 530 lines) is replaced by cases for the new structure, each naming the bug
it catches:

- repositories run side by side (two slow forge stubs finish in about one stub's time);
- a failing lookup in one repository leaves the other's reports intact;
- `--workspace` is still exactly one report;
- a held lock is waited for, then skipped with the stderr line and exit 0, and no forge call;
- a second run that waits gets the lock and runs;
- the deadline: a forge stub that ignores TERM and hangs is dead after the deadline, the lock is
  free, the other repository was reported, the hung repository's cache file is byte for byte
  what it was, and no temporary file older than a minute survives the next run;
- TERM to the run ends an ordinary hung forge stub and frees the lock;
- a cache write is a rename of a temporary file in the cache directory (the logging `mv`);
- the lock file's mode is 0200;
- a missing `timeout` or `jq` exits 2 before any `herdr` call;
- a run deadline of 0, empty, `08` or `1.5` exits 2 before any `herdr` call;
- a run that waited for the lock still ends at the deadline counted from its start;
- structural pins: the script contains no `set -m`, no `trap`, no `python`, and no bare
  `command herdr` (AGENTS.md).

The plist pin that `AbandonProcessGroup` stays absent remains. Other files that move with the
change: the plist's and the `dev.phase` plugin's comments, and the `herdr-phase` notes in
`AGENTS.md`.

The suite's time is measured with `./tests/run.sh herdr-phase` before the first change and on
the final commit. `chore/test-audit` cuts tests in this suite and merges on 2026-11-13: the line
rebases onto `main` after that merge and before its final run, and the "before" figure is
re-taken on that `main`.

### 9. Live checks

- **Before the push (the line):** an unsandboxed `phase.sh refresh --force` from the checkout
  against the live Herdr session paints the same badges as the deployed script (compare
  `herdr workspace list` metadata before and after), and its run time is recorded.
- **After `chezmoi apply` (Michael):** reload the LaunchAgent (`launchctl bootout` and
  `bootstrap`; the commands go in the final report), watch one cycle, remove the old cache
  debris, and run the sandboxed lock probe of section 3.

## Left to the builder

- How the two forge answers reach `jq`.
- The exact case layout of the new section N, and how the deadline case stays fast (a deadline
  of 1 s is enough).
- Whether `_refresh` takes its arguments as words or flags.
