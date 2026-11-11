# Archive finished review threads

**Status:** Implemented (branch `feat/archive-review-threads`; no MR, a dotfiles line)
**Date:** 2026-11-11
**Sign-off:** Michael, 2026-11-11 (Codex spec review approved in round 3, `xr-1794359940-6c5ebaf4`)
**Amended:** 2026-11-11, after §0's check failed. Michael's ruling: keep this design and report
the app's catalog bug upstream. See "Amendment (2026-11-11)" below; the sections it changes say
so where they stand.
**Branch:** `feat/archive-review-threads`, in the `wt` checkout
`~/.local/share/chezmoi-feat-archive-review-threads` (a dotfiles `wt` line run before the rules
that allow it are merged; see `docs/superpowers/specs/2026-11-11-wt-dotfiles-design.md` §5 on
`feat/wt-dotfiles`, and "Where this line runs" below)
**Design chosen:** Michael, 2026-11-11, in conversation (option 1 of three)

**Where this line runs.** Until `feat/wt-dotfiles` is merged and applied, a dotfiles sibling has
none of the sandbox's root-keyed write denials. Michael accepted that gap for this line at
sign-off, as he did for `feat/wt-dotfiles` and `feat/draft-status`. The plan's implementers run in
this checkout.

## Why

`ChatGPT.app` bundles Codex (`Contents/Resources/codex-cli`, 0.167.0) and reads the same
`~/.codex` as the launchd Codex daemon that `xreview` drives. Its Codex list shows every local
thread that is not archived. Michael sees the review conversations there, on this Mac only, so
this is local listing, not account sync.

Measured 2026-11-11 over the previous 7 days:
- `~/.codex/sessions` held 43 unarchived threads, and 40 of them were reviews (their first
  message is an `xreview` packet);
- `~/.codex/archived_sessions` held 218 more, 206 of them reviews.

Review threads are left unarchived in three ways:
- `round --reset` archives only superseded threads (`archive_superseded`), so the last
  checkpoint's thread of every checkout stays;
- `wt-rm`'s release (`xreview-rpc release --dir`, spec 2026-10-15) archives a loaded thread only to
  unload it, then restores it on purpose, because the protocol has no unload request;
- a removed harness worktree's last thread is never touched again.

Michael chose this over a separate Codex home for reviews, which would have needed a second
daemon, its own login and Herdr-restore routing, and would have moved his own pane chats too.

## Goals

Restated by the amendment: what this line delivers is correct archiving on the Codex side. The
daemon's lists stay clean and the app's Archived view is right. The app's main list clears only
when the app fixes its incremental sync or reconciles in full (see the amendment).

- When `wt-rm` tears a checkout down, every review thread `xreview` started for that checkout is
  archived for good.
- The review threads already left over from removed checkouts are archived once.
- An archived review thread stays recoverable (`xreview-rpc thread-unarchive`).

## Non-goals

- A separate Codex home for reviews.
- Archiving the current review thread of a checkout that still exists.
- Any change to `round --reset` rotation, the review ledger, or the pre-merge gate, with one
  exception. `archive_superseded` deletes the `superseded` list even when an archive failed,
  although its comment promises that nothing is ever silently dropped. It keeps a failed id
  queued instead, so the main checkout, which is never torn down, stops accumulating threads.
- Removing `xreview`'s per-checkout state directories.
- An automatic trigger for the cleanup (§3).
- Writing into the app's files, `~/.codex/sqlite/codex.db` included (amendment).

## Anti-goals

- Archiving a thread `xreview` did not start: Michael's own Codex chats in a checkout's pane keep
  today's release behaviour (archive, then restore). The single exception is §3's old pane
  sessions, by Michael's ruling.
- A change to `wt-rm`'s existing order, refusals or exit codes. Archiving review threads is
  cosmetic, so its failure never blocks or fails a removal; it is reported with the command that
  retries it.
- A cleanup that archives without first showing what it will archive.

## Design

### 0. Check first

Before any code: archive one leftover review thread of a removed checkout with
`xreview-rpc thread-archive`, and ask Michael to confirm that it left the ChatGPT app's Codex
list. If the app still lists archived threads, this design cannot work: unarchive the thread and
stop, and the line reports to the driver.

Outcome (2026-11-11): the app still listed it; see the amendment.

### 1. Which threads are review threads

None of today's records proves that `xreview` *started* a thread:
- `xreview init <id>` and `XREVIEW_THREAD` can pin any existing thread, Michael's own included,
  and its id then reaches `pin`, `turns/` and the receipts;
- `review-thread` is written only after a turn starts, so a thread whose dispatch failed before
  its first turn is in no record.

So creation provenance is added.

- **A creation record.** Right after `thread/start` answers, before anything else in the dispatch,
  `xreview` appends the new thread id, with the checkout's real path, to a per-checkout `started`
  list in its state directory.
  Only ids in `started` are ever archived for good. A pinned thread (`pin`, `XREVIEW_THREAD`) is
  never in it, because `xreview` did not start it. The remaining gap is a process killed between
  `thread/start`'s answer and that append. The spec accepts it: such a thread is empty, and the
  cleanup's content rule below does not select it.
- **Records from before this change** have no provenance. `wt-rm` (§2) uses `started` only.
  The one-off cleanup (§3) may select a thread whose first user message is an `xreview` packet,
  because `xreview` sends that packet as the first turn of every thread it starts, and a pinned
  personal thread's first message is Michael's own. A thread with no turns and no `started`
  entry is never selected. That is the historical coverage limit, and the dry run states it.

### 2. `wt-rm`

Release keeps today's behaviour for every thread (archive, then restore), so a removal that stops
afterwards leaves the checkout and all its threads as they are today. That covers check 4 finding
a process, git refusing, or any later refusal.

Only once the removal is confirmed, with the checkout gone and its worktree registration
removed, does `wt-rm` archive for good the threads in that checkout's `started` list (§1). That
covers loaded or not, superseded ones whose archive was still queued, and the current one.

- **State directory names collide.** `state_dir` maps `/` to `_`, so `/r/a_b` and `/r/a/b` share
  one directory. A thread is therefore archived only when both its `started` path and the `cwd`
  the daemon records for it (`thread/read`, C7) are under the removed checkout, compared whole
  path components at a time as in spec 2026-10-15. A thread of a still-existing checkout that
  shares the directory is never selected. The same rule governs clearing `review-thread`, and
  the cleanup (§3), whose "checkout gone" test uses the daemon's recorded `cwd`.

- A thread whose archive the archived listing confirms (C9 of spec 2026-10-15) is done. Its
  checkout's `review-thread` record, if it names that thread, is then cleared. The state
  directory outlives the checkout, so a new checkout at the same path (a recreated branch, a
  reused name, or two paths colliding in the `/`-to-`_` mapping) would otherwise resume an
  archived thread. Whether `thread/resume` works on an archived thread is unverified. `pin` is
  Michael's and is never touched.
- A failed or unconfirmed archive changes neither the removal nor its exit code. It prints the
  id and the retry command, and the cleanup (§3) also finds the thread later, since its checkout
  is gone.

### 3. One-off cleanup

A command in `xreview-rpc`, named by the builder:
- It lists review threads (by §1: a `started` entry, or a first user message that is an `xreview`
  packet) whose recorded checkout (`cwd`) no longer exists; harness worktrees under
  `.claude/worktrees/` count, as do removed `wt` siblings.
- It archives them only when asked to.
- The dry run prints each id, `cwd`, last update and how it was identified.
- The line runs the dry run and puts its output in its report. The real run happens after
  Michael's go, by him or by the line.
- **Old pane sessions (Michael's ruling, 2026-11-11).** Before reviews moved to the daemon,
  Michael opened the Codex pane himself and reviews ran in that session. About 82 such threads are
  unarchived, 46 of them in checkouts that are gone; their first user message is a greeting
  ("hi", "ready") and every later one is an `xreview` packet. The cleanup also selects these, but
  only when their checkout is gone and every user message after the first is an `xreview` packet.
  This is the one exception to the anti-goal on threads `xreview` did not start. The dry run lists
  them under their own heading.
- It is safe to re-run by hand, and it clears `review-thread` records as §2 does. Nothing triggers
  it automatically.
- A harness worktree's last review thread still stays behind after this change, because nothing
  in the dotfiles sees a harness worktree removed (28 of the 96 leftovers measured on 2026-11-11).
  That is a known limit. It becomes rare once `feat/wt-dotfiles` moves dotfiles lines to `wt`,
  and the re-runnable cleanup catches it.
- **Recorded cwd and origin (amendment).** A thread's recorded `cwd` can differ from where it
  began. The cleanup keeps selecting by the daemon's recorded `cwd`. A thread whose origin differs
  from that `cwd` is listed under its own heading and never selected, and the dry run states the
  limit. The origin is the thread's `started` path, else its rollout's first `session_meta` cwd.
  A thread whose origin cannot be read is listed the same way.

### 4. Tests

- `wt-rm`'s suite (`wt-functions`, heavy) covers:
  - review threads archived;
  - non-review threads still restored;
  - an archive failure that changes neither the removal nor its exit code;
  - a daemon that is down.
- The `xreview-rpc` suites cover:
  - the selection: `started` only for `wt-rm`, a pinned personal thread never selected, and
    the first-message rule only in the cleanup;
  - the old-pane rule: a greeting followed only by packets in a gone checkout is selected; a
    greeting followed by any message of Michael's own, or a checkout that still exists, is not;
  - `review-thread` cleared after a confirmed archive, and `pin` left alone;
  - two checkouts whose paths collide in one state directory: removing one archives none of the
    other's threads and leaves its `review-thread` in place;
  - `archive_superseded` keeping a failed id queued;
- `xreview`'s suites cover the `started` append coming before the first turn, including a
  dispatch that fails after `thread/start`;
- `wt-rm`'s suite also covers a removal that aborts after the release (check 4, git refusal):
  nothing is archived for good;
  - the cleanup's dry run and real run;
  - never touching a thread whose checkout exists.
- Existing stubs of the daemon protocol are reused.

### 5. After the merge

Michael: `chezmoi apply`, then the cleanup's real run once he has seen its dry run, and
`wt-rm feat/archive-review-threads`, which then exercises §2 on its own review threads.

## Amendment (2026-11-11)

**§0's outcome.**
- A thread archived through the daemon (`xreview-rpc thread-archive`) stayed in the app's Codex
  list, even after the app was relaunched.
- A thread Michael archived from the app's own UI left the list and showed in its Archived view.
  A before/after diff shows how the two archives compare:
  - **On the Codex side they are the same.** The app's archive makes the same change as the
    daemon's `thread/archive`: in `~/.codex/state_5.sqlite` it sets `archived` and
    `archived_at`, and it moves the rollout to `archived_sessions/`. Neither archive changes
    `updated_at`. Afterwards the daemon's `thread/list` lists the thread as archived.
  - **The app also edits its own catalog.** It deletes the thread's row from
    `local_thread_catalog` in its private `~/.codex/sqlite/codex.db`. That catalog is what the
    main list reads.
- **The catalog drops a row only two ways:** an archive from the app's own UI, or a full
  reconcile.
  - The catalog was built on 2026-11-01 and has not been reconciled in full since, despite
    several relaunches and an app update.
  - Its incremental sync, on an `updated_at` watermark, ignores archived threads. This held even
    when a rename moved the thread's `updated_at` past the watermark.
  - 23 rows in the catalog were threads already archived on the Codex side.
- **No supported interface reaches the catalog.** The daemon protocol covers the whole Codex-side
  archive. The app's own app-server is a stdio child of the app.

**Michael's ruling (2026-11-11).**
- Keep this design. The goal is restated above: correct Codex-side archiving. The app's main list
  clearing is a known limit, not a failure of this line.
- Report the catalog bug to the Codex repository. Michael approves the text and posts it.
- Nothing here writes into the app's files, `codex.db` included (Non-goals).

**Found during the check: a recorded cwd can differ from its origin.** In one review thread the
first `session_meta` named a removed harness worktree, while the daemon records an existing
directory that a later turn ran in. §3's selection by the daemon's `cwd` would therefore never
select it, which is the safe direction. §3 now lists such threads and never selects them.

**Measured while building (2026-11-11).**
- **Two cwds per thread.** `thread/list` reports a thread's original cwd, and `thread/read` its recorded, latest one. `thread/list`'s `cwd` filter matches the original.
  - This corrects C9 of spec 2026-10-15 for a thread whose cwd changed.
  - This line confirms archives through every cwd a thread may be listed under (plan, ruling 15).
  - `release` is unchanged here and still confirms with the recorded cwd. That gap predates this line and was reported to the driver.
- **Compressed rollouts.** The daemon lists a compressed rollout as `…jsonl`, while the file on disk is `…jsonl.zst`.
- **The first real dry run.**
  - Selected: 82 by a first packet and 33 old pane sessions, 115 in all.
  - Not selected: 1 pinned thread, and 13 threads whose origin differs from their recorded cwd.
  - The 13 are harness-worktree reviews whose later turns ran in the main checkout. §3's re-runnable cleanup therefore never archives them, which narrows its claim to catch a harness worktree's last thread.
  - 34 more old pane sessions mix in hand-relayed `<from-claude-code>` messages. They are not `xreview` packets, so the cleanup does not select them.

## Left to the builder

- The command's name and flags in §3.
- The `started` list's format and its locking against concurrent dispatches from one checkout.
