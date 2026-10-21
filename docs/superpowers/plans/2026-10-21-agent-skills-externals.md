# Agent skills as pinned chezmoi externals: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented on `feat/agent-skills`. Do not run it again; the spec's Errata section
records what review rounds changed after this plan was approved.

**Goal:** Install Clarity for Claude Code and Codex as a pinned chezmoi archive external,
and report new upstream releases as GitHub issues from a weekly workflow.

**Architecture:**
- **Install:** one archive external puts the skill in `~/.agents/skills/clarity` (Codex reads
  it), and a managed relative symlink exposes it in `~/.claude/skills`.
- **Updates:** a Bash 3.2 script compares each pin with the upstream's latest release and,
  with `--open-issues`, files deduplicated issues. A minimal workflow runs it weekly.
- **Cold cache:** three existing suites stop misreporting a cold external cache as missing
  allowlist entries.

**Tech Stack:** chezmoi 2.73.3 externals, Bash 3.2 (macOS `/bin/bash`), `gh` CLI, GitHub
Actions.

**Spec:** `docs/superpowers/specs/2026-10-21-agent-skills-externals-design.md` (Approved).
Executors read it alongside this plan.

## Global Constraints

- **Public repository:** no secrets, no third-party skill files committed. Only the upstream
  name and a commit SHA appear.
- **Shell:** scripts are Bash 3.2 compatible (no associative arrays, `mapfile`, `${x,,}`).
  `.scripts/` and `tests/` files are mode 755 with a correct shebang.
- **Suites:** they live in `tests/<subject>.test.sh`. Each prints `  PASS: …` or `  FAIL: …`
  lines, ends with `RESULT: <n> passed, <m> failed`, exits non-zero on any failure, and exits
  2 when its subject is missing. Run suites by executing them, never as `bash x.test.sh`.
- **The pin:** `https://github.com/addyosmani/clarity/archive/e27ceeff60368cf6966b4ea00a5b9b36418ee9a0.tar.gz`,
  with the tag comment `# v0.2.1`.
- **Workflow action:** `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`.
- **Workflow permissions:** exactly `contents: read` and `issues: write`.
- **Issue label:** `skill-update`. Issue title: `Skill update: <name> <new label>`.
- **Warm-cache command, verbatim:** `command chezmoi --source <checkout> managed >/dev/null`,
  run outside the sandbox.
- **Shared checkout:** re-check `git branch --show-current` is `feat/agent-skills` right
  before every commit.

## Review Focus

1. **A bump to a release that moved `SKILL.md`:** the include list then installs no skill.
   The issue checklist and the AGENTS.md bullet tell the bumper to confirm, after warming,
   that `command chezmoi managed` lists `.agents/skills/<name>/SKILL.md`. Task 3 asserts the
   issue body carries that line.
2. **A local run on macOS `/bin/bash` 3.2:** a Bash 4 construct passes on the CI runner and
   breaks here. The Task 3 suite invokes the script with `/bin/bash`.
3. **GitHub API failure in a scheduled run** (rate limit, 5xx): the result must be exit 2,
   a failed run and no issue, never "up to date". Task 3 tests a failing `gh`.
4. **An entry with no tag comment:** the display falls back to the short SHA. Task 3 tests
   it.
5. **A pending issue for an older release when a newer one ships:** a new issue opens and
   the old one is left alone. Task 3 tests a title that differs only in the tag.

## Controller steps (not tasks)

These are the session's own steps, not delegated tasks.

- **Before Batch A:** set the spec's `**Status:**` to `In progress` and commit it.
- **After Batch A is committed:** warm chezmoi's cache, unsandboxed, with
  `command chezmoi --source /Users/michael/.local/share/chezmoi managed >/dev/null`. Then
  check `ls ~/.cache/chezmoi/external | wc -l` grew. Without it, `codex-config`,
  `claude-settings` and `live-feedback-skill` fail in the sandbox.
- **After each batch:** run the full suite once with `./tests/run.sh` (sandboxed) and record
  passed/total.
- **After Batch B:** run `.scripts/skill-updates.sh` live (sandboxed, real `gh`). Expect
  `current: clarity v0.2.1` and exit 0.
- **Final pre-merge commit:** set the spec's and this plan's status to `Implemented`.

## Batches

| Batch | Tasks | Run together because |
|---|---|---|
| A | 1, 3 | the files are disjoint, and neither suite loads the other's files |
| B | 2, 4 | the files are disjoint; Task 2's suites read `.chezmoiignore`, which only Task 1 changes |

---

### Task 1: Clarity external, Claude Code symlink, ignore entries, external suite

**Depends on:** none.

**Files:**
- Create: `.chezmoiexternal.toml`
- Create: `dot_claude/skills/symlink_clarity`
- Modify: `.chezmoiignore`. Add `!.claude/skills/clarity` after the `live-feedback`
  re-include block (about line 94). Add `.github/` after the `.scripts/` entry (about line
  19), with a one-line comment that it holds CI workflows and is never deployed.
- Create: `tests/agent-skills.test.sh` (mode 755)

**Interfaces:**
- **Produces the entry format** that Task 3 parses and Task 4 documents:
  - a header line `[".agents/skills/<name>"]`
  - 4-space-indented `key = value` lines
  - an optional `# vX.Y.Z` comment on the line directly above `url = "…"`
- **Produces** `dot_claude/skills/symlink_<name>`, holding exactly
  `../../.agents/skills/<name>` plus a newline.
- **Produces** `tests/agent-skills.test.sh`, which Task 2 extends with a section.

**Steps:**

- [ ] **Step 1: Write `tests/agent-skills.test.sh`.**

  **Setup.**
  - Shebang `#!/usr/bin/env bash`, `set -uo pipefail`, and `SRC` as the repository root.
  - Exit 2 when `$SRC/.chezmoiexternal.toml` or `chezmoi` (`command -v chezmoi`) is missing.
  - `T=$(mktemp -d "${TMPDIR:-/tmp}/agent-skills.XXXXXX")`, cleaned on EXIT.
  - Define `_pass`, `_fail` and the closing `RESULT` line as in `tests/codex-config.test.sh`.
  - **Entries:** every `[".agents/skills/<name>"]` header; zero entries is a FAIL.
  - **The parser:** a narrow awk/sed over the section, up to the next `[` header, that
    ignores `#` comment lines.

  **Static checks** as functions `static_ok <toml> <name>`, returning 0 or 1 and printing the
  reason on failure:
  - `type = "archive"`
  - the URL matches
    `^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/archive/[0-9a-f]{40}\.tar\.gz$`
  - `refreshPeriod` is absent, or `0`

  **The behaviour harness**, as `behaviour_ok <toml> <ignore-file> <symlink-src-dir> <name>`,
  returning 0 or 1 and printing the first failing check. Steps 1 to 4 build the scratch
  source and destination; steps 5 to 9 are the checks.

  1. **Scratch source.** Build `$T/case-N/src` from the given `.chezmoiignore`, the given
     `dot_claude/skills/symlink_<name>` (when present), and an `.chezmoiexternal.toml`
     holding only that entry. Rewrite its `url` line to `url = "file://$T/case-N/fixture.tar.gz"`.
  2. **Fixture tarball.** It has a top directory `<repo>-<sha>/`. The layout for `clarity`
     (a `case` statement keyed by name; any other name FAILs with
     "no fixture for <name>: add one") is one file each:
     - at the top: `SKILL.md`, `LICENSE`, `README.md`, `DESIGN.md`, `PRODUCT.md`,
       `netlify.toml`, `skills.sh.json`, `.gitignore`
     - in directories: `.claude/launch.json`, `.github/workflows/validate.yml`,
       `commands/clarity-review.md`, `evals/e.md`, `references/edit.md`,
       `references/review.md`, `samples/s.md`, `scripts/prose_stats.py`,
       `scripts/strip_markdown.py`, `site/index.html`
  3. **Destination.** `$T/case-N/home`, pre-seeded with `.agents/skills/basecamp/SKILL.md`
     and `.claude/skills/cross-review/SKILL.md` (the content `sentinel`).
  4. **First apply.**
     `chezmoi --config <empty file> --source … --destination … --cache $T/case-N/cache --persistent-state $T/case-N/state.db apply --force </dev/null`.
  5. **Exact file set.** `find home/.agents/skills/<name> -type f` (relative, sorted) equals
     `LICENSE`, `SKILL.md`, `references/edit.md`, `references/review.md`,
     `scripts/prose_stats.py`, `scripts/strip_markdown.py`.
  6. **Stale-file removal.** Touch `home/.agents/skills/<name>/stale.md`, apply again, and
     check it is gone.
  7. **Siblings.** Both sentinels still exist with the content `sentinel`.
  8. **The link.** `readlink home/.claude/skills/<name>` is exactly
     `../../.agents/skills/<name>`, and `home/.claude/skills/<name>/SKILL.md` is readable
     through it.

  The harness never touches the network: the only URL it applies is the fixture's
  `file://`.

  **Cases** (each `_pass`/`_fail`):
  - the production `.chezmoiexternal.toml`, `.chezmoiignore` and `dot_claude/skills`:
    `static_ok` 0, `behaviour_ok` 0
  - **negative**, each mutating a copy and expecting a non-zero return:
    - url → `…/archive/main.tar.gz` (static)
    - an added `refreshPeriod = "168h"` (static)
    - include → `["*/LICENSE"]` (behaviour)
    - include → `["**"]` (behaviour)
    - the `exact = true` line deleted (behaviour)
    - `symlink_<name>` absent (behaviour)
    - the `!.claude/skills/<name>` line deleted from the ignore copy (behaviour)

- [ ] **Step 2: Run it and see it fail.** Run `./tests/agent-skills.test.sh` (sandboxed).
  Expected: exit 2, "missing … .chezmoiexternal.toml".

- [ ] **Step 3: Create `.chezmoiexternal.toml`, `symlink_clarity` and the two
  `.chezmoiignore` lines.** Copy the spec's TOML block verbatim, including `# v0.2.1` above
  `url`.

- [ ] **Step 4: Run it and see it pass.** Run `./tests/agent-skills.test.sh` (sandboxed).
  Expected: every case PASS, exit 0.

- [ ] **Step 5: Hand back.** Report the changed files and the suite's passed/total. The
  controller commits as
  `Install Clarity as a pinned chezmoi external with a Claude Code symlink`.

---

### Task 2: Cold-cache handling in the three `chezmoi managed` suites

**Depends on:** Task 1, which created `tests/agent-skills.test.sh`, and the controller's
cache warm-up.

**Files:**
- Modify: `tests/codex-config.test.sh:223` (section J)
- Modify: `tests/claude-settings.test.sh:641`
- Modify: `tests/live-feedback-skill.test.sh:34`
- Modify: `tests/agent-skills.test.sh` (add a section at the end, before `RESULT`)

**Interfaces:**
- **Consumes:** the warm-cache command from Global Constraints.
- **Produces:** on a failing `chezmoi managed`, each of the three suites writes exactly
  these two lines to stderr and exits 2:
  ```
  INCONCLUSIVE: chezmoi managed failed: <chezmoi's first stderr line>
    a cold external cache does this; warm it outside the sandbox: command chezmoi --source <SRC> managed >/dev/null
  ```
  `<SRC>` is the suite's repository-root variable. Each suite keeps its existing `chezmoi`
  arguments; only stderr handling and the failure branch change.

**Steps:**

- [ ] **Step 1: Write the failing section in `tests/agent-skills.test.sh`** ("cold external
  cache").
  - Resolve the real binary with `command -v chezmoi`.
  - Write `$T/stub/chezmoi`. When `managed` is among its arguments, it prints
    `chezmoi: Get "https://github.com/x/y/archive/0.tar.gz": tls: failed to verify certificate: x509: OSStatus -26276`
    to stderr and exits 1. Otherwise it `exec`s the real binary with the same arguments.
  - For each of `codex-config`, `claude-settings` and `live-feedback-skill`, run
    `PATH="$T/stub:$PATH" "$SRC/tests/<suite>.test.sh"` and capture stdout, stderr and the
    exit status.
  - Assert three things: the exit is 2; stderr contains
    `INCONCLUSIVE: chezmoi managed failed: chezmoi: Get` and
    `command chezmoi --source $SRC managed >/dev/null`, with `$SRC` expanded and unquoted,
    exactly as the suites print it; and stdout has no `FAIL:` line mentioning
    `chezmoi-managed` or `chezmoi manages`.

- [ ] **Step 2: Run it and see it fail.** Run `./tests/agent-skills.test.sh`. Expected: the
  three new cases FAIL (each suite currently reports per-target FAILs and exits 1).

- [ ] **Step 3: Change the three suites.** Send `chezmoi … managed` stderr to a file under
  the suite's temp dir (`live-feedback-skill` has `$T`, `codex-config` has `$T`, and
  `claude-settings` gets a `mktemp` if it has none). On a non-zero exit, print the two
  lines above and `exit 2`.

- [ ] **Step 4: Run them and see them pass.**
  - `./tests/agent-skills.test.sh`: every case PASS.
  - `./tests/codex-config.test.sh`, `./tests/claude-settings.test.sh` and
    `./tests/live-feedback-skill.test.sh`: each exits 0 with the cache warm.

- [ ] **Step 5: Hand back.** The controller commits as
  `Report a cold chezmoi external cache as inconclusive, not as missing targets`.

---

### Task 3: `.scripts/skill-updates.sh` and its suite

**Depends on:** none. It uses its own fixtures in Task 1's entry format.

**Files:**
- Create: `.scripts/skill-updates.sh` (mode 755, `#!/usr/bin/env bash`, Bash 3.2)
- Create: `tests/skill-updates.test.sh` (mode 755)

**Interfaces:**
- **Consumes:** the entry format from Task 1.
- **Produces:** `.scripts/skill-updates.sh [--open-issues] [--externals PATH]`.
  - **Input:** `PATH` defaults to `<script dir>/../.chezmoiexternal.toml`. Only
    `.agents/skills/<name>` entries are read. The owner, repo and SHA come from the URL. The
    pinned label is the `# vX` comment directly above `url`, else the first 7 characters of
    the SHA.
  - **Latest:** `gh api repos/<o>/<r>/releases/latest --jq .tag_name` gives the tag, and
    `gh api repos/<o>/<r>/commits/<tag> --jq .sha` gives its commit (this endpoint peels an
    annotated tag; measured 2026-10-21 on `v0.2.1`, which gave `e27ceef…`). If the
    releases call fails with `HTTP 404` on stderr, it falls back to
    `gh api repos/<o>/<r>/commits/HEAD --jq .sha`, with the new label being the 7-character
    short SHA. Any other failure is an error.
  - **stdout:** one line per skill, `current: <name> <pinned label>` or
    `update: <name> <pinned label> → <new label> https://github.com/<o>/<r>/compare/<pinned sha>...<new sha>`.
  - **stderr:** diagnostics, prefixed `skill-updates: `.
  - **Validation of every `gh` answer:** a commit must match `^[0-9a-f]{40}$`, and a tag
    must be non-empty with no whitespace. Anything else (empty, `null`, a non-SHA string) is
    an error for that skill, which then gets neither a `current:` nor an `update:` line.
  - **Exit, default mode:** 0 when everything is current, 1 when any update exists, 2 on any
    error (no `gh`, a `gh` failure other than the 404 fallback, an answer that fails
    validation, an unparseable entry, zero entries, an unknown option). An error is never
    printed as `current:`.
  - **`--open-issues`:** computes the same results, then for the updates:
    1. `gh label create skill-update --color 0E8A16 --description "A pinned agent skill has a newer upstream release" --force`
    2. `gh issue list --label skill-update --state open --limit 200 --json title --jq '.[].title'`
    3. for each update whose title `Skill update: <name> <new label>` is not in that list:
       `gh issue create --title <title> --label skill-update --body <body>`

    It makes no label or issue calls when there are no updates. If the label or the list
    call fails, it creates no issue at all, because without the existing titles it cannot
    dedupe. It exits 2 in that case.

    Exit: 0 when every update has an open issue (or there are none), 2 if any lookup,
    label, list or create call failed. A failed lookup for one skill still lets issues be
    filed for the skills it could resolve.
  - **The issue body**, with substitutions:
    ```
    <name> has a newer upstream release: <pinned label> → <new label>.

    Compare: <compare URL>

    - [ ] Read the diff, especially SKILL.md, references/ and every script.
    - [ ] On a branch, change the SHA and its tag comment in .chezmoiexternal.toml; put `Closes #<this issue>` in the commit message.
    - [ ] Warm chezmoi's cache outside the sandbox: `command chezmoi --source <checkout> managed >/dev/null`.
    - [ ] Confirm `command chezmoi --source <checkout> managed` lists `.agents/skills/<name>/SKILL.md`.
    - [ ] After merge: `chezmoi apply`.
    ```

**Steps:**

- [ ] **Step 1: Write `tests/skill-updates.test.sh`.**
  - Exit 2 if the script is missing.
  - Stub `gh` on `PATH`, keyed on `"$*"`. It serves `releases/latest`, `commits/<ref>`,
    `label create`, `issue list` and `issue create` from per-case environment variables
    (body, exit code and stderr text), and appends every call to `$CALLS`, in the style of
    `tests/reconcile-agents.test.sh`.
  - Invoke the script as `/bin/bash "$SCRIPT" --externals "$T/externals.toml" …`.
  - **Fixture SHAs:** the pin `P=e27ceeff60368cf6966b4ea00a5b9b36418ee9a0`, a newer release
    commit `B` (40 × `b`), and a HEAD commit `C` (40 × `c`).
  - **Cases, default mode:**
    - the pin equals the release commit: stdout `current: clarity v0.2.1`, exit 0
    - a newer release `v0.3.0` → `B`: stdout
      `update: clarity v0.2.1 → v0.3.0 https://github.com/addyosmani/clarity/compare/$P...$B`,
      exit 1
    - releases 404 (stderr `gh: Not Found (HTTP 404)`, exit 1) and HEAD `C`: stdout
      `update: clarity v0.2.1 → ccccccc …`, exit 1
    - releases fail with `HTTP 502`: exit 2, and no `current:` line
    - `gh` returns empty stdout with exit 0: exit 2
    - the commit lookup returns `null`, or `not-a-sha`, with exit 0: exit 2, and that skill
      has no `current:` or `update:` line
    - the release lookup returns `null` with exit 0: exit 2
    - `gh` absent from `PATH`: exit 2
    - an entry whose URL isn't a GitHub archive URL: exit 2
    - no tag comment: the pinned label is `e27ceef`
    - two entries, one current and one stale: exit 1, and only the stale one has `update:`
    - an unknown option: exit 2
  - **Cases, `--open-issues`** (assert on `$CALLS`):
    - an update, the label absent and no open issues: `label create skill-update` is
      recorded before `issue create`; the title is `Skill update: clarity v0.3.0`; the body
      contains the compare URL and
      `lists \`.agents/skills/clarity/SKILL.md\``; exit 0
    - an open issue `Skill update: clarity v0.3.0` exists: no `issue create`, exit 0
    - an open issue `Skill update: clarity v0.2.9` exists: `issue create` is called, exit 0
    - `label create` fails: exit 2, and no `issue create`
    - `issue list` fails: exit 2, and no `issue create`
    - `issue create` fails: exit 2
    - two entries, one update and one whose commit lookup returns `not-a-sha`: an issue is
      created for the update only, exit 2
    - every pin current: no `label`/`issue` calls, exit 0

- [ ] **Step 2: Run it and see it fail.** Run `./tests/skill-updates.test.sh`. Expected:
  exit 2, "missing … skill-updates.sh".

- [ ] **Step 3: Write `.scripts/skill-updates.sh`** to the interface above, with a header
  comment stating its contract and exit codes, in the style of
  `.scripts/preflight-ssh-agent.sh`. Use `gh`'s `--jq`, so there is no `jq` dependency.
  Capture stdout and stderr separately, because a 404 prints its JSON body on stdout.

- [ ] **Step 4: Run it and see it pass.** Run `./tests/skill-updates.test.sh`. Expected:
  every case PASS, exit 0.

- [ ] **Step 5: Live check (sandboxed, real `gh`).** Run `.scripts/skill-updates.sh`.
  Expected: `current: clarity v0.2.1`, exit 0. Run it only after Task 1's
  `.chezmoiexternal.toml` exists. In Batch A, the controller runs it instead.

- [ ] **Step 6: Hand back.** The controller commits as
  `Add a skill update check that reports new releases`.

---

### Task 4: Weekly workflow and AGENTS.md

**Depends on:** Task 3 (`tests/skill-updates.test.sh` and the CLI).

**Files:**
- Create: `.github/workflows/skill-updates.yml`
- Modify: `tests/skill-updates.test.sh` (add a static-checks section)
- Modify: `AGENTS.md`. Add a Rules bullet (spec, "Updating a skill", last paragraph) that
  also names the `SKILL.md` confirmation. In the Layout block, add
  `.chezmoiexternal.toml    # pinned third-party skills (archive externals)` and
  `.github/workflows/       # CI: the weekly skill-update check (ignored)`.

**Interfaces:**
- **Consumes:** `.scripts/skill-updates.sh --open-issues`, exit 0 or 2, and the
  `GH_TOKEN`/`GH_REPO` environment that `gh` reads.

**Steps:**

- [ ] **Step 1: Write the failing static section in `tests/skill-updates.test.sh`.**
  - The file exists.
  - The `permissions:` block (lines up to the next top-level key) is exactly
    `contents: read` and `issues: write`.
  - Every `uses:` matches `@[0-9a-f]{40}`.
  - There is a `schedule:` with a `cron:`, and a `workflow_dispatch:`.
  - A `run:` line invokes `.scripts/skill-updates.sh --open-issues`.
  - The checkout step sets `persist-credentials: false`.

- [ ] **Step 2: Run it and see it fail.** Run `./tests/skill-updates.test.sh`. Expected:
  the new cases FAIL.

- [ ] **Step 3: Write the workflow.**
  - `name: skill-updates`
  - Triggers: `schedule` with `cron: "17 6 * * 1"`, plus `workflow_dispatch`.
  - Top-level `permissions` as above.
  - One job, `check`, on `ubuntu-latest`, with two steps:
    1. the pinned checkout with `persist-credentials: false`
    2. `run: .scripts/skill-updates.sh --open-issues`, with `GH_TOKEN: ${{ github.token }}`
       and `GH_REPO: ${{ github.repository }}`

  Then add the AGENTS.md lines.

- [ ] **Step 4: Run it and see it pass.** Run `./tests/skill-updates.test.sh`. Expected:
  every case PASS.

- [ ] **Step 5: Hand back.** The controller commits as
  `Run the skill update check weekly and document third-party skills`.
