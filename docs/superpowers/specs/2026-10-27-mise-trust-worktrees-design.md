# mise trust follows the content across a repository's checkouts

**Status:** In progress
**Date:** 2026-10-27
**Branch:** `feat/mise-trust-worktrees`

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

An `untrusted` entry `<dest>/<rel>` is checked on its own side first: no component below
`<dest>` a symlink, and a regular file. Then candidate `<c>` vouches when:

1. no component of `<c>/<rel>` below `<c>` is a symlink, and it is a regular file;
2. `command mise -C <c> trust --show` lists `<c>/<rel>` as `trusted`;
3. `cmp -s <c>/<rel> <dest>/<rel>` reports them identical.

The first candidate that vouches ends the search; `command mise trust <dest>/<rel>` follows. The
re-check of old §Closing the check-then-trust window is bound to that candidate: `<c>/<rel>`
still identical, `<dest>/<rel>` listed `trusted`, `<c>/<rel>` still listed `trusted`. Otherwise
`--untrust` and refuse, as now; no other candidate is tried for that file.

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
refusal before `mise trust`, replacing the main-checkout reasons), and `it changed while wt was
trusting it` (unchanged).

The `review` line is a `diff` against the base checkout's copy when `wt` knows the base and that
copy meets rules 1 and 2 and differs; otherwise against the main checkout's copy on the same
terms, as today; otherwise `cat` of the worktree file. Quoting and `then: mise trust` are
unchanged.

### 5. `wt-rm` checks trust before it disrupts anything

Step 1 ends with the carry, after the lock classification (the checks that write nothing go
first) and before step 2, when `_wt_hook_check` reports a valid hook (0). If it returns 1, the
report lines stand, then `wt-rm: nothing was closed or removed — review the mise config above,
then: wt-rm <branch>`, and `wt-rm` returns 1 before any Herdr call. The carry refuses when the
read of `<dest>` or of the worktree list fails, or a config stays untrusted; a failed candidate
read only removes that witness, with its "cannot vouch" line, as in §3. With no hook (2) there
is no check.

Right before `_wt_hook_run … teardown`, a read-only `_wt_mise_show <dest>` must succeed and list
no `untrusted` entry, or `wt-rm` refuses with "teardown not run, Herdr workspaces closed" and
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
and of the reads only a failed one of `<dest>` or of the worktree list refuses; the reopen
points at the report lines, not `wt-prepare`; the config pin lives in
`tests/wt-functions.test.sh`. Ruled by the controller during execution (2026-10-27): a reopen
that carried a file adds the never-prepared `wt-prepare` line (§6), and it holds the popup.

Left to the builder: how the base reaches `_wt_mise_trust` (an argument through
`_wt_do_prepare` is enough), the candidate cache's structure, and message wording within the
shapes above.
