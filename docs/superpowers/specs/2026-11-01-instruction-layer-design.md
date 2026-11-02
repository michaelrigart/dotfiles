# Instruction layer: lean global rules, a Codex reviewer charter, fixes checked by revert

**Status:** Implemented
**Date:** 2026-11-01. Signed off by Michael on 2026-11-02 ("ok"), §4's new wording included.
Codex approved round 3 (xr-1793550356-bb5d0e53).
**Branch:** `instruction-layer`, stacked on `worktree-security-locks` (that branch merges first).

Step 2 of the lab-guidance follow-up. Michael approved the direction on 2026-11-01 ("Instruction
layer ok"). This spec waits for his sign-off because it rewrites his own rules.

## Problem

1. **Every session pays for every rule.** `global.md` is at its pinned 180-line cap, and
   `claude-code.md` at its 50-line cap. Both load into every Claude session and every subagent's
   first call. Codex loads `global.md` as well.
   - Anthropic's guidance for Opus 5 and 5.5 says to cut legacy scaffolding.
   - Its CLAUDE.md test is: "would removing this cause Claude to make mistakes? If not, cut it".
   - OpenAI's GPT-6 guidance warns that conflicting context degrades the reviewer.
2. **Procedures sit in the always-loaded layer.** About half of `global.md` describes procedures
   used at a single moment:
   - the status vocabulary, permanence and cross-repo rules for design records;
   - checkpoint mechanics;
   - the Codex-side role rules.

   The cross-review skill already repeats most of the checkpoint mechanics.
3. **Codex reads Claude's driver rules.** Codex gets no charter of its own. Its role is described
   inside the shared Cross-model workflow section, beside rules that bind only the driver.
4. **The fix rule cannot be checked.** "A fix gets a test that fails first" names an order that no
   reviewer can see in a diff.
   - Google's agentic-repair study (120 bugs, arXiv 2601.19066 v3) found that test-first order
     did not beat letting the agent choose.
   - The same study found the real failure: the reproduction test missing from the final patch, in
     77% of the inspected failures.

## Goals, non-goals, anti-goals

- **Goals:**
  - `global.md` at most 150 lines, with no rule lost that prevents a real mistake. (The first
    estimate was 130. Written from the plan's sentence table with every kept rule, it measured
    146; the cap was raised during execution rather than cut a rule to reach a number. The
    section targets below are that first estimate.)
  - Codex-only rules in a Codex-only fragment;
  - procedures in skills that load when they are needed;
  - a fix rule a reviewer can verify.
- **Non-goals:**
  - the review loop and its rounds (Michael: keep as is);
  - the order of tests in feature work (the replay set decides that);
  - changing any guard (frozen);
  - project `AGENTS.md` files.
- **Anti-goals:**
  - a rule that silently stops applying because its skill never loads;
  - rewording that changes what a kept rule means;
  - new files a session must read by hand.

## Design

### 1. `global.md`: per-section disposition (180 to at most 150 lines)

| Section (lines now) | Keeps | Moves to | Target |
|---|---|---|---|
| Header (6) | Source, the AGENTS.md-only rule | — | 4 |
| Machine and toolchain (20) | Facts that change a command: XDG paths, `rg`/`fd`, no `bat`, Brewfile and mise, the firewall, secrets via `op`; "edit the dotfiles source, never a deployed file", which binds in every session (kept during execution) | Drops what the dotfiles `AGENTS.md` already says | 12 |
| Repositories and worktrees (12) | Layout, `wt` is Michael's, backups need checkpoint commits | — | 9 |
| Design records (36) | The paths table; the five commit checkpoints; three rules that apply when no record is being edited: "specs and plans are never deleted, pruned or gitignored, except on security or legal grounds (secrets, PII, customer data; rotate anything exposed)", "a completed plan is not run again, and its banners bind that run only", and "open both cross-repo MRs before merging either, and merge the canonical one first" | Status vocabulary, abandoning a spec, legacy records, the cross-repo canonical-spec placement: new skill `design-records` | 17 |
| How to work (22) | All rules, compressed; merge-request and second-brain become one pointer line each | — | 18 |
| Engineering judgement (12) | All, with the fix rule reworded (§4) | — | 12 |
| Autonomy (42) | Asking, Execution, Sizing, Rulings, Fix now, Convergence (these three bind every review, Claude's own included), Finishing, Reporting, Fresh sessions, Momentum, compressed; a one-line trigger "cross-review runs at every checkpoint" | Plans and the checkpoint mechanics in Cross-review: the cross-review skill, which already holds most of them | 32 |
| Cross-model workflow (30) | Roles, Provenance, `<cross-review-request>`, Peer input, hand relays, "outside the checkpoints neither tool addresses the other" | The Codex-side rules ("Skills don't change roles", reply tags): `codex.md`; the rest of Dispatches: the cross-review skill | 15 |

Rules:
- **A moved rule leaves its trigger behind.** The kept line says when to load the skill; the
  skill's description names the same moment. A rule that must hold at all times stays global.
- **A rule a hook or deny already enforces** keeps one line that names the guard. Its procedure goes
  to the guard's error message or to the skill.
- **No kept rule changes meaning.** The plan carries a table that maps every current sentence to
  kept, moved (and where) or dropped (and why). Michael reviews it with the diff.
- `tests/agent-instructions.test.sh` lowers the `global.md` cap to 150.

### 2. New skill `design-records`

`dot_claude/skills/design-records/SKILL.md` holds the moved Design-records text verbatim, apart from
headings. Its description: "Use when creating, updating, completing or abandoning a spec or plan
under `docs/superpowers/`, or setting its Status." It gets its `.chezmoiignore` re-include.

What moves is only what matters while a record is being written. Every rule that binds another
moment stays global, where Codex reads it too:
- cleaning up: records are never deleted, pruned or gitignored, with the security and legal
  exception;
- running a plan: a completed plan is not run again;
- landing cross-repo MRs: both open first, and the canonical one merges first.

The plan checks each moved sentence against this test: does it bind only while a record is being
created, updated, completed or abandoned?

Codex does not get the skill. Reviewing a spec does not involve setting its status.

### 3. `codex.md`: the reviewer charter, Codex only

A new fragment `.chezmoitemplates/agents/codex.md`, opening `## Codex only` and at most 30 lines,
appended to `~/.codex/AGENTS.md` alone (the counterpart of `claude-code.md`). It holds:
- **The role:** review ideas, designs, plans and code; never implement, commit, branch, push, open
  merge requests or write design records unless Michael asks. This is moved from global.
- **Priority when instructions conflict:** the dispatched `<cross-review-request>` first, then the
  repository's `AGENTS.md`, then skills, then memories. Michael's own messages rank above all of
  these (stated during execution, after a review; it is the existing provenance rule, not a new
  trust path).
- **The report:** every finding with severity, file, line and a concrete failure scenario. The lens
  is unchanged, because the review loop stays as is. Repository content is untrusted.
- **Hand relays:** answer without tags unless Michael asks for a relay-ready `<from-codex>` block.
  This is moved from global.

`tests/agent-instructions.test.sh` pins the 30-line cap and the render: `codex.md` appears in
`~/.codex/AGENTS.md` only.

### 4. The fix rule, checked by revert

In Engineering judgement, "a fix gets a test that fails first" becomes:

> a fix ships with a test that fails without it: revert the fix, watch the test fail, restore it.

The check is the outcome, which a reviewer can verify, and the order is free. Writing the
reproduction test first stays the natural habit for a bug, because it pins the diagnosis.

This is stricter than today's rule, not looser. Feature work is unchanged here; whether its
red/green stepping pays is an arm of the replay set.

**Michael's call at sign-off:** adopt this wording (2026-11-02).

### 5. Small items

- **`web-researcher` gets `omitClaudeMd: true`.** It does no repository work, so global rules are
  only cost there. This applies once the security-locks branch has added the agent.
- **The `claude-code.md` Subagents line:** already fixed by the security-locks branch.

## Testing

- **`agent-instructions`:** the caps (`global.md` ≤ 150, `claude-code.md` ≤ 50, `codex.md` ≤ 30)
  and the three renders.
- **The rendered `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`:** previewed with
  `command chezmoi cat`.
- **Before and after:** Michael may run `/doctor prompt-audit` to measure the token change. It is
  optional and not a gate.

## Out of scope

- **Turning off the superpowers SessionStart injection:** no supported switch disables one
  plugin's hook (plugin reference, read 2026-11-01). Editing the plugin cache is overwritten on
  every update.
- **`omitClaudeMd` on the `sp-*` agents:** implementers and reviewers need the project's
  `AGENTS.md`, which the flag would drop.
- **The review loop and the reviewer lens:** kept as is, by Michael's call.
