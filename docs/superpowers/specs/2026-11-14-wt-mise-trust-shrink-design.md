# Shrink wt's mise-trust carry

**Status:** Approved
**Date:** 2026-11-14
**Branch:** `refactor/wt-mise-trust`
**Sign-off:** the driver session (chezmoi-c1), on Michael's delegation, 2026-11-14; Codex spec
review approved (rounds 1–2, on the approach 1 draft; the rulings below changed the design).

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
`mise trust <path>`.

## Approaches

1. **Check mise's own record.** `mise trust <file>` (mise 2026.11.8, paranoid mode) writes
   `<state>/trusted-configs/<name>`, a symlink to the file's canonical path, and `<name>.hash`,
   the sha256 of the bytes it read; mise loads a file only when its bytes hash to that value,
   and the sandbox cannot write the store. Hash the worktree file; a candidate vouches when its
   stored hash equals that hash and `trust --show` lists it `trusted`; after `mise trust`, the
   worktree file's stored hash and a fresh hash must both equal it. About 333 → 200 lines, and
   it closes two 10-27 residuals. **Not taken** (driver's ruling on Michael's delegation,
   2026-11-14): every carry would depend on mise's undocumented store layout, so a mise upgrade
   that changes it would make every carry refuse until someone notices, and Michael does not
   want later surprises from building on mise internals. The residuals it closes are ones he
   accepted on 10-27, and the race paths never fired.
2. **Trim only (taken).** Keep the algorithm and every check, drop the base branch, fold the
   withdraw helper into the carry, cut comments that retell the spec. About 333 → 245 lines.
3. **Drop the race handling** on 10-27's own threat model. About 333 → 120 lines, but a config
   could then be trusted through a race the current code catches: it weakens a check.

Writing mise's store directly was rejected without a sketch.

## Design

**Unchanged** from 10-19 and 10-27: which files are carried and when, `_wt_mise_show` and how
every read fails closed, the vouching rules (plain on both sides, the candidate's copy listed
`trusted`, `cmp` identical), the candidate set (registered checkouts sharing `<main>`'s Git
common directory, minus `<dest>` and missing directories), the identity pins and the post-trust
re-check bound to the voucher (10-27 §3), the three refusal reasons and the rerun hint, every
stop and withdraw message, the `wt-rm` checks (§5), the reopen carry and its lines (§6),
`_WT_MISE_CARRIED`, the anti-goals, and the accepted residuals with their threat model.

**The base branch goes** (10-27 §2's base checkout and §4's base baseline). `wt` no longer
computes it and `_wt_do_prepare`, `_wt_mise_trust` and `_wt_mise_candidates` lose the argument;
`_WT_MISE_BASEDIR` goes. `wt`'s `branching <branch> from <from>` line is unchanged.

- **Candidate order:** `<main>`, then the others in Git's order.
- **Success line:** still `wt: mise trust carried to <dest>/<rel> (trusted in <c>)`, but `<c>` is
  the first that vouches in the new order. When main does not vouch and both the base checkout
  and an earlier sibling do, it now names the earlier sibling (10-27 named the base).
- **Refusal `review` line:** a `diff` against `<main>/<rel>` when that copy is plain, listed
  `trusted` and differs; otherwise `cat` of the worktree file. 10-27 tried the base checkout's
  copy first.

**`_wt_mise_withdraw` folds into `_wt_mise_trust`.** Its three uses (a failed post-trust read of
`<dest>`, of the voucher, and a re-check that fails) become one untrust path with the same
outcomes and lines: untrust; if that fails, the collected refusals, the "may still be trusted"
line, then the stop line; if a read failed, the refusals and the read's stop line; otherwise the
file joins the refusals with the changed reason.

**Comments** keep the non-obvious why of each rule (why a check exists, what it cannot see) and
point at the specs instead of retelling them; no comment cites a review round or a case ID.

**Target:** the remaining seven functions at about 245 lines or fewer, counted the same way
(from each function's leading comment to its closing brace).

## Testing

`tests/wt-functions.test.sh` (heavy). The refactor's proof is that every mise case not about the
base branch passes unchanged. The base cases go or lose the base:

- XC1, XC5, XC6 (candidate order and `_WT_MISE_BASEDIR`): rewritten to the new order with no
  base; the "main is not listed twice" and "gone checkout is absent" assertions stay.
- X29 (the base vouches ahead of an earlier sibling): now expects the earlier sibling's name.
- X30 (diff against the base's copy): now expects the diff against main's trusted copy.
- X25b, X35, X36: keep their scenarios, expectations follow the two rules above.

Live check after `chezmoi apply`: one `wt <branch>` in a `~/Code` repository with a trusted
`mise.toml` carries it and opens.

## Rulings

- Approach 2 over approach 1 (driver, on Michael's delegation, 2026-11-14; reason above).
- The base branch goes, with the changed success and refusal lines above (driver, 2026-11-14,
  on Claude's recommendation: never exercised for real).
