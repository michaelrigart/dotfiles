# Test audit: fewer, stronger tests

**Status:** In progress (branch `chore/test-audit`; the dotfiles have no MR)
**Date:** 2026-11-11
**Sign-off:** Michael, 2026-11-11 (Codex spec review approved in round 3, `xr-1794362121-2ad56b13`)
**Branch:** `chore/test-audit`, in the `wt` checkout `~/.local/share/chezmoi-chore-test-audit` (a
dotfiles `wt` line run before the rules that allow it are merged; Michael accepted the sandbox gap
for this line as for the others, see `docs/superpowers/specs/2026-11-11-wt-dotfiles-design.md` §5 on
`feat/wt-dotfiles`)
**Design approved:** Michael, 2026-11-11, in conversation

## Why

Michael's impression is that agents write too many tests, so suites grow and every full run takes
longer, while some tests do not hold the essence of what they protect.

The dotfiles bear it out (byte sizes from the git tree, a rough guide):

| Date | `tests/` | Code | Suites |
|---|---|---|---|
| 2026-10-01 | 724 KB | 440 KB | 36 |
| 2026-11-01 | 1,930 KB | 993 KB | 61 |
| 2026-11-11 | 3,024 KB | 1,555 KB | 67 |

- `tests/` holds about 36,000 lines of shell, about twice the size of the code it tests.
- The three heavy suites alone take about 11 minutes.

Three sources of surplus are visible:
- **Wording pins.** `tests/agent-instructions.test.sh` has 55 `need_flat` checks that require
  exact sentences in the instruction fragments. They break on every rewording, and they catch
  little beyond a dropped rule, which happened once.
- **One test per review finding.** Every finding of every review round becomes a pinned case, and
  so does every fix, because "a fix ships with a test that fails without it". Suites grow each
  round and never shrink.
- **Duplication across layers.** One behaviour is often covered by a unit suite, a replay suite
  and a live suite.

The largest suites guard safety boundaries (`wt-functions`, `git-forge-guard`, `xreview`), where
depth is warranted. The audit needs evidence per test, not a blanket cut.

## Goals

- Smaller and faster suites with no loss of regression-catching power, measured by mutation.
- A tighter testing rule, so that surplus tests stop accumulating.
- A method that the next audit (a `~/Code` project) can reuse. The method is this spec plus the
  findings document. The harness stays specific to this repository, and the next audit builds or
  picks a tool for its own language and runner.

## Non-goals

- A `~/Code` project. That is the next line, in a repository Michael picks.
- Making suites faster by any means other than removing or merging tests (parallelism, fixtures).
- The live suites that measure the sandbox or the real daemon (`live-*`, `ssh-credential-inventory`,
  `zshrc`, `dev-topology`, `dev-integrations`).

## Anti-goals

- Catching fewer mutations after the cuts than before, code mutants or rule mutants.
- Deleting any test without evidence. The evidence is one of:
  - its class: a wording pin, a test of a stub's own behaviour, or a proven duplicate;
  - targeted mutants (§1.2) killed by another test.
  In a suite that guards a safety boundary (sandbox, guards, credentials, deletion, push or merge
  tooling), only the targeted-mutant evidence counts.
- Dropping coverage of a safety rule in the instruction fragments, whether an approval, a
  credential, a deletion, a push or merge, the sandbox or a guard. A pin on such a rule may be
  replaced, never just dropped. The rule is always in the approved replacement set, and its rule
  mutants must be killed by the replacement checks (Phase 3, step 4). Classification alone never
  exempts it.
- Holding the machine's test lock for hours while other lines need it.

## Design

### Phase 1: measure (nothing is deleted)

1. **Inventory.** For every suite: lines, assertions (as `run.sh` counts them), run time on the
   default and heavy runs, the script or scripts it tests, and its `test-requires` tag.
2. **Mutation sampling.**
   - **The harness.** It lives outside `tests/`, so `run.sh` never picks it up; the builder
     names it and places it under `.scripts/`. For each script under test it generates a bounded
     sample of mutants: a negated condition, a deleted statement, a changed exit status, `&&` and
     `||` swapped, a changed comparison. It runs that script's own suite against each mutant and
     records which assertions failed.
   - **Working copy.** Mutants are applied in a temporary copy of the checkout, never in the
     checkout itself.
   - **Attributable kills.** A mutant counts as killed only when the unmutated baseline passed in
     the same run conditions and a named assertion failed. A suite that times out or dies
     partway is "inconclusive", never "killed". Survivors are re-run once, to rule out a flaky
     pass.
   - **Two kinds of mutants.**
     - A random sample per script measures the baseline kill rate and finds gaps. It runs only
       the script's own suite.
     - Targeted mutants decide deletions. For each deletion candidate, they break the code that
       the candidate exercises (found by reading the test) and check whether another test kills
       them. A candidate claimed as a cross-suite duplicate runs every suite that loads the file.
     A test that kills no random-sample mutant is not thereby surplus: a sparse sample rarely
     touches the code a given test covers.
   - **Budget.** Unattended sessions of about 3 hours each. The harness is resumable and keeps
     its results, so the work can span several sessions (Michael's machine time; the driver's
     call). The heavy suites get few random mutants, and their targeted mutants cover only
     candidates. No suite is edited in phase 1 to make it cheaper to run. The harness takes the
     `run.sh` machine lock per suite run, never for a whole session, so the other lines' runs
     interleave.
   - **Output.** For each assertion, the mutants it killed. For each script, the mutants nothing
     killed (gaps).
   - **Rule mutants for the instruction fragments.** The sentence pins in
     `agent-instructions.test.sh` protect prose (`global.md`, `claude-code.md`, `codex.md`), which
     code operators never touch. For each pinned rule, the harness therefore also makes rule
     mutants: the sentence deleted, and the rule weakened ("Never" to "Prefer not to", "must" to
     "should", a named boundary dropped from a list). It records which pins kill them. That sample
     is the baseline that phase 3's replacement checks must match.
3. **Classification.** A reviewer reads every suite and sorts each test into one of five kinds:
   behaviour, wording pin, duplicate of another suite's case (named), test of a stub's own
   behaviour, or live measurement.
4. **Findings.** A tracked findings document beside the plan holds:
   - the ranked list, each test marked delete, merge or keep, with its evidence (kills, class,
     duplicate) and the time it saves;
   - the gaps found;
   - before-numbers: suites, lines, assertions, default and heavy run times, kill rate.

### Phase 2: Michael's checkpoint

The line stops and reports the findings to the driver, who brings them to Michael. Nothing is
deleted until Michael approves the list, wholly or in part. Gaps are reported, not fixed: closing a
gap adds a test, and Michael decides which gaps are worth it.

### Phase 3: cut, replace the pins, tighten the rule, validate

This phase starts only after `feat/wt-dotfiles`, `feat/draft-status` and
`feat/archive-review-threads` are merged. Those lines edit several of the same suites and
`global.md`. The line rebases its own branch onto the new `main` and refreshes the findings for
any suite those lines changed.

All edits come first, then one validation of the final state:

1. **Delete and merge** what Michael approved.
2. **Replace the pins.** `tests/agent-instructions.test.sh` swaps its exact-sentence pins for a
   small set of checks on the rules whose loss would matter. The builder proposes the set, and it
   is part of the phase 2 list. Every safety rule (see Anti-goals) is in the set, whatever the class
   of its old pin.
3. **Tighten the rule.** `global.md`'s testing line ("Each test names the behaviour it pins…")
   changes. The file is at its 150-line cap, so the new text replaces old text.
   - Test behaviour, not wording.
   - Extend an existing case before adding a new one.
   - "A fix ships with a test that fails without it" is qualified, by Michael's ruling of
     2026-11-11:
     - a real bug fix still ships with a test;
     - a review finding gets one only when the bug could plausibly come back;
     - every test that is written keeps the revert check (revert the fix, watch the test fail,
       restore it).
   - The places that restate the clause say the same:
     - `dot_claude/skills/cross-review/SKILL.md` (why test paths stay writable in an apply
       window);
     - `dot_claude/agents/sp-architect.md`;
     - `dot_claude/agents/sp-reviewer.md`.
     So does its pin in `tests/agent-instructions.test.sh`.
4. **Validate the final state.**
   - Re-run the mutation sample on the touched scripts: every code mutant killed before is still
     killed.
   - Re-run the rule mutants against the replacement checks: every rule mutant on a rule in the
     approved set is still killed. The rule mutants are regenerated from the final `global.md`,
     so the tightened line is covered too.
   - Run the full suite and the heavy suites.
   - Record the after-numbers beside the before-numbers.

A fix after validation repeats step 4.

## Left to the builder

- The harness's name, language and mutation operators, within §1.2.
- The per-script mutant counts within the time cap.
- The findings document's layout.
