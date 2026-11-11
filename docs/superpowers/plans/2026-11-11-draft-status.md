# Draft Status for MR and PR Spaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress on `feat/draft-status` (dotfiles: no MR)

**Goal:** Give an open draft MR or PR its own `draft` phase badge, look GitHub PRs up beside GitLab
MRs, and make a status change reach the Herdr sidebar within about 60 s.

**Architecture:** Everything lives in `dot_config/herdr/executable_phase.sh`, the reporter that the
`dev.phase` plugin hooks and the `be.netronix.herdr-phase-refresh` LaunchAgent run. A fourth phase
token (`draft`) joins the phase group. `repo_slug` learns a forge, so GitHub repositories get a
`gh pr list` table in the same format, cache and stale fallback as GitLab's, with CI taken from
the list's `statusCheckRollup`. For freshness, the timer forces every lookup, and a focus refresh
skips the TTL behind a per-repository lookup stamp. Each repository is refreshed as its own
background job, under a lock that allows one refresh of a repository at a time.

**Tech Stack:** bash 3.2 (`/bin/bash`), `/usr/bin/python3 -I` (3.9, stdlib only), `glab` 1.130,
`gh` 2.103, herdr 0.9.5, launchd.

**Spec:** `docs/superpowers/specs/2026-11-11-draft-status-design.md`, approved in `3477b61`, plus
the §5 amendment (per-repository jobs) committed with this plan. Read it before any task; §1–§5
below are the spec's sections.

## Global Constraints

- `phase.sh` runs unsandboxed. It keeps all of these: the `#!/bin/bash` shebang; `PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}`
  as its first command; `cd /`; `/usr/bin/python3 -I`; `git -C`. No here-documents and no
  here-strings, because bash 3.2 writes both to a temp file, which fails from `/` when the script
  runs sandboxed.
- One stable `--source herdr-phase`. Exactly one phase token (`active`, `draft`, `review`,
  `merged`) and at most one CI token (`ci_ok`, `ci_fail`, `ci_run`) are set per report, and the
  rest are cleared: 7 keys per report, under herdr's limit of 16.
- `ICON_DRAFT` is U+EBDB (`\xee\xaf\x9b`). Ref prefixes: `!<iid>` on GitLab, `#<number>` on GitHub.
- The `$draft` sidebar token goes right after `$active`: `{ token = "$draft", fg = "#ff9e64", bold = true }`.
- GitHub lookups are `gh pr list -R github.com/<owner>/<repo> --state open|merged --limit 100 --json …`,
  run from `/`. A GitHub slug is exactly `owner/repo`, each part `[A-Za-z0-9._-]+`, with no `..`.
- A failed or non-JSON answer is a failed lookup. A stale cache beats an empty table. GitHub CI
  read from a cache older than `STALE_PIPELINE` (1800 s) is dropped.
- GitLab lookups and GitLab cache file names stay as they are (§2, Non-goals).
- No `launchctl` action. No token outside the keychain. `chezmoi apply`, the LaunchAgent reload,
  `wt-rm` and merging are Michael's.
- Off-limits, because the parallel `feat/wt-dotfiles` line changes them:
  `dot_claude/modify_private_settings.json`, `.chezmoitemplates/agents/`, AGENTS.md's
  shared-checkout bullet, and the sandbox suites. The one AGENTS.md edit allowed here is the
  `herdr-phase` note under Testing.
- Run suites directly (`./tests/herdr-phase.test.sh`, `./tests/run.sh herdr`), never through an
  interpreter. Report totals as passed/total.
- Commits: imperative mood, no agent attribution, task-sized. Run `git branch --show-current`
  (it must print `feat/draft-status`) right before each commit.

## §5 baseline (measured 2026-11-11, before any change)

Fenrir had 19 linked spaces: four GitLab repositories with 10 open MRs, and two GitHub
repositories (tagteam, dotfiles) that had no lookup yet.

| Measure | Value | How |
|---|---|---|
| LaunchAgent cadence | 202–204 s between run starts (interval 180 s) | the first cache write of each run: 01:41:02, 01:44:24, 01:47:48 |
| Run time under launchd | first to last cache write 18–21 s | cache mtimes |
| Run time, forced | 22.0 s; cold 25.5 s; warm 3.2 s; focus (warm) 0.14 s | the deployed `phase.sh`, `env -i`, its own cache dir, reports swallowed |
| Calls per forced run | 18 `glab` (8 `mr list`, 10 per-MR `api`), each 1.0–1.5 s, all sequential | timed wrapper |
| `gh pr list` | open with rollup 0.5–0.8 s; merged without rollup 0.54 s; merged with rollup 5.1 s and 240 KB | `env -i HOME PATH`, from `/` |
| Worst-case staleness | ~323 s: a focus refresh renews the 120 s TTL cache just before a run, so the run reuses it and the next lookup is one cadence later. Without that, ~203 s | arithmetic over the above |

The cadence is the interval plus about one run time. That fits launchd timing from the previous
exit, and also timer leeway; without `launchctl` the two can't be told apart. Either way, run time
adds straight to staleness.

## Rulings

Trade-offs inside the spec, decided by the line:

1. **CI from the open list's `statusCheckRollup`**, not one call per PR (§2, left to the builder).
   The merged query omits the rollup: measured 5.1 s and 240 KB with it, 0.54 s without.
2. **The rollup's buckets follow `gh pr checks`.** Fail: `FAILURE`, `ERROR`, `CANCELLED`,
   `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE`. Pending: `QUEUED`, `IN_PROGRESS`,
   `PENDING`, `EXPECTED`, `REQUESTED`, `WAITING`. Success: `SUCCESS`, `SKIPPED`, `NEUTRAL`.
   A CheckRun's state is its `conclusion` once `status` is `COMPLETED` and its `status` before
   that; a StatusContext's state is its `state`. A state outside the three buckets (for example
   `STALE`) gives no badge, never `ok`.
3. **`derive` learns the ref prefix from a forge argument**, not a table column (§2, left to the
   builder).
4. **GitHub cache keys are prefixed `github@`.** `@` is outside the GitLab slug alphabet, so a
   GitHub `o/r` (`github@o%2Fr.tsv`) never meets a GitLab `o/r` (`o%2Fr.tsv`), and GitLab's file
   names stay as they are.
5. **`gh` runs under `env -i HOME="$HOME" PATH="$PATH"`**, the environment launchd gives it and in
   which it was measured to authenticate. No caller's `GH_*`, `XDG_CONFIG_HOME`, proxy or CA
   variable (for example from a Herdr server started under direnv) reaches the token. `glab`
   has the same gap today. It stays open (GitLab non-goal) and goes in the report.
6. **The timer forces every lookup** (`refresh --force`). Without that, a focus refresh renews a
   cache and the next timer run reuses it, which is the ~323 s worst case. The TTL (120 s) now
   applies only to the startup and worktree hooks.
7. **The focus refresh is `refresh --fresh --workspace <id>`.** It looks the space's repository up
   (table, and that space's pipeline) whatever the TTL, unless a lookup of that repository
   started less than `FRESH_GAP` = 10 s ago. In that case it answers from the cache, as a failed
   lookup would. The gap is measured from a stamp, `<key>.lookup`, that every forge lookup
   touches before it calls out. The stamp is read and touched only while the repository's lock is
   held (Ruling 11), so a failing forge, or two refreshes at once, are rate-limited too.
   `--force` ignores the stamp (the keybinding and the timer), and the TTL path does not read it.
8. **Cache files are replaced atomically** (`mktemp` beside the file, then `mv -f`). A refresh killed
   mid-write then leaves the previous table, never half of a new one that would later read as a
   valid, shorter table.
9. **Jobs are not capped.** Each repository is refreshed as its own background job (`&` and
   `wait`), the §5 amendment Michael approved on 2026-11-11. There is no cap because the number of
   repositories with linked worktrees is small: 6 today.
10. **StartInterval 50** (the §5 amendment). With per-repository jobs the run is about 8 s, so
    the cadence is about 58 s and a change shows in at most about 65 s. That is 72 runs/h.
11. **One refresh of a repository at a time, under a kernel lock.**
    - Each repository's job opens `$CACHE_DIR/<key>.lock` on file descriptor 9
      (`exec 9>>…`) and takes an exclusive `flock` with `/usr/bin/lockf -s -t "$LOCK_WAIT" 9`
      (`lockf`'s file-descriptor mode, meant for locking inside a shell script).
    - The job holds the lock across that repository's stamp check, lookups, cache writes and
      reports. Two refreshes of the same repository therefore run one after the other, and the
      second one's lookup starts after the first has published.
    - The kernel releases the lock only when every process holding the descriptor has exited:
      the job and every child it started, a report in flight included. Nothing reclaims,
      expires or breaks a lock. An old holder therefore can never publish after its successor,
      and a parent that dies while its job lives on does not release the job's lock (all
      measured on this machine: a second `lockf -t 0` is refused with 75, a waiter gets the lock
      when the holder ends, and a holder killed with `SIGKILL` keeps it until its last child
      exits).
    - A refresh that cannot take the lock within `LOCK_WAIT` = 30 s skips that repository and
      reports none of its spaces; the holder reports them.
    - A stuck holder (a forge call that never returns) is ended by the run deadline (Ruling 12).
    - The lock files stay in place (empty files). Different repositories have different locks, so
      per-repository jobs still run side by side.

12. **A run deadline (driver ruling, 2026-11-12).** The main script waits for its jobs for at
    most `RUN_DEADLINE` = 40 s, under the 50 s interval. Then it ends every unfinished job and
    exits. A hung forge call therefore never holds up the timer for the other repositories.
    - Each job runs in its own process group: `set -m` just for the fork, then `set +m`. At the
      deadline the script sends TERM to that group, and KILL after a short grace. That reaches
      the job's `glab` or `gh` call too, so no process of the job outlives the run. The script
      does this itself rather than relying on launchd, so a hook-started run behaves the same
      as a timer run.
    - The shell's own notice that a job was killed is suppressed: the main shell's stderr goes
      to `/dev/null` during the wait. The jobs keep their own stderr.
    - Measured under the pinned `env -i` environment with bash 3.2: the job's process group is
      its PID, and a group TERM kills a grandchild forge call.
    - Every cache write is atomic, through a temporary file in the same directory and `mv`. That
      covers the MR/PR table, the pipeline status and the focus stamp. A job killed at the
      deadline therefore leaves its cache as it was.
    - **Correction (driver ruling, 2026-11-12).** The first version of this ruling relied on
      launchd's group kill as a second line of defence. That kill cannot reach the jobs, because
      `set -m` puts each one in its own process group. In its place:
      - the main shell traps TERM, HUP and INT;
      - on any of them it sends TERM to every live job group, then KILL after `KILL_GRACE` = 2 s to
        any group that still has a member, then reaps the jobs and exits;
      - the grace is pinned at ≤ 5 s so it fits inside launchd's 20 s `ExitTimeOut` on
        `bootout`/`kickstart -k`;
      - the plist pin that `AbandonProcessGroup` stays absent still covers the main shell's own
        group.
    - **Accepted limit.** A SIGKILL of the main shell cannot be trapped. A job it orphans is
      bounded by nothing: forge calls have no timeout, and a job has no deadline of its own. If a
      forge call hangs, that repository's badges stay frozen until the call ends. `pkill -f
      phase.sh` recovers. Only a manual `kill -9`, or a grace longer than `ExitTimeOut`, reaches
      this.
13. **Accepted limit (driver ruling, 2026-11-12).** A sandboxed command can take a repository's
    lock, because `flock` needs only read access and the lock files are readable from the
    sandbox. That freezes the repository's badges, and every run pays `LOCK_WAIT` for it, bounded
    by the deadline. It writes nothing and runs nothing. The fix is a read-deny for
    `~/.cache/herdr-phase` in the sandbox settings, which `feat/wt-dotfiles` owns. It is a
    follow-up for Michael to decide, not part of this line.

**Call budget at 72 runs/h:**
- GitLab: 2 per repository plus 1 per open MR per run, so 18 per run today, ~1,300/h, against
  GitLab.com's 2,000 per minute per user.
- GitHub: 2 per repository per run, ~290/h for two repositories. Focus lookups add at most one per
  repository per 10 s (360/h × 2 calls), and in practice one per human space switch. Worst case
  ≤ ~1,700/h against 5,000/h.

## Review Focus

- **The 50 s timer and a focus refresh hit the same repository at once.** Neither may read a
  truncated table, and an older lookup that finishes last may not overwrite a newer badge
  (Task 4: lock, reversed-completion test, inode test).
- **A valid empty list (`[]`) is an answer, not a failure.** When a PR is closed, its badge must
  go. Only a failed or non-JSON answer falls back to the cache (Task 2).
- **A rollup can mix CheckRuns (`status`/`conclusion`) and StatusContexts (`state`), with an
  unknown conclusion among successes.** No false `ok` (Task 3).
- **A Herdr server started under direnv or mise carries `GH_CONFIG_DIR`, `GH_HOST`, `GH_TOKEN`,
  `HTTPS_PROXY` or `SSL_CERT_FILE` into its hooks.** None of them may reach `gh` (Task 2).
- **A focus right after a failed lookup, with no cache at all.** No PR state is invented and no
  second call is made within the gap; after the gap, one call (Task 5).

---

### Task 1: The `draft` phase

**Depends on:** none.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (header comment, `usage`, `derive`, `report`)
- Modify: `dot_config/herdr/config.toml` (`[ui.sidebar.spaces]` row 2 and its comment)
- Modify: `dot_config/herdr/plugin-phase/herdr-plugin.toml` (`description`)
- Test: `tests/herdr-phase.test.sh`, `tests/herdr-config.test.sh`

**Interfaces:**
- Produces: `report <ws> <phase> <value> <ci>`, where `<phase>` is one of `active draft review merged`.
  It always emits the four phase keys in that order, then `ci_ok ci_fail ci_run`.
- Produces: `derive` prints `draft <ICON_DRAFT> !<iid>` and then `open <iid>` for an open draft
  MR. The `open` line is unchanged for a ready MR.
- Produces (test helper): `phase_check <ws> <phase> <value> <label>`. It passes when the
  workspace's report carries `--token <phase>=<value>` and `--clear-token <t>` for each of the
  other three phase tokens.

- [ ] **Step 1: Write the failing tests.** In `herdr-phase.test.sh`:
  - Replace the B-section assertion "open draft MR -> active, draft icon" with
    `phase_check w5 draft "$ICON_DRAFT !11" "open draft MR -> draft, carries !11"`.
  - Section C: every report carries 7 keys, and exactly one `--token` for a phase key.
  - Section K: "the draft keeps its phase token beside the pipeline" expects `--token draft=$ICON_DRAFT !11 `.
  - Section A: `--help` prints `Phases: active, draft, review, merged.`
  - Section I: the loop over sidebar tokens covers `active draft review merged`.
  - A new section, "moves between draft and the other phases". It rewrites `$MROPEN`/`$MRMERGED`
    for `feature/draft` and runs `refresh --force --workspace w5` each time. Each step passes
    `phase_check` for the new phase:
    - draft (`!11`) to review (`!11`);
    - review back to draft;
    - draft to active (the MR is gone from both lists);
    - active to draft;
    - draft to merged (`!11` in the merged list only).

  Restore the fixtures afterwards.

  In `herdr-config.test.sh`:
  - `in_order "$SPACES" '$active' '$draft' '$review' '$merged' '$ci_ok' '$ci_fail' '$ci_run' 'token = "branch"'`;
  - `{ token = "$draft", fg = "#ff9e64", bold = true }` is present.
- [ ] **Step 2: Run them and see them fail.** Run `./tests/herdr-phase.test.sh; ./tests/herdr-config.test.sh`.
  Expected: FAIL on the draft and token-count cases.
- [ ] **Step 3: Implement.**
  - `derive`: an open draft MR prints `draft $ICON_DRAFT !$iid`.
  - `report`: the phase loop is `active draft review merged`.
  - The comments above `report` and in the header say four phases and 7 keys.
  - `usage` ends `Phases: active, draft, review, merged.`
  - `config.toml`: add the `$draft` entry after `$active`; the row comment says four tokens.
  - Plugin `description = "Badge worktree spaces with active / draft / in review / merged"`.
- [ ] **Step 4: Run them and see them pass.** Same command. Expected: `RESULT: N passed, N total, 0 failed`
  for both.
- [ ] **Step 5: Commit.** `git add` the four files plus the two suites, then
  `git commit -m "Give an open draft MR its own draft phase badge"`.

### Task 2: GitHub PR lookups

**Depends on:** Task 1.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`repo_slug`, `cache_key`, `mr_table`, a new
  `gitlab_rows` and `github_rows`, `derive`, `cmd_refresh`, header comment)
- Modify: `AGENTS.md`, the `herdr-phase` note under Testing only: "stubs `herdr`, `glab` and `gh`
  on `PATH`"
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Consumes: `report`, `phase_check` (Task 1).
- Produces:
  - `repo_slug <repo_root>` prints `<forge> <slug>` (`gitlab` or `github`), or fails.
  - `cache_key <forge> <slug>` prints `<slug with / as %2F>` for gitlab and
    `github@<slug with / as %2F>` for github.
  - `mr_table <forge> <slug> <force:0|1>` prints the table or fails. It keeps its cache, TTL and
    stale fallback; Task 5 replaces `<force>` with a mode.
  - `gitlab_rows <slug>` and `github_rows <slug>` print table rows. Exit 0 is a full answer
    (cache it). Exit 3 means the open rows only, because the merged half failed (use it, don't
    cache it). Anything else is a failed lookup.
  - Table row: `branch<TAB>opened|merged<TAB><number><TAB>0|1[<TAB><ci>]`. Column 5 exists only on
    GitHub rows: `ok`, `fail`, `run` or empty on open rows, empty on merged ones. Task 3 fills it;
    this task writes it empty.
  - `derive <checkout> <root> <table> <forge>`: the ref is `!<n>` (gitlab) or `#<n>` (github). The
    second line is `open <n>`, plus ` <ci>` when column 5 is non-empty.

- [ ] **Step 1: Write the failing tests.**
  - Add a `gh` stub beside `glab`.
    - It answers `pr list -R github.com/<o>/<r> --state open|merged --limit 100 --json <fields>`
      from per-repository fixture files. Any other `-R` form, or a missing `--limit 100`, is an
      error exit.
    - It logs `gh $*` to the call log and its working directory to `$PWDS`, and dumps its
      environment to a file.
    - `gh` runs under `env -i`, so the stub gets its paths from a file at a fixed location the
      suite writes, not from the environment.
    - Failure modes: exit 1 with a message on stderr; `garbage` with exit 0; `{"message":"x"}`
      with exit 0; and the merged half alone failing.
  - Add a third repository with a `git@github.com:test/proj3.git` remote and worktrees for:
    - an open ready PR (`#21`);
    - an open draft PR (`#22`);
    - a merged PR (`#23`);
    - a branch whose only PR is cross-repository (`isCrossRepository: true`, `#24`);
    - a branch with a merged `#25` and an open `#26`.

    Use its own workspace JSON.
  - Assertions:
    - `review $ICON_MR #21`, `draft $ICON_DRAFT #22`, `merged $ICON_MERGE #23`.
    - The cross-repository PR leaves the space `active`.
    - The reused branch reports `review … #26`.
    - Draft to ready (`isDraft` flips) moves `#22` to `review`.
  - Calls:
    - A cold refresh makes exactly 2 `gh pr list` calls for the repository, one `--state open`
      and one `--state merged`. The merged call's `--json` has no `statusCheckRollup`.
    - Every call has `-R github.com/` and runs from `/`.
    - Inside the TTL there are no calls; `--force` and `TTL=0` make 2.
  - Environment: with `GH_HOST`, `GH_REPO`, `GH_CONFIG_DIR`, `GH_TOKEN`, `GITHUB_TOKEN`,
    `XDG_CONFIG_HOME`, `HTTPS_PROXY` and `SSL_CERT_FILE` exported by the caller, none of them is
    in the stub's environment.
  - Failures, on a warm cache:
    - exit 1, `garbage`, or an object answer each keep `review … #21` (stale over empty);
    - the merged half failing keeps the open rows, drops `merged`, and is not cached (the next
      run makes 2 calls);
    - a cold cache plus a failure gives no PR state.
  - A valid `[]` for both states replaces the table: `#21` goes back to `active`.
  - Slugs. These make a `gh` call with `-R github.com/test/proj3`:
    - `git@github.com:test/proj3.git`;
    - `https://github.com/test/proj3`;
    - `https://github.com/test/proj3.git`;
    - `ssh://git@github.com/test/proj3.git`.

    These make no `gh` call:
    - `git@github.com:a/b/c.git`;
    - `https://github.com/a/../b`;
    - `https://github.com/a/b?x=1`;
    - `git@github.com.evil.com:a/b.git`;
    - `https://evil.com/github.com/a/b`.
  - Cache keys: a GitLab `test/proj3` and a GitHub `test/proj3` in one run leave
    `test%2Fproj3.tsv` and `github@test%2Fproj3.tsv`, and each space shows its own forge's badge.
  - Section G: the "no forge" remote becomes `git@codeberg.org:test/proj.git`, and there is no
    `glab` and no `gh` call for it.
- [ ] **Step 2: Run them and see them fail.** Run `./tests/herdr-phase.test.sh`. Expected: FAIL on
  every GitHub case. The GitLab cases still pass.
- [ ] **Step 3: Implement.**
  - `repo_slug` checks the three GitHub prefixes exactly (`git@github.com:`,
    `https://github.com/`, `ssh://git@github.com/`) before the GitLab test. It strips one
    trailing `.git` and checks `owner/repo`.
  - `mr_table` keeps its cache logic and calls `gitlab_rows` (today's two `glab` calls and parser,
    moved unchanged) or `github_rows`.
  - `github_rows` runs `env -i HOME="$HOME" PATH="$PATH" gh pr list -R "github.com/$slug" …`, once
    per state, and takes each exit status on its own.
  - One `python3 -I` parse:
    - each answer must be a JSON list;
    - drop cross-repository rows, a branch holding a tab or newline, and a non-integer number;
    - map `OPEN` to `opened` and `MERGED` to `merged`;
    - an open row wins over a merged one for the same branch.
  - `cmd_refresh` splits `repo_slug`'s output with parameter expansion and passes the forge to
    `mr_table` and `derive`. CI stays GitLab-only (`pipeline_class`) until Task 3.
- [ ] **Step 4: Run them and see them pass.** Run `./tests/herdr-phase.test.sh`. Expected: 0 failed.
- [ ] **Step 5: Commit.** `git commit -m "Look up GitHub PRs for Herdr space badges"` (phase.sh,
  the suite, AGENTS.md).

### Task 3: GitHub CI from the PR list's rollup

**Depends on:** Task 2.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`github_rows` parse, `mr_table` cache reads,
  `cmd_refresh` CI choice)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Consumes: table column 5 and `derive`'s `open <n> <ci>` (Task 2), and `ci_check` (section K).
- Produces: `read_table <cache_file>` prints the cached table. It blanks column 5 when the file is
  older than `STALE_PIPELINE`. Every cache read in `mr_table` goes through it.

- [ ] **Step 1: Write the failing tests.** Give the open PR `#21` these rollups in turn, then run
  `refresh --force` on its space and `ci_check` it:

  | Rollup | Expect |
  |---|---|
  | `[]` | none |
  | all CheckRun `COMPLETED`/`SUCCESS` | ok |
  | `SUCCESS`, `SKIPPED`, `NEUTRAL` | ok |
  | successes and one `FAILURE` | fail |
  | each of `ERROR`, `CANCELLED`, `TIMED_OUT`, `ACTION_REQUIRED` and `STARTUP_FAILURE`, alone | fail |
  | `IN_PROGRESS` and `SUCCESS` | run |
  | `QUEUED` | run |
  | StatusContext `PENDING` | run |
  | StatusContext `ERROR` | fail |
  | `FAILURE` and `IN_PROGRESS` | fail |
  | CheckRun `SUCCESS` and StatusContext `SUCCESS` | ok |
  | `SUCCESS` and a `COMPLETED`/`STALE` | none |
  | `statusCheckRollup` not a list | none |

  Also:
  - the draft `#22` shows its CI;
  - the merged `#23` shows none;
  - CI costs no extra `gh` call (still 2 per repository).
  - Stale limit: warm the cache, make `gh` fail, and age the `.tsv`:
    - 29 minutes: CI kept;
    - 31 minutes: the CI tokens are cleared and `review … #21` is kept.
- [ ] **Step 2: Run them and see them fail.** Run `./tests/herdr-phase.test.sh`. Expected: FAIL on
  the CI cases.
- [ ] **Step 3: Implement.**
  - The open-state parse computes column 5 from `statusCheckRollup` using Ruling 2.
  - `mr_table` reads every cache through `read_table`.
  - In `cmd_refresh`, the CI is `pipeline_class` for gitlab, and for github it is the `open`
    line's third word, kept only if it is `ok`, `fail` or `run`.
- [ ] **Step 4: Run them and see them pass.** Same command. Expected: 0 failed.
- [ ] **Step 5: Commit.** `git commit -m "Badge GitHub PR checks from the PR list's rollup"`.

### Task 4: Refresh each repository as its own locked job

**Depends on:** Task 3. Implements the §5 amendment and pins each of its constraints, plus
Rulings 8 and 11.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`cmd_refresh`, a new `refresh_repo`, the lock,
  atomic cache writes, header comment)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Consumes: `repo_slug`, `cache_key`, `mr_table`, `pipeline_class`, `derive`, `report`.
- Produces:
  - `refresh_repo <root> <force:0|1> <spaces>` handles one repository's spaces
    (`ws<TAB>path<TAB>root` lines). It works out the slug, takes the repository's lock, fetches
    the table, then derives, looks up CI for and reports each space, and releases the lock.
    Task 5 replaces `<force>` with a run mode.
  - `cmd_refresh` starts one `refresh_repo` per repository in `spaces` order, each as a
    background subshell, and `wait`s for all of them.
  - Each job opens `$CACHE_DIR/<key>.lock` on fd 9 and takes it with
    `/usr/bin/lockf -s -t "$LOCK_WAIT" 9` (Ruling 11). When that fails, the job exits 0 without
    reporting.
  - `age_of <file>` prints seconds since the file's mtime, or a large number when it is missing.
  - Every cache write goes through `mktemp "$cache.XXXXXX"` and `mv -f`.

- [ ] **Step 1: Write the failing tests.** Add a section, "each repository is its own job":
  - **No repository waits for another.** `test/proj`'s `glab mr list` stub blocks until a report
    for a `test/proj2` space shows up in the call log, then logs `overlap`. After 5 s it gives up
    and logs `timeout`. Since `spaces` sorts `test/proj` first, a sequential run must time out.
    A full `refresh --force` logs `overlap` and no `timeout`.
  - **One report per workspace.** In that run every linked space is reported exactly once, all
    with `--source herdr-phase`, 7 keys and exactly one phase `--token`. The phases match
    section B's.
  - **A failing lookup stays in its own repository.** With `test/proj`'s lookups failing on a
    cold cache, `test/proj2`'s spaces still get their own badges (`!`-numbers from their own
    table). `test/proj`'s spaces fall back to git-only phases, and RC is 0.
  - **The tables never mix.** Both repositories carry an MR on the same branch name with
    different numbers, and each space reports its own repository's number.
  - **The run takes as long as its slowest repository.** Three repositories, each stub sleeping
    1 s per `mr list` call (2 s per repository): the run finishes in under 4.5 s, where a
    sequential run takes at least 6 s.
  - **A single space is one report.** `refresh --workspace w4` still makes exactly one report.
  - **An older lookup never lands last.** The test steps:
    1. A stub's first open-list call for `test/proj` answers `feature/draft` as a draft. It
       creates a "started" marker and sleeps 2 s.
    2. Every later call answers it ready.
    3. Run A, `refresh --force --workspace w5`, in the background, and wait for the marker.
    4. Run B, the same command, and wait for both.

    Assertions:
    - the last report for w5 is `review … !11`;
    - the cached `.tsv` has draft `0`;
    - B's lookup started after A's report (the order in the call log).
  - **A held lock is waited for, then skipped.**
    - The suite holds `test/proj`'s lock from its own subshell (`exec 9>>…`, `lockf -s 9`,
      `/bin/sleep 3`).
    - A `refresh --force` with `LOCK_WAIT` lowered to 1 reports no `test/proj` space, still
      reports every `test/proj2` space, and exits with RC 0.
    - To lower `LOCK_WAIT`, the suite gets an override variable, `HERDR_PHASE_LOCK_WAIT`, as it
      has `HERDR_PHASE_TTL`.
  - **A dead parent does not free its job's lock.** Start A as in the reversed-order case (its
    lookup stalls 2 s), and kill A's top-level `bash` once the marker appears. B
    (`LOCK_WAIT=10`) then waits for A's job; B's lookup starts after A's report, and the last
    report for w5 is B's `review … !11`.
  - **No lock outlives its run.** After every case above, `lockf -s -t 0` on each `.lock` file
    succeeds.
  - The section K listing gains the lock files:
    `a%2Fb_c.lock a%2Fb_c.mr10.pipeline a%2Fb_c.tsv a_b%2Fc.lock a_b%2Fc.mr10.pipeline a_b%2Fc.tsv `.
  - **Atomic writes.** The `.tsv`'s inode changes across a forced lookup, and no temporary file is
    left in the cache dir.
- [ ] **Step 2: Run them and see them fail.** Run `./tests/herdr-phase.test.sh`. Expected: FAIL
  with `timeout` logged, on the timing bound, the reversed order, the held lock, the dead
  parent and the inode.
- [ ] **Step 3: Implement.**
  - Group `spaces` lines by `root` into `refresh_repo` calls in background subshells, then `wait`.
  - `LOCK_WAIT` honours `HERDR_PHASE_LOCK_WAIT`, for the suite only; its default is 30 s.
- [ ] **Step 4: Run them and see them pass.** Run `./tests/herdr-phase.test.sh`. Expected: 0 failed.
- [ ] **Step 5: Commit.** `git commit -m "Refresh each repository's Herdr badges as its own locked job"`.

### Task 5: A focus refresh and timer that keep the badge fresh

**Depends on:** Task 4.

**Files:**
- Modify: `dot_config/herdr/executable_phase.sh` (`FRESH_GAP`, `--fresh`, lookup modes, the
  stamp, `usage`, the header comment)
- Modify: `dot_config/herdr/plugin-phase/herdr-plugin.toml` (the focus hook and its comment)
- Modify: `Library/LaunchAgents/be.netronix.herdr-phase-refresh.plist.tmpl` (`--force`,
  `StartInterval` 50, comments)
- Test: `tests/herdr-phase.test.sh`

**Interfaces:**
- Consumes: `refresh_repo`, `age_of`, `mr_table`, `pipeline_class`, `read_table`,
  `cache_key`.
- Produces:
  - `refresh [--force | --fresh] [--workspace ID]`.
  - `refresh_repo <root> <run: ttl|force|fresh> <spaces>`.
  - The lookup mode is `ttl`, `force` or `cached`:
    - `mr_table <forge> <slug> <mode>` and `pipeline_class <slug> <iid> <mode>` take it in place
      of the `force` flag;
    - `cached` never calls out; it answers as a failed lookup would.
  - The stamp `$CACHE_DIR/<key>.lookup` is written (atomically, Ruling 12) right before every forge lookup, always under
    the repository's lock.

- [ ] **Step 1: Write the failing tests.**
  - `--fresh --workspace w4` on a warm TTL cache makes 2 `mr list` calls and 1 `api` call.
  - Again at once: 0 calls, and the report is still `review … !10` with its CI.
  - With the stamp aged 11 s (`touch -t`): 2 and 1 again.
  - `glab` failing: `--fresh` after an aged stamp makes its calls and keeps the cached badge;
    `--fresh` again at once makes 0 calls.
  - A cold cache with a fresh stamp: no PR state and 0 calls.
  - **Concurrent `--fresh`.** Two `--fresh --workspace w4` processes start together with an aged
    stamp. The `mr list` stub sleeps 1 s. Exactly 2 `mr list` calls are made (one lookup), both
    processes report `review … !10`, and RC is 0 for each.
  - `--force` right after `--fresh` makes its calls. `--fresh` right after `--force` makes 0.
  - Default `refresh` keeps the TTL rules: the section D counts are unchanged.
  - A gated `--fresh` shows a pipeline cache 29 minutes old, and clears the CI tokens at 31.
  - A GitHub space under `--fresh`: 2 `gh` calls, then 0.
  - The section K listing becomes
    `a%2Fb_c.lock a%2Fb_c.lookup a%2Fb_c.mr10.pipeline a%2Fb_c.tsv a_b%2Fc.lock a_b%2Fc.lookup a_b%2Fc.mr10.pipeline a_b%2Fc.tsv `.
  - Section I:
    - the plist's ProgramArguments carry `refresh` then `--force`;
    - its `StartInterval` is between 30 and 60 s, replacing the 1–10 minute case;
    - the focus hook passes `--fresh --workspace`;
    - its fallback with no workspace id is a plain `refresh`.
- [ ] **Step 2: Run them and see them fail.** Run `./tests/herdr-phase.test.sh`. Expected: FAIL on
  the `--fresh`, stamp, concurrency and wiring cases.
- [ ] **Step 3: Implement.**
  - `FRESH_GAP=10`.
  - Inside `refresh_repo`, with the lock held, the repository's mode is:
    - `force` under `--force`;
    - under `--fresh`, `cached` when `age_of` the stamp is under `FRESH_GAP`, and `force`
      otherwise;
    - `ttl` with neither.
  - `usage` documents `--fresh`.
  - The header, plugin and plist comments describe the new cadence: timer forced every 50 s,
    focus fresh within 10 s, TTL for startup and worktree events, one refresh per repository at a
    time.
  - `StartInterval` is 50.
- [ ] **Step 4: Run them and see them pass.** Same command. Expected: 0 failed.
- [ ] **Step 5: Commit.** `git commit -m "Keep Herdr phase badges within a minute of the forge"`.

---

## Close-out (the controller, not a subagent)

1. Run `./tests/run.sh` (full) and `./tests/run.sh xreview git-forge-guard wt-functions`, and
   record each as passed/total.
2. Measure §5 after, with the same harness as the baseline: the branch's `phase.sh` against the
   live session, reports swallowed, its own cache dir, unsandboxed.
   - Record the cold and forced run time, the warm time, a `--fresh` focus time, and the calls
     per run.
   - The cadence after is the interval plus the run time, computed; it can only be measured once
     Michael reloads the LaunchAgent.
3. Run the §4 pre-push gate: the branch's exact `gh pr list -R github.com/michaelrigart/tagteam …`
   calls (open with the rollup, merged without), unsandboxed from `/`, under
   `env -i HOME PATH=<pinned>`. It must return JSON.
4. Run the Codex pre-merge review (`xreview … --checkpoint pre-merge --diff main...feat/draft-status`)
   and iterate to approval.
5. Final commit: the spec and this plan go to `**Status:** Implemented on feat/draft-status (no MR)`,
   and this plan is marked completed.
6. Push `feat/draft-status`.
7. Report to chezmoi-c2. Michael's steps after the merge:
   - `chezmoi apply`;
   - `launchctl bootout gui/$(id -u)/be.netronix.herdr-phase-refresh` and then
     `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/be.netronix.herdr-phase-refresh.plist`;
   - a Herdr config reload, or a server restart, for `$draft`;
   - check that `launchctl kickstart -k gui/$(id -u)/be.netronix.herdr-phase-refresh` during a run
     leaves no `phase.sh` job behind (Ruling 12's trap);
   - check that a UI-driven space switch fires `workspace.focused` on 0.9.5 (badge current within
     a few seconds of focus);
   - `wt-rm feat/draft-status`.
