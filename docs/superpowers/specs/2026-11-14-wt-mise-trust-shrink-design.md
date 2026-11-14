# wt checks a carried trust against mise's own record

**Status:** In progress
**Date:** 2026-11-14
**Branch:** `refactor/wt-mise-trust`

Item 38 of the 2026-11-11 setup review: "`wt`: shrink the mise-trust carry (330 lines); keep the
worktree guard." Changes [mise trust follows the content across a repository's
checkouts](2026-10-27-mise-trust-worktrees-design.md) (stays `Implemented`); "10-27 §X" names its
sections. The worktree guard (`dot_claude/executable_worktree-guard.sh`) is not touched.

## What the 333 lines do, and what happened for real

Eight functions in `dot_config/zsh/functions` (539–884, 934–954), measured 2026-11-14:
`_wt_mise_trust` 138, `_wt_mise_candidates` 59, `_wt_mise_trust_report` 38, `_wt_mise_show`
37, `_wt_mise_reopen_carry` 21, `_wt_mise_withdraw` 18, `_wt_mise_plain` 11, `_wt_mise_ident`
11; 95 of them are comment lines. Roughly half guard one race: a writer that flips
`<dest>/<rel>` between the `cmp` and `mise trust` (identity pins, two post-trust `trust --show`
reads, a second `cmp`, the withdraw helper and its stop paths). Another ~40 lines carry the
base branch, used only to order candidates and to pick the `review` diff's baseline.

Real runs, from every Claude Code transcript (fixture paths excluded; Michael's own popup runs
leave no record):

- 39 carries into about 25 real worktrees (tagteam, curato, muninn, tafl, skald, VM.Portal,
  hulder, linger). 5 were vouched by a sibling, not main (`curato-fable-review` ×3,
  `VM.Portal-feature-design-improvements` ×2): the multi-checkout search is used.
- One refusal since 10-27 (`curato-snapshot-by-value/mise.local.toml`, "matches no trusted
  copy"); the rest are the pre-10-27 VM.Portal `Gemfile`/`mise.toml` refusals 10-27 fixed.
- Never seen: "changed while wt was trusting it", "cannot vouch", a failed read of a worktree,
  of the worktree list or of mise, a failed withdraw, a symlink refusal.

The brief's premise that `wt` copies mise's state does not hold: it already trusts only through
`mise trust <path>`. What can shrink is the race handling and the base branch.

## mise facts this rests on

Measured with mise 2026.11.8, paranoid mode, a scratch `MISE_STATE_DIR`:

- `mise trust <file>` writes `<state>/trusted-configs/<name>`, a symlink to the file's
  **canonical** path (a symlinked directory or file is resolved), and `<name>.hash`, the
  sha256 of the bytes it read (64 hex digits, no newline). `--untrust` removes both.
- A file is trusted, by `trust --show` and when mise loads it, exactly when its current bytes
  hash to the stored value; bytes changed back to the stored ones are trusted again.
- `--ignore` keeps both store files and adds `<state>/ignored-configs/<name>`; `trust --show`
  then lists the file `untrusted`. So a stored hash alone does not mean "trusted".
- The sandbox cannot write `~/.local/state`, so the store is a record no agent can forge.
  `<state>` is `$MISE_STATE_DIR`, else `$XDG_STATE_HOME/mise`, else `~/.local/state/mise`.
- Michael's store holds 135 hash records, no path twice; reading them all with zsh's `zstat`
  takes under a millisecond.

## Approaches

1. **Check mise's own record (recommended).** Hash `<dest>/<rel>` once; a candidate vouches when
   mise's stored hash for its copy equals that hash and `trust --show` lists the copy
   `trusted`; after `mise trust <dest>/<rel>`, mise's stored hash for it must equal the same
   value, else `--untrust` and refuse. Whatever bytes sit in `<dest>/<rel>` later, mise loads
   only bytes with that hash, so the race is decided by mise's record, not by re-reading a
   file a writer controls. About 333 → 200 lines; closes the 10-27 residuals that are writes
   or swaps of the worktree file's bytes. Cost: it reads an undocumented store layout; a
   change fails closed (nothing vouches) and a contract case against the real mise pins it.
2. **Trim only.** Keep the algorithm, drop the base branch, fold the withdraw helper into the
   carry, cut the comments. About 333 → 245 lines; no new dependency; the residuals stay.
3. **Drop the race handling** on 10-27's own threat model (a hand-typed `mise trust` after a
   review has a longer window). About 333 → 120 lines, but an untrusted config could then be
   trusted through a race the current code catches: it weakens a check, which the brief rules
   out.

Rejected without a sketch: writing mise's store directly (copying the voucher's record), which
bypasses mise and is what the brief warns against.

## Design (approach 1)

Unchanged: where the carry runs and when it stops (10-19 spec, 10-27 §5 and §6), what
`_wt_mise_show` reads and how it fails closed, the candidate set (every registered checkout
sharing `<main>`'s Git common directory, minus `<dest>`, `<main>` first, then Git's order), the
plainness rule for both copies, the refusal reasons and lines, the `wt-rm` checks, the reopen
carry and its lines, `_WT_MISE_CARRIED`, and the anti-goals (never trust content Michael has not
trusted in some checkout; `mise trust` only with a path, never `--all`; never another checkout's
trust; never the setup or teardown hook while a worktree config stays untrusted).

**The record.** `_wt_mise_hashes` reads every `<name>.hash` whose `<name>` is a symlink and maps
the link's target to the hash. A target with two different records maps to a value that matches
nothing. A failed read of the store (no `zsh/stat`) stops the carry like a failed `trust
--show`. An absent store is an empty record.

**Carrying one untrusted `<dest>/<rel>`:**

1. `<dest>/<rel>` is plain, as now, or it is refused (symlink reason).
2. `h` = sha256 of `<dest>/<rel>`; a failed read refuses it with the changed reason.
3. A candidate `<c>` vouches when `<c>/<rel>` is plain, the record for `${c:A}/<rel>` equals `h`,
   and `mise -C <c> trust --show` lists `<rel>` `trusted` (read only for a candidate whose
   record matched, at most once per run; a failed read prints the existing "cannot vouch" line).
   The first that vouches ends the search; none refuses it with the "matches no trusted copy"
   reason.
4. `command mise trust <dest>/<rel>`; a failure stops the carry, as now.
5. Re-read the record. The one for `${dest:A}/<rel>` equals `h`: carried, with the existing line
   naming `<c>`. Otherwise `command mise trust --untrust <dest>/<rel>` and refuse with the
   changed reason and its rerun hint; a failed untrust stops with the existing "may still be
   trusted" line.

`${dest:A}` and `${c:A}` give the canonical key because no component below them is a symlink
(step 1, step 3); a `<dest>` that is itself a symlink is refused before any of this, as now.

**Report.** The `review` line diffs against `<main>/<rel>` when that copy is plain, listed
`trusted` and different; otherwise it is `cat` of the worktree file. The base checkout's
baseline goes.

**Removed:** the base branch (`wt` passes none; `_wt_do_prepare` and `_wt_mise_trust` lose the
argument, `_WT_MISE_BASEDIR` goes), `_wt_mise_ident` and every pin, the two post-trust
`trust --show` reads and the second `cmp`, `_wt_mise_withdraw` (its one remaining use is
inlined), and comments that retell the spec.

**What changes for Michael.** Carries and refusals in his repositories are the same, with two
visible differences: the success line may name a different voucher when several qualify
(`<main>` first, then Git's order, no base preference), and a refusal's `review` diff is
against main's trusted copy or the file itself, never the base checkout's.

**One case now carries that used to refuse:** the vouching copy is rewritten while `wt` trusts
the worktree's file. Before, the re-check refused; now the worktree file is trusted with the
hash mise stored for the voucher, which is content Michael trusted there, so the anti-goal
holds.

**Residuals.** 10-27's writes that do not move the change time, and swaps of the file itself,
are now closed: mise's record decides. Still open, as before (10-19 "misdirected rollback"): a
directory or the file swapped for a symlink between step 1 and `mise trust` makes mise trust
the link's canonical target; step 5 then untrusts `<dest>/<rel>`, which reaches that target only
while the link is still in place. Parent-directory configs and configs `trust --show` does not
list stay out of scope (10-27).

## Testing

`tests/wt-functions.test.sh` (heavy). The mise stub keeps mise's real store layout under a
fixture `MISE_STATE_DIR` (symlink to the canonical path plus `<name>.hash`) instead of its text
store; `mise_seed` and `mise_unseed` write and remove that layout. The flip hooks stay.

- **Contract with the real mise:** in a scratch `MISE_STATE_DIR` with paranoid mode, the real
  binary's `trust` of a file, and of the same file through a symlinked directory, reads back
  through `_wt_mise_hashes` as its canonical path mapped to its sha256; `--untrust` removes it.
  No real mise outside the stub directory: `INCONCLUSIVE:` and exit 2.
- Kept with their expectations: carried from main and from a sibling; refused when no copy
  vouches, for a symlink, for a symlinked `<dest>`; the show parser cases; no `mise`; trust and
  untrust failures; the `wt-rm` and reopen cases; the X13/Y18 sweeps (never `--all`, never
  without a path, always under a destination).
- The flip of `<dest>/<rel>` during `mise trust`, flipped back before step 5: refused and
  untrusted (stored hash is the flipped bytes').
- New: a candidate whose record matches but which `trust --show` lists `untrusted` (ignored)
  never vouches; a path with two different records never vouches and is never carried.
- Changed: the voucher flipped during `mise trust` now carries (above).
- Deleted with their code: the identity-pin cases, the base-order and base-diff cases, and the
  post-trust re-read failures.

Live check after `chezmoi apply`: one `wt <branch>` in a `~/Code` repository with a trusted
`mise.toml` carries it and opens.

## Calls made in writing this spec

Settled by Claude for the driver's ruling: approach 1; the base branch goes; a candidate's
`trust --show` is read only after its record matched; a duplicate record matches nothing; the
real-mise contract case lives in `wt-functions` and exits 2 without a real mise.
