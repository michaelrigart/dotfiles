# Worktree hook protocol

**Status:** Approved
**Date:** 2026-07-30

## 1. Problem

The dotfiles repository provides a general development workflow:

- `wt <branch> [start-point]` creates a sibling Git worktree, copies declared
  Git-ignored files, and opens the checkout through `dev`.
- `wt-rm <branch>` validates and removes that worktree and its Zellij session.

The generic layer cannot prepare every project to run concurrently. A Rails
application may need logical PostgreSQL databases and a web port; a .NET project
may need different services; a Python project may need a per-worktree virtual
environment. Encoding any of those policies in `wt` would couple the shared
workflow to individual projects.

Repositories need a small extension point through which they prepare and reclaim
their own worktree resources. The generic layer supplies orchestration, ordering,
trust boundaries, and recovery without learning what those resources mean.

The existing copy step also has no generic retry path. After a partial `wtcp`
failure, reopening with `wt <branch>` deliberately skips preparation and goes
straight to `dev`. The protocol therefore needs a named preparation command that
covers both copied files and project setup.

## 2. Goals

1. Let any repository under the general workflow opt into project-specific
   worktree setup and teardown.
2. Keep the protocol independent of shell and application stack.
3. Execute only a hook supplied by Git's primary worktree, never one introduced
   solely by the target feature branch.
4. Make lifecycle ordering and failure states predictable.
5. Never destroy a worktree or branch on a failure path, and never force one.
6. Provide an idempotent retry path for partial copying and setup.
7. Work after a fresh clone with no per-machine configuration.

Goal 5 is deliberately narrow. It constrains the generic layer's own actions: no
failure path removes a worktree, deletes a branch, or passes `--force` to a
command that would. It is **not** a guarantee about file contents. Hooks run with
the user's full privileges and cwd set to the worktree; a hook can modify or
delete anything there. The protocol preserves the checkout, not its contents.

## 3. Non-goals

The generic layer does not:

- Allocate ports, databases, containers, storage, queues, or other resources.
- Promise that every worktree can run a concurrent full application stack.
- Define what "isolated enough" means for a repository.
- Roll back a partially successful hook.
- Reconcile whether setup ran, whether existing copied files are valid, or
  whether teardown reclaimed the intended resources.
- Persist protocol state or completion markers.
- Orchestrate worktrees created, moved, or removed through raw Git commands.

Each adopting repository owns its resource policy, implementation, tests, and
documentation.

### 3.1 Relationship to committed behavior

Commit `6e0213e` already implements and verifies the generic worktree lifecycle.
This design does not revisit it. Already in place:

- `wt <branch> [start-point]`, branching from the caller's `HEAD` with the base
  reported.
- `_wt_assert_worktree` destination and branch validation, including husks and
  slash-versus-hyphen slug collisions.
- `.worktreeinclude` copying through `wtcp`, with warnings for missing entries.
- `wt-rm` with dirty preflight, stop-session-before-remove, safe `branch -d`, and
  husk reporting.
- `_wt_session_name` as canonical naming, with `dev` resolving session names by
  generate-and-compare.
- `dev` reporting each session-creation step separately.
- `.scripts/test-wt-functions.sh`, 46 assertions.

**New here:** the `.worktreehook` protocol; `wt-prepare` and the extracted
preparation routine; manifest path validation; per-target locking; the
config-resistant cleanliness helper applied at three checkpoints; primary-worktree
resolution via `worktree list`; shell-quoted branch names in recovery messages;
absent-session-is-success.

**Changed here:**

- `wtcp` becomes required only when copying is actually needed. Today a present
  `.worktreeinclude` fails without `wtcp` even if every destination exists.
- The copy filters to missing destinations. Today it is unfiltered, which is
  correct only because creation always targets a fresh worktree — it would fail
  on the retry path this design introduces.
- `wt` gains hook pre-validation before `git worktree add`.

## 4. Terms and resolution rules

- **Target worktree:** the sibling checkout being prepared or removed.
- **Preparation:** copying missing `.worktreeinclude` destinations, then invoking
  project setup.
- **Hook:** the primary worktree's `.worktreehook` executable.

### 4.1 Primary worktree resolution

The **primary worktree** is the first `worktree` entry reported by:

```sh
git worktree list --porcelain -z
```

`-z` with NUL-aware parsing is required, not optional. The plain porcelain format
is line-based and offers no guarantee that a path is emitted raw, so a path
needing quoting — or containing a newline — cannot be parsed unambiguously. `-z`
removes the question rather than relying on which characters happen to trigger
quoting. The same applies wherever the protocol enumerates worktree paths,
including `_wt_assert_worktree`.

If that entry is followed by a `bare` marker, the repository has no primary
working tree and every lifecycle command refuses with an explicit error.

This rule is normative because the obvious shortcut is wrong. Taking the parent
of `git rev-parse --git-common-dir` resolves correctly for a standard
non-bare repository (`/…/repo/.git` → `/…/repo`) but yields the *containing
directory* for a bare repository (`/…/repo.git` → `/…/`), which is not a
worktree at all. Resolution must come from `worktree list`, not from path
arithmetic on the common directory.

### 4.2 Cleanliness checks

Every cleanliness check in this protocol uses one helper with a fixed invocation,
run with Git's routing environment cleared:

```sh
git -C <worktree> status --porcelain=v1 --untracked-files=normal \
                         --ignore-submodules=none
```

with the exit status captured **separately** from the output. Each part is
mandatory, and each closes a way the check can return "clean" for a dirty tree:

- **Routing variables cleared.** An exported `GIT_WORK_TREE` redirects
  `git -C <worktree> status` to a different checkout entirely: the dirty target
  returns empty output with exit status `0`, indistinguishable from clean. The
  helper clears `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`,
  `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, and `GIT_NAMESPACE`
  before invoking Git.
- `--untracked-files=normal` defeats `status.showUntrackedFiles=no`, which
  otherwise makes a dirty tree return empty output.
- `--ignore-submodules=none` defeats `diff.ignoreSubmodules` and
  `submodule.<name>.ignore`, which can hide a dirty submodule.
- `--porcelain=v1` pins the format against a future default change.
- A nonzero exit is an *unknown* state and fails closed. Testing output alone
  reads a failed `git status` — corrupt index, unreadable worktree — as "no
  changes", the most dangerous possible misreading.

Assigning and testing must be separate statements. In zsh, `local x="$(cmd)"`
reports the *builtin's* status, not the command substitution's, silently hiding
the failure this rule exists to catch.

**Routing clearance is not specific to `status`.** An exported `GIT_DIR` equally
misroutes `worktree list`, `ls-files`, `worktree remove`, and `branch -d` — which
would corrupt primary-worktree resolution, hook validation, and removal itself.
Every Git invocation the protocol makes runs with the same variables cleared, not
only the cleanliness helper.

Ignored files are intentionally invisible to these checks. Hook output must be
ignored (§5.3), and `git worktree remove` tolerates ignored files while refusing
untracked ones.

## 5. Hook protocol

### 5.1 File and trust boundary

A repository opts in with one tracked executable at its primary worktree root:

```text
.worktreehook
```

The hook is valid only when all of these hold:

1. `git ls-files --stage -- .worktreehook` reports exactly one stage-0 entry with
   mode `100755`.
2. The primary working-tree path exists and is a regular file.
3. It is not a symbolic link.
4. It is executable.

The index check rejects untracked hooks, `100644` files, `120000` symlinks,
`160000` gitlinks, and conflicted hooks (which have no stage-0 entry). The
filesystem checks reject a tracked regular hook replaced locally by an unstaged
symlink, or one that has lost its executable bit.

Both halves are required. A tracked symlink satisfies "tracked" and "executable"
— `test -x` follows it — while the code that runs lives outside the repository
entirely. Conversely, the index mode alone cannot see an unstaged local swap.

A hook indexed as `100644` reports the repository-level repair:

```sh
git add --chmod=+x .worktreehook
```

Requiring `100755` in the index, not merely on disk, makes opt-in reproducible:
a hook tracked as `100644` arrives non-executable in every fresh clone.

If neither the index nor the working tree contains `.worktreehook`, the
repository has not opted in and hook execution is a successful no-op. Any partial
or inconsistent presence is a configuration error, never a silent skip — a hook
someone forgot to `chmod +x` would otherwise produce a worktree that looks
prepared and is not.

The executable is always read from the primary working tree. A `.worktreehook`
present only in the target branch is ignored. This prevents a newly checked-out
feature branch from introducing code that `wt` executes automatically.

The guarantee is deliberately narrow. The protocol does not sandbox or validate
hook contents, and does not protect against hostile, compromised, pulled, or
locally modified code already present in the primary working tree. The trusted
source is whatever the primary worktree currently has checked out — usually
`main`, but the protocol does not assume it.

#### Validation is point-in-time

Validation checks a pathname; execution happens later — after copying in
preparation, and after session shutdown in teardown. Anything that mutates the
primary worktree's `.worktreehook` or index in that window is validated in one
state and executed in another.

This is declared unsupported rather than defended against. Snapshotting the
validated bytes and executing the copy would change `$0` and break hooks that
resolve sibling files relative to their own path, for no gain against a threat
the trust model already admits: §5.1 does not protect against code already in the
primary working tree, and anyone able to swap the hook mid-run can equally swap it
before the run.

Two consequences are normative:

- Validation runs **immediately before each execution**, not once per command.
  The early pre-validation in `wt` (§7.1 step 3) is a usability guard that avoids
  creating a worktree for a misconfigured repository; it does not substitute for
  the check preceding the hook itself.
- Concurrent mutation of the primary worktree's hook or index during a lifecycle
  command — a `git pull` or branch switch in another terminal — is unsupported.
  The per-target lock does not cover it, because it is keyed by target slug while
  the primary worktree is shared by every target.

### 5.2 Invocation

The hook is executed as a process, never sourced, so its shebang selects the
interpreter. It receives exactly one positional argument:

```text
setup | teardown
```

The verb set is closed. Adding a third verb is a breaking protocol change
requiring every existing hook to be updated.

The hook's working directory is the target worktree. It inherits the foreground
command's stdin, stdout, and stderr. Interactive prompts are therefore legal —
a setup hook may need to drive `op` — and the protocol imposes no timeout.

The generic layer supplies:

```text
WT_MAIN       Absolute primary-worktree root
WT_WORKTREE   Absolute target-worktree root
WT_BRANCH     Exact Git branch name
WT_SLUG       Directory slug: WT_BRANCH with "/" replaced by "-"
```

The `WT_*` set is additive. Hooks must not treat it as exhaustive or reject
unknown variables, so a later addition is not a breaking change.

Setup deliberately receives no indication of whether it came from initial
creation or from recovery. The two paths must be behaviorally identical, which is
what keeps idempotency real rather than conditional on an invocation reason.

Exit status `0` means success. Any nonzero status, including the conventional
`130` after `SIGINT`, means failure. Both verbs must be recognized; either may be
an explicit successful no-op.

A minimal portable shape:

```sh
#!/usr/bin/env sh
set -eu

case "$1" in
  setup)    ;;  # Idempotently prepare this worktree.
  teardown) ;;  # Idempotently reclaim project-owned resources.
  *) echo "usage: .worktreehook setup|teardown" >&2; exit 64 ;;
esac
```

### 5.3 Project-hook obligations

**Idempotency.** Both verbs must be idempotent. Retry is the only recovery
mechanism the protocol offers.

**Deterministic identity.** Resource identity must derive from the stable `WT_*`
inputs. No identifiers pass from setup to teardown.

**Naming as a compatibility contract.** Stable inputs alone are not sufficient.
If version 1 names a database `app_$WT_SLUG` and version 2 changes the formula,
version 2's teardown derives the wrong name from the same inputs and silently
fails to reclaim anything. A naming change must retain teardown support for
resources created by older hook versions while worktrees using those names may
still exist.

**Hook removal is a breaking change.** Deleting `.worktreehook` while prepared
worktrees exist strands their resources permanently: the protocol will treat the
repository as never having opted in, and teardown becomes a no-op. A repository
retiring its hook must keep a teardown-capable hook in place until no prepared
worktrees remain.

**Git cleanliness.** Files created by either verb must be Git-ignored or written
outside the target worktree. Setup output that is not ignored immediately dirties
the checkout. Teardown output that is not ignored makes the non-forced
`git worktree remove` that follows it refuse — a failure whose symptom appears
one step away from its cause, in a state where resources are already reclaimed.

The generic layer verifies process exit status and Git state only. It cannot
verify semantic idempotency, resource identity, or successful reclamation.

## 6. Concurrency

Lifecycle commands mutate shared state: the worktree directory, the repository's
worktree registry, Zellij sessions, and project resources. Two commands running
against the same target can interleave destructively — `wt-prepare` copying into
a directory `wt-rm` is removing, or two `wt-prepare` runs invoking setup
simultaneously against hooks that assume they are alone.

Each of `wt`, `wt-prepare`, and `wt-rm` therefore holds a per-target advisory
lock across its lifecycle work: acquired before validation, released once that
work completes.

The lock covers lifecycle work, **not** the session handoff. `wt` releases before
calling `dev`, because `dev` attaches a session that outlives the command by
hours; holding across it would block every later lifecycle command on that target
for the lifetime of the session. The window this opens is the same one §8 already
declares unsupported — a concurrent `dev` racing a removal — and closing it here
would not close it there, since `dev` takes no lock of its own.

The lock is held by the **command**, not by the shared preparation routine. `wt`
acquires it once and calls the routine directly; the routine never acquires.
`wt-prepare` is the thin command wrapper that acquires the lock and then calls
the same routine. The reason this matters is process-scoped `fcntl(2)` release
semantics, described under **Mechanism** below.

- **Mechanism:** `zsystem flock` from the `zsh/system` module. Despite the name
  this is an `fcntl(2)` record lock, and its semantics differ from `flock(2)` in
  ways this design must handle explicitly.
- **Lock file:** `<git-common-dir>/wt-locks/<slug>.lock`. It is per-repository and
  never inside a worktree; a lock file inside the target would dirty it and block
  the very removal it guards. **It must be created before acquisition** —
  `zsystem flock` opens an existing path and does not create one, failing outright
  if it is missing.
- **Acquisition:** `zsystem flock -t 0 -f FD <lockfile>`, capturing the descriptor.
  `-t 0` makes a busy target refuse immediately rather than block.
- **Release:** an unconditional explicit `zsystem flock -u $FD`, in an
  always-runs block. Kernel release on process death is a backstop for shell
  death and `SIGKILL`, **not** the primary mechanism.
- **Availability:** if `zmodload zsh/system` fails, the command refuses rather
  than running unlocked.

Explicit unlock is required because these are sourced shell functions, not
scripts. Returning from a function does not close the descriptor: the fd stays
open in the interactive shell, so the lock persists for the rest of the session
and every later `wt` against that target refuses. The lock must be released on
every exit path, including failures and early returns.

`fcntl(2)` semantics also give the command/routine split described above a
stronger justification than deadlock avoidance. Locks are held per *process*, not per
descriptor, so a nested acquisition inside the same shell **succeeds** rather than
deadlocking — and closing or unlocking any one descriptor releases the process's
lock on that file entirely. A preparation routine that acquired and released its
own lock would therefore silently drop the lock its caller still believes it
holds. Silent loss is worse than a deadlock, which is why only the outermost
command locks.

The corollary is that this lock provides no intra-process exclusion. That is
acceptable: a single shell runs one lifecycle command at a time, and the case
being defended against is concurrent commands in different terminals.

A PID-file scheme was rejected: it must define missing, truncated, and malformed
ownership records, and any "check liveness, then remove and retake" sequence is
itself racy, since two processes can both conclude a lock is stale and clobber
each other. The kernel lock has no ownership record to reclaim.

## 7. Preparation lifecycle

### 7.1 Initial creation: `wt <branch> [start-point]`

Creation covers two cases — a branch that does not yet exist, and an existing
local branch that has no worktree. Both follow the same sequence:

1. Resolve the primary worktree, target path, branch, and slug.
2. Acquire the target lock.
3. Validate hook configuration **before creating anything**.
4. Create the Git worktree, and the branch if it does not already exist.
5. Invoke the preparation routine (§7.2).
6. Call `dev` only after preparation succeeds.

Pre-validation, preparation, and the failure semantics are identical for both.
Only step 4 differs:

- **New branch:** created from the **caller's** `HEAD`, matching plain
  `git worktree add -b` — branch from where you are, and work offline. An
  explicit start point overrides it. The base is reported, including
  `detached@<sha>` when the caller is not on a branch; branching from a detached
  commit is sometimes deliberate, so this is visibility, not a warning.
- **Existing local branch:** checked out into the new worktree as-is. Supplying a
  start point alongside an existing branch is contradictory and is refused.

Both paths are already implemented in `6e0213e`; what this design adds to each is
the hook pre-validation at step 3 and the routine at step 5.

Hook validation is repeated inside preparation because the hook may change
between the two calls. A validation failure before creation leaves no worktree
directory and no branch; that observable outcome, not merely the ordering, is
what the tests assert.

If preparation fails after creation, the worktree and branch remain and `dev` is
not called.

### 7.2 Explicit preparation: `wt-prepare <branch>`

`wt-prepare` is the public recovery command. It acquires the target lock, then
runs the preparation routine below — the same routine `wt` calls at §7.1 step 5,
under the lock `wt` already holds.

The routine performs:

1. Derive the canonical target from the current repository and branch.
2. Refuse an absent target path with an explicit "does not exist" error, distinct
   from the not-a-registered-worktree error.
3. Validate the registered worktree and branch through `_wt_assert_worktree`,
   which also catches slash-versus-hyphen slug collisions.
4. Validate the primary-worktree hook **before copying anything**.
5. Read the primary worktree's `.worktreeinclude`, if present.
6. Validate every manifest entry (§7.3).
7. Warn for listed entries that do not exist in the primary worktree.
8. Filter out destinations that already have a filesystem entry, including a
   symlink.
9. Run `wtcp` only when at least one destination remains missing, invoked as
   `wtcp --from "$root" -- "${missing[@]}"`. The `--` terminator is mandatory:
   manifest entries are arbitrary strings, and one named `-h` is otherwise parsed
   as an option — verified to print usage instead of copying.
10. **Re-validate the hook**, immediately before executing it.
11. Invoke `.worktreehook setup`, if the repository opted in.

Validating the hook before copying keeps failure modes uniform: a misconfigured
repository changes nothing. This mirrors the same principle applied in teardown,
where hook validation precedes session shutdown.

Filtering is required for correctness, not convenience. `wtcp` refuses existing
destinations and **returns nonzero** while still copying the missing ones, so
passing the full manifest on a retry fails every second run by construction.

An existing destination means "done". Preparation never overwrites, hashes, or
validates it. A truncated, corrupted, or stale existing file requires deliberate
manual repair, such as a reviewed `wtcp --force`. The protocol does not self-heal.

When every destination exists, `wtcp` is neither required nor invoked — so a
repository whose worktrees are already populated does not need `wtcp` installed.
Setup still runs on every explicit preparation.

`wt-prepare` does not create, stop, attach, or switch Zellij sessions. It may
therefore run while the target session and application are live. Project hooks
must tolerate that or document their own operational restriction.

### 7.3 Manifest validation

`.worktreeinclude` is tracked, so its contents are repository-supplied input to a
copy operation. Each entry must be a repository-root-relative path. An entry is a
configuration error, failing before any copying, when it:

- is absolute,
- begins with `~`, or
- contains a `..` component.

Without this, a tracked manifest could name a source outside the repository and
copy it into the worktree — the same class of boundary the hook's tracked-file
rule exists to enforce.

Lexical checks alone do not establish containment. A path with no `..` component
still escapes if any *directory* component is a symbolic link: the target
worktree's tree comes from the feature branch, so a branch that commits `config`
as a symlink to somewhere outside redirects `config/master.key` on write. The
source side is equally affected by symlinks in the primary worktree.

Every component of both the resolved source and the resolved destination path is
therefore checked, and the rule is **asymmetric**:

- **Source:** no component may be a symbolic link, *including the final one*. A
  final source symlink is not merely a reference — it is dereferenced on read, so
  a manifest entry pointing at an external directory makes `wtcp` copy that
  directory's contents into the target.
- **Destination:** no *parent* component may be a symbolic link. An existing final
  destination symlink is permitted, and only because §7.2 filters out every
  destination that already exists: it is skipped, never followed, and never
  written through.

The asymmetry is the point. Treating both sides alike would either forbid the
legitimate "destination already exists" case or admit the source escape.

Blank lines and `#` comments are ignored; entries are whitespace-trimmed.

### 7.4 Reopening: `wt <branch>`

For an existing valid worktree, `wt` calls `dev` without copying files or running
setup. Reopening is free of *preparation* side effects. It is not free of side
effects generally: `dev` may create, attach, or switch the Zellij session and run
whatever the layout starts.

## 8. Teardown lifecycle: `wt-rm <branch>`

1. Derive the canonical target; refuse an absent path explicitly.
2. Acquire the target lock.
3. Validate the registered worktree and branch.
4. Refuse when invoked from inside the target worktree — removal would pull the
   cwd out from under the shell, and the session about to be stopped is the one
   running the command.
5. **Cleanliness check 1** (§4.2), before anything is disrupted.
6. Validate hook configuration, still before anything is disrupted.
7. Stop the target Zellij session; abort if shutdown fails.
8. **Cleanliness check 2**, after shutdown and before teardown.
9. **Re-validate the hook**, immediately before executing it.
10. Invoke `.worktreehook teardown`, with the worktree and copied configuration
    still present.
11. **Cleanliness check 3**, after teardown and before removal.
12. Run `git worktree remove`, never `--force`.
13. Attempt `git branch -d`, never `-D`.
14. Warn if the target directory remains or reappears after Git reports success.

**An absent session counts as successful shutdown.** Step 7 succeeds when no
session matching the target exists — that is the normal state on a retry, and
treating it as failure would make `wt-rm` unretryable exactly when retry matters.
Only a session that exists and cannot be stopped aborts.

Stopping before removal is an invariant, not a courtesy: a live process holding
the directory open is what leaves an empty `tmp/` husk behind after removal. If
shutdown fails, continuing would remove the directory out from under a running
session, which is the outcome the ordering exists to prevent.

Three cleanliness checks are needed because the tree can become dirty between
them, from three different causes:

- Check 1 catches pre-existing uncommitted work, before the workspace is
  disrupted.
- Check 2 catches files flushed *by* session shutdown — application processes
  writing on exit are precisely how the observed Bootsnap husks arose.
- Check 3 ties non-ignored hook output to its cause, before Git's more generic
  removal refusal appears one step later.

Teardown is not invoked while the target session is running **as verified
immediately before invocation**. That is intentionally asymmetric with setup,
which may run against a live session.

The narrower wording is deliberate. `dev <target>` is a normal, frequently used
command that takes no lifecycle lock, so a `dev` run in another terminal can
recreate the session between step 7's shutdown and step 10's teardown. The
protocol does not prevent this: locking `dev` would put a lifecycle lock in the
path of ordinary everyday use, for a race that only arises from deliberately
reopening a worktree that is being removed.

Concurrent direct `dev` against a target under `wt-rm` is therefore unsupported,
and the invariant is stated as what the protocol verifies rather than as a
guarantee about the world. Step 8's cleanliness check and step 11's re-check
remain the practical defenses: a session restarted mid-removal will usually be
caught as new worktree activity, and Git's non-forced removal refuses regardless.

A teardown failure preserves the worktree with its session stopped. Retrying
`wt-rm <branch>` reruns the idempotent teardown hook.

Git remains authoritative and may still refuse removal on a later race.

## 9. Failure and recovery

### 9.1 Preparation

These fail before setup runs:

- Invalid hook configuration.
- Invalid manifest entry.
- Missing `wtcp` when at least one destination needs copying.
- Nonzero `wtcp`.

A missing manifest *source* warns and continues: `.worktreeinclude` is tracked,
so hard-failing on a stale line would block every worktree in the repository
until someone commits a fix. A nonzero setup hook fails before `dev`.

Every creation-path preparation failure preserves the worktree and prints both
recovery steps, because `wt-prepare` deliberately does not touch sessions and
therefore cannot finish the job alone:

```sh
wt-prepare <branch> && wt <branch>
```

### 9.2 Escaping in recovery messages

Any branch name interpolated into a printed command must be shell-quoted
(`${(q-)branch}` in zsh). Git rejects `;`, `$(`, backticks, spaces, and `~` in
branch names, but **accepts** `&`, `|`, and `'`. A branch named `x&y` would print
as `wt-prepare x&y`, which on paste backgrounds one command and runs another.
Quoting is a correctness requirement for any copy-pasteable output, not a
formatting preference.

### 9.3 Teardown

Before session shutdown, an invalid worktree, dirty or unreadable status, or
invalid hook fails without disrupting the workspace.

After session shutdown:

- A nonzero teardown preserves the worktree with resources in an unknown partial
  state.
- A dirty or unreadable check-3 status preserves the worktree with resources
  potentially already reclaimed.
- A later `git worktree remove` failure likewise leaves a stopped worktree whose
  resources may already be gone.

Each of these reports the exact partial state. The user may fix the obstruction
and retry `wt-rm`, or resume development instead by reconstructing resources and
reopening:

```sh
wt-prepare <branch> && wt <branch>
```

The generic layer never restarts the session automatically, because resource
state after a failed teardown is unknown and returning the user to a running
application would be the worse default.

If safe branch deletion refuses after removal, removal still succeeds and the
branch is kept, with an instruction to inspect or merge it before deleting it
explicitly. The message never offers a copy-pasteable `-D`.

### 9.4 Interruption

Hooks inherit stdin and may legitimately wait for interaction, so the protocol
sets no timeout. `Ctrl-C` is the interrupt mechanism.

When control returns to the wrapper, interruption is handled like any other
nonzero result. A real foreground `Ctrl-C` signals the whole process group and
can terminate the shell before a recovery message prints. Ordering is therefore
the safety guarantee, and it differs by entry point:

- **Setup during creation:** the worktree remains, `dev` has not run, and no
  session was created.
- **Setup during `wt-prepare`:** the worktree remains, and any pre-existing
  session is untouched and still running — `wt-prepare` never manages sessions,
  so interruption cannot leave one half-built.
- **Teardown:** the worktree remains, because removal follows the hook, and the
  session is already stopped.

The lock is released on `INT` and `TERM` so an interrupted command does not
block the retry.

## 10. Manual Git operations

The protocol orchestrates only its own commands. Worktrees created, moved, or
removed with raw Git receive no guarantees.

Two cases are worth stating because they produce confusing refusals rather than
obvious breakage:

- **`git worktree move`** desynchronizes the path from the derived slug.
  `wt-prepare` and `wt-rm` will refuse, because the derived target no longer
  matches a registered worktree.
- **`git branch -m`** desynchronizes the branch from the directory name. The
  validator will refuse on branch mismatch.

In both cases the protocol refuses rather than guessing, and reconciliation is
manual: move the directory back, or remove it with raw Git and reclaim project
resources by hand. Nothing repairs the correspondence automatically.

## 11. Testing strategy

Extend `.scripts/test-wt-functions.sh`. Continue using real Git repositories so
Git's own branch, index, cleanliness, and worktree refusals remain part of the
test. Stub Zellij, `wtcp`, and fixture hooks where deterministic invocation
logging is needed.

Two harness constraints, both learned the hard way:

- Root scratch directories at `$TMPDIR` explicitly. Bare `mktemp -d` ignores it
  on macOS in favour of the per-user Darwin temp dir, which sandboxed runners may
  refuse to write.
- Simulating an absent tool requires a stripped `PATH`, not a moved stub. `wtcp`
  is really installed on this machine, so hiding the stub silently falls through
  to the real binary and the test passes for the wrong reason.

### 11.1 Hook validation

- No hook: successful no-op.
- Stage-0 `100755` regular executable: accepted and executed.
- `100644`: rejected with the `git add --chmod=+x` remedy.
- Tracked `120000` symlink: rejected.
- Untracked executable: rejected.
- Conflicted hook with no stage-0 entry: rejected.
- Index-`100755` replaced locally by a symlink: rejected.
- Index-`100755` without its working-tree executable bit: rejected.
- Hook present only in the target branch: never executed.
- Primary-worktree hook used even when the target is another branch.
- Shebang honored; the hook is not sourced.

For pre-validation through `wt`, assert the *consequence*: no target directory
and no new branch exist. Ordering alone would still pass if creation happened and
were rolled back sloppily.

### 11.2 Interface

A fixture hook verifies the exact verb, target-worktree cwd, correct absolute
`WT_MAIN`/`WT_WORKTREE`, exact `WT_BRANCH`/`WT_SLUG`, inherited stdin, and
pass-through stdout and stderr.

### 11.3 Preparation

- Hook validation precedes copying, and runs again immediately before setup.
- Creation orders creation → filtered copy → setup → `dev`.
- Creation for an **existing local branch** pre-validates, prepares, and gates
  `dev` identically to the new-branch path.
- An existing branch supplied with a start point is refused.
- Reopening calls `dev` with no copy and no setup.
- Absent target gets the explicit "does not exist" error.
- Slug/branch collisions are refused.
- Only missing destinations reach `wtcp`.
- Existing destinations remain byte-identical.
- Nothing missing: `wtcp` neither required nor invoked.
- Missing sources warn without failing.
- Absolute, `~`-prefixed, and `..`-containing manifest entries are refused before
  any copying.
- `wtcp` failure skips setup and `dev`; setup failure skips `dev`.
- Failures preserve the worktree and print both recovery steps.
- Repeated preparation stays clean and reruns only setup.
- Preparation makes no Zellij calls, including with an active session.

### 11.4 Teardown

Keep the existing dirty, unknown-state, wrong-branch, current-worktree,
session-stop, safe-branch-deletion, and husk tests. Add:

- Hook validation precedes session shutdown.
- Session shutdown precedes teardown.
- An absent session counts as successful shutdown.
- Teardown sees the worktree and copied files still present.
- Teardown failure preserves the stopped worktree.
- Tracked or untracked teardown output triggers the check-3 refusal.
- Git-ignored teardown output allows removal.
- A teardown hook that corrupts the linked worktree's index makes check 3
  unreadable; removal fails closed.
- Successful teardown precedes removal.
- Retry reruns teardown idempotently.

The corrupt-index fixture must corrupt from *inside* teardown. That exercises the
third status call independently of the already mutation-tested preflight, and
proves the worktree survives when resources may already be reclaimed.

### 11.5 Cleanliness and concurrency

Cleanliness, at each of the three checkpoints:

- `status.showUntrackedFiles=no` does not make a dirty worktree read as clean.
- An exported `GIT_WORK_TREE` pointing at a clean decoy does not make a dirty
  target read as clean. Same for `GIT_DIR` and `GIT_INDEX_FILE`.
- `diff.ignoreSubmodules=all` does not hide a dirty submodule.
- Check 2 specifically: a stubbed session shutdown that writes a non-ignored file
  into the worktree is caught *before* teardown runs.

Routing clearance beyond `status`: with `GIT_DIR` exported to an unrelated
repository, primary-worktree resolution, hook validation, and `wt-rm` still act on
the correct repository.

Concurrency:

- A held lock makes a second lifecycle command in another process refuse
  immediately and name the busy target.
- **Persistent-shell release:** in one long-lived shell, a completed lifecycle
  command leaves no lock behind — a second run against the same target in that
  same shell succeeds. This is the regression test for the explicit-unlock rule;
  without it the descriptor stays open and every later run refuses.
- The lock is released after a *failed* command, so retry is not blocked.
- A lock held by a process killed with `SIGKILL` is acquirable by the next
  command with no manual cleanup.
- A missing lock file is created before acquisition rather than causing failure.
- A missing `zsh/system` module makes the command refuse rather than run
  unlocked.

Two cases from the PID-file design are deliberately absent: missing and malformed
lock ownership. An `fcntl(2)` lock has no ownership record to be missing or
malformed, so those tests describe a mechanism this design rejected.

Manifest containment:

- Absolute, `~`-prefixed, and `..`-containing entries are refused.
- An entry whose source or destination traverses a symlinked *parent* component
  is refused; the copy does not land outside the worktree.
- An entry whose **final source component** is a symlink to an external directory
  is refused — without this it is dereferenced on read and that directory's
  contents are copied into the target.
- An entry whose final *destination* component is an existing symlink is filtered
  as "already present", never followed and never written through.
- An entry named `-h` is copied rather than parsed as an option, proving the `--`
  terminator is present.

### 11.6 Recovery-message quoting

Branch names that Git accepts but that carry shell meaning must appear quoted in
every printed recovery command. Cover `x&y`, `x|y`, and `x'q` — all three are
valid Git branch names, and all three change the meaning of a pasted command if
emitted raw. Assert the emitted text, not merely that a message was printed.

### 11.7 Interruption is a proxy

A fixture hook exiting `130` verifies preserved state. This is explicitly a
proxy: a hook that signals only itself is indistinguishable from `exit 130` at
the caller, and simulating a real foreground `Ctrl-C` means signalling the whole
process group, which takes the test runner down with it. Real signal delivery
rests on the ordering argument in §9.4, not on a test.

### 11.8 Project-level obligations

Every adopting repository must test deterministic resource identity from `WT_*`,
setup idempotency, teardown idempotency, backward-compatible cleanup across
naming changes, absence of non-ignored worktree output, and its own
partial-failure recovery. The generic suite tests none of this.

### 11.9 Verification commands

```sh
zsh -n dot_config/zsh/functions .scripts/test-wt-functions.sh
zsh .scripts/test-wt-functions.sh
git diff --check
chezmoi apply
cmp dot_config/zsh/functions ~/.config/zsh/functions
```

## 12. Alternatives considered

These are closed decisions, recorded for the record rather than left open.

**Mise-level derivation.** Rejected as the generic protocol. Mise may be an
implementation detail inside a hook, but cannot express setup and cleanup
consistently across Rails, .NET, and Python.

**Generic runtime isolation.** Rejected. The shared layer guarantees
orchestration only; each repository decides whether it needs a concurrent full
stack, a web-only sibling, or nothing.

**Tracked hook with a per-repository allowlist.** Rejected. Hash approval in
`~/.local/state` adds prompts and state while protecting one of many ways
repository code already executes — `bin/dev`, Rakefiles, mise config — so it does
not move the real trust boundary.

**Untracked personal hook.** Rejected. Avoids cross-developer execution but
breaks fresh-clone behavior and turns repository customization into repeated
per-machine configuration.

**Target-branch hook.** Rejected. Lets an unreviewed feature branch introduce
code executed merely by creating its worktree.

**Separate setup and teardown files.** Rejected. One executable keeps shared
naming logic together and forces every opted-in project to acknowledge both
lifecycle directions, even when one is a no-op.

**Marker-based automatic retry.** Rejected. A marker creates protocol state that
can go stale and invites the generic layer to reconcile project semantics.
`wt-prepare` is explicit and stateless.

**Re-copying the full manifest, or `wtcp --force`.** Rejected. The full manifest
fails on every retry because `wtcp` refuses existing destinations; `--force`
would overwrite intentional per-worktree configuration.

**Generic rollback.** Rejected. The shared layer cannot safely reverse resources
it does not understand. Idempotency plus explicit retry is the recovery contract.

## 13. Consequences

- `wt`, `wt-prepare`, and `wt-rm` form a complete generic lifecycle.
- Repositories gain a fresh-clone-compatible customization point without leaking
  their stack into the dotfiles functions.
- Setup and teardown may leave partial project state; the worktree survives and
  retry is defined.
- Hook authors accept idempotency, naming-compatibility, hook-retirement, and
  Git-cleanliness obligations.
- Manual Git worktree operations remain possible but bypass orchestration and
  produce refusals until reconciled by hand.
- Project-specific adoption, including any Curato database and port policy, needs
  its own design record and implementation.

## 14. Open questions

None.
