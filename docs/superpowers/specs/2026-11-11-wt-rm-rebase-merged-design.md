# wt-rm: delete rebase-merged branches

**Status:** Implemented (branch `fix/wt-rm-rebase-merged`; no MR, a dotfiles line)
**Date:** 2026-11-11
**Sign-off:** Michael, 2026-11-11, given in advance and relayed by the tagteam session; Codex spec
review approved in round 2 (`xr-1794428865-1662fe5b`)
**Branch:** `fix/wt-rm-rebase-merged`, in the `wt` checkout `~/.local/share/chezmoi-fix-wt-rm-rebase-merged`
**Amends:** `docs/superpowers/specs/2026-07-30-worktree-hook-protocol-design.md` §8 step 13 and
§9.3 ("Attempt `git branch -d`, never `-D`"). It also records the squash rule that d7fa282 added
to `wt-rm` without a spec. The rest of that spec stands.

## Why

`wt-rm` removes a checkout and then deletes its branch if the branch's work is in the base. After
Michael ran `wt-rm` on five tagteam lines that GitHub had rebase-merged, four branches stayed
("kept (not fully merged)"), although every commit was in `main`. Each one had to be deleted by
hand.

- `git branch -d` asks an ancestry question. A rebase-merge gives every commit a new SHA, so `-d`
  refuses.
- The fallback, `_wt_branch_content_merged` (`dot_config/zsh/functions`), merges the branch into
  the base in memory (`git merge-tree --write-tree <base> <branch>`). It deletes the branch only if
  the result is the base's own tree. Once a later base commit touches the same lines, that 3-way
  merge conflicts and the branch is kept. Every PR in tagteam adds a line to CHANGELOG's Unreleased
  block, so in practice only the last-merged branch is ever deleted.

Evidence, reproducible in `~/Code/tagteam` (re-measured 2026-11-11), with base `b611dc74`:

| Head | `git cherry b611dc74 <head>` | merge-tree result equals base tree |
|---|---|---|
| 8bae266b | 3 `-` | no |
| b4ac20ac | 16 `-` | no |
| b6c3339c | 38 `-` | no |
| c3742426 | 5 `-` | no |
| 61bddf6d (merged last) | 30 `-` | yes |

GitLab squash-merges have the same weakness: once a later commit touches the lines a squash commit
touched, the merge-tree test keeps the branch.

## The rule today (since d7fa282, recorded here for the first time)

`_wt_rm_branch` runs after the checkout is removed. It never fails the removal.

1. `git branch -d <branch>`. On success the branch is gone.
2. Otherwise `_wt_branch_content_merged`, against each base in turn: the main checkout's current
   branch (`symbolic-ref HEAD`), then the remote's default branch (`refs/remotes/origin/HEAD`). A
   base equal to the branch is skipped. For each base:
   - if the branch has no net change against the merge-base (`git diff --quiet <mb> <branch>`), skip
     this base. `wt-rm` never force-deletes a branch whose commits add nothing, however empty they
     are;
   - if `git merge-tree --write-tree <base> <branch>` succeeds and its tree equals the base's tree,
     the branch's content is in the base.
3. If a base says yes, `git branch -D` and print `✓ deleted branch <b> (squash-merged — …)`.
   Otherwise print `wt-rm: branch <b> kept (not fully merged) — inspect or merge it before deleting
   it explicitly.` The message never offers a copy-pasteable `-D` (§9.3 of the 2026-07-30 spec).

Every failure along the way (no base, no merge-base, an unmergeable branch, a git without
`--write-tree`) keeps the branch.

## Goals

- A branch whose every change landed in the base through a rebase-merge is deleted, however the
  base has moved since.
- A branch whose whole change landed as one squash commit is deleted, however the base has moved
  since.
- Nothing the base lacks is ever deleted. Every unclear case keeps the branch.

## Non-goals

- Fetching. `wt-rm` judges the refs it has. A merge the local `main` and `origin/HEAD` have not
  seen yet keeps the branch, as today.
- Branches merged with conflict resolution or edits (a rebase that had to resolve a conflict, a
  squash commit edited before landing). Their patches differ from the branch's, so they are kept,
  as today.
- The advice lines of a partial removal (`git branch -d <b>`, `functions` around line 1755). A
  retried `wt-rm` applies the new rule.
- Any change to how `wt-rm` removes the checkout, or to the "kept" message.

## Anti-goals

- Deleting a branch because most of it is merged. The test is all or nothing.
- Deciding by commit metadata (author, date, message, PR number). An amended commit keeps its
  author date and message while its content changes.

## Design

### Order

`_wt_rm_branch` keeps its shape. `git branch -d` stays first. If it refuses, each base is tried in
today's order (local HEAD, then `origin/HEAD`; a base equal to the branch is skipped). For each
base, after today's no-net-change guard (unchanged), three tests run in order, and the first that
says yes deletes the branch with `git branch -D`:

1. **Rebase test** (new).
2. **Squash test** (new).
3. **Merge-tree test** (today's test, unchanged): it still covers merges the other two cannot see,
   such as a squash onto a moved base whose context lines changed.

If no base says yes, the branch is kept with today's message.

### Patch ids

Both new tests find candidates by **verbatim patch id**. A matching id only nominates a pair; the
pair counts only once the replay check (below) passes. Ids are computed one per non-merge commit,
with plumbing only:

```
git rev-list --no-merges <range> \
  | git diff-tree --stdin -p --full-index --no-renames \
  | git patch-id --verbatim
```

For a whole change it is `git diff-tree -p --full-index --no-renames <from> <to> | git patch-id
--verbatim`.

Why these choices (measured with git 2.56 on 2026-11-11):

- **Not `git cherry`.** Its patch ids ignore whitespace: a branch commit that indents a line with
  four spaces matched a base commit that indents it with a tab. It skips merge commits on the
  branch without saying so. It also matches an empty commit against any unrelated empty commit.
- **`--verbatim`**, so whitespace counts.
- **Plumbing (`diff-tree`), never `diff`/`log -p`**, so user configuration cannot change the
  patch. With `color.diff=always`, `git diff | git patch-id` printed no id at all, and with
  `diff.noprefix` it printed a different id. `diff-tree` gave the same id under `color.ui`,
  `diff.noprefix`, `diff.mnemonicPrefix`, `diff.external` and `diff.renames`.
- **`--full-index`**: for a binary file the patch id hashes the blob ids on the `index` line, so
  they must be complete. Two different changes to one binary file gave different ids.
- **`--no-renames`** on both sides, so a rename is compared as the same delete and add.
- An empty commit produces no id. It neither matches nor blocks; the no-net-change guard is what
  stops a branch with nothing in it.

An empty id list, a failed command, or output that is not lines of two hex object ids is a failure,
and a failure keeps the branch (for this test and this base).

### Replay check

A patch id ignores where a hunk sits. Measured: a file holding two identical blocks, a branch that
changes the first and a base commit that makes the same change to the second gave equal verbatim
ids, although the branch's change never landed.

So a candidate pair (branch change `C` from `F` to `T`, base commit `X` with parent `X^`) counts
only if replaying the change onto `X^` reproduces `X` exactly:

```
git merge-tree --write-tree --merge-base=<F> <X^> <T>    # its tree must equal X^{tree}
```

For one commit, `F` is `C^` and `T` is `C`. For the squash test's whole change, `F` is the
merge-base and `T` is the branch. This is the 3-way cherry-pick that a rebase-merge performs. A
conflict, a non-zero exit, a git without `--merge-base` (before 2.40) or any other tree means no.

Measured with git 2.56: the repeated-block pair is rejected. A genuine cherry-picked copy on a
moved base passes, and so does a GitLab-style squash commit, each after a later conflicting base
commit. All 92 commits of the four kept tagteam branches pass against their id-matched copies.

### Rebase test

Yes when all of these hold:

- the branch side, `<base>..<branch>`, has **no merge commit**. A merge commit can carry content of
  its own (a conflict resolution), and patch ids cannot see it;
- the branch side has at least one patch id;
- every branch commit with an id **pairs with a base commit of its own** in `<branch>..<base>`. The
  base commit has the same id and passes the replay check, and no base commit is paired twice.
  Pairing is greedy in branch order. A pairing that fails, ambiguous duplicates included, keeps the
  branch. Because each base commit is used once, matching counts like a multiset: a branch that
  applies a change, reverts it and applies it again is not covered by a base that applied and
  reverted it once.

This is Git's own idea of "already applied" (what `git rebase` drops), made strict: the same
verbatim patch, and the cherry-pick a rebase-merge performs reproduces the copy exactly.

### Squash test

Yes when all of these hold:

- the branch and the base have exactly one merge-base (`git merge-base --all` prints one line).
  With several, "the branch's whole change" is undefined;
- the patch id of the whole change, `<mb>` to `<branch>`, is not empty;
- it differs from the patch id of every one of the branch's own commits. When the whole change
  equals one of its commits, the rest of the branch nets out in patch terms, and the rebase test
  alone judges it. Without this, a branch that applies a change, reverts it and applies it again
  would match the base's copy of its first commit, although the base lacks the change. A
  single-commit branch loses nothing: the rebase test sees its one commit;
- it equals the patch id of at least one non-merge commit in `<mb>..<base>` for which the replay
  check of the whole change passes.

A GitLab squash commit has the merge-base as its parent and the branch's tree as its tree, so its
patch is the branch's whole change, byte for byte. Measured: after such a squash and a later commit
that edits the same CHANGELOG lines, the merge-tree test says no and this test says yes.

### Messages

On deletion, the `✓ deleted branch <b> (…)` line names the test that matched and the base it
matched against: rebase-merged (each commit has a copy in the base), squash-merged (one base commit
carries the whole change), or merged (its content is in the base, the merge-tree test). The exact
wording is the builder's. Every word of today's "kept" message stays.

### Cost

On tagteam, ids for the whole history (1,389 non-merge commits) take 0.75 s. Ids plus a replay of
each commit take 0.61 s for the largest kept branch (38 commits). Each test computes the base side
once per base. No path filter or cache is needed.

## Accepted limits

- **Context drift.** A rebase that lands a commit next to lines changed after the branch was cut
  (within the patch's 3 context lines) changes its patch id. Measured: a CHANGELOG entry rebased
  under a newly added neighbour gets a different id. Such a branch falls through to the merge-tree
  test, and is kept if that conflicts too. GitHub refuses a rebase-merge that conflicts, and the
  author's rebase then updates the branch itself, so the tagteam pattern stays covered.
- **Reverted after merging.** A branch whose copies landed and were then reverted on the base is
  deleted, as `git branch -d` deletes a merged branch after a revert. Its commits stay reachable
  through the base's history.
- **Equal patches from elsewhere.** A branch commit whose exact patch also landed independently,
  at the place the replay puts it (the same one-line version bump, say), counts as applied. Its
  content is in the base.
- **The replay is Git's merge.** If Git's 3-way merge would place a change somewhere unexpected
  (repeated blocks, with the base having removed one of them), the check trusts it. A rebase-merge
  of the same commit would have landed exactly that.
- **Order.** The rebase test does not check that the copies landed in the branch's order.

## Tests

In `tests/wt-functions.test.sh`, beside the squash cases (`sq1`–`sq4`). Each case names the
behaviour it pins and the bug it catches.

Behaviour. Each must fail on today's `main`:

1. **Rebase-merge, then a conflicting base commit.** The branch's commits are copied onto the base
   (cherry-picked, so they get new SHAs), then a later base commit edits the same lines. Deleted.
   Catches: no rebase test (today the merge-tree test conflicts and keeps it).
2. **GitLab squash, then a conflicting base commit.** A squash commit with the merge-base as parent
   and the branch's tree (`git commit-tree`), merged into the base with `--no-ff`, then a later
   commit that edits the same lines. Deleted. Catches: no squash test.

Safety. Each passes on today's `main`, since it keeps the branch, and must fail against the
deliberately broken variant named:

3. **One unmerged commit among copied ones.** Kept. Catches: a rebase test that accepts "most".
4. **No net change.** The branch adds a change and reverts it; both are copied onto the base. Kept.
   Catches: the new tests running before, or without, the no-net-change guard.
5. **Repeated block, one commit.** A file holds two identical blocks. The branch's one commit
   changes the first; a base commit makes the same change to the second. Kept. Catches: a rebase
   test without the replay check.
6. **Merge commit with content of its own.** The branch has a copied commit and a merge commit
   whose conflict resolution adds a line the base lacks. Kept. Catches: a rebase test that ignores
   merge commits.
7. **Repeated patch.** The branch applies a change, reverts it and applies it again; the base has
   copies of the first two only. Kept. Catches two broken variants, each on its own: set instead
   of multiset matching (the rebase test says yes), and a squash test that does not stand aside
   for one of the branch's own commits (it matches the base's copy of the first apply).
8. **Repeated block, whole change.** As case 5, but the branch reaches the change in two commits
   (`old` to `mid`, then `mid` to `new`), so only the squash test can match it. Kept. Catches: a
   squash test without the replay check.

No case pins `--verbatim`: with the replay check, whitespace-blind ids would only nominate more
candidates, which the replay rejects. It stays for precision.

Fixture notes, measured by the builder check on 2026-11-11:

- Case 1 moves the base before copying the commits. A cherry-pick made in the same second onto an
  unmoved base can reproduce the original SHA, and `git branch -d` then succeeds before the new
  tests run.
- Case 6 cannot merge the base into the branch: the copied commit then drops out of
  `<branch>..<base>`, and the merge-ignoring variant keeps the branch too. It merges a side branch
  whose commits are also copied onto the base, with a resolution of its own.

Cases 1 and 2 run through `wt-rm`. Cases 3–8 may drive the helper directly on a plain repository if
that is cheaper; each still asserts that the branch exists afterwards. The existing cases (`h`, `i`,
`sq1`–`sq4`, `q11`, `q12`, `q24`–`q26`) keep passing unchanged.

The plan runs each safety case against its broken variant once, and records that it failed.

## Records

- This spec is the record of `wt-rm`'s branch-deletion rule, today's squash rule included.
- The 2026-07-30 spec gets a dated amendment banner at the top, in the style of its 2026-10-13 one,
  pointing here for §8 step 13 and §9.3. Its body is not rewritten.
- The comment above `_wt_branch_content_merged`, and the one above the `sq1` tests, are updated to
  match.

## Driver rulings

Michael approved the direction: delete on a rebase-merge via `git cherry`, on a squash-merge via
patch id, keep today's tests as fallbacks, and keep the branch whenever in doubt. Three details
were settled here, all on the side of keeping:

- **Verbatim plumbing patch ids instead of `git cherry`.** They are the same test made strict
  (see "Patch ids"). They keep every branch `git cherry` would keep, with one exception: a commit
  with no changes neither blocks nor matches. That is what the squash path has done since d7fa282
  (case `sq1`).
- **The squash test stands aside when the whole change equals one of the branch's own commits.**
  Found by the builder check (case 7). It costs one rare case: a squash-merged branch whose other
  commits net out. The rebase test then judges it, and the merge-tree test is still the fallback.
- **A patch-id match must survive the replay check.** Found by the Codex spec review (round 1):
  equal ids alone would delete a branch whose change went to an identical block elsewhere. The
  check costs nothing measurable and removes no tagteam deletion.

## Left to the builder

- Function names and structure. One helper may compute the id lists for both tests.
- The exact deletion wording, within "Messages".
- Whether cases 3–8 drive `wt-rm` or the helper.
- How a failure inside a test is detected, within "Patch ids" (any failure keeps the branch).
