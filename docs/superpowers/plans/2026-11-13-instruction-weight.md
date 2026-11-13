# Instruction Weight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move workflow-only detail out of the dotfiles `AGENTS.md`, `claude-code.md` and the
`cross-review` skill to where it is used, without losing a rule.

**Architecture:** Text moves, no behaviour changes. Each moved sentence lands verbatim in a file
that is loaded when it binds (`tests/AGENTS.md`, `.chezmoiexternal.toml`, the `plan-run` skill, an
agent description, an `xreview` refusal). The always-loaded file keeps the rule and a pointer.
`tests/fixtures/agent-instructions/rules.tsv` pins every kept and moved rule.

**Tech Stack:** Markdown, bash test suites (`tests/*.test.sh`, run through `./tests/run.sh`),
chezmoi templates.

**Spec:** `docs/superpowers/specs/2026-11-13-instruction-weight-design.md`
**Status:** In progress

## Global Constraints

- No rule changes meaning. A sentence leaves a file only as a row of a table in this plan: kept,
  moved (where) or dropped (why).
- Moved text is copied verbatim, apart from headings and the joining words a new place needs.
- A `rules.tsv` row with `safety` = `yes` is moved or split, never removed; its terms stay whole
  sentences.
- `global.md`, `codex.md` and the bodies of `dot_claude/agents/sp-*.md` do not change.
- No guard's behaviour changes. No file under `dot_claude/` that is a guard is edited in A or B.
- This repository is public: nothing private in any moved text.
- Execute suites (`./tests/run.sh <name>`), never `bash tests/…`. Never chain after `cd`.
- Check `git branch --show-current` prints `chore/instruction-weight` before each commit.
- Commits: imperative mood, no agent attribution.
- **Cap:** the spec's goal for `AGENTS.md` is at most 205 lines, measured 201 (decided by the
  driver on Michael's delegation once Tasks 1 and 2 were measured). The assertion is added
  after Task 2, at 205.

## Review Focus

1. **A subagent edits a suite without the nested file loaded.** Nested `AGENTS.md` loading is
   documented for the main session's Read only. The root pointer must tell every agent to read
   `tests/AGENTS.md` before adding or changing a suite or the runner. Task 1 pins the pointer.
2. **A pin on a TOML comment.** The `rule` helper treats every line starting `# ` as its own
   block. A procedure step in `.chezmoiexternal.toml` that wraps over two comment lines cannot
   be pinned. Task 2 keeps each pinned step on one line.
3. **Frontmatter that stops parsing.** An unquoted `description:` breaks on `: `, ` #` or a
   leading backtick, and an agent file that fails to parse is skipped silently. Task 3 writes
   the added clauses without backticks and checks each file still lists.
4. **The rendered `CLAUDE.md` after the table goes.** The lines after the table must still
   belong to the Subagents bullet (two-space indent), or `cc-no-review-forks` finds its anchor
   in the wrong block. Task 3 previews the render.
5. **The rebase onto `fix/xreview-trust`.** That branch adds a paragraph to `AGENTS.md` Testing
   (`xreview-guard-cli`) and rewrites the skill. Task 4 places the paragraph in
   `tests/AGENTS.md` and builds C's table from the rebased skill, not from today's.

---

### Task 1: Split Testing into the root and `tests/AGENTS.md`

**Depends on:** nothing.

**Files:**
- Create: `tests/AGENTS.md`
- Modify: `AGENTS.md:114-242` (Testing), `AGENTS.md:99-112` (Layout: name `tests/AGENTS.md`)
- Modify: `tests/fixtures/agent-instructions/rules.tsv`, `tests/agent-instructions.test.sh`,
  `.scripts/test-audit/subjects.tsv`
- Possibly: `tests/missing-subject.test.sh` (see Step 6)

**Disposition** (line numbers are `AGENTS.md` at cbd9b46):

| Lines | Block | Disposition |
|---|---|---|
| 116 | intro sentence | dropped in Task 2: it repeats the Rules bullet "`tests/` holds every test suite, one `<subject>.test.sh` per script under test" |
| 118-124 | command block | kept |
| 126-131 | parallel runs | kept, as the first paragraph of the kept text below; moved: `RUN_JOBS` and its default, "an explicit `RUN_JOBS=1` … sequential order", the `# test-serial` sentence |
| 133-139 | runner lock | kept: "one per machine", who-holds-the-lock sentence, "Never wrap it in `lockf` yourself."; moved: the lock path and `RUN_SH_LOCK`, `RUN_SH_LOCK_WAIT` with exits 75 and 2, `RUN_SH_LOCKED` |
| 141-146 | execute suites | kept, as the text below; moved: "because it stubs zsh builtins", "`run.sh` executes them for this reason" |
| 148-154 | gates, exact name | kept whole |
| 156-166 | gated-suite table | kept whole |
| 168-172 | map row, `--changed` lines | kept whole |
| 174-176 | `live-write-boundary` sibling | kept whole (a prerequisite for running it) |
| 178-181 | never run the `live-*` four unsandboxed | kept whole |
| 183-185 | control for sandbox mode | kept, as the text below; moved: the "18-test regression" history |
| 187-192 | brace expansion | kept, as the text below (the parenthesis about arguments kept whole) |
| 194-198 | passed/total | kept, as the text below; moved: the "324 assertions" history |
| 200-206 | two suite gotchas | moved |
| 208-211 | cold external cache | kept whole (reads a run's result) |
| 213-218 | missing-subject guard | moved; what its exit 2 looks like in a run is kept, as "Reading a run" below |
| 220-231 | output idioms, `failed_keys`, `write-boundary-probe` | moved; how a kv suite's result reads is kept, as "Reading a run" below |
| 233-242 | `HERDR_SESSION` | moved whole as history; its rule goes to Rules in Task 2 |

Nothing else is dropped in this task.

**Kept text, exact** (wrap at 95 columns):

```markdown
Suites run in parallel and print in name order, so the verdicts do not depend on load; a
load-sensitive suite's assertion count can differ between runs (`xreview-packet` F7 slices a
20,000-file case into 8 or 9).

**The runner locks itself:** one per machine. A runner that has to wait prints on stderr who
holds the lock (arguments, checkout, minutes held), again each minute, and once it has the lock
how long it waited (`run.sh: waited 9 min for the test-run lock`). Never wrap it in `lockf`
yourself.

**Execute suites, never prefix an interpreter.** Every suite carries a correct shebang (most
bash; `chezmoi-wrapper`, `dev`, `dev-integrations`, `dev-topology`, `op-edit` and `wt-functions`
are zsh). `./tests/x.test.sh` is always right; `bash tests/x.test.sh` on a zsh suite reports
bogus syntax errors that read exactly like a regression.

**Control for sandbox mode before calling anything a regression:** compare only runs made in
the same mode.

**Never invoke suites with brace expansion.** `bash tests/live-{a,b}.test.sh` expands to
`bash a b` — only the first runs, and the skipped suite prints nothing, so the run looks like a
clean pass. Use `run.sh`, or a loop over a glob. (<the existing parenthesis, unchanged>)

**Report totals as passed/total, never "N green".** `run.sh` prints `passed/total` per suite,
judges each on its **exit status**, and cross-checks that against the counted assertions: a
suite that dies partway is reported `INCONSISTENT` instead of folded into a total.

**Reading a run.** A `????` row is not a verdict: the suite asserted nothing, or its exit
status contradicts its assertions (`INCONSISTENT`). Read the exit status the row prints and the
line `run.sh` shows under it. Exit 2 is a suite's own guard (a missing subject, an
`INCONCLUSIVE:` condition), never 1: 1 means an assertion failed. A kv suite (the `KEY=VALUE`
status of `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` and
`live-write-boundary`) encodes failures in its values and exits with the count, so it is judged
on exit status alone. A kv suite that fails a probe closes with one `failed_keys=<key>,<key>`
line; `run.sh` shows that line and any `INCONCLUSIVE:` lines under the FAIL row, never a
`KEY=VALUE` line, so no value is echoed.

**Before adding or changing a suite, a fixture or the runner, read `tests/AGENTS.md`:** it
holds the suite conventions, the runner's knobs and the suite-specific gotchas. Claude Code
loads it when it reads a file under `tests/`; a subagent and Codex read it by hand.
```

**`tests/AGENTS.md`** opens with:

```markdown
# Writing and changing suites

What binds only while a file under `tests/` is written or changed. Running suites, the gated
suites and reporting: the root `AGENTS.md`, Testing.
```

then the moved blocks verbatim under these headings, in this order: `## The runner` (parallel
knobs, `# test-serial`, lock path and variables), `## A new suite` (missing-subject guard,
output idioms and `failed_keys`, `write-boundary-probe`), `## Suite-specific` (the two gotchas,
"because it stubs zsh builtins"),
`## History` (the 18-test and 324-assertion cases, the whole `HERDR_SESSION` block).

- [ ] **Step 1: Write the failing pins.** Add to `rules.tsv` (tab-separated; columns id, file,
  anchor, safety, terms, note):

  | id | file | anchor | safety | terms |
  |---|---|---|---|---|
  | `a-tests-pointer` | `AGENTS.md` | ``read `tests/AGENTS.md` `` | no | `adding or changing a suite;the runner;a subagent and Codex read it by hand` |
  | `a-live-sandboxed` | `AGENTS.md` | ``**Never run `live-agent-auth` `` | yes | the block's three sentences, whole, `;`-separated |
  | `a-exact-name` | `AGENTS.md` | `only an exact suite name lifts it` | no | `A substring filter` |
  | `a-execute` | `AGENTS.md` | `**Execute suites, never prefix an interpreter.**` | no | ``./tests/x.test.sh` is always right`` |
  | `a-passed-total` | `AGENTS.md` | `**Report totals as passed/total` | no | `exit status;INCONSISTENT` |
  | `a-reading-run` | `AGENTS.md` | `**Reading a run.**` | no | `is not a verdict;INCONSISTENT;Read the exit status the row prints;judged on exit status alone;failed_keys=` |
  | `a-map-row` | `AGENTS.md` | `gets its map row in the same commit` | no | `quote those lines in the pre-merge report` |
  | `t-missing-subject` | `tests/AGENTS.md` | `must fail loudly, not silently pass` | no | `exits 2 if not;Exit 2, never 1` |
  | `t-kv` | `tests/AGENTS.md` | `Two output idioms exist` | no | `failed_keys=;so no value is echoed` |

  The line cap is added in Task 2. In `tests/agent-instructions.test.sh`, add `$SRC/AGENTS.md`
  and `$SRC/tests/AGENTS.md` to the suite's "missing file under test" loop.

- [ ] **Step 2: Run it and see it fail.**
  Run: `./tests/run.sh agent-instructions`
  Expected: exit 2, `missing file under test: …/tests/AGENTS.md`. Then `touch tests/AGENTS.md`
  and rerun: FAIL on the three new rows only: `a-tests-pointer`, `t-missing-subject`, `t-kv`.

- [ ] **Step 3: Write `tests/AGENTS.md`** from the Disposition table, verbatim.

- [ ] **Step 4: Rewrite `AGENTS.md` Testing** to the kept blocks, in their present order, with
  the exact text above; add `tests/AGENTS.md` to the Layout tree's `tests/` line.

- [ ] **Step 5: Check nothing was lost.** Every sentence of old lines 116-242 is in the new
  root or in `tests/AGENTS.md`:
  Run: `git show HEAD:AGENTS.md | sed -n '114,242p' | tr -s ' \n' '\n' | sort -u > "$TMPDIR/old.words"`
  and `cat AGENTS.md tests/AGENTS.md | tr -s ' \n' '\n' | sort -u > "$TMPDIR/new.words"`, then
  `comm -23 "$TMPDIR/old.words" "$TMPDIR/new.words"`.
  Expected: no output except words from the sentences reworded above ("Comparing", "believable",
  and the like, which must then appear in `## History`: so in practice empty). Explain any word
  that remains in the report.

- [ ] **Step 6: Map and guard rows.** Add `AGENTS.md` and `tests/AGENTS.md` to
  `.scripts/test-audit/subjects.tsv` as `prose`, suite `agent-instructions`, in path order,
  matching the neighbouring rows' columns. `tests/missing-subject.test.sh` hides one file per
  suite: add a row only if its table lists one per guarded file rather than one per suite (read
  its header; say which in the report).

- [ ] **Step 7: Run the suites.**
  Run: `./tests/run.sh agent-instructions missing-subject run`
  Expected: all pass; quote the `passed/total` lines.

- [ ] **Step 8: Commit.** `git add AGENTS.md tests/AGENTS.md tests/fixtures/agent-instructions/rules.tsv tests/agent-instructions.test.sh .scripts/test-audit/subjects.tsv` (plus `tests/missing-subject.test.sh` if changed);
  message `Move suite-writing detail to tests/AGENTS.md`.

### Task 2: Rules: the bump procedure, the `.scripts` inventory, the herdr rule

**Depends on:** Task 1 (same files: `AGENTS.md`, `rules.tsv`).

**Files:**
- Modify: `AGENTS.md:55-83` (the `.scripts/` and skills bullets), add one Rules bullet
- Modify: `.chezmoiexternal.toml` (comment block at the top)
- Modify: `tests/fixtures/agent-instructions/rules.tsv`, `.scripts/test-audit/subjects.tsv` if
  `.chezmoiexternal.toml` has no `agent-instructions` entry

**Disposition:**

| Lines | Sentence | Disposition |
|---|---|---|
| 71-73 | pinned externals, `symlink_`, re-include | kept |
| 73-75 | `skill-updates.sh` weekly, `skill-update` issues; closing one declines the release | kept |
| 75-83 | "A bump reads the upstream diff first … `Closes #<issue>`." | moved to `.chezmoiexternal.toml` |
| 55-63 | helpers are not `run_once_`; the managed-settings installer and who runs it | kept |
| 63-65 | `measure-interventions.py` …, `process-replay.py` … `xreview-replay.py` are the replay-experiment harnesses | dropped as inventory (the files and `docs/superpowers/specs/2026-11-02-replay-set-design.md` state it), except "its package `process_replay/`, plain 644 modules", kept as a clause of the mode sentence |
| 66 | `skill-updates.sh` is non-interactive too and runs weekly | dropped: the skills bullet says it |
| 66-68 | mode 755, git stores only the exec bit | kept |

The skills bullet ends: "To bump one, follow the procedure at the top of
`.chezmoiexternal.toml`."

New Rules bullet, exact, placed after the `tests/` bullet:

```markdown
- `layout.sh`, `tab-goto.sh` and `phase.sh` thread `--session` into every herdr call and never
  call `command herdr` bare: inside a Herdr pane `HERDR_SOCKET_PATH` outranks `HERDR_SESSION`,
  so a bare call targets the pane's own session. `layout.sh` starts a server whenever
  `HERDR_SESSION` is set, even inside a pane. History: `tests/AGENTS.md`.
```

The comment block in `.chezmoiexternal.toml` opens `# Bumping a pinned skill:` and gives the
moved sentences as numbered steps, each pinned step on ONE comment line (Review Focus 2).

- [ ] **Step 1: Write the failing pins** in `rules.tsv`:

  | id | file | anchor | safety | terms |
  |---|---|---|---|---|
  | `a-bump-pointer` | `AGENTS.md` | `Third-party skills are pinned` | no | ``follow the procedure at the top of `.chezmoiexternal.toml`;Closing one without a bump declines that release`` |
  | `ext-bump-scan` | `.chezmoiexternal.toml` | `agent-text-scan --diff` | yes | the whole moved sentence, on one comment line: ``A bump reads the upstream diff first and runs `agent-text-scan --diff` on it: an `invisible` finding stops the bump until Michael has seen it, and any other finding that matters goes in the commit message.`` |
  | `ext-bump-warm` | `.chezmoiexternal.toml` | `managed >/dev/null` | no | `outside the sandbox` |
  | `ext-bump-closes` | `.chezmoiexternal.toml` | `Closes #<issue>` | no | `commit message` |
  | `a-herdr-bare` | `AGENTS.md` | ``never call `command herdr` bare`` | no | `--session;HERDR_SOCKET_PATH` |

- [ ] **Step 2: Run** `./tests/run.sh agent-instructions`; expected: those five rows FAIL.
- [ ] **Step 3: Make the edits** per the Disposition table.
- [ ] **Step 4: Check the externals file still parses and nothing else moved.**
  Run: `command chezmoi --source /Users/michael/.local/share/chezmoi-chore-instruction-weight managed`
  Expected: lists `.agents/skills/clarity/SKILL.md` as before (same count of lines as on main).
  If it exits 2 for a cold cache, that is not a failure of this task: say so.
- [ ] **Step 5: Run** `./tests/run.sh agent-instructions agent-skills skill-updates`; expected:
  all pass. Then add the cap assertion to `tests/agent-instructions.test.sh`, beside the
  fragment caps and in their shape: `AGENTS.md is at most 205 lines`, reading `$SRC/AGENTS.md`;
  see it pass, and see it fail with the limit temporarily set to 100 (restore it). Quote the totals.
- [ ] **Step 6: Commit**, message `Put the skill-bump procedure in the externals file`.

### Task 3: `claude-code.md`: the Subagents table and the plan workspace

**Depends on:** Task 2 (`rules.tsv`).

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md:15-29`
- Modify: `dot_claude/agents/sp-architect.md`, `sp-standard.md`, `web-researcher.md`
  (frontmatter `description:` only)
- Modify: `dot_claude/skills/plan-run/SKILL.md` (description; new last section)
- Modify: `tests/fixtures/agent-instructions/rules.tsv`

**Disposition:**

| Text | Disposition |
|---|---|
| table row `sp-mechanical`: tasks from a clear plan | dropped: its description says "Implementation from a well-specified plan task" |
| row `sp-standard`: integration, debugging, fix rounds, plan-run controllers, merges | dropped: in its description, after "merge-conflict resolution" becomes "merges and merge-conflict resolution" |
| row `sp-reviewer`: cold diff review, every per-task review and re-review | dropped: its description says it |
| row `sp-architect`: …; a fix only after an `sp-standard` attempt at it failed | description's last sentence becomes "Implementation only as an escalation, as a fix only after an sp-standard attempt at it failed." |
| row `web-researcher`: all web research, a skill's researchers included: … | description opens "All web research on untrusted pages, a skill's researchers included." The rest is already there |
| "Use the named types …", "Go up a tier …", "Reviews never run as forks …" | kept, as one bullet |
| "Delete a finished `.superpowers/sdd/<plan>` workspace with `sdd-clean <workspace>`, never `rm -rf`." | moved verbatim to `plan-run`, new last section `## After the run` |
| "Other deletions and container removals wait … as commands." | kept; the bullet becomes: "**Cleanup never blocks a run.** Deletions and container removals wait until the run's work is done and go together, or into the final report as commands. A plan workspace: the `plan-run` skill." |

`plan-run` description becomes: `Use when running an implementation plan as its controller.
Its rules take precedence over superpowers:subagent-driven-development and its templates.`

- [ ] **Step 1: Change the pins** in `rules.tsv` (the test fails first):
  - `cc-table-standard`: file `dot_claude/agents/sp-standard.md`, anchor `name: sp-standard`,
    terms `fix rounds;plan-run controllers;merges and merge-conflict resolution`.
  - `cc-table-web`: file `dot_claude/agents/web-researcher.md`, anchor `name: web-researcher`,
    terms `holds only WebFetch;All web research;a skill's researchers included`.
  - new `ag-architect-fix`: `dot_claude/agents/sp-architect.md`, anchor `name: sp-architect`,
    no, terms `a fix only after an sp-standard attempt at it failed;final whole-branch review`.
  - `cc-cleanup` (safety yes): terms become the one kept sentence, whole, plus
    ``A plan workspace: the `plan-run` skill.``
  - new `pr-sdd-clean` (safety yes): `dot_claude/skills/plan-run/SKILL.md`, anchor
    `sdd-clean <workspace>`, terms the moved sentence, whole.
  - `cc-subagents` and `cc-no-review-forks`: unchanged, and must still pass.
- [ ] **Step 2: Run** `./tests/run.sh agent-instructions`; expected: the five changed rows FAIL.
- [ ] **Step 3: Make the edits.** Keep each `description:` on one line, with no `: `, ` #` or
  backtick added to an unquoted value. Then check every unquoted description:
  Run: `awk '/^description: [^"]/ { v = $0; sub(/^description: /, "", v); if (v ~ /: | #|^`/) print FILENAME ": " v }' dot_claude/agents/*.md dot_claude/skills/*/SKILL.md dot_agents/skills/*/SKILL.md`
  Expected: no output.
- [ ] **Step 4: Preview the render.**
  Run: `command chezmoi --source /Users/michael/.local/share/chezmoi-chore-instruction-weight cat /Users/michael/.claude/CLAUDE.md`
  Expected: the Subagents bullet is one bullet of four lines with no table;
  `wc -l .chezmoitemplates/agents/claude-code.md` prints 41 or 42.
- [ ] **Step 5: Run** `./tests/run.sh agent-instructions claude-settings agent-skills live-feedback-skill review`.
  Expected: all pass; quote the totals. A `????` row for a cold cache is not a failure; say so.
- [ ] **Step 6: Commit**, message `State agent routing in the agent descriptions`.

### Hold point: A and B

The controller (not a task): full default suite once, the sandboxed real-system run
(`command chezmoi --source <checkout> apply --dry-run --verbose`), the final whole-branch review,
`./tests/run.sh --changed`, Codex pre-merge on `main...chore/instruction-weight`, push, and the
report to the driver with the measured table. Then wait for the driver's word on
`fix/xreview-trust`.

### Task 4: Rebase and write C's table (controller)

**Depends on:** the driver's word that `fix/xreview-trust` is on main.

- [x] Rebase onto `origin/main` (done, 4c35ad4). The `xreview-guard-cli` paragraph that branch
  added to `AGENTS.md` Testing was split by the move test: what its exit 2 means reads a run's
  result and stays in the root, joined to the cold-cache paragraph (as the plan review ruled
  for that paragraph); "the pin in the suite is updated in the change that weighs the new
  command or flag" binds while changing the suite and moved to `tests/AGENTS.md`,
  `## Suite-specific`. Root: 204 lines.
- [ ] Append `## Appendix C` to this plan: one row per sentence or list item of the rebased
  `dot_claude/skills/cross-review/SKILL.md` (kept / moved to which `xreview` or guard message /
  dropped as rationale, with the rule it explained), and one row per `die` in
  `dot_local/bin/executable_xreview` that the skill's two refusal lists name, with its closing
  clause: the agent's action, or `Michael's call: report this and stop.` A refusal is marked
  Michael's call exactly when today's escalation list names it.
- [ ] If the kept rows exceed 150 lines, or a moved sentence needs a guard's deny message
  changed, stop: that goes to Michael before any edit.
- [ ] Replace Tasks 5 to 7 below with full steps written from the appendix, commit, and send
  the plan to Codex at the `plan` checkpoint. Execution of C starts once it approves.

### Tasks 5 to 7: C (outline; steps written in Task 4)

- **Task 5, refusals.** `dot_local/bin/executable_xreview`: each listed `die` gets its closing
  clause. `tests/xreview.test.sh`: each escalation refusal ends with the Michael's-call clause,
  and no wait-and-retry refusal does. **Depends on:** Task 4.
- **Task 6, the skill.** `dot_claude/skills/cross-review/SKILL.md` rewritten from the
  appendix's kept rows; `rules.tsv` rows `cr-*` unchanged and passing; a cap of 150 lines in
  `tests/xreview-skill.test.sh`. **Depends on:** Task 5 (the skill points at the clauses).
- **Task 7, the skill's consistency suite.** `tests/xreview-skill.test.sh`: a check whose
  sentence moved to a message now reads the message; one whose sentence was dropped as
  rationale goes, each listed in the appendix. **Depends on:** Task 6.

Then the same hold-point steps as above; `--changed` runs the heavy `xreview` suite.
