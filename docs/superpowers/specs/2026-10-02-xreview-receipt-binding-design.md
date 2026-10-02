# xreview receipt binding (P1-A)

**Status:** Approved (signed off by Michael 2026-10-02 after five Codex spec rounds)
**Date:** 2026-10-02
**Scope:** `dot_local/bin/executable_xreview`, `dot_claude/executable_xreview-guard.sh`, the
cross-review skill, and their test suites. This closes P1-A, which has been open since the relay
shipped (2026-08-31).

## 1. Problem

The pre-merge guard (`xreview-guard.sh`) is meant to make sure nothing is proposed or merged
without an approving Codex pre-merge review. Since 2026-09-30, the latest pre-merge receipt
for a branch must say `approve`. On 2026-10-01, a day with 30+ reviewed branches across 18
repos, the guard turned out to be bypassed by every normal flow, without anyone intending to.

1. **The receipt records the wrong subject.**
   - A receipt stores the branch and HEAD that were checked out at dispatch.
   - Reviews dispatched from the main checkout with `--diff main..chore/x` were recorded as
     `branch: main`, the checkout's branch rather than the reviewed one.
   - The guard keys its lookup on the branch checked out where `glab mr create` runs, so it
     would have consulted the wrong receipts.
2. **Only two command shapes are gated:** `glab mr create` and `gh pr create`. That day the
   work went through:
   - `glab api -X POST …/merge_requests` (create);
   - `glab api -X PUT …/merge_requests/N/merge`, `gh pr merge` and a local
     `git merge <branch>` on `main` (merge).

   None of these reached the guard, so it never fired.
3. **There is no freshness check.**
   - A receipt stays valid after new commits.
   - The global rule ("commits after the last pre-merge review need a new review") was kept
     by hand on every fix round. Nothing enforced it.
4. **Ledgers are split per checkout.**
   - The ledger is keyed by the checkout's top-level path, so a harness worktree under
     `.claude/worktrees/…` writes to a ledger the main checkout never reads.
   - A review covering 17 other repos, dispatched from the dotfiles checkout, left no
     receipt in any of them.
5. **Ledger appends are not locked.** This was part of the original P1-A finding.

Until this is fixed, receipts and the guard are reminders, not authorization, and the human
merge gate is what actually holds.

## 2. Goals and non-goals

**Goals**
- **Approve a change, not a branch name.** A receipt records the exact change Codex
  reviewed and the branch it is meant to land on. The gate opens only for that change
  landing there.
- **Gate where agents propose and merge.** That covers MR/PR creation and agent-run merges:
  forge CLI, forge API and a local merge into the default branch.
- **Keep the freshness rule automatic.** Any content change after the approving review
  closes the gate. A clean rebase does not.
- **One ledger per repository,** shared by all of its worktrees. A single review may target
  several repositories.
- **Never let a newer review be shadowed by an older approval,** even when a write fails.
- **No new prompts.** The guard only denies, with a reason, and stays silent otherwise
  (prompt budget: destructive actions only).

**Non-goals**
- P1-B: reviewer text reaching Claude's context. It is narrowed, not closed, and stays
  out of scope.
- Merges Michael performs in a forge web UI. Those are his human gate.
- Obfuscated commands, such as a verb assembled from variables, `eval`, a script file, or a
  user-defined CLI alias. This keeps the existing guard threat model: plausible agent
  commands only.
- Merge requests from forks. A source repository other than the checkout's `origin` is
  denied rather than modelled.

## 3. Design

### 3.1 The reviewed change and its fingerprint

**Target.** A review target is a tuple:
- the repository, identified by its absolute git common directory
  (`git rev-parse --path-format=absolute --git-common-dir`);
- the destination branch (`dest`);
- the base commit;
- the tip commit.

**Default branch.** Read from `refs/remotes/origin/HEAD`, falling back to `main`, then
`master`.

**Range normalization.**
- A range whose left side names a branch (`X`, `origin/X`, in `X..B` or `X...B` form) is
  normalized:
  - `dest` is the branch *name*, `X`;
  - `dest_ref` is the ref exactly as given (`origin/X` stays `origin/X`);
  - `base = git merge-base <dest_ref> <tip>`.

  The name decides which merges the receipt can open, while the ref, as written, decides
  the base.
  - So `main..feature` stays full after `main` has advanced past the branch point.
  - `release/1.2...hotfix` is full for the destination `release/1.2`.
- A left side that is a commit rather than a branch (`5c86f2c..B`) keeps its literal base,
  has no `dest`, and is *partial*.

**Full target.** A target is *full* when it has a `dest` and
`base = merge-base(dest_ref, tip)`. Only a full target can open the gate, and only for its
`dest`. A partial range, such as a review of just the fix commits, is recorded but never
opens the gate. The review packet can still steer Codex's attention to the new commits while
`--diff` names the full range.

**Fingerprint: exact content identity, not a patch hash.**
- It is the SHA-256 of the sorted lines `<path>\t<old-mode>\t<new-mode>\t<old-blob>\t<new-blob>`
  taken from:
  ```
  git diff --raw -z --no-abbrev --no-renames --no-ext-diff --no-textconv --ignore-submodules=none <base> <tip>
  ```
  `--ignore-submodules=none` overrides any `diff.ignoreSubmodules` or `submodule.*.ignore`
  setting, so a changed gitlink always counts. The inlined review diff uses the same flag.
- It is whitespace-sensitive, location-sensitive and binary-sensitive, because it names
  the exact before and after blob of every changed path. Mode changes count, and a rename
  is a delete plus an add.
- **Rebase:**
  - stable when the destination did not touch any changed path, because both blobs are
    unchanged;
  - changed when it did touch one, so a re-review follows. That is the conservative side,
    on purpose.
- An empty diff has no fingerprint and cannot be approved.

A patch hash (`git patch-id`) was rejected. It ignores whitespace, and with reduced context
it lets an approval transfer to the same edit made at another location.

### 3.2 Ledger entries

The ledger holds two kinds of entry. Both carry `v:2`, `nonce` and `dispatched_at` (UTC,
fixed at dispatch).

```json
{"v":2,"kind":"pending","nonce":"xr-…","dispatched_at":"…","checkpoint":"pre-merge",
 "targets":[{"repo":"/abs/common/dir","dest":"main","dest_ref":"main","branch":"chore/x","range":"main..chore/x",
             "base":"<sha>","tip":"<sha>","full":true,"fingerprint":"<id>"}]}
{"v":2,"kind":"receipt","nonce":"xr-…","dispatched_at":"…","checkpoint":"pre-merge",
 "verdict":"approve","findings":0,"thread":"…","turn":"…","tier":"…","targets":[…same…]}
```

- **Pending** is appended at dispatch, before the review turn starts.
- **Receipt** is appended at collect, with the verdict.
- `targets` lists only the entries for that ledger's repository. The fields are fixed at
  dispatch, from what Codex was sent; nothing is re-read at collect time.
- **Idempotent per nonce.** A ledger that already holds a receipt for a nonce is not
  appended to again.
- **The review's state** is the receipt for its nonce if one exists, otherwise its pending
  entry.
- v1 receipts (no `v`) stay in old ledgers and are shown as "on record", but they never open
  the gate.

### 3.3 Ledger location and writes

**Location.** `$XDG_STATE_HOME/xreview/ledgers/<key>/reviews.jsonl`.
- `<key>` is the SHA-256 of the absolute git common directory path. That is
  collision-resistant: mapping `/` to `_` would merge `/a_b/.git` and `/a/b/.git`.
- The directory also holds a `repo` file naming the path, for humans.
- Every worktree of a repository resolves to the same ledger.
- All other xreview state keeps its current per-checkout location (turns, threads, rounds,
  pins, apply window). Only the ledger moves.

**Writes.**
- Each append takes a `mkdir <ledger>.lock` lock, because macOS has no `flock(1)`.
- The lock is retried for up to 5 s. A lock older than 60 s is stale and is broken.
- **Pending write failure is fatal.** If a pre-merge dispatch cannot append its pending entry
  to every target ledger, it is refused before any turn starts. So every pre-merge review
  that runs is on record.
- **Receipt write failure only warns.** If collect cannot append a receipt, it warns on
  stderr. The pending entry then remains the newest state for that change, so the gate stays
  closed (§3.6) until a later collect records the receipt.

**Reads** parse one line at a time (`fromjson?`), as now.

### 3.4 Dispatch

`--diff` becomes repeatable: `--diff [<repo-path>:]<range>`.
- With no path, the range belongs to the current repository.
- **Spec and plan checkpoints** may have no target at all, as today: artifact-only reviews
  need no committed diff, and they write no ledger entries.
- **A pre-merge checkpoint** with no `--diff` targets the current branch, with `dest` set to
  the default branch. A pre-merge dispatch whose targets are all empty is refused.

For each target, dispatch:
- resolves the repository;
- normalizes the range (§3.1);
- resolves `base` and `tip`;
- decides `full`;
- computes the fingerprint;
- inlines `git diff <base> <tip>`.

The existing size cap applies to the total of all inlined diffs. For pre-merge, dispatch
then writes the pending entries (§3.3), and only then starts the turn. Targets and
`dispatched_at` are also kept in `turns/<nonce>.targets` for collect. The existing turn
record's format is unchanged, so old records still collect.

### 3.5 Collect

When the verdict is in (rc 0), collect groups the targets by repository and appends one
receipt to each repository's ledger, idempotent per nonce. If there is no targets file (a
turn from before this change), it writes a v1-style receipt as today. That keeps every
in-flight turn collectable.

### 3.6 Guard

**Gated command shapes.** A verb counts only in command position.

| Shape | The change, and its destination |
|---|---|
| `glab mr create`/`new` | source: `--source-branch`/`-s`, else the current branch; dest: `--target-branch`/`-b`, **required** |
| `gh pr create`/`new` | source: `--head`, else the current branch; dest: `--base`/`-B`, **required** |
| `glab api` / `gh api` POST to `…/merge_requests` or `repos/<o>/<r>/pulls` | `source_branch`/`head` and `target_branch`/`base` |
| `git merge <ref>` while the repo's current branch is its default branch | `<ref>`; dest: the default branch |
| `glab mr merge`/`accept [<n>]`, `glab api` PUT `…/merge_requests/<n>/merge` | the pinned head; dest: the MR's `target_branch` from `glab api …/merge_requests/<n>` |
| `gh pr merge [<n>]`, `gh api` PUT `repos/<o>/<r>/pulls/<n>/merge` | the pinned head; dest: `baseRefName` from `gh pr view <n> --json baseRefName` |

**The creation destination must be explicit.** The CLIs can take an implicit base from
per-branch configuration (for example `branch.<b>.gh-merge-base`), which the guard would
have to reimplement. So a CLI creation without `--target-branch`/`--base` is denied, and
the message names the flag. The API forms always carry the destination field.

**Unresolved forms are denied.** The guard denies when it cannot read the source, head or
destination of:
- any `glab api`/`gh api` call with method POST, PUT or PATCH whose path names
  `merge_requests` or `pulls`;
- any `glab api graphql`/`gh api graphql` call carrying a mutation that creates or merges an
  MR/PR or enables auto-merge (`mergeRequestCreate`, `mergeRequestAccept`,
  `mergeRequestSetAutoMerge`, `createPullRequest`, `mergePullRequest`,
  `enablePullRequestAutoMerge`).

Agents use the CLI or REST forms above instead.

**Plain commands only.** A gated verb must be a single plain command.
- Allowed:
  - an optional leading `cd <literal path> &&`, which the guard resolves;
  - `sudo`;
  - `git -C <path>`, `glab -R <repo>`, `gh -R <repo>`;
  - the `XREVIEW_GUARD=off` assignment (the bypass).
- **Any other `VAR=` assignment on a gated verb, or an `env` wrapper, is denied.** Variables
  such as `GH_REPO`, `GITLAB_HOST`, `GIT_DIR` and `GIT_WORK_TREE` change the execution
  context.
- Any other compound that contains a gated verb is denied: `git switch main && git merge x`,
  a pipe, `;` chains or subshells. The message says to run the verb as a plain command.

The guard therefore evaluates the repository, branch and forge context the verb will
actually run in. This is the same grammar discipline as the push guard.

**Creation is checked against the remote head.**
- The forge proposes the branch as it exists on the remote, so the guard reads that head:
  `git ls-remote <remote> refs/heads/<source>`. The source repository must be the checkout's
  `origin`; forks are denied.
- The head object must exist locally; otherwise the guard denies and the message says to
  fetch.
- Movement after creation is not the creation gate's concern: the pinned merge gate
  (below) decides what lands.

**Forge merges are pinned.**
- A forge merge must name the expected head SHA: `glab mr merge --sha <sha>`, the GitLab API
  `sha` field, `gh pr merge --match-head-commit <sha>`, or the GitHub API `sha` field. The
  forge then refuses the merge if the branch moved after the check.
- The pinned head's full fingerprint against the MR's destination must be approved
  (decision below). It is not compared with a recorded tip, so a clean rebase keeps working.
- A forge merge without a pin is denied, and the message gives the current head to pin once
  it is approved.
- **Deferred merges are denied**: `merge_when_pipeline_succeeds` / auto-merge, and
  `gh pr merge --auto`. Their pipeline wait is a long window in which the MR could be
  retargeted, and no forge lets a merge pin its destination. An agent waits for the
  pipeline, then runs an immediate pinned merge.

**Destination commit.** The guard resolves destination D to a commit:
- for forge shapes, to `refs/remotes/origin/D`, which must exist locally (otherwise it
  denies, and the message says to fetch);
- for a local `git merge`, to the checked-out default branch's `HEAD`.

**Decision** for a change with tip T and destination D, in the repository whose common
directory is R:
1. Compute the fingerprint F of `merge-base(<D's commit>, T)..T` from local objects.
2. Consider every v2 pre-merge entry in R's ledger with a full target whose `repo` is R,
   whose `dest` is D and whose fingerprint is F. Take each review's state (§3.2).
3. Allow if and only if the latest of them, ordered by `dispatched_at`, is a receipt that
   says `approve`.

A newer pending review, a newer `changes` verdict, or a receipt that failed to write all
close the gate. Spec and plan entries never count.

**Fails closed on gated shapes.** The guard denies when a gated shape matches but the check
can't be completed:
- not inside a git repository;
- the head is not available locally (the message says to fetch);
- the forge lookup fails;
- the change is empty;
- the ledger is unreadable.

Any non-gated command is allowed, as now. The fast path stays a shell substring test on the
payload. Commands containing none of `create`, `new`, `merge`, `accept`, `pulls` or
`graphql` cost no subprocess.

**Repository for a forge-API shape.** The guard finds the repository by `-R`/`--repo`, then
by the current directory. Its `origin` must match the project in the command, which may be a
path or a numeric ID resolved through the API. Otherwise the guard denies and says to run
from that project's checkout.

**Deny message.** It names:
- the change (repo, source, destination, tip, fingerprint);
- what is on record for it, and for the branch name, v1 and pending entries included;
- the exact dispatch to run: `xreview dispatch --checkpoint pre-merge --diff <dest>...<branch> <body>`;
- for a forge merge, the head to pin.

`XREVIEW_GUARD=off` stays as the only bypass, for Michael's explicit use, and the MR must
say so.

### 3.7 Cross-review skill and docs

- The skill text says a pre-merge review that is meant to open the gate must use the full
  range against the branch it will land on: `<dest>...<branch>`, or `<dest>..<branch>`,
  which is normalized (§3.1).
- It also says forge merges by an agent pin the head (`--sha` / `--match-head-commit`), are
  never deferred (wait for the pipeline, then merge), and that MR/PR creation names its
  destination explicitly.
- It shows the multi-repository form.
- It notes that a fix round needs a fresh full-range round.
- The guard's header comment drops the "receipt is advisory about freshness" rationale.
  Freshness is now enforced, and the rebase case is handled by the fingerprint.

## 4. Interactions

- **Push guard and forge guard:** unchanged. Pushes are not gated by review; merges and
  MR creation are.
- **In-flight branches at rollout:** v1 receipts cannot open the gate, so any branch already
  reviewed under v1 needs one fresh full-range pre-merge round before an agent creates or
  merges its MR.
- **The safe-autonomy evaluation** (about 15 October) counts guard denies. The rollout date
  goes into that spec's notes, so new denies are attributed correctly.

## 5. Testing

`tests/xreview-guard.test.sh` and `tests/xreview.test.sh`, run in fixture repositories, with
`glab`, `gh` and remotes stubbed as the suites already do.

- **Fingerprint and normalization:**
  - a clean rebase onto a destination change in another file keeps it;
  - a rebase over a destination change in the same file changes it;
  - a one-line text change changes it;
  - a whitespace-only change (indentation, or inside a string) changes it;
  - the same edit applied at a different location changes it;
  - a one-byte binary change changes it;
  - a mode-only change changes it;
  - a gitlink (submodule pointer) change changes it, even with `diff.ignoreSubmodules=all` set;
  - an empty range has none;
  - `main..feature` after `main` advanced is normalized and full;
  - `origin/release/1.2...hotfix` with no local `release/1.2` resolves through the remote
    ref, and a stale local `release/1.2` is not used;
  - a commit-based left side is partial.
- **Gate:**
  - an approved full change opens every gated shape for its `dest`, and only that `dest`:
    the same change merged into another branch is denied;
  - one extra commit closes it;
  - a later `changes` verdict closes it;
  - a newer pending review closes it;
  - a failed receipt write leaves the gate closed;
  - re-collecting an old approve after a newer `changes` does not reopen it;
  - a partial-range approve, spec and plan reviews, and v1 receipts do not open it.
- **Shapes:**
  - each create and merge form, including `glab mr new`/`accept`, `gh pr new`, `gh api`
    PUT/POST `…/pulls`, and the GraphQL mutations (denied);
  - `git -C <path> merge` on the default branch is gated, and on a non-default branch it is
    not;
  - `git switch main && git merge x` and `x; glab mr create` are denied as compound;
  - `cd <path> && glab mr create` is resolved in that path;
  - `GH_REPO=o/r gh pr create`, `GIT_DIR=… git merge x` and `env … glab mr merge` are
    denied;
  - an unpinned forge merge is denied;
  - a deferred merge (`merge_when_pipeline_succeeds`, `--auto`) is denied, even pinned;
  - a CLI creation without `--target-branch`/`--base` is denied;
  - a pin whose fingerprint is unapproved is denied;
  - a rebased pin with an unchanged fingerprint is allowed;
  - a creation whose remote head differs from the approved local branch is denied;
  - a fork source is denied;
  - `rg 'glab mr merge'` and a commit message containing "merge" are not gated.
- **Dispatch:**
  - spec and plan dispatches with no `--diff` still work;
  - a pre-merge dispatch whose pending write fails is refused.
- **Fail-closed paths:**
  - no repository;
  - head missing locally;
  - forge lookup failure;
  - unreadable ledger.
- **Multi-repository:** one dispatch with two `--diff <repo>:<range>` targets writes one
  pending entry and one receipt into each ledger, and each opens its own repository's gate.
- **Worktrees:** a review collected from a harness worktree opens the gate in the main
  checkout.
- **Isolation:** two repositories whose paths would collide under a `/`→`_` mapping get
  separate ledgers, and an approval in one never opens the other, even for identical blobs
  and destination.
- **Locking:** 20 concurrent appends produce 20 valid lines, and a stale lock is broken.
- **Old turns:** an old turn record without a targets file still collects, as v1.

## 6. Rollout

One branch and one Draft review cycle:
1. this spec;
2. the plan, reviewed by Codex;
3. execution, subagent-driven;
4. the pre-merge review.

This branch is reviewed and merged under the deployed, old xreview and guard. The old guard
does not gate a local `git merge`, and the dotfiles have no MR, so no bypass is needed. Once
the merge is applied, every gated action on every repository needs a v2 receipt (§4,
in-flight branches).

## 7. Risks and limits

- **Command coverage:** a gated verb assembled from variables, `eval`, a script file or a
  user-defined CLI alias passes. This is the same threat model as the push guard; the
  classifier covers deliberate obfuscation.
- **Rebase churn:** a rebase over destination changes that touch the same files needs a
  re-review. That is the price of an exact identity, and it is accepted.
- **Network:** creation reads the remote head with one `git ls-remote`. A forge merge looks
  up its destination with one API call. Both happen only when the shape matches.
- **Destination binding at check time:** the source head is pinned by the forge, but the
  destination cannot be. Another actor retargeting an MR in the seconds between the guard's
  lookup and the immediate merge could land an approved change on an unapproved branch.
  - This needs a concurrent, deliberate actor, which is outside the guard's model.
  - The long window, deferred merges, is closed by denying them.
- **Stale lock:** a crashed writer can hold the ledger lock for up to 60 s before it is
  broken. Dispatch and collect wait at most 5 s. Dispatch then refuses; collect then warns,
  and the pending entry keeps the gate closed.
