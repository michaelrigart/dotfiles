# wt-rm: finish a partial removal

**Status:** Implemented (branch fix/wt-rm-partial-removal; the dotfiles have no MR, so the rulings are recorded in "Implementation notes" at the end)

Amends the removal step of the [worktree hook protocol](2026-07-30-worktree-hook-protocol-design.md)
(§9.3) and check 4 of the [Herdr/wt simplification](2026-10-01-herdr-wt-simplification-design.md)
(§2). Everything else in `wt-rm` keeps its order and its refusals.

## Problem

`git worktree remove` deletes the checkout first and Git's registration
(`.git/worktrees/<id>`) second. When the second delete fails, `wt-rm` is left in a state it
cannot describe or recover from:

- Its failure message says "worktree kept" and offers `wt-prepare <branch> && wt <branch>`,
  although the checkout is gone.
- The retry it offers exits at once with "`<dest>` does not exist", because the entry check
  tests only for the directory.

Observed 2026-10-13 in `~/Code/tagteam`: `command wt-rm m4-run-sessions`, run from a sandboxed
Claude Code session, deleted the checkout, then Git failed with
`failed to delete '.git/worktrees/tagteam-m4-run-sessions': Operation not permitted`. The
registration and the branch had to be cleared by hand. The cause of that `EPERM` is not
established: the same delete, sandboxed, succeeds in other sessions.

A second, separate failure came up on 2026-10-09. Check 4 refused two removals because of
Codex's `node_repl` MCP server, which the Codex app-server daemon runs per loaded thread, with
its cwd in the thread's checkout. Closing the Herdr workspace ends the Codex client, and the
daemon then stops that thread's server, but only a few seconds later. A retry minutes later
passed both times.

## Design

### 1. An honest failure message

> **2026-10-13 — amended at Michael's request.** The first version split only on whether
> `$dest` still exists and kept the old message whenever it did. Git also fails the other
> way: when it cannot delete the checkout (the existing q11 case), it still deletes the
> registration. That left "worktree kept" false, and both routes it offered refuse with
> "not a registered worktree". When both deletes fail, Git has still removed the checkout's
> `.git` link, so a surviving directory is not necessarily a working checkout.

When `git worktree remove` fails in the normal path, `wt-rm` reports what is actually left.
It checks three things:
- whether `$dest` still exists (`-e` or `-L`);
- whether Git still registers a worktree at `$dest`. Git's worktree list is read quietly;
  a list that cannot be read counts as unknown, never as "gone".
- when it is registered and its `.git` link is still there, whether it is still a **working
  checkout** of the branch. That means Git, run inside `$dest`, succeeds and reports `$dest`
  as its top level and `<b>` as its branch: the same test `_wt_assert_worktree` applies, and
  which both the retry and `wt-prepare` go through. If Git cannot confirm this (a read
  fails, or answers differently), the state is unknown. `wt-rm` never advises deleting a
  registered directory that still has its `.git` link.

A directory whose `.git` link is gone is not a working checkout. Git deletes that link before
the rest of the checkout, so a partly deleted checkout lacks it. That the link is gone is
proven from a listing of `$dest`, as §2 proves absence. A failed `stat` of `$dest/.git`
proves nothing, so a listing that fails makes the state unknown. An unregistered directory is
not a worktree, whatever it holds.

| Checkout | Registration | Message |
|---|---|---|
| a working checkout | registered | unchanged: "worktree kept", with both recovery routes |
| exists, `.git` link gone | registered | the partly-deleted message below; once the leftover is deleted, the retry finishes it (§2) |
| gone | registered | the partial-removal message below; the retry finishes it (§2) |
| exists | gone | the leftover message below |
| gone | gone | the leftover message, saying nothing is left on disk |
| has its `.git` link, not confirmed working | registered | the unknown-state message below |
| any | unknown | the unknown-state message below |

Every case exits 1 and keeps the branch. Every route a message offers is one that works from
that state.

- **Partly deleted, registration left:**

  ```
  wt-rm: removing <dest> failed partway — the checkout is partly deleted and no longer a working checkout, but Git's registration of it remains. Herdr workspaces closed, teardown done; branch <b> kept.
      Fix the obstruction Git reported above, delete what is left in <dest> yourself, then finish with: wt-rm <b>
  ```

  The leftover holds only what checks 1–3 allowed (ignored files), or files that were
  recreated during the removal.
- **Checkout gone, registration left:**

  ```
  wt-rm: removing <dest> failed partway — the checkout is deleted, but Git's registration of it remains. Herdr workspaces closed, teardown done; branch <b> kept.
      Fix the obstruction Git reported above, then finish with: wt-rm <b>
  ```

  It offers no `wt-prepare` route, because there is no checkout left to prepare.
- **Registration gone, checkout left:**

  ```
  wt-rm: removing <dest> failed partway — Git's registration of it is removed, but the directory remains and is no longer a worktree. Herdr workspaces closed, teardown done; branch <b> kept.
      Inspect what is left in <dest> and delete it yourself, then delete the branch if its work is merged: git branch -d <b>
  ```

  `wt-rm` never deletes an unregistered directory, and it offers no retry. A retry would
  refuse at "not a registered worktree", whose own hint already says to remove the leftover.
  When both are gone, the first line ends "…and nothing is left at <dest>" instead, and the
  second line keeps only the `git branch -d` advice.
- **Unknown:**

  ```
  wt-rm: removing <dest> failed, and Git's state cannot be read to tell what remains. Herdr workspaces closed, teardown done; branch <b> kept.
      Check <dest> and `git worktree list` yourself before retrying.
  ```

### 2. A retry that finishes the removal

The entry check changes from "`$dest` is a directory" to the following.

- `$dest` is a directory: the normal path, unchanged.
- `$dest` is **positively absent**, and Git's worktree list holds a record whose resolved
  path equals `$dest`: the recovery path below. Positively absent means all three of these
  hold:
  - neither `-e` nor `-L` is true for `$dest`;
  - its parent directory can be listed;
  - the listing has no entry with `$dest`'s name.

  A failed `stat` is not evidence of absence: it also fails when access to the path is
  denied, and Git's own `prunable` test fails the same way.
  - If the parent cannot be listed, `wt-rm` refuses: "cannot confirm `<dest>` is gone".
  - The record does not have to be `prunable`. Git never marks a locked record that way, and
    a registration that kept the Herdr lock is the main case this path exists for.
  - If the record's branch is not `refs/heads/<branch>`, `wt-rm` refuses and names the
    branch it has.
- Anything else: the existing "`<dest>` does not exist." refusal.

**The decision is made under the lock.** `wt-rm` takes the per-target lock before it chooses
between the two paths, so a concurrent `wt` or `wt-rm` on the same target is refused rather
than raced.

**The recovery path** runs under that lock and releases it the same way. In order:

1. **Classify Git's lock.** As in the normal path: the Herdr reason authorises
   `--force --force`, any other reason is a refusal that keeps the registration, and an
   unlocked record uses a plain `git worktree remove`.
2. **Close Herdr workspaces.** `_wt_stop_herdr_workspaces "$dest"`, with the same refusals.
   A workspace or a pane can still point at the deleted path.
3. **Announce what is skipped.** Hook validation, checks 1–4 and teardown all need the
   checkout, so none of them runs. `wt-rm` says so in one line:

   ```
   wt-rm: <dest> is already gone — finishing its removal without re-running teardown.
       If it was deleted by hand rather than by an interrupted wt-rm, reclaim its resources yourself.
   ```
4. **Remove the registration.** `git worktree remove [--force --force] "$dest"`. For a missing
   checkout, Git removes only that registration. That is verified with git 2.56 for an unlocked record; the suite covers the locked one. No repo-wide
   `git worktree prune` is used: it would touch other records and skip locked ones.
   - On failure, `wt-rm` names the remaining state ("Git's registration of `<dest>` remains;
     branch `<b>` kept") and says to fix the obstruction and retry `wt-rm <b>`.
5. **Delete the branch** with the existing branch-deletion step, unchanged.

### 3. A grace period before check 4 refuses

> **2026-10-15 — amended.** The Codex daemon keeps an idle thread, and its MCP helpers,
> loaded for ~60 s after its client goes, not "a few seconds"; this grace period does not
> cover it. `wt-rm` now releases the checkout's Codex sessions before check 4; see
> [wt-rm: release the checkout's Codex sessions](2026-10-15-wt-rm-codex-session-release-design.md).

When `wt-teardown scan` lists processes, `wt-rm` scans again every 0.5 s, for up to 5 s in
total.

- It proceeds as soon as a scan comes back empty.
- A scan that fails inside the loop fails closed, as today.
- If the list is still non-empty after 5 s, the refusal is the same one as today, but its
  first line also says it waited 5 s.

There is no setting for the grace period. The test suite stubs `sleep`.

## Out of scope

- **Making agents run `wt-rm` outside the sandbox** (an entry in the global instructions'
  "Needs the escape" list). The cause of the `EPERM` is unconfirmed. Once change 2 is in, a
  sandboxed failure is a plain retry from outside the sandbox.
- **Treating Codex-daemon processes specially in the scan.** The grace period covers any
  process that exits shortly after its workspace closes.
  > **2026-10-15 — amended.** Still not done in the scan: `wt-rm` releases the sessions
  > before it instead; see [the release spec](2026-10-15-wt-rm-codex-session-release-design.md).

## Testing

All new cases go in `tests/wt-functions.test.sh` and use real repositories, as the suite does
today.

- **Partial removal.** Teardown sets the registration directory to `chmod 500`, so Git deletes
  the checkout and then fails on the registration. Expected:
  - the new message, without "worktree kept" and without the `wt-prepare` route;
  - the branch is kept, and the record is still registered and still carries the Herdr
    lock.

  After `chmod 700`, a retry of `wt-rm <b>` exits 0, prints the skipped-teardown notice,
  removes the registration with `--force --force`, and deletes the merged branch. This is
  the Herdr-locked success case.
- **An unlocked missing checkout** (the lock removed before the checkout is deleted) is
  removed with a plain `git worktree remove`.
- **The recovery path's own refusals,** each leaving the registration and the branch in place:
  - a missing checkout that Git does not know: the existing "does not exist" refusal;
  - a missing checkout registered on another branch;
  - a missing checkout locked for a reason other than Herdr's;
  - a missing checkout whose parent directory cannot be listed (`chmod 100` on the parent: still searchable, so the main checkout beside it keeps working, but not listable);
  - a foreign Herdr pane whose cwd is under the missing path.
- **Grace period.** A `sleep` stub logs every call, and the tests assert that log.
  - A scan that stays busy for three polls, then comes back empty: removal proceeds after
    exactly three 0.5 s sleeps.
  - A scan that stays busy: the refusal names the wait after exactly ten 0.5 s sleeps, and
    the checkout, registration and branch survive.
  - A scan that is busy, then fails: `wt-rm` fails closed, and the checkout, registration
    and branch survive.
- **Every row of the §1 table, each with its route exercised:**
  - **A working checkout, registered.** A test-only mode of the git call-failure injector
    fails `git worktree remove` without running it. Expected: "worktree kept" and both
    routes. A retry of `wt-rm <b>` without the injector then exits 0.
  - **Partly deleted, registered.** Teardown makes both the registration directory and an
    ignored subdirectory of the checkout unwritable. Expected: the partly-deleted message,
    without "worktree kept" or the `wt-prepare` route. Then the permissions are restored and
    the leftover is deleted by hand, and `wt-rm <b>` exits 0 and removes the registration.
  - **Checkout gone, registration left:** the partial-removal case above.
  - **Registration gone, checkout left:** the existing q11 fixture. It now expects the
    leftover message, without "worktree kept", the retry or the `wt-prepare` route. The
    directory remains, Git no longer lists it, and the branch is kept. Deleting the leftover
    and running `git branch -d <b>` both succeed.
  - **Unknown, worktree list.** The injector fails the worktree-list read that follows the
    failed removal. Expected: the unknown-state message, and the branch kept.
  - **Unknown, checkout not confirmed.** The removal fails before Git touches anything, and
    the injector fails the branch read inside the checkout after it printed the right
    answer. Expected: the unknown-state message, never "worktree kept" and never advice to
    delete the directory. The checkout is intact.
  - **Both gone** has no fixture. Git reports failure only when a delete fails, so in
    practice something is always left behind. That row exists to fail closed, not because
    it was observed.

## Implementation notes

The branch is `fix/wt-rm-partial-removal`. It ran as four plan tasks, with a fresh review after each and three fix rounds on Task 4. Codex approved the spec, the §1 amendment, the plan and the added Task 4, each in its second round.

### Beyond the spec's letter

- **Absence proof (§2).** It also requires the main checkout's name in the parent listing. The glob's `N` qualifier returns nothing for a listing that failed, so without that check a failed listing would read as "absent".
- **Shared lookup.** The recovery path and the §1 report share one quiet record lookup, `_wt_worktree_record`. An empty worktree list counts as a failed read.
- **Proving the `.git` link is gone.** This uses `command ls -A`, with its exit status checked. Its environment is pinned (`CLICOLOR_FORCE` and `LS_COLORS` unset, `QUOTING_STYLE=literal`, `LC_ALL=C`), so decorated output cannot fail the exact `.git` match. A failed match would read as "link gone", which is the unsafe direction.
- **Test injector.** The suite's git call-failure injector gained `WT_FAIL_SKIP`, which fails a mutating call without running it, and a second slot (`WT_FAIL_MATCH2`, `WT_FAIL_NTH2`, `WT_FAIL_LOG2`), which always runs the real git first.

### Rulings

Each ruling lists what it costs if it is wrong.

- **The original q11 message.** It was escalated rather than changed under the first spec. Michael chose to fix it, which became the §1 amendment. Cost: none now.
- **Lock files for typos.** `wt-rm <typo>` now creates an empty `.git/wt-locks/<slug>.lock` before refusing, because the decision is made under the lock (§2). `wt` already does this. Cost: empty lock files.
- **A checkout moved by hand** (not deleted) looks absent, and the retry unregisters it. Its files survive at the new place, and unmerged branches are kept. Cost: `git worktree repair` no longer applies to it.
- **Grace-period wording.** "after waiting 5 s" counts sleep time only. A deadline loop would make the instant-`sleep` schedule untestable. Cost: the real wait is about 5 s plus 11 `lsof` runs.
- **Record walker.** The recovery path's record walker is separate from `_wt_git_lock_state`'s and `_wt_primary`'s. Folding them together would touch helpers the normal path depends on. Cost: the walkers could drift apart.
- **Unsearchable parent.** `$dest`'s own existence is still decided by `-e`/`-L`. When its parent cannot be searched, the result is the "checkout is deleted … finish with: wt-rm" message. That is retry advice, never deletion advice, and the retry's own absence proof then refuses. Cost: one misleading message in that case.
- **Test-hygiene gaps.** These were accepted:
  - The restores after `chmod 500` (Q12, q11) and `chmod 100` (Q16) have no trap. A failed assertion never aborts the suite.
  - q11 cannot catch a "both messages printed" regression.

  Cost: stray temporary directories, and one undetected double message.
- **Branches with no fixture.** These fail closed, but cannot be reached without faking Git or Seatbelt:
  - the "both gone" row;
  - the half of the absence proof where the name is listed but `stat` fails;
  - the top-level-mismatch branch of the working-checkout test.

  Cost: three untested branches.
- **The q23 ls-decoration check** only discriminates where `ls` is BSD ls. GNU ls never colours a pipe by default, so there the pin is inert. Cost: no guard on a GNU-ls machine, where the hazard does not arise either.

### Test record

- `tests/wt-functions.test.sh`: 509/509 (it was 385 before the branch).
- Full `./tests/run.sh` on 4e56515: 31 suites passed, 3714/3714 assertions; 8 skipped by their `needs:` tags.
