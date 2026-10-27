# mise trust follows the content across a repository's checkouts

**Status:** Implemented
**Date:** 2026-10-27
**Branch:** `feat/mise-trust-worktrees` (the dotfiles have no MR; the rulings are recorded under
"Rulings and accepted residuals" at the end)

Extends [wt carries mise trust into new worktrees](2026-10-19-wt-mise-trust-design.md), which
stays `Implemented`. Its rules hold unless a section below replaces them; "old §X" names its
sections.

## Problem

Measured 2026-10-26/27, mise 2026.10.19.

- **The main checkout is the only witness.** In VM.Portal on 2026-10-26,
  `wt feature/multi-camera-alert-rules feature/design-improvements` (and a second branch)
  stopped: `Gemfile` and `mise.toml` "differ from the main checkout's". Both were
  byte-identical to the copies already trusted in the base branch's checkout,
  `VM.Portal-feature-design-improvements`; the main checkout is plain `main`.
- **`Gemfile` is a mise config only through a setting.** The global config sets
  `idiomatic_version_file_enable_tools = ["ruby"]` (there since the repository's initial
  commit), so mise reads `Gemfile` and `.ruby-version` for the Ruby version and paranoid mode
  hashes them like `mise.toml`. Every added gem untrusts that checkout, and a `git pull` on main
  untrusts main's. `idiomatic_version_file_disable_files = ["Gemfile"]` has no effect (as an
  environment variable and in a scratch global config, bare name and full path: `Gemfile` stays
  listed and still blocks `mise current ruby`). With `idiomatic_version_file_enable_tools = []`,
  `trust --show` lists neither `Gemfile` nor `.ruby-version`.
- **Ruby pins** in the main checkouts under `~/Code`: VM.Portal, curato and VM.Website in
  `mise.toml`; quadrant, budgetbeheer and springpaleis in `.tool-versions` (read natively, not
  as an idiomatic file). Only presence relies on `.ruby-version` alone (`ruby-4.0.3`).
- **Removal meets the same wall, later.** VM.Portal's `.worktreehook teardown` runs
  `mise exec … bin/rails runner` in the worktree, and `wt-rm` runs teardown at step 4, after
  closing the Herdr workspaces (step 2). A config changed since it was trusted (a rebase, a gem)
  fails teardown there; with a terminal, mise may ask to trust mid-teardown, because the hook
  inherits stdin. No logged failure was found; the mechanism is from the code.
- **A reopen only warns**, pointing at `wt-prepare`, which also re-runs the setup hook.

## Scope

Non-goals: harness worktrees' own trust (old §Non-goals; they still count as candidates);
curato's rewritten `mise.local.toml` (the old ruling stands); re-trusting a checkout's own
configs after a pull, rebase or edit (Michael's review point, paranoid mode's purpose);
presence, which moves to the global Ruby 4.0.9 (Michael): no pin is added here, and bumping its
stale `.ruby-version` is presence's own change.

Anti-goals, unchanged: `wt` never trusts content Michael has not trusted in some checkout;
never runs `mise trust` without a path or with `--all`; never changes another checkout's trust;
never reaches the setup or teardown hook while a worktree config stays untrusted.

## Design

### 1. Ruby's idiomatic version files off

`dot_config/mise/config.toml` sets `idiomatic_version_file_enable_tools = []` in `[settings]`,
explicitly, so a changed mise default cannot bring the files back. Its comment: through mise a
Gemfile only selects a Ruby version, and bundler executes the whole Gemfile on every `bin/rails`
anyway, so dropping it from mise's trust costs nothing paranoid mode protects; pin Ruby in
`mise.toml` or `.tool-versions`. Nothing needs re-trusting after `chezmoi apply`, and a worktree
blocked only by its `Gemfile` is unblocked by the apply alone.

### 2. Candidates

`_wt_mise_trust <main> <dest> [<base>]` keeps its place and old §Which files, with "the main
checkout" replaced by candidates: the checkouts in `git -C <main> worktree list --porcelain -z`,
read once per run, minus `<dest>` (compared resolved) and any whose directory is missing. Each
is tried once, in this order: `<main>`; the base branch's checkout when `wt` knows the base; the
rest in Git's order. A candidate other than `<main>` counts only if
`git -C <c> rev-parse --path-format=absolute --git-common-dir` names `<main>`'s common
directory, so a registered path swapped for a link into another repository cannot vouch. If the
list cannot be read, the step trusts nothing and returns 1, as for a failed read of `<dest>`.

`wt` knows the base only when it creates a branch: the start point, or the caller's branch when
none is given. The base checkout is the worktree whose record reads `branch refs/heads/<base>`.
A start point that is no local branch (`origin/main`, a tag, a commit), an existing branch, a
reopen, `wt-prepare` and `wt-rm` have no base.

### 3. Carrying one file

`<dest>` itself must not be a symlink: one that points at another checkout would make
`mise trust <dest>/<rel>` land on that checkout's file, so the step prints `wt: <dest> is a
symlink — trusting nothing.` and returns 1 (a ruling during execution, see the end).

An `untrusted` entry `<dest>/<rel>` is checked on its own side first: no component below
`<dest>` a symlink, and a regular file. Then candidate `<c>` vouches when:

1. no component of `<c>/<rel>` below `<c>` is a symlink, and it is a regular file;
2. `command mise -C <c> trust --show` lists `<c>/<rel>` as `trusted`;
3. `cmp -s <c>/<rel> <dest>/<rel>` reports them identical.

The first candidate that vouches ends the search; `command mise trust <dest>/<rel>` follows. The
re-check of old §Closing the check-then-trust window is bound to that candidate: `<c>/<rel>`
still identical, `<dest>/<rel>` listed `trusted`, `<c>/<rel>` still listed `trusted`. Otherwise
`--untrust` and refuse, as now; no other candidate is tried for that file.

Those re-reads alone do not close the window: a writer that controls `<dest>/<rel>` can show
good bytes to the search `cmp`, its own bytes while `mise trust` hashes the file and the
`-C <dest>` read runs, and good bytes again to the final `cmp`, leaving its own bytes trusted.
So the step also pins the identity of both files of the pair with
`/usr/bin/stat -f '%i %Fc'`: the inode and the change time in nanoseconds, without following
a symlink. The pins are taken:
- for `<dest>/<rel>`, before its plainness check and candidate search;
- for `<c>/<rel>`, before its plainness check and search `cmp`;
- for both files again, after the final `cmp`.

Any difference, or a failed `stat`, means `--untrust` and refuse with the changed reason (§4).
Before any trust, a failed first `stat` of the destination refuses the file with nothing to
withdraw, and a failed first `stat` of a candidate only means `<c>` cannot vouch.

**What is detected:** a change that moves the inode or the change time of `<dest>/<rel>` or of
the vouching copy between the first pin and the final check.
- These move one of them: a `write()` or truncation, a rename or replacement of the file, and a
  symlink put in its place.
- Nothing sets the change time back: `touch` and `utimes` set only the access and modification
  times.

This closes the cheap content flip, the one a writer gets with no special tooling.

**Threat model** (controller's ruling, 2026-10-27): parity with Michael's own `mise trust`.
When he reviews a file and then runs `mise trust` by hand, a process racing that file has the
same window. The carry is held to that bar, not above it. "Rulings and accepted residuals"
records what this leaves:
- writes that do not move the change time;
- path swaps above the file, or of a symlink's target;
- a mount-over;
- changes inside the clock's resolution.

A later finding that is a race achievable by hand against a manual `mise trust` is recorded
there as a residual and opens no fix round.

Measured on macOS:
- `%Fc` has nanosecond resolution;
- a `write()` moves it, and `touch -m` cannot move it back;
- a write through a held shared mapping does not move it until the mapping is released.

A candidate's `trust --show` is read lazily, when a file first needs it, and at most once per
run for the search; the re-check always reads afresh. Old §Failing closed still holds for the
read of `<dest>`, `mise trust`, `--untrust` and the re-check's reads.

**A failed read of a candidate skips it; it does not stop the step.** It prints
`wt: cannot read mise's trust status for <c> — it cannot vouch.`, and `<c>` is out for the run.
The old spec stopped on a failed read of the main checkout because, with one witness, nothing
could be carried afterwards and a stop was the clearest report. With several, a failed read
removes one witness and nothing more: trust still needs a successful read of the vouching
candidate and the re-check, so a skip can only carry fewer files, never one nobody trusted.
Stopping would let one broken checkout block every `wt` in the repository.

### 4. Report

A carried file's line names its witness: `wt: mise trust carried to <dest>/<rel> (trusted in
<c>)`. A refused file has one of three reasons: `it is a symlink or not a regular file` (the
worktree's own side), `it matches no trusted copy in this repository's checkouts` (every other
refusal before `mise trust`, replacing the main-checkout reasons), and the changed reason.

The changed reason is the old spec's `it changed while wt was trusting it`. It is followed by
`    nothing was trusted; if nothing else is writing there, run the command again.`, because
the change can be harmless, such as an editor saving the file during the window. The hint is
the controller's ruling during execution.

The `review` line is a `diff` against the base checkout's copy when `wt` knows the base and that
copy meets rules 1 and 2 and differs; otherwise against the main checkout's copy on the same
terms, as today; otherwise `cat` of the worktree file. Quoting and `then: mise trust` are
unchanged.

### 5. `wt-rm` checks trust before it disrupts anything

Step 1 ends with the carry, after the lock classification (the checks that write nothing go
first) and before step 2, unless `_wt_hook_check` reports no hook (2); an invalid hook (1)
already refused earlier. The gate is "not 2" rather than "is 0" so that it matches
`_wt_hook_run`, which runs the hook for any status but 1 and 2 (a ruling during execution; equal
for every status `_wt_hook_check` returns today). If the carry returns 1, the
report lines stand, then `wt-rm: nothing was closed or removed — review the mise config above,
then: wt-rm <branch>`, and `wt-rm` returns 1 before any Herdr call. The carry refuses when the
read of `<dest>` or of the worktree list fails, or a config stays untrusted; a failed candidate
read only removes that witness, with its "cannot vouch" line, as in §3. With no hook (2) there
is no check.

Right before `_wt_hook_run … teardown`, under the same gate, a read-only `_wt_mise_show <dest>`
must succeed and list no `untrusted` entry, or `wt-rm` refuses with "teardown not run, Herdr
workspaces closed" and
the retry line. Closing the workspaces can rewrite a git-ignored `mise.local.toml` that check 2
does not see, and the anti-goal binds at the hook, not at step 1.

- **Double-force removal** (a Herdr-owned checkout) changes only the final
  `git worktree remove`; teardown runs, so both checks run as for any removal.
- **The checkout is already gone** (`_wt_rm_registration`): no teardown and no config, so
  neither check runs and `mise` is never called.
- **A retry** after a failed teardown or removal runs step 1 again; trusted files need nothing.

The step list above `wt-rm` gains both checks.

### 6. A reopen carries

`wt <branch>` on an existing worktree runs the carry (no base, no setup hook) in place of the
read-only check, and never stops the reopen. When the carry returns 1, its report lines stand,
then `wt: opening <dest> anyway — its shells load no project mise config until the files above
are trusted.`, and `_WT_NOTICE` is set so the popup waits. The refusal lines do not point at
`wt-prepare`: the report's `review` and `then: mise trust` lines are the direct route, and
`wt-prepare` would also re-run the setup hook. A failed withdraw prints its line; the reopen goes
on. When the carry trusted at least one file, the reopen adds `wt: if this worktree was never
prepared, run: wt-prepare <branch>` (quoted like the other recovery lines) and sets
`_WT_NOTICE`, because a creation stopped at this step never ran its setup hook.

## Testing

`tests/wt-functions.test.sh`, mise stubbed as now, siblings made with `git worktree add`. The
stub gains a `trust --show` that fails for one `-C` directory from the start
(`SHOW_FAIL_DIR_AFTER_TRUST` fails only after a trust). New cases:

- Carried from a sibling when main's copy differs; the line names the sibling.
- Carried when main's copy is untrusted and a sibling's identical copy is trusted.
- Refused when only untrusted or differing copies exist: no `mise trust`, the new reason.
- Re-check bound to the vouching candidate: the sibling loses trust during `mise trust`
  (`MAIN_FLIP` on its path), so `--untrust` follows and no other candidate is tried.
- A missing or unreadable candidate is skipped and a later one vouches; the failed read says so.
- A registered worktree replaced by a symlink to another repository's checkout never vouches.
- With a base, its checkout is read before the other siblings (call log).
- `review` diffs against the base checkout's copy when trusted and different, against main's
  without a base, and is `cat` when neither qualifies.
- `wt-rm` with a hook and an untrusted config refuses with no Herdr call and no hook run; once
  the config is carried, it proceeds through teardown.
- `wt-rm` whose first candidate's (main's) `trust --show` fails while a later sibling vouches
  prints the cannot-vouch line, carries the file and proceeds through teardown.
- `wt-rm` whose read of `<dest>` fails refuses with no Herdr call.
- `wt-rm` with no hook, and the already-gone path, make no `mise` call.
- `wt-rm`: a config untrusted after step 1 (the Herdr stub's close rewrites it) stops before
  the hook.
- Reopen carries, warns only for the rest, opens, popup waits; a reopen that carried a file
  prints the never-prepared line, and one that carried nothing does not.
- `mise trust` never runs without a path or with `--all` (X13, over the new calls too).

Added during execution:
- the flip-around-the-calls race, driven by the stub, is refused and untrusted, whether it
  flips `<dest>/<rel>` or the vouching copy;
- `_wt_mise_ident` reads the same twice for an untouched file. It differs after a same-size
  rewrite, or after the file is replaced by a symlink;
- a `<dest>` that is itself a symlink is refused;
- `wt-rm` with a hook and no mise makes no `mise` call, and one with an invalid hook makes none
  either;
- the worktree list is read once per run;
- `_WT_MISE_CARRIED` is reset per run;
- the teardown re-check is read-only: with an empty trusted witness, a carrying re-check would
  trust;
- the X13 and Y18 sweeps are allowlists: every `trust` path is under a destination checkout.

Existing cases keep their scenarios; X2 to X5 expect the new reasons and `review` lines.

No suite owns `dot_config/mise/config.toml`. Its pin goes in this suite's mise section, since
the carry's file set rests on it: `[settings]` holds `idiomatic_version_file_enable_tools = []`,
and a missing file exits 2.

Live check after `chezmoi apply`: in VM.Portal, `wt <new-branch> feature/design-improvements`
carries `mise.toml` from that branch's checkout, and `trust --show` there lists no `Gemfile`.

## Calls made in writing this spec

Settled by Claude, not by Michael; each can be overruled at sign-off: a failed candidate read
skips that candidate, and a failed read of the worktree list stops (§2, §3); a candidate other
than main must share main's Git common directory; three refusal reasons, and the success line
names the vouching checkout; the `wt-rm` carry runs after the lock classification, and teardown
gets a read-only re-check; in `wt-rm` too a failed candidate read only skips that candidate,
and of the search reads only a failed one of `<dest>` or of the worktree list refuses (a failed
re-check read refuses as in §3); the reopen's
refusal lines point at the report lines, not `wt-prepare`; the config pin lives in
`tests/wt-functions.test.sh`. Ruled by the controller during execution (2026-10-27): a reopen
that carried a file adds the never-prepared `wt-prepare` line (§6), and it holds the popup.

Left to the builder: how the base reaches `_wt_mise_trust` (an argument through
`_wt_do_prepare` is enough), the candidate cache's structure, and message wording within the
shapes above.

## Rulings and accepted residuals

Rulings made during execution, by the controller unless marked:

- **§6, the never-prepared line and its popup hold.** Controller's ruling; Michael to confirm.
- **§3, the file-pair identity pin.** It answers a race the final review verified: the content
  flip around `mise trust`. Its first pin is taken before the plainness check.
- **§3, the directory-chain pinning was built and then reversed.**
  - Two re-reviews had extended the pin to each file's lexical and canonical directory chains:
    first after a directory swapped around the trust passed the file pin, then after a symlink
    swapped in before the pin passed the lexical chain.
  - The controller reversed it on two observations.
  - Real runs: in one read-only sample, `$HOME`'s change time moved once in 80 quarter-second
    reads, about every 20 s. By estimate, a pinned chain would refuse spuriously in a few
    percent of real runs.
  - The suite: every fixture sits below `/private/tmp/claude-501`, a directory that every
    sandboxed command in every session writes to.
    - Four unmutated runs failed 38, 16, 5 and 0 carry-success cases.
    - The first run overlapped another full suite. The other three used a private `TMPDIR`
      that was still below that directory.
    - In one noisy run, the noise also hid a deleted re-check condition.
  - What the chains caught is now accepted under the threat model below.
- **§4, the changed reason** returns to the old spec's copy, because directories are no longer
  pinned. The rerun hint stays.
- **§3, `<dest>` itself must not be a symlink.**
- **§5, the mise gates use "not 2".**
- **The reopen helper** became `_wt_mise_reopen_carry <main> <dest> <branch>` (it trusts files,
  and needs the branch for the never-prepared line).
- **The candidate list returns 1** when the porcelain holds no `worktree ` record, as well as on
  a failed read.
- **The suite pins its FUNCS target to exit 2.**
- **A suite-local `jq` stub.** It skips a `jq` that is a mise shim (a stale
  `~/.local/share/mise/shims/jq` on Michael's machine). Without it, a fixture repository holding
  a `mise.toml` would run the real mise through the shim and fail.

Accepted residuals:

- **The threat model of §3: parity with a manual `mise trust`** (controller's ruling). Each
  race below is open to a process that races Michael when he reviews a file and trusts it by
  hand, so the carry is no weaker than that.
  - **Writes that do not move the change time.** Example: a write through a held shared
    mapping. A writer maps the file, writes its own bytes while `mise trust` hashes, writes the
    good bytes back before the final `cmp`, and holds the mapping past the final pin. Measured:
    the identity stays unchanged while the dirty mapping is held.
  - **Path swaps of any directory above the file, or of a symlink's target.** Renaming one
    aside, putting one with the writer's bytes in its place, and restoring it leaves the file's
    own identity unchanged. A variant, recorded at the round 4 re-review:
    1. before the first pin, the writer hard-links `<dest>/.config/mise.toml` into a
       directory it controls;
    2. after the plainness check, it swaps `<dest>/.config` for a symlink to that directory, so
       the pinned file is the same inode;
    3. it then swaps the target directory around `mise trust`.

    The pin sees nothing, and the worktree keeps a symlinked `.config`.
  - **A filesystem mounted over a directory on the path** during the window and unmounted
    before the final pin. Mounting needs DiskArbitration or `hdiutil`. Whether the agent
    sandbox can reach them is unverified.
  - **Changes inside the change-time clock's resolution**, which is nanosecond-grained on APFS.
- **Stopping rule** (controller's ruling). A finding that is a race achievable by hand against a
  manual `mise trust` is recorded here as a residual, and opens no fix round. Any other finding
  is fixed as usual.
- **A candidate's common directory** is checked once, when the list is read. A `.git` file
  planted in a sandbox-writable directory can forge it, so it is defence in depth. The boundary
  is mise's store, which the sandbox cannot write: a candidate vouches only for bytes mise
  already trusts at its path.
- **The re-check does not re-run the plainness check.** A file replaced by a symlink after the
  first pin is a new inode at its path. A directory on the path swapped for a symlink is the
  path-swap residual above.
- **A hook that becomes valid in the main checkout between step 1 and teardown** skips both
  `wt-rm` checks. Whoever can commit a hook already runs code through it.
- **Configs that `mise -C <dest> trust --show` does not list** are invisible to every check: a
  `mise.toml` in a subdirectory the hook enters, or a `MISE_ENV` the hook sets. So are
  parent-directory configs (old spec's scope).

Live check, pending after `chezmoi apply`: the VM.Portal check under Testing.
