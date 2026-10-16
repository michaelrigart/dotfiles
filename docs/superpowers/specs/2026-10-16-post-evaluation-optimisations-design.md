# Post-evaluation optimisations

**Status:** Approved
**Date:** 2026-10-16
**Branch:** `feat/post-evaluation-optimisations`

Follows the +14-day evaluation of [safe autonomy](2026-09-30-safe-autonomy-design.md) (§5),
recorded in that spec's "Evaluation, 2026-10-16" note. The evaluation passed on avoidable turns
(11.7%, baseline 35%) and on safety, and failed the prompts-per-week criterion on paper. This
spec takes the cheapest findings with the largest measured cost. None of them adds a prompt.

## Problem

Measured over 2026-10-02..16 (52 sessions, 818 human turns after the first):

1. **Wasted subagent calls.** The path-resolution guard denied 1,102 calls, 97% of them in
   subagents writing `cd <absolute path> && …`. 741 of 1,631 subagent transcripts hit it at
   least once; after the denial 86% switch to absolute paths. No instruction mentions the rule.
   Subagents do load `~/.claude/CLAUDE.md`: the "Recursive search" rule in it is there, and that
   denial is rare (29).
2. **Status checks.** They are 65 of the 96 avoidable turns. Most come from plan runs and
   backfills that last hours with no visible progress: "how much work is still left?",
   "are we still making progress?". The subagent-driven-development skill tells the controller
   not to post progress summaries, and nothing else shows where a plan run stands.
3. **`xreview --help`.** 16 dispatches failed with "unknown option: --help": agents probing the
   usage. Each one also counts as a dispatch failure in the evaluation.
4. **Prompts that guard nothing.** 127 permission prompts in 15.5 days. About 22 were
   `rm -rf <repo>/.superpowers/sdd/<plan>`, the git-ignored workspace the SDD skill deletes
   at the end of every plan; it matches the `Bash(rm -rf /Users/michael/*)` ask rule. About 20
   were `git push <remote> --delete <branch>` after a merge, which rule 4 of the push guard
   always asks for. Deleting a branch whose tip is already in the default branch loses nothing.

## Design

### 1. The `cd` rule in the instructions

`claude-code.md` replaces its "Recursive search" bullet with a "Path-resolution guard" bullet
that carries both shapes the guard denies: never start a Bash call with `cd` (use absolute
paths, `git -C`, or a `cd` in a call of its own), and name directories instead of a recursive
`grep`/`rg` over `.`. One bullet, so the reach is every session and every subagent.

### 2. Progress

- **Statusline segment.** When the session's repository has an active plan run, the statusline
  shows `plan <done>/<total>` and, when it can, `~<eta>`.
  - Active: the most recently modified `<toplevel>/.superpowers/sdd/*/progress.md`, modified
    within the last 6 hours, whose first line is `# SDD ledger — plan: <path>`, and whose plan
    file exists under the top level.
  - `total` counts the plan's `### Task <N>` headings; `done` counts distinct `N` in the
    ledger's `Task <N>: complete` lines. Shown only while `0 < total` and `done < total`.
  - ETA: the ledger's age divided by `done`, times `total - done`; shown only when
    `done >= 1` and the ledger was created within the last 12 hours, rounded to minutes
    under an hour, otherwise to half hours.
  - The segment goes last, after the skill. It is the first one dropped when the line is too
    narrow, and any failure (no repository, unreadable ledger, odd format) leaves it out
    silently.
- **Room for it.** Inside a Herdr pane (`HERDR_PANE_ID` set) the statusline drops its
  directory and branch segments, which the Herdr workspace already shows. Outside one it
  keeps them.
- **Instruction.** The global Momentum rule gains one clause: a run expected to take longer
  than about 15 minutes gets its size and ETA when it starts and one line at each milestone,
  without stopping. It covers backfills and other runs that are not plans.

### 3. `xreview --help`

`xreview help`, `xreview -h|--help`, and `--help` or `-h` anywhere after a subcommand print the
usage of every subcommand to stdout and exit 0. Nothing else changes.

### 4. Fewer prompts

- **Finished plan workspaces.** A new `~/.local/bin/sdd-clean <workspace>...` deletes a plan
  workspace only when its real path is `<top>/.superpowers/sdd/<name>`, `<top>` is a git work
  tree's top level, the workspace is not a symlink, and `git check-ignore` reports it ignored.
  Anything else is refused with the reason, and nothing is deleted. The allow list gains
  `Bash(sdd-clean *)`, and `claude-code.md` says to delete a finished workspace with it rather
  than `rm -rf`, which overrides the SDD skill's `rm -rf <workspace>`.
- **Merged-branch deletes.** Rule 4 of the push guard stops asking for a delete-only push
  whose every deleted ref is a merged branch, pinned to the tip that was checked. Every other
  rule-4 check runs first and unchanged. Among them, a remote whose push URL differs from its
  fetch URL, or that has several push URLs, is already refused, so there is one destination.
  - **Delete-only:** `--delete`/`-d` with at least one refspec, or only `:<dst>` refspecs; and
    no `--prune`, `--mirror`, `--all`, `--force`, `-f` or `+` refspec.
  - **Branches only:** each destination is `<name>` or `refs/heads/<name>`, other than the
    default branch.
  - **Merged:** one `git ls-remote` against that push URL reads the current tips of the
    default branch and of every branch being deleted. Each branch exists there, both tips exist
    locally, and each branch tip is an ancestor (`git merge-base --is-ancestor`) of both the
    remote's default tip and the local default branch, `refs/heads/<default>`.
  - **Pinned:** each deleted branch carries `--force-with-lease=<branch>:<sha>` (or
    `refs/heads/<branch>:<sha>`) naming exactly the tip just read. git enforces the lease at
    the push itself, so a commit pushed in between makes the push fail rather than vanish.

  The outcomes:
  - merged and pinned: no ask;
  - merged, but a pin is missing or names another sha: a silent deny whose reason is the exact
    command to run, `git push --force-with-lease=<branch>:<sha> <remote> --delete <branch>`
    with the tip just read;
  - anything else, a network error included: today's ask.

  The remote's default branch can still move backwards between the check and the push, by a
  force-push in a repository that does not forbid one. The deleted commits then still sit on
  the local default branch, so nothing is lost and a push restores them. A delete whose tip the
  local default branch lacks (a forge merge not yet pulled) asks, as today.

## Expected effect

Net prompts: about −40 per two weeks (−22 workspace deletes, −20 branch deletes); nothing
added. Re-measured with `measure-interventions.py --days 14` and the prompt audit at about
2026-10-31, together with the guard-retirement check:

- subagent path-resolution denials down by at least 80%;
- no `xreview` "unknown option" failures;
- status checks below half of today's share of avoidable turns;
- permission prompts per week at or below 34 (the week-41 level).

## Testing

- `statusline.test.sh`: the progress segment from fixture ledgers (active, stale, finished,
  no plan file, odd first line, narrow terminal); directory and branch hidden with
  `HERDR_PANE_ID` set and shown without it. The existing cases run with it unset, since the
  suite itself usually runs in a Herdr pane.
- `xreview.test.sh`: each help form exits 0 with the usage on stdout.
- A new `sdd-clean.test.sh`: deletes a real ignored workspace; refuses a tracked directory,
  a symlink, a path outside `.superpowers/sdd/`, and a non-repository; deletes nothing on
  refusal.
- `git-forge-guard.test.sh`: a merged, pinned delete is silent, by `--delete`, `-d` and
  `:ref`, with a short and a `refs/heads/` lease; a merged delete with no pin, a bare
  `--force-with-lease` or a pin to another sha is denied with the pinned command; each of
  unmerged, default branch, tag, missing on the remote, missing locally, `--prune`, a mixed
  push, an `ls-remote` failure and a tip the local default branch lacks still asks; a remote
  with a separate push URL is still
  refused. Against a real bare remote, git rejects a pinned delete once the branch has moved,
  which is the property the pin relies on.
- `claude-settings.test.sh`: the new allow rule. `agent-instructions.test.sh`:
  both fragments stay within their line caps (180 and 50), trimmed elsewhere if needed,
  with no rule removed.

## Out of scope

Each gets its own spec, in this order:
- A sandbox-escape audit: escapes doubled (2,056 vs 924); make the habitual escapers (`cargo
  test`, python, glab, kubectl, headless Chrome, brakeman) run sandboxed or declare them.
- The global `pre-push` hook for the secret scan (safe-autonomy follow-up).
- The pre-merge gate's fit for diffs over the review cap and for MR writes through `glab api`.

Not addressed: the 10 "continue" turns after the Mac slept mid-run. It stays awake on its own;
the runs broke on a closed lid or a flat battery, which no power assertion prevents.

Also deferred: "undraft also starts a pipeline" as a standing rule, and the 2026-10-13
candidates (mutation testing, N+1 detection).
