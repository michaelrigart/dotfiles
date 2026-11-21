# Workflow v2, increment 3: the `merge-state` tool — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `feat/workflow-v2-switch`)

**Goal:** The first three fields of the merge state (`Merge`, `Checked`, `Check by hand`) are
printed by a tool with a suite, and the `merge-request` skill only says to run it and paste its
output.

**Architecture:** One read-only script, `merge-state`, beside `change-facts` and built on its
pattern. It measures what a tool on the machine records (the review ledger's gate decision,
`change-facts`, the `Checks` line on origin's default branch, the paths of the change) and takes
every other fact as a required argument that it prints. It gates nothing. The skill's prose
conditions and their pins are replaced by the tool's `--help` and its suite.

**Tech Stack:** Python 3.9 (`/usr/bin/python3 -I`), `/usr/bin/git`; a bash suite; Markdown
skills; `rules.tsv` pins.

**Spec:** `docs/superpowers/specs/2026-11-20-workflow-v2-design.md`, subsection "The
`merge-state` tool" under "Amendments during implementation" (signed 2026-11-21). It is the
source for every rule below; where this plan and it disagree, stop and report.

**Size:** about 250 lines of code and 350 of tests, as the amendment estimates.

## Global Constraints

- The tool gates nothing: no guard, hook, script or setting reads its output, and nothing in
  `dot_claude/` or `xreview` changes. `dot_claude/xreview-ledger.py` is called, never edited.
- Caps, measured with `wc -l`: `global.md` 150, `claude-code.md` 50, `codex.md` 30, this
  repository's `AGENTS.md` 240, the `cross-review` skill 250. None of those files changes here.
- A pin in `tests/fixtures/agent-instructions/rules.tsv` is replaced, never dropped: a safety
  row on a sentence that leaves the skill is replaced by a case in `tests/merge-state.test.sh`,
  and the commit message names each replaced row and its case.
- No comment in the script beyond its module docstring and one-line docstrings, on the pattern
  of `change-facts`. No agent attribution anywhere.
- Implementers run the suites for what they changed and the linters, never the full suite, and
  do not commit: the controller commits each task.
- Read `tests/AGENTS.md` before writing or changing a suite.

## Tasks

### Task 1: The `merge-state` script and its suite

**Depends on:** nothing

**Files:**
- Create: `dot_local/bin/executable_merge-state` (mode 755)
- Create: `tests/merge-state.test.sh` (mode 755, bash)
- Modify: `.scripts/test-audit/subjects.tsv` (a row for the script, on the pattern of the
  `executable_change-facts` row)
- Modify: `tests/missing-subject.test.sh` (a row for the new suite's guard)
- Test: `tests/merge-state.test.sh`, `tests/missing-subject.test.sh`, `tests/test-audit`'s
  drift check (`./tests/run.sh test-audit` only if the map row's form is in doubt)

**Interface.**

```
merge-state <destination> <head> --claude-review <type>:<commit> | none
    --suite <passed>/<total> | none  --lint pass | fail | not-run | none
    --ci green | pending | failed | none
    --spec <path> | none  --boundary <what> | none  --check <what> | none
    [--hold <reason>]
merge-state --help
```

- Shebang `#!/usr/bin/python3 -I`. Git is `/usr/bin/git` with the same global options and the
  same from-scratch environment as `change-facts` (copy its `ENV` and `GIT`; do not import it).
- `<destination>` is a branch name; the tool reads `origin/<destination>` and never fetches.
  `<head>` is any revision; it is resolved to its 40-character commit id.
- Every option except `--hold` is required. `--boundary` and `--check` repeat; `none` beside
  another value of the same option is a usage error. `<type>` is `sp-reviewer` or
  `sp-architect`. `<passed>/<total>` is two non-negative integers.
- Exit 0 whenever a block is printed, whatever its state. Exit 2, one `merge-state: …` line on
  stderr and nothing on stdout for: a usage error (a missing or malformed option included), a
  directory that is not a git repository, a `<head>` or `--claude-review` commit that names no
  commit. `--help` prints the usage and the condition table below, and exits 0.
- Every declared text (`--boundary`, `--check`, `--hold`, the `--spec` path) is printed with
  control characters, format characters and line breaks shown as `?` (the `printable` function
  of `change-facts`, tabs not kept).

**Measured facts.**

- **Codex approval.** Run `/usr/bin/python3 <ledger> decide . <destination>
  origin/<destination> <head-id>`, where `<ledger>` is `$XREVIEW_LEDGER` or
  `~/.claude/xreview-ledger.py`, with `HOME` and `XDG_STATE_HOME` passed through. Its stdout is
  one JSON object. `allow` true: the nonce is the `xr-…` token of `reason`. Otherwise the item
  text is `reason`. No ledger script, a non-JSON answer or no `origin/<destination>`: not
  approved, with an item that names what could not run.
- **Sizes.** Run the sibling `change-facts` (`change-facts`, else `executable_change-facts`, in
  the script's own directory) with `origin/<destination>...<head-id>` and parse `code: <n>
  lines`, `test: <n> lines`, `test lines deleted: <n>` and the indented lines under `dependency
  lines:`. It missing or failing is a `check first` item that names it, and the sizes print as
  `unknown`.
- **Checks.** The default branch is the target of `refs/remotes/origin/HEAD`. Read `AGENTS.md`
  from it (`git cat-file`), and take the single line that matches
  `**Checks:** strong|weak — <command>; CI required to merge: yes|no`. No default branch, no
  file, no such line or more than one: `weak`, CI not required.
- **Checks line touched.** Any added or deleted line of the change, in a file named
  `AGENTS.md`, that starts with `**Checks:**`.
- **Instruction text touched.** A changed path (`git diff --name-only --no-renames -z
  origin/<destination>...<head-id>`) whose base name is `AGENTS.md`, `CLAUDE.md` or `SKILL.md`;
  or that starts with `.chezmoitemplates/agents/`; or that has a directory `agents` directly
  under a directory named `.claude`, `dot_claude`, `.codex` or `dot_codex`.
- **`--spec`.** The path must start with `docs/superpowers/specs/` and exist at the head; one
  that does not is a usage error.

**State and output.** `hold` when `--hold` is given. Otherwise `check first` when any row
holds; each row that holds prints one numbered item, in this order. Otherwise `safe to merge`,
or `safe to merge once CI is green` with `--ci pending`.

| # | Condition | Item |
|---|---|---|
| 1 | the ledger does not approve this change for this destination | `Codex pre-merge: <reason>` |
| 2 | `--claude-review none`, or its commit is not the head | `Claude review: none`, or `Claude review read <id>, not the head` |
| 3 | `--suite none`, passed < total, or total 0 | `suite: <value>` |
| 4 | `--lint fail` or `not-run` | `lint: <value>` |
| 5 | `--ci failed`; or `--ci none` where the `Checks` line requires CI | `CI: <value>` |
| 6 | the tier is `weak` | `no Checks: strong line on origin's default branch: the missing check` |
| 7 | the change touches a `Checks` line | `the change edits a Checks line: <file>` |
| 8 | the change touches instruction text | `agent instruction text: <files, comma-separated>` |
| 9 | any `--boundary` but `none` | `safety boundary: <what>`, one item each |
| 10 | any dependency line | `new dependency lines:` and the lines as `change-facts` prints them |
| 11 | code over the limit (2000 with `--spec`, 150 with `--spec none`), or size unknown | `size: <code> code lines, over <limit>` |
| 12 | test lines deleted not 0 | `<n> test lines deleted: look at each` |
| 13 | any `--check` but `none` | the text as given, one item each |

```
**Merge:** <safe to merge | safe to merge once CI is green | check first | hold: <reason>>
**Checked:** Codex pre-merge <approve <nonce> on <head-id> into <destination> | none>; Claude review <approve (<type>, on <commit-id>, whole range) | none>; suite <value>; lint <value>; CI <value>; Checks <strong | weak>; size <code> / <test> lines; tests deleted <n>; new dependencies <none | <n> lines>; spec <path | none>; safety boundary <none | the values, comma-separated>
**Check by hand:** nothing
```

With items, the third line is `**Check by hand:**` followed by `1. …` lines. Under `hold` the
items of the rows that hold are still listed.

- [ ] **Step 1: The suite first.** `tests/merge-state.test.sh` on the pattern of
  `tests/change-facts.test.sh` (guard exit 2 when the script is missing, `_pass`/`_fail`, a
  temp dir, a scratch git config). Fixtures: a bare `origin` with `main` and
  `refs/remotes/origin/HEAD` set in the clone, an `AGENTS.md` with a `strong` line on `main`,
  a head with one small code change; a stub ledger script (set through `XREVIEW_LEDGER`) that
  prints a JSON answer chosen per case. Cases:
  - the all-clear case prints exactly the three lines of `safe to merge`, exit 0;
  - `--ci pending` on it prints `safe to merge once CI is green`;
  - one case per row 1 to 13, each changing one thing from the all-clear case and asserting
    `check first`, the row's item, and exit 0; row 2 twice (`none`; another commit); row 3
    three times; row 5 twice (`failed`; `none` with CI required); row 6 three times (a `weak`
    line; no line; a `strong` line only on the head, not on origin's `main`); row 8 once per
    path kind; row 11 twice (151 lines without a spec; 151 lines with a spec is clear);
  - two rows holding at once list both items in table order, numbered;
  - `--hold` prints `hold: <reason>` and still lists the items;
  - each required option left out in turn, `none` beside a value, a bad `<type>`, a bad suite
    figure, a `--spec` path outside `docs/superpowers/specs/` or absent at the head, an unknown
    head, a directory that is no repository: exit 2, one stderr line, no stdout;
  - no ledger script, a ledger that prints no JSON, no sibling `change-facts`, no
    `origin/<destination>`: `check first` with the naming item, never exit 2 and never `safe`;
  - a control character and a line break in `--check` and `--hold` print as `?`;
  - the caller's `GIT_DIR` and a `git` first on `PATH` do not change the output;
  - `--help` exits 0 and holds each of the thirteen condition texts.
- [ ] **Step 2: Run it and watch it fail** for the missing script (exit 2), then with an empty
  script (assertions fail).
- [ ] **Step 3: The script**, until the suite passes. Then the revert check on three cases of
  your choice from rows 1, 8 and 12: break the row in the script, see its case fail, restore.
- [ ] **Step 4: The map row and the guard row.** Add the `subjects.tsv` row and the
  `missing-subject` row. `missing-subject` copies only tracked files, so stage the two new
  files first (`git add dot_local/bin/executable_merge-state tests/merge-state.test.sh`,
  staging only, no commit); then run `./tests/missing-subject.test.sh` and
  `./tests/merge-state.test.sh`.
- [ ] **Step 5: Run it the way its user will**, in this checkout:
  `./dot_local/bin/executable_merge-state main HEAD --claude-review none --suite none --lint
  not-run --ci none --spec docs/superpowers/specs/2026-11-20-workflow-v2-design.md --boundary
  none --check none`, and report the output.

### Task 2: Signed exceptions to the ceiling

**Depends on:** nothing

**Files:**
- Modify: `dot_agents/skills/design-records/SKILL.md` (the "passes its estimate by half"
  paragraph)
- Modify: `dot_claude/skills/plan-run/SKILL.md` (the `change-facts` paragraph under "Before the
  final review")
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (rows `dr-outgrown`, `pr-change-facts`)
- Test: `tests/agent-instructions.test.sh`, `tests/agent-skills.test.sh`,
  `tests/xreview-skill.test.sh`

- [ ] **Step 1: Pins first.** `dr-outgrown` and `pr-change-facts` each gain the term for the
  exception; run `./tests/agent-instructions.test.sh` and see both rows fail.
- [ ] **Step 2: `design-records`.** After "…That is a spec change, so it goes to Michael." add:
  "Where the signed spec records that the increment cannot be split, passing the ceiling does
  not stop the line; passing its estimate by half still does."
- [ ] **Step 3: `plan-run`.** In the `change-facts` paragraph, after "…because it changes the
  spec." add: "An increment whose signed spec records that it cannot be split is not stopped
  by the ceiling, only by its estimate."
- [ ] **Step 4:** Run the three suites.

### Task 3: The skill says to run the tool

**Depends on:** Task 1 (the command, its options and its output are quoted in the skill); Task
2 (both edit `rules.tsv`)

**Files:**
- Modify: `dot_agents/skills/merge-request/SKILL.md` (the dependency bullet's last two
  sentences; the section "The merge state")
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (rows `mr-dependency`,
  `mr-state-block`, `mr-state-safe`, `mr-state-check-first`, `mr-state-sources`; new rows)
- Modify: `tests/agent-skills.test.sh` only if a line there pins text this task changes
- Test: `tests/agent-instructions.test.sh`, `tests/agent-skills.test.sh`

- [ ] **Step 1: Pins first.** Replace `mr-state-safe`, `mr-state-check-first` and
  `mr-state-sources` with safety rows on the new bullets below (`mr-state-tool`,
  `mr-state-declared`, `mr-state-no-tool`), update `mr-state-block` to the new block and
  `mr-dependency` to the new sentence; keep `mr-state-above`, `mr-state-hold`,
  `mr-state-what`. Run the suite and see the new rows fail.
- [ ] **Step 2: The block** becomes the one in Task 1's "State and output", wrapped as the
  skill wraps it, with the six labels and `After merge`, `What and why`, `Evidence` unchanged.
- [ ] **Step 3: The bullets.** Remove the `safe to merge` bullet, the `check first` bullet and
  "Where each `Checked` fact comes from". In their place, before `hold`:
  - **`merge-state` writes the first three fields.** Run it in the checkout after the pre-merge
    review and the last suite run, with the command of Task 1's Interface quoted in a code
    block, and paste what it prints unchanged. Never write or edit `Merge`, `Checked` or `Check
    by hand` by hand. Run it again after every new commit: its output names the head it
    measured. `merge-state --help` lists every condition of `check first`; `safe to merge` is
    what remains when none holds. You add `After merge`, `What and why` and `Evidence`.
  - **Every option is a fact you declare, and every one is required.** Give what is true, and
    `none` or `not-run` where nothing ran; never the value that reads best. `--claude-review`:
    the type and the commit of an approving `sp-reviewer` or `sp-architect` run that read the
    whole range, never the author session's own reading; a run on a later fix commit alone
    does not count. `--suite`: the totals of the repository's pre-merge suite on this head,
    from its own output. `--lint`: the linters' outcome on this head, `none` only where the
    repository has no linter outside its suite. `--ci`: the forge's state for this head, read
    with `gh pr checks`, `glab ci status` or `az pipelines runs list`. `--spec`: the signed
    spec the change belongs to. `--boundary`: each safety boundary the change touches, as
    Sizing lists them, and each line the change adds to a dependency manifest that
    `change-facts` does not know. `--check`: each thing that needs Michael's eyes or hands
    before the merge, and each ruling waiting for him.
  - **Without the tool** (not installed, or it exits 2 and you cannot fix the call), the state
    is `check first` and `Check by hand` says why. Never write `safe to merge` yourself.
- [ ] **Step 4: The dependency bullet.** Its last two sentences become: "`merge-state` lists
  every line `change-facts` prints under `dependency lines`; give any other line the change
  adds to a dependency manifest the command does not know as a `--boundary`. Either forces
  `check first`."
- [ ] **Step 5: "What it is"** keeps its text; "The state is the author's summary of recorded
  facts" becomes "The state is `merge-state`'s summary of measured and declared facts". Update
  its pin's term.
- [ ] **Step 6:** Run both suites; `command chezmoi --source <checkout> cat
  ~/.agents/skills/merge-request/SKILL.md` renders (find the real target with
  `command chezmoi --source <checkout> managed | rg merge-request`).

### Task 4: The records

**Depends on:** Tasks 1 to 3. It comes before the final whole-branch review and Codex's
pre-merge review, so both read the commit that merges; a fix round after them needs no further
record change.

**Files:**
- Modify: `docs/superpowers/specs/2026-11-20-workflow-v2-design.md` (Status)
- Modify: this plan (Status)

- [ ] In one commit after Task 3 and the full suite run, before the final review: the spec's
  status `Implemented`, citing branch `feat/workflow-v2-switch` (the PR number is added by a
  later change, as the design-record rules allow); this plan `Implemented (completed <date> on
  branch feat/workflow-v2-switch; do not run again)`. The controller does this itself.
