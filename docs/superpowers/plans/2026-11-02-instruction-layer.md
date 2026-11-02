# Instruction layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress on `instruction-layer` (the dotfiles have no MR)

**Goal:** `global.md` drops to at most 150 lines with no rule lost: record procedures move to a
`design-records` skill, Codex's rules to a Codex-only `codex.md`, checkpoint mechanics to the
cross-review skill, and the fix rule becomes one a reviewer can check by revert.

**Architecture:** Destinations land first, each pinned in `tests/agent-instructions.test.sh`:
`codex.md` with its render, the new skill with its deployment check, and the cross-review additions.
Then `web-researcher` gets `omitClaudeMd`. `global.md` is rewritten last, by the §1 table below,
so no rule leaves it before its new home holds it.

**Tech Stack:** chezmoi templates (`.chezmoitemplates`, `execute-template`), bash suites,
Claude Code 2.1.316 agent and skill frontmatter, Codex's global `~/.codex/AGENTS.md`.

**Spec:** `docs/superpowers/specs/2026-11-01-instruction-layer-design.md` (Approved, signed off
2026-11-02; Codex xr-1793550356-bb5d0e53). Read it whole first. This plan changes none of its rulings.

## Global Constraints

- **Scope.** Edit only this worktree's source. `chezmoi apply` is Michael's. Before Task 1, this
  plan is committed and the spec's Status is set to `In progress`.
- **Commits.** Only the controller commits; an implementer runs its focused suites and hands back
  uncommitted. Imperative mood, no agent attribution. Before each commit, check that
  `git branch --show-current` prints `instruction-layer`, then read `git diff --cached`.
- **Caps.** `global.md` ≤ 150 lines (call 15), `claude-code.md` ≤ 50 (not edited), `codex.md` ≤ 30. No
  line is wider than 100 columns, matching the current file.
- **The fix rule, verbatim (§4):** `a fix ships with a test that fails without it: revert the fix, watch the test fail, restore it.`
- **The skill description, verbatim (§2):** `` Use when creating, updating, completing or abandoning a spec or plan under `docs/superpowers/`, or setting its Status. ``
- **Meaning.** No kept rule changes meaning (§1). A kept bullet keeps its bold label, because
  other files cite labels: the forge guard's deny text cites "Merge requests", and the suite pins
  Sizing and Convergence.
- **Fragments are plain text.** No `{{` in any fragment, and nothing private: the repo is public.
- **Guards are frozen** (spec non-goal). No guard script changes, comments included.
- **Running suites.** Execute them and never prefix an interpreter: `./tests/run.sh <name>`. The
  tasks run one at a time, so the runner's machine lock never contends.
- **Pre-existing failures.** A failure counts as pre-existing only if the same suite fails on a
  clean checkout of main's tip.

## Review Focus

1. **Meaning drift in a compressed kept rule.** No test can see it. In Task 5 the reviewer reads
   every `Kept` row of the table against the new text. Michael reviews the table with the diff.
2. **A skill that never loads.** Its rules would then silently stop applying (spec anti-goal).
   Task 5 pins the same moment phrase in `global.md`'s trigger line and in the skill's
   description. Whether Claude actually loads it is Michael's rollout check (Task 6).
3. **A17 must survive the move of the checkpoint mechanics.** That is the rule that commits after
   the last pre-merge review need a new one. It binds when work is reported as done, a moment the
   cross-review skill need not be loaded, and in a repo without MRs (the dotfiles) no gate backs it
   up. So it stays global, folded into the A16 trigger line (call 13), and Task 5 pins it there.
4. **The old fix wording survives somewhere loaded.** Task 3 rewrites the cross-review skill's
   RED-test sentence and pins that `genuinely written first` is gone. The apply guard's comments
   (`xreview-apply-guard.sh:6-10`, `:62`) and a test label (`xreview-apply-guard.test.sh:45`)
   keep the RED-test wording. They are frozen and never loaded, so they are not misses.
5. **`omitClaudeMd` misspelled or ignored.** Task 4 pins the exact frontmatter line. Acceptance
   was checked against the 2.1.316 binary only (Spec facts below). Recheck after an upgrade.

## Spec facts checked (2026-11-02)

- **`omitClaudeMd` is a valid agent key in Claude Code 2.1.316.** Checked with
  `LC_ALL=C grep -ao 'omitClaudeMd.\{0,200\}' /opt/homebrew/Caskroom/claude-code@latest/2.1.316/claude`:
  the agent-file parser reads `Y.omitClaudeMd` from frontmatter (beside `background` and `memory`)
  and accepts `true` or `"true"`; the frontmatter key list includes it; the schema describes it
  as "Run this agent without the user, project and local CLAUDE.md instruction files when it runs
  as a subagent; managed policy files are kept."
- **Sandboxed previews of this worktree work.** `command chezmoi --source <worktree> cat` gave
  231 lines for `~/.claude/CLAUDE.md` (180 + 1 + 50) and 180 for `~/.codex/AGENTS.md`, exit 0;
  `managed` lists `.claude/skills/*/SKILL.md` while the externals cache is warm.
- **Skills and guards that already carry a rule.**
  - `second-brain/SKILL.md` has the vault path (`:8-9`) and the never-store list (`:14-15`).
  - `merge-request/SKILL.md:18-21` has the attribution rule, but loads only when an MR is opened.
  - The forge guard's deny cites the "Merge requests" rule in GLOBAL.md, How to work
    (`executable_git-forge-guard.sh:514`), pinned at `git-forge-guard.test.sh:484`.
  - The worktree guard's `REMEDY` (`executable_worktree-guard.sh:48-54`) gives
    `command wt-rm <branch>` and says another tool's worktree follows that tool.
- **Nothing else reads the fragments** except `xreview-skill.test.sh:118` (`round cap`, unaffected).
- **§5's Subagents line is already fixed** on this branch (`claude-code.md:21`, pinned at
  `agent-instructions.test.sh:145`). No task touches `claude-code.md`.
- **Sizing against §4.** Sizing (A9) keeps "test first, implement"; the §4 rule names no order,
  so the two texts agree.
- **Feasibility.** A scratch draft of this table at ≤ 100 columns measured 128 lines, with the
  five checkpoints as one prose paragraph. Its section budgets: header 5, Machine 11, Repos 9,
  Design records 19, How to work 19, Engineering 13, Autonomy 34, Cross-model 18. Call 14 keeps
  three more sentences in Design records (about 2 lines); find them in the other sections first.

## Calls this plan makes

Gaps or tensions in the spec, settled here. Michael can overturn any of them at review.

1. **The attribution rule stays in full** (W14) beside the one-line pointer (W13), though §1
   says "one pointer line": it binds at every commit, not only when the skill loads; the forge
   guard's deny cites it and covers only commits and MR/PR text; the suite pins it in full.
2. **Second brain keeps the pointer and "write it only when asked"** (W17). The vault path (W16)
   and never-store list (W18) drop because the skill holds both; that suite pin moves there.
3. **Unlisted Design-records sentences go by §2's test:** D1 and D19 move; D2, D3 and D20 stay
   (call 14). One pronoun gets its noun back: D15 "An abandoned spec".
4. **Brainstorming is in neither Autonomy list.** A14 stays: it overrides the brainstorming
   skill's one-question-at-a-time default, and no skill of ours loads then. A15 drops as restated.
5. **Parallel work (R2) is in neither Repositories list.** It stays, merged into the `wt`
   bullet: the shared database is a real hazard.
6. **X3 moves to `codex.md`:** §3's role text "is moved from global", and only X3 says "unless
   Michael asks".
7. **R6 becomes a clause naming the worktree guard** (§1's guard rule), whose `REMEDY` carries
   the command. R7 stays: the guard never sees an agent's own worktree.
8. **The Brewfile is called chezmoi-managed** (M9), so dropping M2-M3 as the spec says does not
   turn M9 into an instruction to edit a deployed file.
9. **Duplicates merge:** W9 into E4, M14-M15 into W7-W8.
10. **The cross-review skill's RED-test sentence follows §4** (`SKILL.md:341-343`), or loaded
    context would carry two fix rules.
11. **The dotfiles `AGENTS.md` gets its now-false facts fixed** (`:33-39`, `:81`): the caps, the
    `codex.md` fragment, "pins both". The non-goal "project AGENTS.md files" is read as "no
    restructuring".
12. **Tests:** every instruction-layer pin, the skills' moved-rule pins included, lives in
    `agent-instructions.test.sh` through a new `need_in` helper. The skill deployment check goes
    in `claude-settings` section X beside the agent check, reusing its `chezmoi managed` call and
    INCONCLUSIVE path.
13. **A17 stays global** (controller's ruling at plan time). §1 moves "the checkpoint mechanics"
    to the cross-review skill, but A17 binds when work is reported as done, and the skill need not
    be loaded then: moving it would hit the spec's anti-goal of a rule that silently stops
    applying. It joins the A16 trigger line, so it costs no extra line.
14. **D2, D3 and D20 stay global** (plan review, round 1). D2 and D3 bind whenever a repository's
    `AGENTS.md` is written, and D20 whenever lessons are recorded, a small change included; none
    of these moments loads the `design-records` skill. D2 keeps "points here", which still has its
    referent in `global.md`. The skill keeps D1, D13, D15, D17, D19 and D21. If the three cost the
    130-line cap, Task 5 stops and reports rather than cutting a rule.
15. **The cap is 150, not 130** (controller's ruling during execution, for Michael to confirm).
    Task 5 wrote every Kept row and measured 146 lines at 100 columns; the earlier 128-line
    scratch draft could not have held them all. The options were to cut kept rules (against §1's
    "no rule lost"), strip the blank lines (a line count gamed, tokens unchanged) or raise the
    cap. The cap goes to 150. Sizing also states D1's always-binding half ("Every other change
    has a spec and a plan"), because D1 moved to the skill.
16. **Four rows changed after the Task 5 table review.** X16 (consult Codex when genuinely stuck)
    stays global, joined with X19: the cross-review skill loads only at checkpoints, so moving it
    would leave X19 as a ban on the stuck case. D22 names "the one holding the canonical spec", so
    it binds on cross-repo work without a spec too. M2-M3 (edit the dotfiles source, never a
    deployed file) stay: they bind in every session. R8 survives as a runbook pointer inside R9.
    The result is 150 lines, at the cap.

## The §1 table: every sentence of `global.md`

Each row is one current sentence, identified by its line and opening words.

- **Dispositions:** Kept (meaning unchanged, compression allowed), Moved (with its destination),
  Dropped (with the reason).
- **Abbreviations:**
  - `DR` is the new `design-records` skill.
  - `CR` is `dot_claude/skills/cross-review/SKILL.md`, and `CR:n` is a line in it.
  - `CX` is `codex.md`.

**Header (1-6)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| H1 | 1 | `# Global agent instructions` | Kept |
| H2 | 3 | "Cross-tool guidance for AI coding agents." | Dropped: decides nothing; the title says it |
| H3 | 3-4 | "Source: `.chezmoitemplates/agents/` in the chezmoi repo; edit that…" | Kept |
| H4 | 4-5 | "Claude-only rules go in `claude-code.md`." | Dropped: binds only when editing fragments, in the dotfiles, whose AGENTS.md:33-37 says it (Task 1 adds `codex.md` there) |
| H5 | 5 | "Project rules live only in each repository's `AGENTS.md`…" | Kept |

**Machine and toolchain (7-26)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| M1 | 9-10 | "**Machine:** MacBook Pro, Apple silicon, macOS Tahoe, provisioned from…" | Dropped: changes no command; the harness states the platform, and AGENTS.md:4 says the repo is public |
| M2-M3 | 11 | "**Dotfiles:** managed by chezmoi." / "Edit the source, never a deployed file." | Kept after all (call 16): it binds in every session, and AGENTS.md:21 loads only in the dotfiles |
| M4 | 11-12 | "`chezmoi apply` renders 1Password-backed templates…" | Dropped: `chezmoi apply` is Michael's (AGENTS.md:21-22); its error is in Troubleshooting (:200) |
| M5 | 13-14 | "**Strict XDG:** config `~/.config`…" | Kept |
| M6 | 15-16 | "**Shell and tools:** zsh with Oh My Zsh, Starship, Ghostty, Neovim…" | Dropped: the interactive setup; agent shells are non-interactive, and the harness names the shell |
| M7 | 16-17 | "Prefer `rg`, `fd`, `eza` and `fzf`; there is no `bat`." | Kept for `rg`, `fd`, no `bat`; `eza` and `fzf` dropped as interactive tools |
| M8 | 17 | "Interactive aliases (`ls`) are absent in non-interactive shells." | Dropped: an agent's shell has no alias to miss |
| M9 | 18-19 | "**Packages:** Homebrew packages go in …Brewfile; runtimes … go in mise…" | Kept; the Brewfile is called chezmoi-managed (call 8) |
| M10 | 19-20 | "Never install ad hoc or as global toolchains." | Kept |
| M11 | 21-22 | "**Stack:** Rails first…" and "Ops: Ansible, Kubernetes…" | Dropped: names no command; each repo's own files say its stack |
| M12-M13 | 23-24 | "**Firewall:** an outbound firewall (Little Snitch) blocks…" / "Suspect it first…" | Kept |
| M14-M15 | 25 | "**Secrets:** they come from 1Password (`op`)." / "Never print, log or commit one." | Kept, merged with W7-W8 |

**Repositories and worktrees (27-38)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| R1 | 29 | "**Layout:** code lives in `~/Code/<Org>/<repo>`…" | Kept |
| R2 | 30-31 | "**Parallel work:** `wt <branch>` makes a sibling checkout…; worktrees share one database…" | Kept, merged into the `wt` bullet (call 5) |
| R3-R5 | 32-33 | "**`wt` worktrees are Michael's.**" / "He creates them with `wt`…" / "Never create one, and never offer or run `wt-rm`." | Kept |
| R6 | 33-34 | "If he explicitly asks for a teardown, use `command wt-rm <branch>`, never `git worktree remove`." | Kept as one clause naming the worktree guard; the command is in its REMEDY (call 7) |
| R7 | 34-35 | "A harness worktree (an agent's own isolation) follows its own tool's lifecycle." | Kept |
| R8 | 36 | "**Backups:** Borg runs through Vorta; the runbook is the vault's Backups note." | Kept as a pointer in R9 (call 16): no skill loads on a backup task |
| R9 | 36-37 | "Backups skip uncommitted work in a `wt` worktree…" | Kept |

**Design records (39-74)**: §2's test asks whether a sentence binds only while a record is being
created, updated, completed or abandoned.

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| D1 | 41 | "Every change except a small one (see Sizing) has a spec and a plan…" | Moved → DR. §2: yes. Sizing keeps the always-binding half |
| D2 | 42 | "A repository's `AGENTS.md` points here and adds only project-specific supplements." | Kept, joined with D3 in one sentence (call 14). §2: no; it binds whenever an `AGENTS.md` is written |
| D3 | 42-43 | "Where records live, what is tracked and when each is committed never vary per repository." | Kept, joined with D2 (call 14). §2: no; it is what an `AGENTS.md` may not override |
| D4 | 45-49 | the paths table | Kept |
| D5-D6 | 51 | "**Commit at each checkpoint, not at merge.**" / "Brainstorming notes are never committed." | Kept |
| D7-D11 | 52-57 | checkpoints 1-5 | Kept, as one paragraph |
| D12 | 57 | "A merge SHA can be added later; it never needs its own MR." | Kept |
| D13 | 59-60 | "**Status vocabulary.** Use exactly: `Approved`, …" | Moved → DR (spec). §2: yes |
| D14 | 62 | "**Permanence.** A spec is permanent from sign-off;" | Kept, as the lead of D16 |
| D15 | 62-63 | "an abandoned one is marked `Abandoned` and merged on its own." | Moved → DR as "An abandoned spec is marked…" (spec). §2: yes |
| D16 | 63-65 | "Specs and plans are never deleted, pruned or gitignored, except…" | Kept (spec, §2: binds at cleanup) |
| D17 | 65 | "Legacy records keep their status until verified against history." | Moved → DR (spec). §2: yes |
| D18 | 67-68 | "**Completed documents.** Mark a completed plan so it is not run again; its execution banners…" | Kept (spec, §2: binds when a plan runs) |
| D19 | 68 | "Don't rewrite point-in-time facts." | Moved → DR (call 3). §2: binds only while a record is updated |
| D20 | 69 | "Durable lessons go in the spec, plan, ADR or MR description, never in raw run files." | Kept, after D18 (call 14). §2: no; a small change records lessons with no spec or plan |
| D21 | 71-72 | "**Cross-repo work.** Keep one canonical spec, referenced by repository and path…" | Moved → DR (spec). §2: yes |
| D22 | 72-73 | "Open both MRs before merging either, and merge the canonical one first." | Kept (spec, §2: binds when landing); "the one holding the canonical spec", so it holds without a spec too (call 16) |
| new | — | the trigger: load the `design-records` skill "when creating, updating, completing or abandoning a spec or plan, or setting its Status" | Added (§1: a moved rule leaves its trigger) |

**How to work (75-96)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| W1-W2 | 77 | "Be concise and direct." / "Lead with the answer…" | Kept |
| W3-W4 | 78-79 | "Make small, focused commits…" / "Add no license headers…" | Kept |
| W5-W6 | 80-81 | "Iterate on focused tests…" / "Before claiming something works…" | Kept |
| W7-W8 | 82 | "Never commit, print or log secrets." / "Check staged changes before every commit and push." | Kept, absorbing M14-M15 |
| W9 | 83 | "Don't create files the task doesn't need, such as unrequested docs, notes or READMEs." | Kept, merged into E4, which gains "notes" (call 9) |
| W10-W12 | 84-87 | "**Every agent confirms first** before…" / "Exempt: …" / "Harness prompts are a backstop…" | Kept |
| W13 | 88 | "**Merge requests.** Load the `merge-request` skill before opening an MR or PR." | Kept: the pointer line |
| W14 | 88-91 | "Never add agent attribution (…) in commits, MR/PR titles and bodies, issues or review comments." | Kept in full (call 1) |
| W15 | 91 | "The published record is Michael's." | Kept |
| W16 | 92-94 | "**Second brain.** The Obsidian vault "MSB" lives at …; the `second-brain` skill holds its conventions." | Dropped: second-brain `SKILL.md:8-9` has the path; W17 names the skill |
| W17 | 94 | "Offer a note when work produces durable knowledge and write it only when asked." | Kept: the pointer line |
| W18 | 95 | "Never store secrets, credentials, customer data, raw conversations or transient working notes." | Dropped: second-brain `SKILL.md:14-15` says it, and it binds only while a note is written (call 2) |

**Engineering judgement (97-108)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| E1-E2 | 99-100 | "Solve today's problem…" / "A pattern or abstraction must solve…" | Kept |
| E3-E4 | 101-103 | "Prefer an in-scope refactor…" / "No unrequested features, files, docs or options." | Kept; E4 gains "notes" (W9) |
| E5 | 104-105 | "Each test names the behaviour…; reuse existing coverage; a fix gets a test that fails first." | Kept, its last clause replaced by the §4 wording |
| E6 | 105 | "Never special-case code to pass a test; report it." | Kept |
| E7 | 106-107 | "Disagree when you have reason to…" | Kept |

**Autonomy (109-150)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| A1-A3 | 111-113 | "These rules bind the top-level session…" / "A subagent does only…" / "Michael signs off specs and merges…" | Kept |
| A4-A5 | 115-117 | "**Asking.** …" / "Otherwise take the sensible default…" | Kept |
| A6-A7 | 118-119 | "**Execution** is always subagent-driven." / "Move on to the next task…" | Kept |
| A8-A10 | 120-124 | "**Sizing.** …" / "A small change (…) skips the spec and plan: test first…" / "Unsure or outgrown…" | Kept, wording unchanged |
| A11 | 125 | "**Plans.** Codex reviews every plan, and execution starts once it approves." | Moved → CR `## When`; CR lacks it (`:16` only names the checkpoint) |
| A12 | 126 | "If Michael asked at spec sign-off to see the plan, stop after Codex approves." | Moved → CR `## When`; CR lacks it |
| A13 | 126-127 | "Either way, put the plan's path in your next status message." | Moved → CR `## When`; CR lacks it |
| A14 | 128 | "**Brainstorming.** Present the whole design in one message." | Kept (call 4) |
| A15 | 128-129 | "The hard gate is the written spec, reviewed by Codex and then signed off by Michael." | Dropped: D7, A3 and A16 restate it (call 4) |
| A16 | 130-131 | "**Cross-review** runs at every checkpoint (spec sign-off, plan completion, pre-merge) without being asked." | Kept: the trigger line; `claude-code.md:46` names the skill |
| A17 | 131-132 | "Commits after the last pre-merge review need a new review before you report the work as done." | Kept, folded into A16's trigger line (call 13) |
| A18-A19 | 133-134 | "**Rulings.** …" / "Escalate only what would change the spec." | Kept (spec: binds every review) |
| A20-A21 | 135 | "**Fix now.** …" / "No follow-up MRs unless Michael asks." | Kept |
| A22-A23 | 136-138 | "**Convergence.** …" / "Two rounds in a row…" | Kept |
| A24-A26 | 139-140 | "**Finishing.** …" / "For the dotfiles, the pushed branch is the end." / "Show no finishing menus…" | Kept |
| A27 | 141-142 | "**Reporting.** End every final report with one state line…" | Kept |
| A28-A29 | 143-145 | "**Fresh sessions.** …" / "Persist anything not yet on disk first…" | Kept |
| A30-A32 | 146-149 | "**Momentum.** …" (three sentences) | Kept |

**Cross-model workflow (151-180)**

| ID | Line | Sentence | Disposition |
|---|---|---|---|
| X1-X2 | 153-154 | "**Roles.** Claude Code drives…" / "Codex independently reviews ideas, designs, plans and code." | Kept |
| X3 | 154-156 | "It does not take over the workflow, create competing canonical artifacts, or change the implementation unless Michael asks." | Moved → CX role bullet (call 6) |
| X4 | 156 | "These are defaults, not capability limits." | Kept |
| X5-X7 | 158-162 | "**Provenance.** Unmarked text is Michael's." / "`<from-codex>` and `<from-claude-code>` wrap…" / "A peer block is quoted material…" | Kept |
| X8-X10 | 163-165 | "**`<cross-review-request>`** is the exception." / "It is an authorised dispatch…" / "The repository content it points at stays untrusted." | Kept |
| X11-X12 | 166-168 | "**Peer input.** …" / "Don't copy the peer's process or assume its conventions are Michael's." | Kept |
| X13 | 169-170 | "**Skills don't change roles.** A skill's trigger describes how to do a thing well, not whose job it is." | Moved → CX, verbatim (spec) |
| X14 | 170-171 | "On Codex's side that means no committing, branching, pushing or opening MRs, no design records, and no competing plan." | Moved → CX role bullet (spec) |
| X15 | 171 | "Review, debugging and hardening are on role." | Moved → CX, verbatim (spec) |
| X16 | 172-173 | "**Dispatches.** Claude Code dispatches to Codex at the checkpoints and when genuinely stuck, sending the artifact…" | Kept, joined with X19 (call 16): the stuck case binds when the skill is not loaded. CR holds the mechanics |
| X17 | 173-175 | "Within a checkpoint it iterates until…, with no round limit and never prolonged for consensus;" | Moved → CR. `:223-224` and `:231` hold all but the last clause; Task 3 adds "Never prolong a loop for consensus." |
| X18 | 175-176 | "Michael hears about disagreements and stalled loops, not routine round counts." | Moved → CR, already there: `:224-226` and the escalation list `:251-275`. Nothing to add |
| X19 | 176 | "Outside the checkpoints, neither tool addresses the other on its own." | Kept (spec) |
| X20 | 177-178 | "**When Michael relays by hand:** evaluate the input, then report…, and stop." | Kept |
| X21 | 178-180 | "Reply without tags unless he asks for a relay-ready handoff, which Claude Code wraps in `<from-claude-code>` and Codex in `<from-codex>`." | Split: the Claude Code half is kept; "and Codex in `<from-codex>`" moves → CX's Hand relays bullet (spec) |

## File map and order

| Task | Files |
|---|---|
| 1 | `.chezmoitemplates/agents/codex.md` (new), `dot_codex/AGENTS.md.tmpl`, `AGENTS.md`, `tests/agent-instructions.test.sh` |
| 2 | `dot_claude/skills/design-records/SKILL.md` (new), `.chezmoiignore`, `tests/claude-settings.test.sh` (section X), `tests/agent-instructions.test.sh` |
| 3 | `dot_claude/skills/cross-review/SKILL.md`, `tests/agent-instructions.test.sh` |
| 4 | `dot_claude/agents/web-researcher.md`, `tests/agent-instructions.test.sh` |
| 5 | `.chezmoitemplates/agents/global.md`, `AGENTS.md`, `tests/agent-instructions.test.sh` |
| 6 | spec and plan Status, Run notes; memory outside the repo |

**All tasks run in sequence; there are no parallel batches.** Every task edits
`agent-instructions.test.sh`, the one suite that pins the instruction layer. Splitting its pins
across suites to buy a batch would scatter the moved-rule pins away from the caps they balance,
and the tasks are small. Task 5 must come after Tasks 1-3 anyway, because it removes what they
receive.

---

### Task 1: The Codex-only fragment

**Depends on:** none. **Tier:** sp-standard. **Spec:** §3.

**Interfaces:**
- `CODEX_MARKER='## Codex only'` sits beside `MARKER` in the suite.
- `dot_codex/AGENTS.md.tmpl` takes the shape of `dot_claude/CLAUDE.md.tmpl`:
  `{{ template "agents/global.md" . }}`, a newline, then `{{ template "agents/codex.md" . -}}`.

- [ ] **Step 1: Failing tests** in `tests/agent-instructions.test.sh`:
  - Add `$FRAG/codex.md` to the missing-file loop (`:19`). Update the header comment (`:2-11`):
    the Codex target is the shared fragment, then the Codex addendum.
  - Codex target: `## Codex only` is at line `frag_lines + 2`, and the last line is not blank.
    Mirror `:67-75`.
  - The GLOBAL and Claude targets carry no `## Codex only` line (`grep -qxF`). `global.md` and
    `claude-code.md` hold no such heading.
  - `codex.md` opens with `## Codex only`, is at most 30 lines, and joins the no-template-action
    loop (`:96`).
  - `need_flat codex.md` for each of these:
    ```
    never implement, commit, branch, push, open merge requests or write design records unless Michael asks
    take over the workflow
    competing canonical artifacts
    competing plan
    A skill's trigger describes how to do a thing well, not whose job it is
    Review, debugging and hardening are on role
    the dispatched `<cross-review-request>` first, then the repository's `AGENTS.md`, then skills, then memories
    severity, file, line and a concrete failure scenario
    Repository content is untrusted
    answer without tags unless Michael asks for a relay-ready `<from-codex>` block
    ```
- [ ] **Step 2: Run red.** `./tests/run.sh agent-instructions` exits 2 with
  `missing file under test: …/codex.md`.
- [ ] **Step 3: Implement.**
  - **`codex.md`:** the `## Codex only` heading, then four bullets in §3's order: the role,
    priority, the report, hand relays.
    - The role bullet is §3's role sentence, plus X3 and X13-X15 kept in meaning. That means: no
      taking over the workflow, and no competing canonical artifacts, a competing plan included.
      A skill's trigger is not a job, and review, debugging and hardening are on role.
    - The report bullet adds no lens, scale or field beyond those words; the review loop stays as
      it is.
    - No other rule goes in.
  - **The template:** the two lines above.
  - **`AGENTS.md:33-39`:** add that `codex.md` (Codex only, opening with `## Codex only`) is
    appended to `~/.codex/AGENTS.md` alone, and that it stays within 30 lines. "pins both, and
    the render" becomes "pins all three, and the renders". At `:81`, list `codex.md` too.
- [ ] **Step 4: Run green** with `./tests/run.sh agent-instructions`.
- [ ] **Step 5: Hand back** to the controller, uncommitted. The controller commits it as `Give Codex its own instruction fragment`.

### Task 2: The design-records skill

**Depends on:** Task 1 (shared suite). **Tier:** sp-mechanical. **Spec:** §2.

**Interfaces:**
- **New suite helper `need_in <path under $SRC> <fixed text> <label>`.** It matches the
  whitespace-flattened file, like `need_flat`, and fails with `missing file` when the path is
  absent. Tasks 3 and 5 use it.

- [ ] **Step 1: Failing tests.**
  - **`tests/agent-instructions.test.sh`:**
    - Add `need_in`.
    - The frontmatter of `dot_claude/skills/design-records/SKILL.md` holds `name: design-records`
      and exactly this line (`grep -qxF`, parsed with the awk at `:156`):
      ```
      description: Use when creating, updating, completing or abandoning a spec or plan under `docs/superpowers/`, or setting its Status.
      ```
    - `need_in` the skill for each moved sentence:
      ```
      Every change except a small one (see Sizing) has a spec and a plan, versioned with the code.
      Use exactly: `Approved`, `In progress`, `Implemented`, `Superseded — see <link>`, `Abandoned — <reason>`.
      An abandoned spec is marked `Abandoned` and merged on its own.
      Legacy records keep their status until verified against history.
      Don't rewrite point-in-time facts.
      Keep one canonical spec, referenced by repository and path, preferably as a forge link and never as a bare path.
      ```
  - **`tests/claude-settings.test.sh`, section X:** after the agent loop (`:941-947`), add a loop.
    Every `dot_claude/skills/*/SKILL.md` must be in `$managed` as
    `.claude/skills/<dir>/SKILL.md`. Without its allowlist entry, a skill never deploys.
- [ ] **Step 2: Run red** with `./tests/run.sh agent-instructions claude-settings`. The skill pins
  fail as missing. Once the skill exists, the managed loop fails until the re-include is in.
- [ ] **Step 3: Implement.**
  - **`SKILL.md`:** frontmatter `name` and `description` as pinned, a `# Design records` title,
    then the six sentences above, verbatim, under headings of your choice. Nothing else goes
    in: everything kept stays in `global.md`, which is always loaded.
  - **`.chezmoiignore`:** after `:102`, add these lines, as cross-review has:
    ```
    !.claude/skills/design-records/
    .claude/skills/design-records/*
    !.claude/skills/design-records/SKILL.md
    ```
- [ ] **Step 4: Run green** with `./tests/run.sh agent-instructions claude-settings`.
- [ ] **Step 5: Hand back** to the controller, uncommitted. The controller commits it as `Add a design-records skill for the record procedures`.

### Task 3: The cross-review skill takes the checkpoint mechanics

**Depends on:** Task 2 (`need_in`). **Tier:** sp-mechanical. **Spec:** §1 (Autonomy,
Cross-model rows), §4.

- [ ] **Step 1: Failing tests** in `tests/agent-instructions.test.sh`.
  - `need_in dot_claude/skills/cross-review/SKILL.md` for each of these:
    ```
    Codex reviews every plan, and execution starts once it approves.
    If Michael asked at spec sign-off to see the plan, stop after Codex approves.
    Either way, put the plan's path in your next status message.
    Never prolong a loop for consensus.
    a fix ships with a test that fails without it
    ```
  - A flattened grep of the skill fails while `genuinely written first` is present.
- [ ] **Step 2: Run red** with `./tests/run.sh agent-instructions`.
- [ ] **Step 3: Implement** in `dot_claude/skills/cross-review/SKILL.md`.
  - **`## When`:** after "Not every turn, and never for reassurance." (`:19`), add one paragraph
    with A11-A13, verbatim.
  - **`## Iterating`:** after its first sentence (`:223-224`), add "Never prolong a loop for
    consensus."
  - **The apply window (`:341-343`):**
    - "because the RED-test rule requires adding one" becomes "because a fix ships with a test
      that fails without it".
    - "whether a RED test was genuinely written first is not mechanisable and remains discipline"
      becomes "whether that test fails without the fix is for the reviewer to check by revert,
      not for a guard".
  - Add nothing for X16 and X18: the skill already says them (table).
- [ ] **Step 4: Run green** with `./tests/run.sh agent-instructions xreview-skill`. `xreview-skill`
  checks that every `xreview <subcommand>` and `XREVIEW_*` named in the skill still exists.
- [ ] **Step 5: Hand back** to the controller, uncommitted. The controller commits it as `Move the plan checkpoint rules into the cross-review skill`.

### Task 4: web-researcher runs without CLAUDE.md

**Depends on:** Task 3 (shared suite only). **Tier:** sp-mechanical. **Spec:** §5.

- [ ] **Step 1: Failing test.** The frontmatter loop at `tests/agent-instructions.test.sh:155`
  gains `'omitClaudeMd: true'`.
- [ ] **Step 2: Run red** with `./tests/run.sh agent-instructions`. It fails with
  `web-researcher frontmatter has omitClaudeMd: true`.
- [ ] **Step 3: Implement.** Add `omitClaudeMd: true` after `effort: medium` in
  `dot_claude/agents/web-researcher.md`. Spec facts above record how the key was checked.
- [ ] **Step 4: Run green** with `./tests/run.sh agent-instructions claude-settings`. Section X
  reads every agent file.
- [ ] **Step 5: Hand back** to the controller, uncommitted. The controller commits it as `Run web-researcher without the CLAUDE.md instructions`.

### Task 5: Rewrite global.md by the table

**Depends on:** Tasks 1-3 (the destinations) and Task 4 (shared suite). **Tier:** sp-standard;
its reviewer is sp-reviewer, with the §1 table as the brief. **Spec:** §1, §4.

**Interfaces:** `need_in` (Task 2).

- [ ] **Step 1: Failing tests** in `tests/agent-instructions.test.sh`.
  - **The cap:** at `:83-84`, `180` becomes `150` (call 15; first `130`) in both the check and its label.
  - **The fix rule.** `need_flat global.md` for the §4 sentence verbatim. A flattened grep fails
    while `a fix gets a test that fails first` is present.
  - **The trigger pair.** `need_flat global.md` for `` `design-records` ``, for
    `creating, updating, completing or abandoning a spec or plan` and for `setting its Status`.
    The first phrase must also appear in the skill's description line. This pins §1's rule that
    the trigger and the description name the same moment.
  - **Rules §2 keeps global.** `need_flat global.md` for each of these:
    - `never deleted, pruned or gitignored`
    - `so it is not run again`
    - `both MRs before merging either, and merge the canonical one first`
    - `adds only project-specific supplements` (D2, call 14)
    - `never vary per repository` (D3, call 14)
    - `never in raw run files` (D20, call 14)
  - **The cross-review trigger.** `need_flat global.md` for
    `runs at every checkpoint (spec sign-off, plan completion, pre-merge)` and for
    `need a new review before you report the work as done` (A17, call 13), and
    `need claude-code.md` for `` runs through the `cross-review` skill ``.
  - **The forge guard's citation.** `need_flat global.md` for
    `` - **Merge requests.** Load the `merge-request` skill before opening an MR or PR. ``
  - **Codex-only text is out of global.** A flattened grep fails while either of these is present:
    `` **Skills don't change roles.** `` or `On Codex's side`.
  - **Rewrapped pins.** The two line-exact pins at `:122-125` become `need_flat` on their
    flattened text, so a rewrap cannot break them.
  - **The never-store pin** (`:139-140`) becomes `need_in dot_agents/skills/second-brain/SKILL.md`
    for `secrets, credentials, customer data, raw conversations or transient working notes in the vault`.
    `write it only when asked` stays on `global.md`.
- [ ] **Step 2: Run red** with `./tests/run.sh agent-instructions`. It fails on the cap, the fix
  rule, the trigger pair and the Skills absence. The other pins pass already: they guard against
  a later edit.
- [ ] **Step 3: Implement.**
  - Rewrite `.chezmoitemplates/agents/global.md` row by row from the table. Kept rows keep their
    meaning and bold labels. Moved and dropped rows go. The added trigger goes at the end of
    Design records.
  - Keep the section order and headings, stay within the Spec-facts budgets, and keep lines at
    100 columns or fewer.
  - If it will not fit in 130 lines without dropping or changing a kept rule, stop and report to
    the controller. Never cut a rule to make the cap.
  - **`AGENTS.md:38`:** 180 becomes 150 (call 15).
- [ ] **Step 4: Run green** with `./tests/run.sh agent-instructions xreview-skill`.
- [ ] **Step 5: Table check.** Walk every row of the §1 table against the diff; the task's
  reviewer repeats it, with the table as the brief:
  - each Kept sentence is present with the same meaning;
  - each Moved sentence is in its destination;
  - each Dropped sentence is gone, for the stated reason.

  Report any row that does not hold.
- [ ] **Step 6: Hand back** to the controller, uncommitted. The controller commits it as `Cut global.md to 146 lines and make the fix rule checkable by revert`.

### Task 6: Finish

**Depends on:** Tasks 1-5. **Tier:** controller.

- [ ] **Run the suites on the final commit.** First `./tests/run.sh`, then
  `./tests/run.sh xreview git-forge-guard wt-functions`. Report each total as passed/total.
- [ ] **Shellcheck the edited suites.** Run it on `tests/agent-instructions.test.sh` and
  `tests/claude-settings.test.sh`. They must show no warning that
  `git show main:<path> | shellcheck -` does not also show.
- [ ] **Preview the renders without applying.**
  - The zsh `chezmoi` wrapper refuses previews off main, and on main its clone hits a sandbox
    denial. `command` bypasses the wrapper.
  - `--source` renders this worktree, not the shared checkout. Sandboxed is fine (Spec facts).
  - Each command is
    `command chezmoi --source /Users/michael/.local/share/chezmoi/.claude/worktrees/security-locks <verb> <target>`,
    with the path spelled out (the worktree guard refuses a computed one):
    - `cat ~/.claude/CLAUDE.md`: `global.md`, one blank line, then `## Claude Code only`; at most
      181 lines; no `## Codex only`.
    - `cat ~/.codex/AGENTS.md`: `global.md`, one blank line, then `## Codex only`; at most 161
      lines; no `## Claude Code only`.
    - `cat ~/.config/agents/GLOBAL.md`: `global.md` alone.
    - `managed` lists `.claude/skills/design-records/SKILL.md`.
    - `cat ~/.claude/agents/web-researcher.md` shows `omitClaudeMd: true`.
- [ ] **Update the memory note** `global-agent-instructions.md`, outside the repo, and its line in
  MEMORY.md. Record: the 150 cap, `codex.md` in the Codex target only, and the `design-records`
  skill.
- [ ] **Make the final commit.** Set the spec and plan Status to
  `Implemented on instruction-layer (no MR)`, add a completion banner to this plan, and fill in
  the Run notes. Then run the pre-merge cross-review and push in a Bash call of its own.
- [ ] **List Michael's rollout in the report.**
  - `chezmoi apply` once both branches are on main. `worktree-security-locks` merges first.
  - In a fresh Claude session, `/skills` lists `design-records`.
  - A new Codex thread reads the new `~/.codex/AGENTS.md`. Reviews get one at the next checkpoint.
  - Optional, not a gate: `/doctor prompt-audit` before and after, for the token change.

## Run notes

*Filled during execution: suite totals, preview results, and any table row the Task 5 review
flagged.*
