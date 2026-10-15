# wt-rm: release the checkout's Codex sessions

**Status:** Implemented (branch `feat/wt-rm-codex-session-release`; the dotfiles have no MR, so the rulings are recorded in "Implementation notes" at the end)
**Date:** 2026-10-15
**Branch:** `feat/wt-rm-codex-session-release`

Amends check 4 of [wt-rm: finish a partial removal](2026-10-13-wt-rm-partial-removal-design.md)
(§3 and its "Out of scope" entry on Codex-daemon processes) and adds a subcommand to
`xreview-rpc` ([xreview on the Codex app-server daemon](2026-09-26-xreview-codex-daemon-design.md),
§7.1). Every other step of `wt-rm` keeps its order and its refusals.

## Problem

Most `wt-rm` runs on a checkout that had a Codex pane end in this refusal:

```
wt-rm: …/VM.Portal-feature-detection-overlap is still in use by a running process after waiting 5 s — removal aborted. Resources may already be reclaimed.
    57530 node_repl
    57531 node
    57551 node_repl
```

The Codex app-server daemon runs MCP helpers for every loaded thread (`node_repl`, and
ChatGPT.app's `cua-repl` under `node`), with their cwd in the thread's checkout. Closing the
Herdr workspace ends the Codex TUI, but the daemon owns the thread and its helpers, and unloads
an idle thread only about 60 s after its last client leaves (C2). The partial-removal spec
assumed "a few seconds" and sized check 4's grace period at 5 s, so the refusal is the normal
outcome, not the exception. A retry a minute later passes.

## Verified facts

Probed 2026-10-15 against Codex 0.162.1 (the launchd daemon and `codex app-server
generate-json-schema`), with scratch threads in scratch directories, all archived afterwards.

| # | Fact |
|---|---|
| C1 | Each loaded thread has three helper processes whose cwd is the thread's `cwd`: `node_repl` (the `node_repl` MCP server) and `node` running `cua-repl.mjs` with its own `node_repl` child. All are children of the daemon. They start with the thread and exit when it unloads. |
| C2 | An idle thread whose last client disconnects stays loaded for about 60 s (measured 61.5 s), then unloads; its helpers exit with it. The same holds for an ephemeral thread. |
| C3 | The protocol has no request to unload a thread. `thread/unsubscribe` detaches only the calling connection: from a fresh connection it answers `notSubscribed`; after `thread/resume` it answers `unsubscribed`, yet the thread stays loaded until C2's timer. |
| C4 | `thread/archive` unloads a loaded thread at once (`thread/status/changed` → `notLoaded`); its helpers are gone within 1 s. |
| C5 | `thread/unarchive` restores the thread: same rollout `path`, turns intact, out of the archived listing (C9), still `notLoaded`. It bumps `updatedAt` to the restore time; `createdAt` and `recencyAt` are unchanged. It works for a thread that never had a turn. A second `thread/unarchive` of a restored thread fails with "no archived rollout found", so its answer alone cannot tell "already restored" from "failed". |
| C6 | An ephemeral thread (`ephemeral: true`, `path: null`) cannot be archived: `thread/archive` fails with "no rollout found" and the thread stays loaded. Only C2's timer unloads it. |
| C7 | `thread/loaded/list` returns only ids (paged by `nextCursor`); `thread/read` (with `includeTurns: false`) gives each one's `cwd`, `status` (`idle`, `active`, `systemError`, `notLoaded`), `ephemeral` and `path` (F8 of the daemon spec). |
| C8 | The daemon socket is denied inside the Claude sandbox (`connect`: Operation not permitted). |
| C9 | `thread/list {archived: true, cwd: [<cwd>], sourceKinds: [<every kind>]}` lists a thread exactly while it is archived. `cwd` must match the thread's recorded `cwd` string exactly. Omitted `sourceKinds` means interactive sources only, so all ten kinds of the schema's `ThreadSourceKind` are passed. `thread/read` still answers for an archived thread (`notLoaded`). |

## Design

### 1. `xreview-rpc release --dir <dir>`

`xreview-rpc` is the only client for Codex's daemon in the dotfiles, so the new command lives
there rather than in a second client. Its docstring stops calling it "xreview's" client;
renaming it is out of scope.

**Under `<dir>`** means: the real path of the thread's `cwd` equals the real path of `<dir>`
or lies below it, compared whole path components at a time, so `VM.Portal` never matches
`VM.Portal-feature-x` and vice versa.

**Pending restores.** Archiving makes a thread vanish from the loaded list, so a release that
stops between archive and a confirmed restore would otherwise lose track of it. Each thread
about to be archived gets a record first:
`${XDG_STATE_HOME:-$HOME/.local/state}/xreview-rpc/release-pending/<thread-id>`, holding the
thread's recorded `cwd` string. The record is deleted only once the thread is confirmed not
archived (C9). A record that cannot be written stops the command before that thread is
archived.

**One release at a time.** Every `release` takes an exclusive `flock` on `release.lock` in
the state directory before it reads or writes any record, and holds it until it exits; the
kernel drops it when the process dies, however it dies, so it never goes stale. A release
waits for the lock, polling every 0.2 s, until the command's deadline, then exits 1 with
`another release is running`. The lock is global rather than per directory, so overlapping
`--dir` scopes and direct calls by hand are serialized too. Releases are short (C4); only the
ephemeral wait (step 5) can hold the lock for up to 90 s. A state directory that cannot be
created or locked is exit 1.

**Confirming a restore** means `thread/list` per C9, for the record's `cwd`, does not list
the id. That answer is authoritative whatever `thread/unarchive` replied (C5). A thread that
was deleted meanwhile is not listed either, so its record is dropped: nothing is left to
restore, and no record can block a removal for ever.

With a 120 s deadline for the whole command, the lock taken first, then one connection:

1. **Finish earlier restores.** For each pending record whose `cwd` is under `<dir>`: send
   `thread/unarchive`, then confirm. Confirmed: delete the record. Not confirmed, or the
   listing fails: the record stays. If any record under `<dir>` stays, print each id as
   `<id> is archived and could not be restored yet` and exit 1 without going on to step 2,
   so nothing more is archived while a restore is owed. Records for other directories are
   left alone, so one failed restore never blocks another checkout's removal.
2. **Select.** Page through `thread/loaded/list` and `thread/read` each id; keep the threads
   under `<dir>`. A thread that `thread/read` reports `notLoaded` has nothing to release. If
   `thread/read` fails for an id, list the loaded threads again: an id that is gone has
   nothing to release, and an id still listed is unknown, so the command prints
   `cannot read Codex session <id>` and exits 1 before archiving anything.
3. **Refuse while running.** If any selected thread is `active`, print
   `<id> is running a turn — let it finish, or open it with codex resume <id> and interrupt it`
   for each, and exit 1 before archiving anything.
4. **Release saved threads.** For each selected thread that is not ephemeral: write its
   record, `thread/archive` (C4), `thread/unarchive` (C5), confirm, delete the record, and
   print `released <id>` on stdout.
   - Archive fails: confirm. Not archived: delete the record. Either way print
     `<id>: archive failed: <daemon's error>` and exit 1.
   - Restore not confirmed (an unarchive error, a lost answer, a failed listing): print
     `<id> is archived and could not be restored yet`, keep the record, and exit 1. The next
     run starts with step 1.
5. **Wait for ephemeral threads.** Archive cannot unload them (C6). Print
   `waiting for ephemeral <id> to unload (up to 90 s)` on stderr and poll
   `thread/loaded/list` every 2 s until every selected ephemeral id is gone; then print
   `released <id>`. A poll that fails counts as still loaded. Any still loaded at 90 s: print
   `<id> (ephemeral) is still loaded — close the Codex client using it` for each, exit 1.

Every diagnostic goes to stderr; stdout carries only the `released <id>` lines.

Exit codes follow the command's existing table:

- **0:** no thread under `<dir>` is loaded, and no pending record under `<dir>` remains.
- **1:** refused or failed, including any pending record under `<dir>` left at the end, the
  lock not taken, and the deadline passing. An uncaught error also exits 1.
- **2:** usage.
- **5:** the daemon was unreachable, and no record under `<dir>` is pending. With a pending
  record under `<dir>` an unreachable daemon is exit 1, because that thread's restore is
  still owed. A connection lost after the first request is not 5: the run ends by the rules
  above.

### 2. A release step in `wt-rm`

New step, between check 3 and check 4:

```
… teardown, check 3, release Codex sessions (new), check 4, removal, branch deletion
```

It runs after Herdr's workspaces are closed (so the TUI has disconnected) and as late as
possible, so a refusal earlier in `wt-rm` never touches a Codex thread.

| `command xreview-rpc release --dir "$dest"` | `wt-rm` |
|---|---|
| exit 0 | Prints `✓ released Codex session <id>` per released thread; nothing when there were none. |
| exit 5 | Prints `wt-rm: the Codex daemon is not reachable — continuing; check 4 decides.` and continues. |
| any other status (1, a signal such as 137 or 130, 127 missing, 2, …) | Refuses: `wt-rm: could not release the Codex sessions in $dest (status <n>) — removal aborted. Resources may already be reclaimed.`, then the command's own lines (indented), then `Then retry: wt-rm <branch>`. The worktree and branch are kept. |

Only exit 5 continues without a release, because only exit 5 is the command's own statement
that no restore is owed under `$dest` (§1). Continuing there does not loosen `wt-rm`: a daemon
that is down has no helpers to leave behind, a hung one leaves them, and check 4 refuses as it
does today. Any other failure, including a release that died mid-way, may have left a thread
archived, so `wt-rm` keeps the checkout and the retry's step 1 restores it.

A missing `xreview-rpc` refuses too, as a missing `wt-teardown` already does: both are deployed
with `wt-rm`. Inside the Claude sandbox the state directory is not writable, so the release
exits 1 and `wt-rm` refuses there; `wt-rm` is run from Michael's own shell.

Check 4 itself, its 5 s grace period and its refusal text are unchanged. The grace period now
covers the ~1 s it takes the released helpers to exit (C4).

### 3. Record amendments

- Partial-removal spec: an amendment banner on §3 and on the "Out of scope" entry, saying the
  daemon's delay is ~60 s, not seconds, and pointing here. The original text stays.
- Daemon spec: an amendment banner on §7.1 listing `release --dir` and pointing here.

## Known limits

- **Clients outside Herdr.** The daemon does not say which clients are subscribed to a thread.
  A Codex client outside Herdr (the desktop app, a TUI in another terminal) holding an idle
  thread in this checkout has that thread unloaded underneath it. If that client's own process
  runs inside the checkout, check 4 still refuses.
- **`updatedAt` moves.** A released thread's `updatedAt` becomes the time of the release (C5),
  so a list sorted by update time shows it as recently touched.
- **The protocol is experimental.** C3–C6 and C9 may change with a Codex update; the live
  canary (Testing) pins C4, C5 and C9.

## Out of scope

- Waiting out C2's timer for saved threads, or killing helpers from `wt-rm`. Both were
  rejected in brainstorming: the first costs ~60 s per removal, the second stops processes the
  daemon still manages.
- Renaming `xreview-rpc` to a general Codex client name.

## Testing

- **`tests/xreview-rpc.test.sh`** (fake daemon on stdio):
  - Selection: the exact dir, a subdirectory, a sibling sharing the prefix
    (`repo` vs `repo-x`) is not selected, and a symlinked `--dir` matches the real `cwd`;
    `thread/loaded/list` across two pages.
  - One `active` thread: exit 1, and no `thread/archive` was sent for any thread.
  - `thread/read` fails for an id still loaded: exit 1, no `thread/archive` sent; for an id
    gone from the second listing: skipped, exit 0.
  - Saved threads: record written, archive, unarchive, archived listing (with `archived`,
    the exact `cwd` and all ten source kinds), record deleted, `released <id>`, in that order.
  - Archive error: exit 1 naming the id; the record is deleted when the listing shows the
    thread not archived, kept when it shows it archived.
  - Restore not confirmed, each way (unarchive error with the thread still listed archived,
    the connection lost after archive, the listing failing): exit 1, record kept. A second run
    restores it in step 1, deletes the record, then exits 0.
  - Unarchive answers "no archived rollout found" but the listing no longer shows the thread:
    confirmed, record deleted.
  - A pending record under `--dir` with the daemon unreachable: exit 1, not 5. A pending
    record for another directory: ignored, exit 0.
  - The state directory comes from `XDG_STATE_HOME`, pointed at the suite's temp dir.
  - The lock: a release started while another process holds `release.lock` sends nothing to
    the daemon and touches no record until the lock is free, then proceeds; one still blocked
    at the deadline exits 1 (the deadline shortened by an environment override). A lock
    holder killed with SIGKILL frees it. An unwritable state directory: exit 1.
  - Ephemeral: unloads on a later poll → `released`; still loaded at the deadline → exit 1.
    The suite shortens the 90 s wait and 2 s poll through environment overrides, as
    `wt-teardown` does for its waits.
  - No thread under `--dir`: exit 0, no output. Daemon unreachable: exit 5.
- **`tests/wt-functions.test.sh`**: a default `xreview-rpc` stub on the suite's stub `PATH`
  (exit 0, no output), so no test reaches the real daemon. New cases:
  - The release runs after teardown and check 3 and before check 4 (call order recorded by
    the stubs), with `--dir` set to the checkout.
  - Exit 0 with ids: one `✓ released Codex session` line per id, removal proceeds.
  - Exit 1, a stub killed by a signal, exit 2, and a missing command (no stub on `PATH`):
    each refuses with its status, keeps the worktree and branch, and never runs
    `git worktree remove`.
  - Exit 5: the continuing line, then check 4 and removal run.
  - A refusal before teardown never calls `xreview-rpc`.
- **`tests/live-codex-daemon.test.sh`** (canary, needs the real daemon): a scratch thread with
  one small turn in a scratch directory; after `xreview-rpc release --dir <scratch>` the
  thread is `notLoaded`, no process has its cwd in the scratch directory within 2 s, the
  archived listing of C9 does not show it, and no pending record is left (C4, C5, C9). The
  thread is archived at the end.

## Implementation notes

The branch is `feat/wt-rm-codex-session-release`. It ran as four plan tasks, with a fresh review after each, up to three fix rounds on a task, and a final whole-branch review whose findings went into one last fix wave. The dotfiles have no MR, so the rulings below are the record.

### Beyond the spec's letter

- **Shared loaded-thread listing.** `cmd_thread_resolve` now calls `loaded_ids()` instead of keeping its own paging loop. Its refusal no longer carries the daemon's error JSON.
- **`settle()`.** One helper drops a record once its restore is confirmed. When the record cannot be removed, step 1 and step 4 say `<id> was restored, but its record could not be removed: …`, return 1 and keep the record for the next run's step 1. Step 1 still tries every other record and names every restore that is still owed.
- **Archive failed, record not removable.** Step 4's archive-failed message gains `; its record could not be removed: …` when the listing confirms the thread was never archived and the record cannot be dropped.
- **Ephemeral wait.** The poll sleep is capped at the end of the wait, and a `Closed` raised mid-poll ends the wait with the same "still loaded" message instead of a lost connection.
- **`wt-rm` output.** Only the release's `waiting for …` lines of stderr reach the terminal live, through `{ release 2>&1 >out } | tee err | grep --line-buffered`; the rest is kept for a refusal. `✓ released Codex session` lines print before a refusal too, so an id released before a later failure is not lost. The scratch directory is removed in `wt-rm`'s `always` block.
- **Lock wait notice.** `take_lock` prints `waiting for another release to finish` through `err` the first time it finds the lock busy, so `wt-rm` is not silent for up to the 120 s deadline.
- **`XREVIEW_RPC_LOCK_BUSY_MARK`.** A test hook: a file touched the first time the lock is found busy, so the lock-wait tests assert on the wait instead of timing it. Precedent: `WT_TEARDOWN_TERM_WAIT`.
- **Thread ids are validated in step 2.** Every selected id is checked against the record-name rule (a full match, so a trailing newline fails) before anything is archived. A bad id refuses the run before any thread listed ahead of it is released.
- **The lock is not only held by the ephemeral wait.** §1's "only the ephemeral wait can hold the lock for up to 90 s" is not quite true: a daemon that hangs holds it until the 120 s deadline.

### Rulings

Each ruling lists what it costs if it is wrong.

- **Parallel batch, controller commits.** Tasks 1 and 3 ran in parallel and the implementers did not commit; the controller committed each task alone. Michael's global instructions (parallel tasks) override the skill's default. Cost: a cross-task interference the scan missed, which the per-task review on its own commit would catch.
- **Shared checkout, no worktree.** Execution ran on the branch in the shared checkout; `wt` worktrees are Michael's. Cost: another session's branch switch carries uncommitted batch work, mitigated by re-checking the branch before every commit.
- **Case-variant paths are not matched.** A `--dir` typed in different case selects nothing, and check 4 refuses as before; the archived listing needs the exact recorded cwd anyway. `$dest` comes from Git's top level. Cost: a session left loaded for a checkout typed in different case.
- **The turn-start window between steps 3 and 4.** A turn that starts after step 3's active check and before step 4's archive is cut short. `wt-rm` runs the release after the checkout's Herdr workspaces are closed, so only an outside client could start one, and the spec leaves it unaddressed. Cost: one turn cut short by an archive.
- **One corrupt pending record blocks every release.** Its scope is unknown, so the run fails closed and names the file. Cost: one stray file blocks all `wt-rm` runs until it is deleted.
- **Archive failed, and the listing shows the thread archived.** Only the spec's `archive failed` text is printed. The kept record is settled by the next run's step 1. Cost: one less explicit message.
- **No `__pycache__` backstop.** Neither `.gitignore` nor `.chezmoiignore` gains an entry; both suites set `PYTHONDONTWRITEBYTECODE`, and a `.chezmoiignore` change is outside this work. Cost: a stray cache from a future ad-hoc import could deploy to `~/.local/bin`.

### Test record

- `tests/xreview-rpc.test.sh`: 204/204
- `tests/wt-functions.test.sh`: 573/573
- Full `./tests/run.sh`: <to be filled by the controller>

### Open items

- The live canary (`tests/live-codex-daemon.test.sh`) fails two checks that predate this branch and that it does not touch: F15 ("the pane shows the turn another client started") and V2 ("the directory chooser appears without -C"). Both are screen-text checks, likely Codex TUI drift. Canary run 2026-10-15: 44/46, every new R1 assertion passing.
